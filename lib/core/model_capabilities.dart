// What the brain answering on this phone can actually do — and what it must
// not be offered.
//
// A 470 MB model asked for a web page does not refuse: it writes a paragraph
// about web pages, and one asked to search the web invents results in the shape
// of results. Neither failure is something a user can tell from a success, so
// the shell stops offering the feature rather than showing a confident wrong
// answer. The same table feeds the system prompt: a model that cannot write an
// artifact file is never taught the `<artifact>` shape, so it also never leaks
// the tag into the bubble.
//
// Three brains, three answers:
//
//   * Qwen 2.5 0.5B — chat, the fast path and ML Kit vision. No artifacts, no
//     web search: both need a model that follows a format instruction through a
//     long prompt, which is the first thing 0.5B drops;
//   * Llama 3.2 1B — the same, plus artifacts. It is big enough to keep a tag
//     around a code block;
//   * Ollama on the PC — everything, because the model is a desktop one.
//
// The answer is *read*, never cached: the selected model changes while the app
// runs, and a capability copied at launch would be a lock the user cannot open.
// [observe] is how the shell says what it just found out about the network, and
// it is the only mutable part.
library;

import 'package:flutter/foundation.dart' show immutable, visibleForTesting;

import 'ai_status.dart' show AiSource, AiStatus;
import 'on_device_model.dart' show ModelChoice, OnDeviceModelChoice;

/// Which brain is answering, in the three shapes a capability question has.
enum NexusBrain {
  /// The 470 MB model: fast, and too small for structured output.
  qwen,

  /// The 770 MB model: slower, and able to write an artifact.
  llama,

  /// Ollama on the user's PC: a desktop model with no size excuse.
  pc,

  /// No brain at all — nothing to gate, because nothing can answer.
  none,
}

/// One feature the table can answer for.
enum NexusFeature {
  /// A file written inside the reply (`<artifact …>`), with a card to keep it.
  artifacts,

  /// Looking the question up on the web before answering it.
  webSearch,
}

/// What one brain unlocks. Built from [NexusBrain], never from a stored flag.
@immutable
class ModelCapabilities {
  const ModelCapabilities(this.brain);

  /// The capabilities of the brain that would answer right now.
  static ModelCapabilities get current => ModelCapabilities(currentBrain);

  /// A test seam, in the shape the rest of the app uses: a test states which
  /// brain it is looking at instead of writing a preference and a file. The app
  /// never sets it.
  @visibleForTesting
  static NexusBrain? debugBrainOverride;

  /// What the last probe of the network found, when it found something the
  /// selected model cannot describe: the PC answering, or no brain at all.
  ///
  /// Null means "the device answers" — or that nobody has looked yet, which is
  /// the same answer for this purpose, because a downloaded model is the first
  /// thing [LocalAiService] tries.
  static NexusBrain? _observed;

  /// Which brain answers right now.
  ///
  /// The PC is preferred over the selected model only when the probe said the
  /// PC is what answers, because that is exactly when no model file was found:
  /// the same order [LocalAiService.current] walks.
  static NexusBrain get currentBrain {
    final NexusBrain? override = debugBrainOverride;
    if (override != null) return override;
    final NexusBrain? observed = _observed;
    if (observed != null) return observed;
    return ModelChoice.instance.choice == OnDeviceModelChoice.llama
        ? NexusBrain.llama
        : NexusBrain.qwen;
  }

  /// Records where the answers are coming from, as `AiStatus.detect` found it.
  ///
  /// An on-device answer clears the observation rather than pinning `qwen` or
  /// `llama`: which of the two it is comes from the picker, and it can change
  /// without another probe.
  static void observe(AiStatus status) {
    _observed = switch (status.source) {
      AiSource.pc => NexusBrain.pc,
      AiSource.none => NexusBrain.none,
      AiSource.onDevice => null,
    };
  }

  /// Forgets what the probe found. Tests use it; the app calls it when the
  /// selection changes, so a stale "the PC answers" cannot outlive the model the
  /// user just downloaded.
  @visibleForTesting
  static void debugReset() {
    _observed = null;
    debugBrainOverride = null;
  }

  /// The brain these capabilities describe.
  final NexusBrain brain;

  /// Whether a reply may carry a file. True for the 1B and the PC: both follow
  /// the `<artifact filename="…">` shape, and neither turns it into prose.
  bool get supportsArtifacts =>
      brain == NexusBrain.llama || brain == NexusBrain.pc;

  /// Whether the next question may be looked up on the web first.
  ///
  /// The PC only. Web search appends results to the prompt, and a small model
  /// reading a page of snippets answers about the snippets instead of about the
  /// question — the answer gets worse, which is the definition of a feature that
  /// should not be offered.
  bool get supportsWebSearch => brain == NexusBrain.pc;

  /// Whether ML Kit's eyes are wired up. They are on every device that has a
  /// brain at all: vision is a plugin, not a model.
  bool get supportsVision => brain != NexusBrain.none;

  /// Whether the instant command path answers before the model is asked.
  bool get supportsFastPath => brain != NexusBrain.none;

  /// Whether [feature] is available on this brain.
  bool supports(NexusFeature feature) => switch (feature) {
    NexusFeature.artifacts => supportsArtifacts,
    NexusFeature.webSearch => supportsWebSearch,
  };

  /// The model as the lock dialog names it — short enough for a sentence.
  String get modelName => switch (brain) {
    NexusBrain.qwen => 'Qwen 0.5B',
    NexusBrain.llama => 'Llama 3.2 1B',
    NexusBrain.pc => 'your PC',
    NexusBrain.none => 'no model',
  };

  /// The sentence a locked feature shows under the "Feature Locked" title.
  ///
  /// Written per feature because the way out is not the same: a bigger model
  /// writes artifacts, but nothing on this phone searches the web well, so the
  /// web row must not send the user off to download a file that would not open
  /// it. Both name the model that is answering, so a 1B user is not told about
  /// the 0.5B's limits.
  String lockMessage(NexusFeature feature) => switch (feature) {
    NexusFeature.artifacts =>
      'The current on-device model ($modelName) is too small to generate '
          'complex code or write files. Download Llama 3.2 1B or connect to '
          'your PC to unlock this.',
    NexusFeature.webSearch =>
      'The current on-device model ($modelName) is too small to search the '
          'web — it answers about the search results instead of the question. '
          'Connect to your PC to unlock this.',
  };

  /// A one-line reason for a row that stays visible but cannot be used.
  String lockSubtitle(NexusFeature feature) => switch (feature) {
    NexusFeature.artifacts => 'Locked — needs Llama 3.2 1B or your PC',
    NexusFeature.webSearch => 'Locked — needs your PC',
  };
}
