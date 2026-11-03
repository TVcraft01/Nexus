// Whether the screens most people never need are on offer.
//
// One thing sits behind it today: the Files tab. A file manager in the bottom
// bar competes with the conversation for the same thumb, and it is a second
// view of the devices the Devices tab already lists — as a tree, which is
// useful when you know what you are looking for and the least obvious
// destination in the app when you do not.
//
// Sending a file does not need it. "Send this to my PC" is an action in the
// chat, on the file that is already there, and it stays in the chat.
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Remembered under this key. Nothing else writes it.
const String kAdvancedModeKey = 'nexus.advancedMode';

/// The Advanced switch in Settings, and the one bit of state behind it.
class AdvancedMode extends ChangeNotifier {
  AdvancedMode._();

  static final AdvancedMode instance = AdvancedMode._();

  bool _enabled = false;
  bool _attached = false;

  /// Whether the File manager tab should be offered.
  bool get enabled => _enabled;

  /// Reads the remembered choice once. A missing preference is simply the
  /// hidden default — never a failed launch.
  Future<void> attach() async {
    if (_attached) return;
    _attached = true;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(kAdvancedModeKey) ?? false;
      if (_enabled) notifyListeners();
    } catch (_) {
      // The switch still works for this session; only the memory is lost.
    }
  }

  /// Turns the advanced screens on or off, and remembers it for next launch.
  Future<void> setEnabled(bool value) async {
    if (_enabled != value) {
      _enabled = value;
      notifyListeners();
    }
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kAdvancedModeKey, value);
    } catch (_) {
      // The switch still follows this session.
    }
  }

  /// Puts the singleton back to the hidden default between tests. It outlives
  /// every widget, so a test that turned it on would otherwise leak into the
  /// next one and hide a regression.
  @visibleForTesting
  void resetForTest({bool enabled = false}) {
    _attached = true;
    _enabled = enabled;
  }
}
