// The default on-device text generation backend running llama.cpp via llamadart.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import 'brain.dart' show ChatTurn;
import 'clock_context.dart' show nexusSystemWithClock;
import 'llm.dart';
import 'local_ai_service.dart';
import 'on_device_ai_service.dart';
import 'on_device_model.dart';
import 'system_actions.dart' show nexusSystemWithCapabilities;
import 'text_generation_backend.dart';

/// On-device LLM inference powered by llama.cpp.
class LlamaCppBackend implements TextGenerationBackend {
  LlamaCppBackend({
    OnDeviceModel model = const OnDeviceModel(),
    Llm? llm,
    this.system = kNexusOnDeviceSystem,
    this.maxTokens = 220,
    this.clock,
    this.includeClock = true,
    this.includeMemory = true,
  }) : _deviceModel = model,
       _fixedEngine = llm;

  final OnDeviceModel _deviceModel;
  final Llm? _fixedEngine;
  Llm? _engine;
  OnDeviceModelChoice? _engineChoice;

  /// The persona and rules, as the model's system turn.
  final String system;

  /// Maximum tokens to generate per response.
  final int maxTokens;

  /// Clock function for timestamping system prompts.
  final DateTime Function()? clock;

  /// Whether current date and time are appended to [system].
  final bool includeClock;

  /// Whether remembered user facts are appended to [system].
  final bool includeMemory;

  /// The file this backend answers from.
  OnDeviceModel get model => _deviceModel;

  void _warmChoice() {
    unawaited(ModelChoice.instance.ensureLoaded());
  }

  Future<Llm> _current() async {
    final Llm? fixed = _fixedEngine;
    if (fixed != null) return fixed;
    _warmChoice();
    final OnDeviceModelChoice choice = _deviceModel.choice;
    final Llm? engine = _engine;
    if (engine != null && _engineChoice == choice) return engine;
    _engine = null;
    _engineChoice = null;
    if (engine != null) await engine.dispose();
    await _ensureMemoryForLoad();
    final Llm built = Llm(
      model: _deviceModel.model,
      modelsDir: _deviceModel.directoryFor,
    );
    _engine = built;
    _engineChoice = choice;
    return built;
  }

  Future<void> _ensureMemoryForLoad() async {
    final int? free = await OnDeviceAiService.availableMemory();
    if (free == null) return;
    final int onDisk = await _deviceModel.sizeBytes();
    final int bytes = onDisk > 0 ? onDisk : _deviceModel.model.bytes;
    final int needed = (bytes * kModelMemoryHeadroom).round();
    if (free >= needed) return;
    debugPrint(
      'AI: ${_deviceModel.label} needs $needed bytes, $free available — '
      'refusing to load it',
    );
    throw InsufficientMemoryException(
      label: _deviceModel.label,
      neededBytes: needed,
      freeBytes: free,
    );
  }

  /// True when the model file is available on disk.
  Future<bool> isModelPresent() async {
    _warmChoice();
    return _deviceModel.isPresent();
  }

  /// Downloads the model file, reporting progress from 0.0 to 1.0.
  Future<bool> download({void Function(double progress)? onProgress}) async {
    _warmChoice();
    return _deviceModel.download(onProgress: onProgress);
  }

  /// Unloads memory weights and deletes the model file.
  Future<int> delete() async {
    _warmChoice();
    await _engine?.unload();
    return _deviceModel.delete();
  }

  /// Releases the engine and its native resources.
  Future<void> dispose() async {
    final Llm? engine = _engine;
    _engine = null;
    _engineChoice = null;
    if (engine != null) await engine.dispose();
    await _fixedEngine?.dispose();
  }

  /// Completes a prompt and returns the whole answer string.
  Future<String> complete(String prompt) async {
    _warmChoice();
    if (!await _deviceModel.isPresent()) throw const ModelNotFoundException();
    if (_engine == null) await _ensureMemoryForLoad();
    final Llm llm = await _current();
    final String capable = nexusSystemWithCapabilities(system);
    final String clocked = includeClock
        ? nexusSystemWithClock(capable, now: clock?.call())
        : capable;
    final String systemTurn = includeMemory
        ? LocalAiService.systemWithMemory(clocked)
        : clocked;
    String answer;
    try {
      answer = await llm.complete(
        prompt,
        system: systemTurn,
        maxTokens: maxTokens,
      );
    } on Object catch (e) {
      debugPrint('AI: on-device generation failed ($e)');
      throw const OnDeviceAiException('The on-device model stopped answering.');
    }
    final String trimmed = answer.trim();
    if (trimmed.isEmpty) {
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

  @override
  Stream<String> generateStream(
    String prompt, {
    List<AiTurn>? history,
  }) async* {
    _warmChoice();
    if (!await _deviceModel.isPresent()) throw const ModelNotFoundException();
    if (_engine == null) await _ensureMemoryForLoad();
    final Llm llm = await _current();
    final String capable = nexusSystemWithCapabilities(system);
    final String clocked = includeClock
        ? nexusSystemWithClock(capable, now: clock?.call())
        : capable;
    final String systemTurn = includeMemory
        ? LocalAiService.systemWithMemory(clocked)
        : clocked;
    bool answered = false;
    final List<AiTurn> turns = history ?? const <AiTurn>[];
    try {
      final Stream<String> pieces = turns.isEmpty
          ? llm.completeStream(prompt, system: systemTurn, maxTokens: maxTokens)
          : llm.completeChatStream(
              system: systemTurn,
              history: <ChatTurn>[
                for (final AiTurn turn in turns) turn.chatTurn,
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
    throw llm.status == LlmStatus.unavailable
        ? const OnDeviceAiException(
            'The on-device model could not be loaded on this device.',
          )
        : const OnDeviceAiException(
            'The on-device model did not answer. Try again.',
          );
  }
}
