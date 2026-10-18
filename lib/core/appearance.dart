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

/// The one preference behind the Theme section's colour wheel.
abstract final class Appearance {
  /// The key the seed is stored under. Stable: a build that renames it drops
  /// every existing custom accent back to the shipped purple.
  static const String accentKey = 'accent_seed';

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
}
