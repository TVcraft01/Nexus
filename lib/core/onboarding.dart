// The one preference that decides which screen the app opens on.
//
// A first run is not the same app as every run after it: on the first one the
// user has no model, no reason to trust the app with 470 MB of their storage,
// and no idea which of the two models they are being offered. So the shell asks
// one question before it draws anything — has this user been here before? — and
// the answer is a single boolean in preferences.
//
// It is deliberately not a "show the tour again" feature, and the flag is
// deliberately written the moment the user leaves the first-run screen by any
// route: a welcome screen that comes back because the app was closed halfway
// through is a screen standing between the user and the app they already met.
library;

import 'package:flutter/foundation.dart'
    show debugPrint, visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

/// Whether the first-run screen has been shown and answered.
abstract final class Onboarding {
  /// The key the flag is stored under. Stable: a build that renames it greets
  /// every existing user as a new one.
  static const String key = 'has_onboarded';

  /// A test seam, in the same shape as [ChatLog.override]: a widget test states
  /// whether this device has been here before rather than arranging a
  /// preference for it. The app never sets it.
  @visibleForTesting
  static bool? debugOverride;

  /// True when this device has already seen the welcome screen.
  ///
  /// A store that cannot be read answers **true**, which is the unusual half of
  /// this decision and the one worth stating: a phone whose preferences cannot
  /// be reached would otherwise show the welcome screen on every single launch,
  /// and a first-run page that never ends is a worse failure than a first-run
  /// page that never appears. The app is usable either way — Settings still
  /// names both models and still offers the download.
  static Future<bool> isDone() async {
    final bool? forced = debugOverride;
    if (forced != null) return forced;
    try {
      return (await SharedPreferences.getInstance()).getBool(key) ?? false;
    } on Object catch (error) {
      debugPrint('ONBOARDING: no preferences store ($error)');
      return true;
    }
  }

  /// Records that the user has left the welcome screen, however they left it.
  ///
  /// Never throws, for the same reason: a failed write must not keep the user
  /// on a screen they have finished with.
  static Future<void> complete() async {
    try {
      await (await SharedPreferences.getInstance()).setBool(key, true);
    } on Object catch (error) {
      debugPrint('ONBOARDING: could not record it ($error)');
    }
  }
}
