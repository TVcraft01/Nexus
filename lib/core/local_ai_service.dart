// The brain the shell talks to — one prompt in, one answer out.
//
// This interface exists because the answer comes from more than one place. The
// device's own model is the first choice: no network, no account, and it works
// on a train. The PC's Ollama is the second: faster and better, but only when
// the phone is on the same Wi-Fi. When neither can answer there is no brain at
// all, and the shell says so in a sentence.
//
// That decision lives here, once, instead of as a branch in every `_send`: the
// screens ask [current] for a brain, and [FallbackAiService] walks the two
// candidates in order. Which brain answered is not a thing a screen needs to
// know — the on-device model and the PC both return a string or throw.
//
// What the interface deliberately does *not* carry: chat history, tools, or a
// timeout. Those are decisions for an implementation — the PC's Ollama does one
// request with a 30-second timeout and no memory, the on-device engine keeps its
// own queue and idle unload. A seam that prescribed them would be a seam the
// second implementation has to fight.
//
// Streaming is carried twice on purpose. [generateResponseStream] is the shape a
// chat bubble wants and the one both screens use; [generateResponse] stays as the
// whole-answer shape, because the one-shot form is the honest way to state "ask
// and wait", and because a brain that cannot stream (a future third one, a test
// fake) can implement it in terms of the one method it already has.
library;

import 'package:flutter/foundation.dart' show debugPrint, immutable;

import 'brain.dart' show ChatTurn;
import 'ollama_service.dart';
import 'on_device_ai_service.dart';

/// One earlier exchange, as a brain that is being asked to remember it needs.
///
/// Deliberately the smallest thing that can carry a conversation: who spoke and
/// what they said. No ids, no timestamps, no per-turn options — a brain that
/// wanted any of those would be asking the screen for something the screen does
/// not have, and a screen that had to build them would be inventing them.
///
/// [fromUser] rather than a role string for the same reason the rest of this
/// file uses booleans: a typo in `'assistant'` would be a silent third role, and
/// there is no third role.
@immutable
class AiTurn {
  const AiTurn({required this.fromUser, required this.text});

  const AiTurn.user(this.text) : fromUser = true;

  const AiTurn.assistant(this.text) : fromUser = false;

  /// True for the user's own words, false for the brain's.
  final bool fromUser;

  /// What was said, as it was said. Never empty: a turn nobody said anything in
  /// is not history, it is a gap, and callers drop those before they get here.
  final String text;

  /// The shape the on-device engine's own seam speaks.
  ChatTurn get chatTurn => (role: fromUser ? 'user' : 'assistant', content: text);

  @override
  String toString() => 'AiTurn(${fromUser ? 'user' : 'assistant'}: $text)';
}

/// How many earlier messages a brain is shown.
///
/// A conversation is context, and context is memory: every turn handed to the
/// model is tokens it holds in a KV cache a phone has a couple of thousand of.
/// Ten is a few exchanges — enough for "and tomorrow?" to have a referent,
/// small enough that a long conversation cannot walk a 0.5B model off the end
/// of its context and turn a good answer into a truncated one.
const int kAiHistoryLimit = 10;

/// [turns] as a brain should be handed them: at most [limit] of the most recent
/// ones, and never starting on the assistant's own words.
///
/// The second rule is what keeps a chat template honest. Templates are built
/// around a conversation that starts with the user — Qwen's ChatML, Llama's
/// headers, Ollama's own renderer — and a message list that opens with an
/// assistant turn is one some of them refuse and others quietly mis-render.
/// Trimming from the front may therefore drop one turn more than [limit] asks
/// for.
List<AiTurn> trimAiHistory(List<AiTurn> turns, {int limit = kAiHistoryLimit}) {
  final List<AiTurn> recent =
      turns.length <= limit ? turns : turns.sublist(turns.length - limit);
  var start = 0;
  while (start < recent.length && !recent[start].fromUser) {
    start++;
  }
  return start == 0 ? recent : recent.sublist(start);
}

/// What the shell needs from a brain.
///
/// One method, because one thing is asked of it: given what the user said, say
/// something back. Failures are part of the contract — `generateResponse`
/// throws (a [ModelNotFoundException], an [OllamaException], any implementation's
/// own exception), and the caller turns that into a sentence on screen rather
/// than a crash. A brain that answered `null` for "I could not" would push that
/// distinction into every caller, which is the thing this interface exists to
/// avoid.
abstract class LocalAiService {
  /// Test seam: the brain a test wants the shell to use.
  ///
  /// A static override rather than an injected dependency because the callers
  /// are widget state — a screen's `_send` and a live turn's answer — and
  /// neither has a constructor to take one through. It is the same shape the
  /// microphone and the speaker already use, which is the point: a test that
  /// fakes the AI reads like a test that fakes the microphone.
  static LocalAiService Function()? override;

  /// The memoised default so the app holds one engine, not one per message.
  ///
  /// An on-device model that was rebuilt for every question would reload 470 MB
  /// of weights each time; [OnDeviceAiService] is cheap to hold and expensive to
  /// recreate, so the chain is built once.
  static LocalAiService? _default;

  /// The brain the shell uses: the fake in a test, the real chain in the app.
  ///
  /// Device first, PC second ([FallbackAiService]), because the device is the
  /// one that is always there. Every screen gets the fallback for free — none of
  /// them has to know which brain answered, and none of them changed when the
  /// on-device engine arrived.
  static LocalAiService get current =>
      override?.call() ??
      (_default ??= FallbackAiService(
        onDevice: OnDeviceAiService(),
        pc: const OllamaService(),
      ));

  /// Forgets the memoised chain. Tests use this after pointing the on-device
  /// model at a temp directory; the app never calls it.
  static void resetDefault() => _default = null;

  /// Answers [prompt], or throws.
  Future<String> generateResponse(String prompt);

  /// The same answer, as it is written.
  ///
  /// This is the shape a chat bubble wants: the first piece arrives while the
  /// model is still thinking, so a screen that used to say "Thinking…" for ten
  /// seconds can show the answer growing instead. A brain that has nothing to
  /// stream yields its whole answer as one piece ([OllamaService] does exactly
  /// that today); the on-device engine yields real tokens.
  ///
  /// The contract mirrors [generateResponse]: a brain that cannot answer at all
  /// throws, and a brain that stops after it has already yielded words throws
  /// too — the caller is showing those words, and it is the only one that can
  /// say the answer ended early. The stream ends when the answer does.
  ///
  /// [history] is what was said before [prompt], oldest first, and it exists for
  /// the one screen that has a conversation rather than a message: live mode,
  /// where the user speaks a reply to something they just heard and "it" would
  /// otherwise have no referent at all. It is optional because every other
  /// caller asks one question at a time — a chat bubble has the thread on
  /// screen, and the privacy promise here is that a brain is told what it needs
  /// and nothing more.
  Stream<String> generateResponseStream(
    String prompt, {
    List<AiTurn> history = const <AiTurn>[],
  });
}

/// The two brains, in the order the app trusts them.
///
/// The first answer wins: an on-device model that speaks is never second-guessed
/// by the PC, which is both the privacy promise and the reason the fallback is
/// invisible when it works. The PC is asked only when the device could not
/// answer at all — no model file ([ModelNotFoundException]), a model that could
/// not load, a model that returned nothing. Every other failure is logged and
/// treated the same way, because the user is waiting and the alternative to
/// trying the PC is a notice they cannot act on.
///
/// When both fail, the error is [OllamaException] carrying
/// [kNexusOllamaUnreachableText] — the one sentence the shell already knows how
/// to show as a red notice.
class FallbackAiService implements LocalAiService {
  const FallbackAiService({required this.onDevice, required this.pc});

  /// The device's own model. Asked first, always.
  final LocalAiService onDevice;

  /// The PC's Ollama. Asked only when [onDevice] could not answer.
  final LocalAiService pc;

  @override
  Future<String> generateResponse(String prompt) async {
    try {
      final String answer = await onDevice.generateResponse(prompt);
      if (answer.trim().isNotEmpty) return answer;
      // The contract says answer or throw; an empty answer is neither, and it
      // is not worth showing to a user who asked a question.
      debugPrint('AI: on-device answered with nothing; trying the PC');
    } on ModelNotFoundException catch (error) {
      debugPrint('AI: ${error.message} Trying the PC.');
    } on Object catch (error) {
      debugPrint('AI: on-device failed ($error); trying the PC');
    }

    try {
      return await pc.generateResponse(prompt);
    } on OllamaException {
      rethrow;
    } on Object catch (error) {
      // A PC seam that throws something other than its own exception is still
      // "the PC did not answer", which is the sentence the user can act on.
      debugPrint('AI: PC failed ($error)');
      throw const OllamaException(kNexusOllamaUnreachableText);
    }
  }

  /// The device's stream, and the PC's only when the device has said nothing.
  ///
  /// The one rule that makes streaming different from the one-shot chain: a
  /// failure *before the first token* is the device's failure, and the PC may
  /// cover it; a failure *after* words are on screen is this turn's failure, and
  /// switching brains mid-answer would hand the user two half-sentences instead
  /// of one with a straight account of what happened. The error is rethrown so
  /// the caller — which holds the words it has already shown — can append the
  /// sentence.
  @override
  Stream<String> generateResponseStream(
    String prompt, {
    List<AiTurn> history = const <AiTurn>[],
  }) async* {
    bool answered = false;
    try {
      await for (final String piece in onDevice.generateResponseStream(
        prompt,
        history: history,
      )) {
        if (piece.isEmpty) continue;
        answered = true;
        yield piece;
      }
      if (answered) return;
      // The contract says answer or throw; an empty stream is neither, and it
      // is not worth showing to a user who asked a question.
      debugPrint('AI: on-device answered with nothing; trying the PC');
    } on OnDeviceAiException catch (error) {
      if (answered) rethrow;
      debugPrint('AI: ${error.message} Trying the PC.');
    } on Object catch (error) {
      if (answered) rethrow;
      debugPrint('AI: on-device failed ($error); trying the PC');
    }

    try {
      await for (final String piece in pc.generateResponseStream(
        prompt,
        history: history,
      )) {
        yield piece;
      }
    } on OllamaException {
      rethrow;
    } on Object catch (error) {
      debugPrint('AI: PC failed ($error)');
      throw const OllamaException(kNexusOllamaUnreachableText);
    }
  }
}
