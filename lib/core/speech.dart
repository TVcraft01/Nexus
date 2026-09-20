// Voice input for the assistant: one seam the composer taps, with the
// Android real implementation behind the `dev.nexus.nexus/speech` channel
// and an honest "not on this device" everywhere else — the same thin
// platform split the phone and clipboard backends use. The recognized text
// is just an ask: it runs through the exact same pipeline as typing.
import 'dart:async' show StreamSubscription;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart'
    show
        TargetPlatform,
        ValueListenable,
        ValueNotifier,
        defaultTargetPlatform,
        visibleForTesting;
import 'package:flutter/services.dart' show EventChannel, MethodChannel;

class SpeechInput {
  const SpeechInput();

  /// Test seam: a fake recognizer for widget tests (like
  /// [QueryLog.readAllOverride]).
  @visibleForTesting
  static SpeechInput Function()? override;

  static SpeechInput get current => override?.call() ?? const SpeechInput();

  /// Whether this device can listen at all. Android can; desktops answer
  /// honestly that voice input isn't set up here.
  bool get available => defaultTargetPlatform == TargetPlatform.android;

  /// Listens for one utterance and returns the recognized text, or null
  /// when nothing was heard, the user cancelled, or voice isn't available.
  Future<String?> listen() async {
    if (!available) return null;
    try {
      return await _channel.invokeMethod<String>('listen');
    } catch (_) {
      return null; // never crash the composer for a mic failure
    }
  }

  static const _channel = MethodChannel('dev.nexus.nexus/speech');
}

/// Speaking for the assistant: reads a reply out loud on devices that can.
/// Android speaks through the system text-to-speech engine (fully on-device,
/// no network — the same zero-cloud rule as the mic); everywhere else this
/// answers honestly that spoken replies aren't set up here, and the
/// assistant simply stays a text companion.
class SpeechOutput {
  const SpeechOutput();

  /// Test seam, like [SpeechInput.override]: a fake speaker for widget
  /// tests, so "the assistant said X" is provable without hardware.
  @visibleForTesting
  static SpeechOutput Function()? override;

  static SpeechOutput get current => override?.call() ?? const SpeechOutput();

  /// Whether this device can read replies out loud at all.
  bool get available => defaultTargetPlatform == TargetPlatform.android;

  /// Says [text] out loud. Returns true when the utterance was handed to
  /// the speech engine. Never throws — a device that can't speak (or a
  /// speech engine that fails) just means the text stays on the card.
  Future<bool> speak(String text) async {
    if (!available) return false;
    try {
      return await _channel.invokeMethod<bool>('speak', {'text': text}) ??
          false;
    } catch (_) {
      return false; // never crash the assistant for a speech failure
    }
  }

  static const _channel = MethodChannel('dev.nexus.nexus/speech_out');
}

/// Whether sound is actually coming out of Nexus right now.
///
/// This is the signal the app never used to have. The speech call above
/// resolves when an utterance is *queued*, so for a long time the app knew it
/// had handed text to the engine but not that anything was being said — which
/// is why the Core has never had a speaking state.
///
/// Android's text-to-speech engine does report it: it announces when an
/// utterance starts and when it finishes or is interrupted. The platform half
/// forwards those over `dev.nexus.nexus/speech_state`, so [speaking] is a fact
/// about this instant rather than an optimistic guess, and the Core's
/// particles only propagate outward while a voice is genuinely playing.
///
/// Where the platform cannot report it (everywhere but Android today),
/// [available] is false and [speaking] stays false: the field then never shows
/// a speaking state, which is the honest answer.
class SpeechPlayback {
  SpeechPlayback();

  static SpeechPlayback? _instance;

  /// Test seam, like the other backends: a fake playback source, so "the Core
  /// pulsed while Nexus spoke" is provable without a speaker.
  @visibleForTesting
  static SpeechPlayback Function()? override;

  static SpeechPlayback get current =>
      override?.call() ?? (_instance ??= SpeechPlayback());

  /// Whether this device can report utterance start and stop.
  ///
  /// Real Android, not "Android according to the framework": a widget test on
  /// a Linux host reports itself as Android, and there is no engine behind
  /// that claim. Subscribing there raises a services error (the channel has no
  /// implementation to activate), which the test framework counts as a failure
  /// rather than something a stream's own error handler can absorb.
  bool get available =>
      defaultTargetPlatform == TargetPlatform.android && Platform.isAndroid;

  final ValueNotifier<bool> _speaking = ValueNotifier<bool>(false);

  /// True while an utterance is being spoken.
  ValueListenable<bool> get speaking => _speaking;

  StreamSubscription<dynamic>? _events;

  /// Starts listening for utterance start/stop. Idempotent, and safe to call
  /// on a platform with no such signal.
  void listen() {
    if (!available || _events != null) return;
    _events = _channel.receiveBroadcastStream().listen(
      (event) => _speaking.value = event == true,
      onError: (Object _) {}, // no channel here: stay quiet, never crash
      cancelOnError: false,
    );
  }

  static const _channel = EventChannel('dev.nexus.nexus/speech_state');
}