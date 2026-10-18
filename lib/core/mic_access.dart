// The microphone permission, asked once, before anything listens.
//
// The recognizer's own first use asks for RECORD_AUDIO too (see
// `MainActivity.listenSpeech`), and that is the problem this file exists for:
// `listen` answers "nothing heard" whether the room was quiet or the microphone
// was refused, so the composer cannot tell a user who said no from a user who
// said nothing. Asking first, in the open, turns that into an answer a UI can
// act on — permission, or a reason to leave the button inert and say why.
//
// The ask itself belongs to the activity, which owns the dialog; this is the
// seam in front of it, and it is deliberately the same shape as
// `location_access.dart`: one ask, one honest result, and a refusal that is
// never retried in a loop.
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show MethodChannel;

/// What came back from the one microphone ask.
class MicrophonePermissionResult {
  const MicrophonePermissionResult({required this.granted, this.message});

  /// True only when Nexus may open the microphone.
  final bool granted;

  /// The honest reason, set exactly when [granted] is false.
  final String? message;
}

class MicrophoneAccess {
  static const _channel = MethodChannel('dev.nexus.nexus/device');

  /// A test seam: widget tests set this to fake the system dialog. The app
  /// never sets it.
  static Future<MicrophonePermissionResult> Function()? debugRequestOverride;

  /// True once the system has refused for good — Android's "Don't allow" with
  /// no dialog left to show.
  ///
  /// Remembered here rather than in the screen that asked, because two things
  /// need it and neither is the asker: the composer, which goes on offering the
  /// gesture while a refusal is only temporary, and [DeviceCapabilities], which
  /// stops offering it at all once there is no way back except the settings
  /// page. A plain static is the honest shape — it is one fact about one
  /// process, and it is never true on a platform that has no such thing as a
  /// permanent refusal.
  static bool permanentlyDenied = false;

  /// Forgets the remembered refusal. Tests use it between cases; the app never
  /// does — a refusal that could be un-remembered at runtime would be a button
  /// that comes back to fail again.
  @visibleForTesting
  static void debugReset() => permanentlyDenied = false;

  /// Asks for the microphone. Off Android, or with no channel — or with an ask
  /// that throws — this is an honest refusal with a reason, never a throw: a
  /// composer that crashes over a permission is worse than a mic that will not
  /// open, and the reason is what the button goes on to say.
  static Future<MicrophonePermissionResult> requestOnce() async {
    final override = debugRequestOverride;
    if (override != null) return override();
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        'requestMicrophone',
      );
      if (raw?['ok'] == true) {
        return const MicrophonePermissionResult(granted: true);
      }
      final permanently = raw?['permanentlyDenied'] == true;
      if (permanently) permanentlyDenied = true;
      return MicrophonePermissionResult(
        granted: false,
        message: permanently
            ? 'The microphone is turned off for Nexus in system settings. '
                  'Turn it back on there to talk to me.'
            : 'Microphone permission needed — voice input stays off until '
                  'you allow it.',
      );
    } catch (_) {
      return const MicrophonePermissionResult(
        granted: false,
        message: 'This device has no microphone for Nexus to ask.',
      );
    }
  }
}
