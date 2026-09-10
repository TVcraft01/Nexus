// Voice input for the assistant: one seam the composer taps, with the
// Android real implementation behind the `dev.nexus.nexus/speech` channel
// and an honest "not on this device" everywhere else — the same thin
// platform split the phone and clipboard backends use. The recognized text
// is just an ask: it runs through the exact same pipeline as typing.
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, visibleForTesting;
import 'package:flutter/services.dart' show MethodChannel;

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