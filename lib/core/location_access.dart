// The location permission, asked once and answered honestly.
//
// Place reminders need the fix even when Nexus is closed, so the toggle
// asks for foreground and background location together, with the reason
// said out loud first. A denial is never retried in a loop and never
// silently worked around: the toggle stays off, time reminders keep
// working, and the row says why.
import 'package:flutter/services.dart' show MethodChannel;

/// What came back from the one permission ask.
class LocationPermissionResult {
  const LocationPermissionResult({required this.granted, this.message});

  /// True only when Nexus may take a fix with the app closed.
  final bool granted;

  /// The honest reason, set exactly when [granted] is false.
  final String? message;
}

class ReminderLocation {
  static const _channel = MethodChannel('dev.nexus.nexus/device');

  /// A test seam: widget tests set this to fake the system dialog. The
  /// app never sets it.
  static Future<LocationPermissionResult> Function()? debugRequestOverride;

  /// Asks for foreground + background location together. Off Android (or
  /// with no channel) this is silence, never a throw - the caller treats
  /// it as denied and says so.
  static Future<LocationPermissionResult> requestAlways() async {
    final override = debugRequestOverride;
    if (override != null) return override();
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        'requestReminderLocation',
      );
      if (raw?['ok'] == true) {
        return const LocationPermissionResult(granted: true);
      }
      final permanently = raw?['permanentlyDenied'] == true;
      return LocationPermissionResult(
        granted: false,
        message: permanently
            ? 'Location is turned off for Nexus in system settings. '
                  'Turn it back to \u2018Always\u2019 there to use place reminders.'
            : 'Location reminders need \u2018Always\u2019 location permission, '
                  'so they can fire while Nexus is closed. Time reminders '
                  'still work.',
      );
    } catch (_) {
      return const LocationPermissionResult(
        granted: false,
        message: 'This device has no location service for Nexus to ask. '
            'Time reminders still work.',
      );
    }
  }

  /// Opens this app's system settings page, where the user can change a
  /// denied permission by hand. Best-effort and silent on failure.
  static Future<void> openAppSettings() async {
    try {
      await _channel.invokeMethod<void>('openAppSettings');
    } catch (_) {
      // No bridge - nothing to open.
    }
  }
}
