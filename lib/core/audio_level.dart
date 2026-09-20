// The microphone's loudness, as a number the Core's particle field can move
// to.
//
// Unlike the rest of the voice path this is a *stream*, not a call: Android's
// speech recogniser reports the RMS of what it is hearing several times a
// second while it listens (`onRmsChanged`), and the platform half forwards it
// over `dev.nexus.nexus/speech_level`. That is a real measurement of the user's
// voice, not a guess read off a timer — which is exactly why the field is
// allowed to react to it.
//
// Everywhere else there is no level, and [available] says so. A platform
// without it gets a Core that still shows "listening" honestly (the microphone
// really is open) but never pretends to react to loudness it cannot measure.
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, visibleForTesting;
import 'package:flutter/services.dart' show EventChannel;

class MicLevel {
  const MicLevel();

  /// Test seam: a fake level source for widget tests, like
  /// [SpeechInput.override]. A widget test that wants a loud voice feeds one.
  @visibleForTesting
  static MicLevel Function()? override;

  static MicLevel get current => override?.call() ?? const MicLevel();

  /// Whether this device can measure loudness at all.
  ///
  /// Real Android, not "Android according to the framework": a widget test on
  /// a Linux host reports itself as Android, and there is no recogniser behind
  /// that claim — subscribing would raise a services error instead of a quiet
  /// field. The same rule as [SpeechPlayback.available], for the same reason.
  bool get available =>
      defaultTargetPlatform == TargetPlatform.android && Platform.isAndroid;

  /// Loudness while the microphone is open: 0 is a quiet room, 1 is a voice
  /// close to the phone. The stream ends when the caller stops listening (it
  /// is created per listening session), and never throws — a mic that fails
  /// just means the field breathes at its floor.
  Stream<double> get levels {
    if (!available) return const Stream<double>.empty();
    return _channel
        .receiveBroadcastStream()
        .map(_fromPlatform)
        .handleError((Object _) {})
        .where((value) => value != null)
        .cast<double>();
  }

  double? _fromPlatform(Object? event) {
    if (event is double) return normalizeLevel(event);
    if (event is num) return normalizeLevel(event.toDouble());
    return null; // an event this build does not understand: stay quiet
  }

  static const _channel = EventChannel('dev.nexus.nexus/speech_level');

  /// Maps a recogniser RMS reading in dB to 0..1.
  ///
  /// Android reports roughly -2 dBFS in a quiet room and +10 or so for a voice
  /// close to the phone (it can read higher in a loud room, so the top is
  /// clamped). The curve lifts the bottom of the range, because quiet speech
  /// still deserves to move the field — a wave that only answers shouting is a
  /// wave that looks broken when someone talks normally.
  @visibleForTesting
  static double normalizeLevel(double rmsDb) {
    const quiet = -2.0;
    const close = 12.0;
    final x = ((rmsDb - quiet) / (close - quiet)).clamp(0.0, 1.0);
    return math.pow(x, 0.75).toDouble();
  }
}
