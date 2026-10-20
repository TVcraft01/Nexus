/// The AI this shell talks to when it needs words back: Ollama, on the user's
/// own PC, over the local network.
///
/// It is one implementation of [LocalAiService] — the brain behind the seam, and
/// the only one that exists today. It is deliberately not in the cloud. Nexus is
/// a local-first app — the mesh, the files, the microphone and the language model
/// all live on hardware the user owns — so a model running in somebody else's
/// datacenter would be a different product. Ollama is
/// the local model runner people already have, it speaks plain HTTP on
/// `11434`, and it needs no key, no account and no SDK: three facts that make it
/// the right seam for a shell that has to work with whatever the user already
/// installed.
///
/// ## Where the PC is
///
/// [kNexusOllamaHost] is the address, and it is a *compile-time* value on
/// purpose: this build has no settings row for it yet, and a wrong address here
/// fails the same way a switched-off PC does — visibly, with
/// [kNexusOllamaUnreachableText] — rather than silently. On the desktop build,
/// which runs on the same machine as Ollama, the default is right. On a phone it
/// has to be the PC's LAN address, which is a build argument:
///
/// ```
/// flutter run --dart-define=NEXUS_OLLAMA_HOST=http://192.168.1.100:11434
/// ```
///
/// ## What it does not do
///
/// No streaming (the shell shows the answer when it is whole, which is also what
/// makes the live page's "Thinking…" state honest), no chat history (each call
/// is one prompt, and the caller decides what goes in it), and no retries — a PC
/// that is not answering is not one to hammer, and the user is standing right
/// there reading the error.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'clock_context.dart' show nexusSystemWithClock;
import 'local_ai_service.dart';
import 'system_actions.dart' show kNexusReasoningRules, kSystemActionRules;

/// What the PC's model is told it is, before the action rules below.
///
/// The same three rules as the phone's own brain, in the same order, and with
/// the same promise: the app acts, the model asks. The wording differs in one
/// place — this model is not the one running on the user's phone — and that is
/// the kind of difference a model should be told rather than made to guess.
const String kNexusOllamaPersona =
    'You are Nexus, a private assistant. '
    'Answer in two or three short sentences. '
    'Never say you did something yourself — the app does it and tells them.';

/// [kNexusOllamaPersona] with the five actions this shell can run.
///
/// Sent as one system turn on `/api/chat` and as the `system` field on
/// `/api/generate`, so the PC's model is offered exactly the vocabulary the
/// phone's model is — the two brains answering differently about what they can
/// do is a bug the user would read as one of them lying.
const String kNexusOllamaSystem =
    '$kNexusOllamaPersona\n\n$kNexusReasoningRules\n\n$kSystemActionRules';

/// Where Ollama is expected to be listening.
///
/// The default is the desktop build's own machine. Override it for a phone with
/// `--dart-define=NEXUS_OLLAMA_HOST=http://<pc-ip>:11434`, or by constructing an
/// [OllamaService] with its own [OllamaService.baseUrl].
const String kNexusOllamaHost = String.fromEnvironment(
  'NEXUS_OLLAMA_HOST',
  defaultValue: 'http://localhost:11434',
);

/// The model asked for by default. Small enough to answer on a laptop CPU,
/// good enough to be worth wiring up.
const String kNexusOllamaModel = 'llama3.2';

/// What the user is told when no brain answered at all.
///
/// One sentence, said in one place, because three surfaces say it — the chat's
/// error bubble, the live page, and the Settings status row — and they must not
/// drift into three explanations of one failure. It used to promise the
/// on-device engine ("PC not found. On-device AI coming soon."); that engine is
/// here now, so the sentence names the two things the user can actually do:
/// download the model onto this device, or start the Ollama they already have.
///
/// The name is historical: this is the sentence for "no brain answered", which
/// is still the failure an unreachable Ollama produces — just not only that one.
const String kNexusOllamaUnreachableText =
    'No AI available. Download a model in Settings, or start Ollama on your PC.';

/// A failure with a sentence fit to show the user.
///
/// Everything that can go wrong on this seam arrives as one of these: a refused
/// connection, a timeout, an HTTP error status, a body that is not the JSON
/// Ollama promised. The callers ([HomeTab._answer] and the live page) do not
/// distinguish between them, because the user cannot act on the difference —
/// what they can act on is whether the PC answered at all.
class OllamaException implements Exception {
  const OllamaException(this.message);

  /// What to put on screen. Always one of the shared sentences in this file.
  final String message;

  @override
  String toString() => 'OllamaException: $message';
}

/// The PC's model, as one implementation of [LocalAiService].
///
/// It is the only one there is today, and it is deliberately an *implementation*
/// rather than the seam itself: the shell asks [LocalAiService.current] for a
/// brain, and this is what that getter answers with until an on-device engine
/// can take over when there is no PC on the network. The test seam lives on the
/// interface too ([LocalAiService.override]), so a widget test fakes the brain
/// and not this particular client.
class OllamaService implements LocalAiService {
  const OllamaService({
    this.baseUrl = kNexusOllamaHost,
    this.model = kNexusOllamaModel,
    this.timeout = const Duration(seconds: 30),
    this.client,
    this.system = kNexusOllamaSystem,
    this.clock,
    this.includeClock = true,
    this.includeMemory = true,
  });

  /// The PC and port, without a trailing slash (`http://192.168.1.100:11434`).
  final String baseUrl;

  /// The model name, exactly as `ollama list` spells it.
  final String model;

  /// How long to wait before giving up on the PC.
  ///
  /// Thirty seconds is generous for a small model on a laptop and still short
  /// enough that a phone which cannot reach the PC at all is told so while the
  /// user is still looking at the screen. The live page makes the wait visible
  /// ("Thinking…"), so the timeout is the user's patience rather than a
  /// progress bar's.
  final Duration timeout;

  /// The HTTP client, for the one test that wants to see the request itself.
  /// Null means "make one per call" — the app has no connection pool to keep,
  /// and a client that outlived the app's own lifetime would be one more thing
  /// to close.
  final http.Client? client;

  /// The system turn: who the model is and which actions it may ask for.
  ///
  /// A field rather than a constant baked into the request, because it is the
  /// part of the prompt the shell — not the user — owns, and a test asserting
  /// what the PC is told should not have to read it off the wire.
  final String system;

  /// The clock the system turn is built from, or null for [DateTime.now].
  ///
  /// A model has no clock of its own — asked the time it invents one — so the
  /// device's is appended to the system turn on every request. A field rather
  /// than a direct [DateTime.now] so a test can pin the sentence it asserts.
  final DateTime Function()? clock;

  /// Whether the clock is appended to [system]. Chat keeps it; the vision turn
  /// does not, because a picture question is not a question about today.
  final bool includeClock;

  /// Whether the app's remembered facts are appended to [system]. Chat keeps
  /// them; vision does not, for the same reason it has no clock.
  final bool includeMemory;

  /// The whole answer as one piece.
  ///
  /// Ollama is asked with `stream: false`, so the reply really is one JSON
  /// object — and this is where that becomes the stream contract rather than a
  /// special case in every caller. The shell's bubble grows on the first (and
  /// only) piece exactly as it does on the last token of a local model; turning
  /// this into a real NDJSON stream is a change to this method alone.
  @override
  Stream<String> generateResponseStream(
    String prompt, {
    List<AiTurn> history = const <AiTurn>[],
  }) async* {
    yield await generateResponse(prompt, history: history);
  }

  /// Whether the PC is answering at all, without asking it to think.
  ///
  /// `GET /api/tags` is Ollama's cheapest call — it lists the models rather
  /// than running one — so it is the right probe for a Settings row: a status
  /// line must not cost a generation. Never throws; two seconds is long enough
  /// for a PC on the same Wi-Fi and short enough that a phone with no PC does
  /// not leave the row spinning.
  Future<bool> isReachable({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    try {
      final http.Response response = await (client ?? http.Client())
          .get(Uri.parse('$baseUrl/api/tags'))
          .timeout(timeout);
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// `POST /api/generate`, one prompt in, one answer out.
  ///
  /// The payload is the plainest Ollama request there is:
  ///
  /// ```json
  /// {"model": "llama3.2", "prompt": "…", "system": "…", "stream": false}
  /// ```
  ///
  /// — and `stream: false` matters twice over: it makes Ollama answer with a
  /// single JSON object instead of a stream of them, and it is why the live
  /// page can show "Thinking…" and then a whole sentence rather than growing
  /// one word at a time.
  ///
  /// Throws [OllamaException] with a sentence fit to show, and never anything
  /// else: a caller that has to tell a `SocketException` from a `TimeoutException`
  /// to print a message is a caller that will get it wrong once and print a
  /// stack trace to a user.
  /// With [history], the same answer is asked for through `/api/chat` instead,
  /// with the earlier turns as messages.
  ///
  /// Two endpoints rather than one because they are two different requests, and
  /// the difference is visible in what the model does with them: `/api/generate`
  /// renders a bare prompt through the model's template, which is exactly right
  /// for a single question and wrong for a conversation — Ollama would have no
  /// idea which lines were the assistant's. A caller with nothing to remember
  /// therefore keeps the request it always made, byte for byte, and only live
  /// conversation pays for the richer one.
  @override
  Future<String> generateResponse(
    String prompt, {
    List<AiTurn> history = const <AiTurn>[],
  }) async {
    final bool chat = history.isNotEmpty;
    final Uri uri = Uri.parse('$baseUrl/api/${chat ? 'chat' : 'generate'}');
    // Built per request, not stored: the answer to "what time is it" has to be
    // the time now, not the time the service was constructed. A vision turn
    // opts out of the clock entirely.
    final String clocked = includeClock
        ? nexusSystemWithClock(system, now: clock?.call())
        : system;
    final String systemTurn = includeMemory
        ? LocalAiService.systemWithMemory(clocked)
        : clocked;
    final Map<String, Object?> payload = chat
        ? <String, Object?>{
            'model': model,
            'messages': <Map<String, String>>[
              <String, String>{'role': 'system', 'content': systemTurn},
              for (final AiTurn turn in history)
                <String, String>{
                  'role': turn.fromUser ? 'user' : 'assistant',
                  'content': turn.text,
                },
              <String, String>{'role': 'user', 'content': prompt},
            ],
            'stream': false,
          }
        : <String, Object?>{
            'model': model,
            'prompt': prompt,
            'system': systemTurn,
            'stream': false,
          };
    http.Response response;
    try {
      response = await (client ?? http.Client())
          .post(
            uri,
            headers: const <String, String>{'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(timeout);
    } on OllamaException {
      rethrow;
    } catch (_) {
      // Everything the transport can throw lands here — a refused connection
      // (Ollama not running, or a phone on the wrong network), a DNS failure,
      // a timeout, a client that was closed under us. They are one sentence to
      // the user, and the sentence names the two likeliest causes.
      throw const OllamaException(kNexusOllamaUnreachableText);
    }

    if (response.statusCode != 200) {
      throw OllamaException(
        'Local AI answered with an error (HTTP ${response.statusCode}). '
        'Check that "$model" is installed: ollama pull $model',
      );
    }

    final String text;
    try {
      final Object? decoded = jsonDecode(response.body);
      final Map<Object?, Object?>? body = decoded is Map ? decoded : null;
      // `/api/chat` answers under `message.content`, `/api/generate` under
      // `response`. One reader for both, so a change of endpoint is not a change
      // of error handling.
      final Object? answer = chat ? _messageContent(body) : body?['response'];
      if (answer is! String || answer.trim().isEmpty) {
        throw const OllamaException(
          'Local AI answered with nothing. Try again, or try a different model.',
        );
      }
      text = answer.trim();
    } on OllamaException {
      rethrow;
    } catch (_) {
      // A body that is not JSON at all: a proxy page, a captive-portal login, a
      // port on the PC that happens to be something else entirely.
      throw const OllamaException(kNexusOllamaUnreachableText);
    }
    return text;
  }

  /// The assistant's sentence inside a `/api/chat` body: `message: {content}`.
  /// Null for every shape that is not one, which the caller reports as the
  /// same "answered with nothing" a `/api/generate` body without `response`
  /// gets.
  static Object? _messageContent(Map<Object?, Object?>? body) {
    final Object? message = body?['message'];
    return message is Map ? message['content'] : null;
  }
}
