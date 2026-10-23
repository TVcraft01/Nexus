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
import 'dart:io' show File, Platform;

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import 'llama_cpp_backend.dart';
import 'llm.dart';
import 'local_ai_service.dart';
import 'on_device_model.dart';
import 'system_actions.dart'
    show
        kNexusCodeRules,
        kNexusMemoryRules,
        kNexusReasoningRules,
        kSystemActionRules,
        nexusSystemWithCapabilities;
import 'text_generation_backend.dart';

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

/// The rules the model runs under: the persona above, the actions it may ask
/// for, the code it must never refuse, and the memory tags the app reads back.
///
/// One constant rather than a concatenation at each call site, because the two
/// brains must be offered the same vocabulary — see [kNexusOllamaSystem] for
/// the same composition on the PC's side.
///
/// The artifact format is deliberately *not* here: whether it belongs depends on
/// the model that is about to load, and [nexusSystemWithCapabilities] appends it
/// per request.
const String kNexusOnDeviceSystem =
    '$kNexusOnDeviceSystemPrompt\n\n$kNexusReasoningRules\n\n'
    '$kSystemActionRules\n\n$kNexusCodeRules\n\n$kNexusMemoryRules';

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

/// A model that would not fit in memory right now.
///
/// Measured on the A25: asking the 1B model for an answer while the phone was
/// already under pressure is how the app was closed by the system — no
/// exception, no sentence, just the launcher. The weights have to fit beside
/// everything else the phone is holding, so this is checked *before* the engine
/// is built and thrown rather than attempted.
///
/// Its own type, and rethrown by [FallbackAiService] rather than swallowed into
/// the PC fallback, because the caller can do better than a generic failure:
/// switch to the smaller model the user has, or say which download would fit.
class InsufficientMemoryException extends OnDeviceAiException {
  const InsufficientMemoryException({
    required this.label,
    required this.neededBytes,
    required this.freeBytes,
  }) : super('Not enough memory to run $label.');

  /// The model that did not fit, as the picker names it.
  final String label;

  /// The room the guard asked for: [kModelMemoryHeadroom] times the file.
  final int neededBytes;

  /// What the device reported as available when the load was refused.
  final int freeBytes;

  @override
  String toString() =>
      'InsufficientMemoryException: $label needs $neededBytes bytes, '
      '$freeBytes available';
}

/// How much room a model needs beyond its own file, as a multiple of it.
///
/// 1.5× is the llama.cpp working set — the mmapped weights, the KV cache, and
/// the native allocations around them. A model loaded with exactly its file
/// size free is a model that loads and then gets the app killed mid-answer,
/// which is the failure this guard exists to turn into a sentence.
const double kModelMemoryHeadroom = 1.5;

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
class OnDeviceAiService implements LocalAiService, TextGenerationBackend {
  OnDeviceAiService({
    OnDeviceModel model = const OnDeviceModel(),
    Llm? llm,
    this.system = kNexusOnDeviceSystem,
    this.maxTokens = 220,
    this.clock,
    this.includeClock = true,
    this.includeMemory = true,
    TextGenerationBackend? backend,
  }) : _deviceModel = model,
       _fixedEngine = llm,
       _backend = backend ??
           (defaultBackendFactory?.call(
                 model: model,
                 llm: llm,
                 system: system,
                 maxTokens: maxTokens,
                 clock: clock,
                 includeClock: includeClock,
                 includeMemory: includeMemory,
               ) ??
               LlamaCppBackend(
                 model: model,
                 llm: llm,
                 system: system,
                 maxTokens: maxTokens,
                 clock: clock,
                 includeClock: includeClock,
                 includeMemory: includeMemory,
               ));

  final OnDeviceModel _deviceModel;

  /// An engine the caller supplied — a test's fake runtime, which must be used
  /// for every model. Null in the app, where the engine is built per selection.
  final Llm? _fixedEngine;

  final TextGenerationBackend _backend;

  /// Optional factory for creating the default text generation backend.
  static TextGenerationBackend Function({
    OnDeviceModel model,
    Llm? llm,
    String system,
    int maxTokens,
    DateTime Function()? clock,
    bool includeClock,
    bool includeMemory,
  })? defaultBackendFactory;

  /// The underlying text generation engine.
  TextGenerationBackend get backend => _backend;

  /// The persona and the rules, as the model's system turn.
  final String system;

  /// How long an answer may be. Small enough that a 0.5B model finishes while
  /// the user is still looking at "Thinking…".
  final int maxTokens;

  /// The clock the system turn is built from, or null for [DateTime.now].
  ///
  /// A field so a test can pin the sentence it asserts; the app leaves it null
  /// and every request is told the time it is being asked at.
  final DateTime Function()? clock;

  /// Whether the device's date and time are appended to [system].
  ///
  /// True for chat, where "what time is it" must never be guessed. False for
  /// the vision brain: a picture question has nothing to do with the clock, and
  /// a small model handed both answered the date instead of the picture.
  final bool includeClock;

  /// Whether the app's remembered facts are appended to [system].
  ///
  /// True for chat, false for the vision turn: a picture question has nothing
  /// to do with the user's name, and a 0.5B model given both answered the fact
  /// instead of the picture.
  final bool includeMemory;

  /// Test seam for the free-memory reading: null reads `/proc/meminfo`.
  ///
  /// Pointing this at a number is how the guard is tested without a phone under
  /// pressure — the alternative is a test that can only pass on a device that
  /// happens to be out of memory.
  @visibleForTesting
  static Future<int?> Function()? availableMemoryOverride;

  /// The file this brain answers from — the Settings row reports the same one.
  OnDeviceModel get model {
    final TextGenerationBackend backend = _backend;
    if (backend is LlamaCppBackend) return backend.model;
    return _deviceModel;
  }

  /// Starts reading the stored selection, without waiting for it.
  void _warmChoice() {
    unawaited(ModelChoice.instance.ensureLoaded());
  }

  /// How many bytes this device could hand to a new process right now.
  ///
  /// `MemAvailable` rather than `MemFree`: the kernel's own estimate of what can
  /// be reclaimed includes reclaimable page cache, and `MemFree` on an idle phone
  /// reads alarmingly low while gigabytes are still there for the taking.
  /// Null — not zero — when the platform cannot answer, so "unknown" is never
  /// mistaken for "full".
  static Future<int?> availableMemory() async {
    final Future<int?> Function()? override = availableMemoryOverride;
    if (override != null) return override();
    if (!Platform.isAndroid && !Platform.isLinux) return null;
    try {
      final String info = await File('/proc/meminfo').readAsString();
      final RegExpMatch? match = RegExp(
        r'^MemAvailable:\s+(\d+)\s+kB',
        multiLine: true,
      ).firstMatch(info);
      if (match == null) return null;
      return int.parse(match.group(1)!) * 1024;
    } on Object catch (error) {
      debugPrint('AI: could not read available memory ($error)');
      return null;
    }
  }

  /// True when a model file is on disk. Cheap, and never a load.
  Future<bool> isModelPresent() async {
    final TextGenerationBackend backend = _backend;
    if (backend is LlamaCppBackend) return backend.isModelPresent();
    _warmChoice();
    return _deviceModel.isPresent();
  }

  /// Fetches the model, reporting progress from 0 to 1. See
  /// [OnDeviceModel.download]: the bytes and their hash are [Llm]'s business.
  Future<bool> download({void Function(double progress)? onProgress}) async {
    final TextGenerationBackend backend = _backend;
    if (backend is LlamaCppBackend) {
      return backend.download(onProgress: onProgress);
    }
    _warmChoice();
    return _deviceModel.download(onProgress: onProgress);
  }

  /// Frees the weights and deletes the file, answering how many bytes went.
  ///
  /// Only ever the selected model's file: the picker may point this service at
  /// either one, and "Delete model" must not take the other one with it.
  Future<int> delete() async {
    final TextGenerationBackend backend = _backend;
    if (backend is LlamaCppBackend) return backend.delete();
    _warmChoice();
    return _deviceModel.delete();
  }

  /// Releases the engine for good. The file stays.
  Future<void> dispose() async {
    final TextGenerationBackend backend = _backend;
    if (backend is LlamaCppBackend) {
      await backend.dispose();
      return;
    }
    await _fixedEngine?.dispose();
  }

  /// Answers [prompt] from this device, or throws.
  @override
  Future<String> generateResponse(String prompt) async {
    final TextGenerationBackend backend = _backend;
    if (backend is LlamaCppBackend) {
      return backend.complete(prompt);
    }
    final StringBuffer buffer = StringBuffer();
    await backend.generateStream(prompt).forEach(buffer.write);
    final String answer = buffer.toString().trim();
    if (answer.isEmpty) {
      throw const OnDeviceAiException(
        'The on-device model did not answer. Try again.',
      );
    }
    return answer;
  }

  /// Answers [prompt] from this device, a word at a time.
  ///
  /// Delegates directly to the underlying [TextGenerationBackend].
  @override
  Stream<String> generateResponseStream(
    String prompt, {
    List<AiTurn> history = const <AiTurn>[],
  }) =>
      _backend.generateStream(prompt, history: history);

  @override
  Stream<String> generateStream(
    String prompt, {
    List<AiTurn>? history,
  }) =>
      _backend.generateStream(prompt, history: history);
}
