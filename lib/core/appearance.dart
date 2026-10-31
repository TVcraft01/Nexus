// The accent colour is a preference, not a field.
//
// A colour the user picked is the most personal thing this app lets them
// change, and Android is allowed to kill a backgrounded app at any moment. A
// custom accent that lived only in a `State` field therefore survived until the
// next time the laundry app asked for memory — which on a phone is hours, not
// weeks. The colour is written the moment the wheel's Done is pressed and read
// before the first frame, so a restart opens in the colour the user chose.
//
// The value is stored as the ARGB int of the seed rather than as a name: the
// seeds are arbitrary colours from a wheel, so a name would be a number with
// extra steps. `null` (or a store that cannot be read) means the shipped
// purple, which is also what a fresh install opens in.
library;

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

/// The one preference behind the Theme section's colour wheel, and the two
/// behind its light/dark switches.
abstract final class Appearance {
  /// The key the seed is stored under. Stable: a build that renames it drops
  /// every existing custom accent back to the shipped purple.
  static const String accentKey = 'accent_seed';

  /// Whether brightness comes from the platform. A separate key from
  /// [darkModeKey] because the two are answers to two questions: the choice
  /// the user made, and whether the phone is allowed to override it. Storing
  /// one derived "dark" would lose the choice the moment the app followed the
  /// system, and turning Follow system back off would land in the wrong half
  /// of the day.
  static const String followSystemKey = 'follow_system';

  /// The user's own dark/light choice, used only while [followSystemKey] is
  /// false. Defaults are the shell's: follow the system, light when not.
  static const String darkModeKey = 'dark_mode';

  /// A test seam, in the same shape as [Onboarding.debugOverride]: a widget
  /// test states the accent this device starts with rather than arranging a
  /// preference for it. The app never sets it.
  @visibleForTesting
  static int? debugOverride;

  /// The stored seed, or null when this device has never picked one.
  ///
  /// Never throws. A store that cannot be read answers null — the shipped
  /// purple — because a theme colour is not worth an error path, and the user
  /// can pick again in two taps.
  static Future<int?> accentSeed() async {
    final int? forced = debugOverride;
    if (forced != null) return forced;
    try {
      return (await SharedPreferences.getInstance()).getInt(accentKey);
    } on Object catch (error) {
      debugPrint('APPEARANCE: no preferences store ($error)');
      return null;
    }
  }

  /// Records the seed. Never throws, for the same reason.
  static Future<void> setAccentSeed(int seed) async {
    try {
      await (await SharedPreferences.getInstance()).setInt(accentKey, seed);
    } on Object catch (error) {
      debugPrint('APPEARANCE: could not record the accent ($error)');
    }
  }

  /// The stored brightness preference, read before the first frame.
  ///
  /// A fresh install follows the system and is light when the system has no
  /// answer — the same starting point the shell had when this lived in a
  /// `State` field, which is now only the fallback for a store that cannot be
  /// read.
  static Future<({bool followSystem, bool dark})> theme() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      return (
        followSystem: prefs.getBool(followSystemKey) ?? true,
        dark: prefs.getBool(darkModeKey) ?? false,
      );
    } on Object catch (error) {
      debugPrint('APPEARANCE: no preferences store ($error)');
      return (followSystem: true, dark: false);
    }
  }

  /// Records one of the two switches. Never throws: a theme preference is not
  /// worth an error path, and the switch has already moved on screen.
  static Future<void> setFollowSystem(bool value) async {
    try {
      await (await SharedPreferences.getInstance()).setBool(
        followSystemKey,
        value,
      );
    } on Object catch (error) {
      debugPrint('APPEARANCE: could not record Follow system ($error)');
    }
  }

  static Future<void> setDarkMode(bool value) async {
    try {
      await (await SharedPreferences.getInstance()).setBool(darkModeKey, value);
    } on Object catch (error) {
      debugPrint('APPEARANCE: could not record Dark mode ($error)');
    }
  }
}
