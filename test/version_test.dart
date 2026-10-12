// The version a build *says* it is must be the version it is.
//
// The updater compares `appVersion` against GitHub release tags, so a constant
// left behind by a release makes the app offer every user an update to the
// build they already have — which is exactly what happened when 0.2.1 shipped
// declaring 0.1.53: the phone ran 0.2.1+155 and still showed the banner
// "Nexus v0.2.1 is available", on every launch.
//
// These guards are the reason it cannot happen again quietly: one pins the
// constant to pubspec.yaml, the others pin the user-visible consequence in
// both directions (no false update on the shipped version, a real prompt when a
// genuinely newer release exists).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/version.dart';
import 'package:nexus/mesh/updater.dart';

/// A GitHub "latest release" answer for one version, with the asset an Android
/// build would install from.
String releaseFor(String version) => jsonEncode({
      'tag_name': 'v$version',
      'html_url': 'https://github.com/TVcraft01/Nexus/releases/tag/v$version',
      'assets': [
        {
          'name': 'Nexus-$version.apk',
          'browser_download_url':
              'https://github.com/TVcraft01/Nexus/releases/download/v$version/Nexus-$version.apk',
        },
      ],
    });

Future<UpdateCheck> checkAgainst(String latestVersion) =>
    Updater.checkForUpdate(
      currentVersion: appVersion,
      fetch: (_) async => UpdateResponse(200, releaseFor(latestVersion)),
    );

/// The `version:` line pubspec.yaml ships, found by walking up from the test's
/// working directory so the guard holds however the suite is invoked.
String pubspecVersion() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    final file = File('${dir.path}/pubspec.yaml');
    if (file.existsSync()) {
      final match = RegExp(r'^version:\s*(\S+)', multiLine: true)
          .firstMatch(file.readAsStringSync());
      if (match != null) return match.group(1)!;
    }
    dir = dir.parent;
  }
  fail('no pubspec.yaml above ${Directory.current.path}');
}

void main() {
  test('appVersion is the version pubspec.yaml ships', () {
    // `version:` is "0.2.1+155" — the part before the build number is what the
    // updater, the peers and the About screen call the version.
    final shipped = pubspecVersion().split('+').first;
    expect(
      appVersion,
      shipped,
      reason: 'bump lib/core/version.dart in the same commit as pubspec.yaml: '
          'the updater compares it against GitHub release tags, and a stale '
          'constant offers users an update to the build they already run',
    );
  });

  test('the shipped version never reads as an update to itself', () async {
    final check = await checkAgainst(appVersion);
    expect(check.failed, isFalse);
    // The banner is driven by info != null (home_shell), so this is the banner
    // staying down — not merely "a check that happened to fail".
    expect(check.info, isNull);
  });

  test('a genuinely newer release still prompts', () async {
    final check = await checkAgainst('99.0.0');
    expect(check.failed, isFalse);
    expect(check.info?.version, '99.0.0');
    expect(check.info?.downloadUrl, isNotNull);
  });
}
