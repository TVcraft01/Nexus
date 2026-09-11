import 'package:flutter/foundation.dart'
    show TargetPlatform, debugPrint, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart' show MethodChannel;

/// Android's Wi-Fi firmware drops multicast and broadcast frames before they
/// ever reach the app: joining the group with `joinMulticast` is not enough.
/// Receiving them requires holding a `WifiManager.MulticastLock`, and the
/// manifest has declared `CHANGE_WIFI_MULTICAST_STATE` for exactly that since
/// the beginning — but nothing ever acquired the lock, so discovery could only
/// ever hear other devices on desktop.
///
/// This is the thin Dart side; the native side lives in MainActivity. The lock
/// is held for the life of the mesh (Nexus is meant to be always-on and
/// reachable) and released when discovery stops. A device that refuses it
/// reports false rather than pretending it can hear anyone.
class MulticastLock {
  static const _channel = MethodChannel('dev.nexus.nexus/network');

  static bool _held = false;

  /// Whether this app holds the lock right now (Android only).
  static bool get held => _held;

  /// Android is the only platform that needs this, so every other platform
  /// skips the native call entirely. A plain Dart test still reports Android
  /// as the target platform, but with no engine there is nothing on the other
  /// end of the channel — [acquire] copes with that below.
  static bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Takes the lock once per process. Returns whether it is held afterwards.
  static Future<bool> acquire() async {
    if (!_supported || _held) return _held;
    try {
      _held = await _channel.invokeMethod<bool>('acquireMulticast') ?? false;
      if (!_held) {
        debugPrint('NEXUS discovery: the Android multicast lock was refused — '
            'this device will not hear nearby Nexus devices.');
      }
    } catch (e) {
      // No native side answering (no engine, or a stripped build): discovery
      // can still announce, it just cannot hear. Never fatal, and the reason
      // is logged on one line rather than as a stack.
      _held = false;
      debugPrint('NEXUS discovery: multicast lock unavailable '
          '(${e.toString().split('\n').first})');
    }
    return _held;
  }

  static Future<void> release() async {
    if (!_supported || !_held) return;
    try {
      await _channel.invokeMethod<void>('releaseMulticast');
    } catch (_) {
      // The lock dies with the process anyway.
    }
    _held = false;
  }
}
