import 'package:package_info_plus/package_info_plus.dart';

/// The current app version — what this build tells the user, its peers, and
/// the auto-updater it is.
///
/// It must match `version:` in pubspec.yaml (which also carries the build
/// number the stores see). The two drifted apart once, and the cost was
/// user-visible: 0.2.1 shipped with this still reading `0.1.53`, so the
/// updater compared GitHub's `v0.2.1` against `0.1.53`, found it newer, and
/// offered every 0.2.x user an update to the build they were already running —
/// the phone showed "Nexus v0.2.1 is available" while running 0.2.1+155.
///
/// test/version_test.dart now fails when the two drift apart again, and proves
/// the shipped version never reads as an update to itself.
const String appVersion = '0.4.0';

/// The version the installed package reports, read from the platform.
///
/// This is the value the updater compares against a release tag, because a
/// constant can be forgotten at release time while the installed package name
/// cannot. The constant above remains the fallback for tests and for any
/// platform where the package channel is unavailable — and the two are kept in
/// step by test/version_test.dart.
Future<String> installedAppVersion() async {
  try {
    final PackageInfo info = await PackageInfo.fromPlatform();
    final String version = info.version.trim();
    return version.isEmpty ? appVersion : version;
  } catch (_) {
    return appVersion;
  }
}
