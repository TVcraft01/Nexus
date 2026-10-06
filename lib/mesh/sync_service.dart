import 'package:flutter/foundation.dart'
    show TargetPlatform, debugPrint, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart' show MethodChannel;

/// The Android foreground service that keeps the mesh alive in the background.
///
/// The mesh is meant to be always-on: another Nexus device must be able to
/// reach this one — and a transfer it started must be able to land here — even
/// with the window closed. Android only grants an app that much background
/// life to a foreground service, and since Android 14 that service must say
/// *why* it is running — a `dataSync` job, an ongoing transfer/replication
/// loop over the mesh.
///
/// The service also owns the Wi-Fi multicast lock (see `NexusSyncService.kt`).
/// The activity used to hold it and dropped it in `onDestroy`, so backgrounded
/// discovery went deaf the moment the user left the app; held by the service
/// it lives exactly as long as the mesh does.
///
/// This is the thin Dart side; the native side is `NexusSyncService`, reached
/// over the existing `dev.nexus.nexus/network` channel. It is a no-op off
/// Android, and a build with no engine answering the channel copes with it
/// silently — the mesh keeps working for as long as the process lives.
class SyncService {
  static const _channel = MethodChannel('dev.nexus.nexus/network');

  static bool _running = false;

  /// Whether the foreground service was asked for and accepted.
  static bool get running => _running;

  static bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Asks Android to run the mesh inside a foreground service, so it keeps
  /// serving and transferring once the window is closed. Returns whether the
  /// service is running afterwards.
  static Future<bool> start() async {
    if (!_supported || _running) return _running;
    try {
      _running = await _channel.invokeMethod<bool>('startSyncService') ?? false;
      if (!_running) {
        debugPrint('NEXUS mesh: Android refused the foreground sync service — '
            'the mesh will stop when the app is closed.');
      }
    } catch (e) {
      // No native side answering (no engine, or a stripped build).
      _running = false;
      debugPrint('NEXUS mesh: foreground sync service unavailable '
          '(${e.toString().split('\n').first})');
    }
    return _running;
  }

  /// Stops the foreground service (and, with it, the multicast lock).
  static Future<void> stop() async {
    if (!_supported || !_running) return;
    try {
      await _channel.invokeMethod<void>('stopSyncService');
    } catch (_) {
      // It dies with the process anyway.
    }
    _running = false;
  }
}
