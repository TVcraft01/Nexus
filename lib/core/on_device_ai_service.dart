// The brain behind the seam, running on this device: a GGUF file in the app's
// documents, loaded through llama.cpp by [Llm], asked one prompt at a time.
//
// This is the implementation [LocalAiService] was cut for. The PC's Ollama is
// fast and good and gone the moment the phone leaves the house; this one has no
// network, no account, and no address to be wrong — only a file that may or may
// not be there. Those two states are the whole contract:
//
//   * the file is missing: [ModelNotFoundException]. Not a crash, not a silent
//     "I don't know" — a specific failure the chain above can act on, because
//     "there is no model on this phone" is exactly the case a PC on the same
//     Wi-Fi should be allowed to cover;
//   * the file is there and the model cannot answer: [OnDeviceAiException].
//
// Both are failures of *this brain*, never of the shell: the caller decides
// whether to fall back or to show a sentence. [LocalAiService.current] is where
// that decision lives (on-device first, then the PC), which is the reason this
// file knows nothing about Ollama.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import 'brain.dart' show ChatTurn;
import 'llm.dart';
import 'local_ai_service.dart';
import 'on_device_model.dart';
import 'system_actions.dart' show kSystemActionRules;

/// What the on-device model is told it is.
///
/// Short on purpose: a 0.5B model spends its attention on the instruction, and
/// three rules are enough for a chat shell — be brief, be private, do not claim
/// to have done something. The third rule is the one [kSystemActionRules]
/// makes possible to keep: the model may *ask* the phone to act, and the shell
/// is what acts and says so, so the model never has to lie about its own hands.
const String kNexusOnDeviceSystemPrompt =
    'You are Nexus, a private assistant running on this device. '
    'Answer in two or three short sentences. '
    'Never say you did something yourself — the app does it and tells them.';

/// The rules the model runs under: the persona above, then the five actions it
/// may ask for.
///
/// One constant rather than a concatenation at each call site, because the two
/// brains must be offered the same vocabulary — see [systemWithActions] in
/// `system_actions.dart` for the same composition on the PC's side.
const String kNexusOnDeviceSystem =
    '$kNexusOnDeviceSystemPrompt\n\n$kSystemActionRules';

/// A failure of the on-device brain, with a sentence fit to show.
///
/// Everything this file throws is one of these (or its subclass
/// [ModelNotFoundException]), the way [OllamaService] throws exactly
/// [OllamaException]: a caller that has to tell a native-library error from a
/// missing file to write a sentence will get it wrong once and show a stack
/// trace to a user.
class OnDeviceAiException implements Exception {
  const OnDeviceAiException(this.message);

  /// What to put on screen, or in a log. Always a whole sentence.
  final String message;

  @override
  String toString() => 'OnDeviceAiException: $message';
}

/// What a streamed answer that stops says where it stopped.
///
/// The words already on screen are kept — they are the model's — and this one
/// sentence is appended, which is why it reads as an ending rather than as a
/// notice: "…stops mid-answer." is about the answer, not about the AI.
const String kOnDeviceStreamFailureText =
    'The on-device model stopped mid-answer.';

/// No model file on this device: the one failure a PC can cover.
///
/// Deliberately its own type rather than a message, because it is the only
/// on-device failure the fallback chain treats as "try the other brain" — a
/// model that is present but cannot load is a different fact, and the Settings
/// row says so.
class ModelNotFoundException extends OnDeviceAiException {
  const ModelNotFoundException()
    : super('No on-device model yet. Download one in Settings.');
}

/// The device's own model, as one implementation of [LocalAiService].
///
/// Construction is free: [Llm] loads lazily on the first question and drops the
/// weights after it has been idle, so holding one of these for the life of the
/// app costs nothing but the file check each answer starts with.
///
/// Two models can live on the disk, and this service follows the one selected in
/// [ModelChoice] rather than the one it was built with: the app builds one of
/// these for the life of the process, and a picker that only took effect after a
/// restart would be a picker that did nothing. Switching is the one place the
/// old engine is thrown away — leaving two sets of weights in a phone's memory
/// is how an app gets closed by Android.
class OnDeviceAiService implements LocalAiService {
  OnDeviceAiService({
    OnDeviceModel model = const OnDeviceModel(),
    Llm? llm,
    this.system = kNexusOnDeviceSystem,
    this.maxTokens = 220,
  }) : _deviceModel = model,
       _fixedEngine = llm;

  final OnDeviceModel _deviceModel;

  /// An engine the caller supplied — a test's fake runtime, which must be used
  /// for every model. Null in the app, where the engine is built per selection.
  final Llm? _fixedEngine;

  /// The engine for the model that was selected when it was built. Rebuilt
  /// (and the old one disposed) the first time the selection changes.
  Llm? _engine;
  OnDeviceModelChoice? _engineChoice;

  /// The persona and the rules, as the model's system turn.
  final String system;

  /// How long an answer may be. Small enough that a 0.5B model finishes while
  /// the user is still looking at "Thinking…".
  final int maxTokens;

  /// The file this brain answers from — the Settings row reports the same one.
  OnDeviceModel get model => _deviceModel;

  /// Starts reading the stored selection, without waiting for it.
  ///
  /// The read is a preference, which on a phone is a platform channel, and the
  /// first question of a session must not block on one: before the read lands
  /// this answers from the default model, which is the file the check is about
  /// to look for anyway. `main()` starts the same read before the first frame,
  /// so a restart answers with the picked model and not with the default — the
  /// wait is paid at launch, where nothing is being typed.
  void _warmChoice() {
    unawaited(ModelChoice.instance.ensureLoaded());
  }

  /// The engine for the selected model, built on first use.
  Future<Llm> _current() async {
    final Llm? fixed = _fixedEngine;
    if (fixed != null) return fixed;
    _warmChoice();
    final OnDeviceModelChoice choice = _deviceModel.choice;
    final Llm? engine = _engine;
    if (engine != null && _engineChoice == choice) return engine;
    // A different model: free the old weights *before* loading the new ones.
    // Both at once is 1.2 GB, which a phone answers by killing the app.
    _engine = null;
    _engineChoice = null;
    if (engine != null) await engine.dispose();
    final Llm built = Llm(model: _deviceModel.model, modelsDir: _deviceModel.directoryFor);
    _engine = built;
    _engineChoice = choice;
    return built;
  }

  /// True when a model file is on disk. Cheap, and never a load.
  Future<bool> isModelPresent() async {
    _warmChoice();
    return _deviceModel.isPresent();
  }

  /// Fetches the model, reporting progress from 0 to 1. See
  /// [OnDeviceModel.download]: the bytes and their hash are [Llm]'s business.
  Future<bool> download({void Function(double progress)? onProgress}) async {
    _warmChoice();
    return _deviceModel.download(onProgress: onProgress);
  }

  /// Frees the weights and deletes the file, answering how many bytes went.
  ///
  /// Only ever the selected model's file: the picker may point this service at
  /// either one, and "Delete model" must not take the other one with it.
  Future<int> delete() async {
    _warmChoice();
    await _engine?.unload();
    return _deviceModel.delete();
  }

  /// Releases the engine for good. The file stays.
  Future<void> dispose() async {
    final Llm? engine = _engine;
    _engine = null;
    _engineChoice = null;
    if (engine != null) await engine.dispose();
    await _fixedEngine?.dispose();
  }

  /// Answers [prompt] from this device, or throws.
  ///
  /// The file check comes first and is the only thing between a missing model
  /// and a 470 MB surprise download: [Llm] starts a fetch on its own when it is
  /// asked to answer without a file, and that is the right behaviour for a
  /// first-run warm-up, not for a question the user is waiting on. Ask the
  /// user's permission with the download button, not with a message.
  @override
  Future<String> generateResponse(String prompt) async {
    _warmChoice();
    if (!await _deviceModel.isPresent()) throw const ModelNotFoundException();
    final Llm llm = await _current();
    String answer;
    try {
      answer = await llm.complete(
        prompt,
        system: system,
        maxTokens: maxTokens,
      );
    } on Object catch (e) {
      // A native library that is not there, a model llama.cpp refuses: the
      // runtime has already been honest in its log, and the user gets one
      // sentence instead.
      debugPrint('AI: on-device generation failed ($e)');
      throw const OnDeviceAiException('The on-device model stopped answering.');
    }
    final String trimmed = answer.trim();
    if (trimmed.isEmpty) {
      // Two different silences: a model that could not come up at all, and one
      // that came up and said nothing. Only the first is worth telling the user
      // their device cannot run this.
      throw llm.status == LlmStatus.unavailable
          ? const OnDeviceAiException(
              'The on-device model could not be loaded on this device.',
            )
          : const OnDeviceAiException(
              'The on-device model did not answer. Try again.',
            );
    }
    return trimmed;
  }

  /// Answers [prompt] from this device, a word at a time.
  ///
  /// The same two guards as [generateResponse] — the file must be there, and a
  /// model that says nothing is a failure — plus one the one-shot shape cannot
  /// have: a stream that dies *after* some words reached the screen throws
  /// [kOnDeviceStreamFailureText] rather than the generic sentence, because the
  /// caller has already shown those words and "it stopped" is the true story.
  /// A failure before the first word is the same failure the one-shot path
  /// reports, so the fallback chain can still cover it with the PC.
  @override
  Stream<String> generateResponseStream(
    String prompt, {
    List<AiTurn> history = const <AiTurn>[],
  }) async* {
    _warmChoice();
    if (!await _deviceModel.isPresent()) throw const ModelNotFoundException();
    final Llm llm = await _current();
    bool answered = false;
    try {
      // With history this is a chat, not a question: the model is handed the
      // turns it was told to remember and then this one, in the same message
      // list the runtime's own template expects. Without history it is the one
      // prompt it has always been — the same call, so a brain asked a single
      // question behaves exactly as it did before this parameter existed.
      final Stream<String> pieces = history.isEmpty
          ? llm.completeStream(prompt, system: system, maxTokens: maxTokens)
          : llm.completeChatStream(
              system: system,
              history: <ChatTurn>[
                for (final AiTurn turn in history) turn.chatTurn,
                (role: 'user', content: prompt),
              ],
              maxTokens: maxTokens,
            );
      await for (final String piece in pieces) {
        if (piece.isEmpty) continue;
        answered = true;
        yield piece;
      }
    } on Object catch (e) {
      debugPrint('AI: on-device streaming failed ($e)');
      throw answered
          ? const OnDeviceAiException(kOnDeviceStreamFailureText)
          : const OnDeviceAiException('The on-device model stopped answering.');
    }
    if (answered) return;
    // Nothing arrived and nothing threw: the model could not come up, or it came
    // up and said nothing. Same two silences as [generateResponse].
    throw llm.status == LlmStatus.unavailable
        ? const OnDeviceAiException(
            'The on-device model could not be loaded on this device.',
          )
        : const OnDeviceAiException(
            'The on-device model did not answer. Try again.',
          );
  }
}
