// Whether this device mirrors notifications from one paired device.
//
// The sync itself is not built yet; the switch in a paired card is the
// preference it will read when it is. Keeping the answer here rather than in
// the widget means the value survives a rebuild, a tab switch and a restart —
// a toggle that forgets itself is worse than no toggle at all.
library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shared_preferences/shared_preferences.dart';

/// One preference per paired device, stored by the device's stable id.
abstract final class NotificationSync {
  /// The prefix in front of a device id. Public because a test reads the same
  /// key the screen writes.
  static const String keyPrefix = 'notification_sync:';

  static Future<SharedPreferences?> _instance() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (error) {
      // A widget test and a desktop without the plugin simply have no stored
      // preference; the switch still works for the session.
      debugPrint(
        'DEVICES: no preferences store for notification sync ($error)',
      );
      return null;
    }
  }

  /// Whether alerts from [deviceId] are mirrored here. Defaults to off.
  static Future<bool> isOn(String deviceId) async {
    final SharedPreferences? prefs = await _instance();
    return prefs?.getBool('$keyPrefix$deviceId') ?? false;
  }

  /// Stores the switch for [deviceId]. Never throws: the screen has already
  /// moved, and a preference write is not a reason to take it back.
  static Future<void> set(String deviceId, bool value) async {
    final SharedPreferences? prefs = await _instance();
    if (prefs == null) return;
    try {
      await prefs.setBool('$keyPrefix$deviceId', value);
    } catch (error) {
      debugPrint('DEVICES: could not store notification sync ($error)');
    }
  }
}
