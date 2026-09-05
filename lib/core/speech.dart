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