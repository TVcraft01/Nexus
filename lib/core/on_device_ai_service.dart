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

import 'package:flutter/foundation.dart' show debugPrint;

import 'llm.dart';
import 'local_ai_service.dart';
import 'on_device_model.dart';

/// What the on-device model is told it is.
///
/// Short on purpose: a 0.5B model spends its attention on the instruction, and
/// three rules are enough for a chat shell — be brief, be private, do not claim
/// to have done something. Actions are the command layer's job; a small model
/// that starts inventing them is worse than one that says it does not know.
const String kNexusOnDeviceSystemPrompt =
    'You are Nexus, a private assistant running on this device. '
    'Answer in two or three short sentences. '
    'Never claim to have performed an action; you can only talk.';

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
class OnDeviceAiService implements LocalAiService {
  OnDeviceAiService({
    OnDeviceModel model = const OnDeviceModel(),
    Llm? llm,
    this.system = kNexusOnDeviceSystemPrompt,
    this.maxTokens = 220,
  }) : _model = model,
       _llm = llm ?? Llm(model: model.model, modelsDir: model.directoryFor);

  final OnDeviceModel _model;
  final Llm _llm;

  /// The persona and the rules, as the model's system turn.
  final String system;

  /// How long an answer may be. Small enough that a 0.5B model finishes while
  /// the user is still looking at "Thinking…".
  final int maxTokens;

  /// The file this brain answers from — the Settings row reports the same one.
  OnDeviceModel get model => _model;

  /// True when a model file is on disk. Cheap, and never a load.
  Future<bool> isModelPresent() => _model.isPresent();

  /// Fetches the model, reporting progress from 0 to 1. See
  /// [OnDeviceModel.download]: the bytes and their hash are [Llm]'s business.
  Future<bool> download({void Function(double progress)? onProgress}) =>
      _model.download(onProgress: onProgress);

  /// Frees the weights and deletes the file, answering how many bytes went.
  Future<int> delete() async {
    await _llm.unload();
    return _model.delete();
  }

  /// Releases the engine for good. The file stays.
  Future<void> dispose() => _llm.dispose();

  /// Answers [prompt] from this device, or throws.
  ///
  /// The file check comes first and is the only thing between a missing model
  /// and a 470 MB surprise download: [Llm] starts a fetch on its own when it is
  /// asked to answer without a file, and that is the right behaviour for a
  /// first-run warm-up, not for a question the user is waiting on. Ask the
  /// user's permission with the download button, not with a message.
  @override
  Future<String> generateResponse(String prompt) async {
    if (!await _model.isPresent()) throw const ModelNotFoundException();
    String answer;
    try {
      answer = await _llm.complete(
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
      throw _llm.status == LlmStatus.unavailable
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
  Stream<String> generateResponseStream(String prompt) async* {
    if (!await _model.isPresent()) throw const ModelNotFoundException();
    bool answered = false;
    try {
      await for (final String piece in _llm.completeStream(
        prompt,
        system: system,
        maxTokens: maxTokens,
      )) {
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
    throw _llm.status == LlmStatus.unavailable
        ? const OnDeviceAiException(
            'The on-device model could not be loaded on this device.',
          )
        : const OnDeviceAiException(
            'The on-device model did not answer. Try again.',
          );
  }
}
