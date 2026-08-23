import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/mesh/updater.dart';

void main() {
  group('compareVersions', () {
    test('orders versions correctly', () {
      expect(Updater.compareVersions('0.1.0', '0.1.1'), lessThan(0));
      expect(Updater.compareVersions('0.1.1', '0.1.0'), greaterThan(0));
      expect(Updater.compareVersions('0.2.0', '0.1.9'), greaterThan(0));
      expect(Updater.compareVersions('1.0.0', '0.9.9'), greaterThan(0));
      expect(Updater.compareVersions('0.1.1', '0.1.1'), 0);
    });

    test('handles v prefixes and build metadata', () {
      expect(Updater.compareVersions('v0.1.1', '0.1.1'), 0);
      expect(Updater.compareVersions('0.1.1+2', '0.1.1'), 0);
      expect(Updater.compareVersions('v0.2.0', '0.1.9'), greaterThan(0));
    });

    test('handles short and malformed versions without crashing', () {
      expect(Updater.compareVersions('0.1', '0.1.0'), 0);
      expect(Updater.compareVersions('abc', '0.1.0'), lessThan(0));
    });
  });

  group('checkForUpdate', () {
    Future<UpdateInfo?> check(String latest, String current) {
      return Updater.checkForUpdate(
        currentVersion: current,
        fetch: (_) async => latest,
      );
    }

    /// Helper: builds a fake GitHub release JSON with the given assets.
    String release(String tag, {List<Map<String, String>>? assets}) => jsonEncode({
          'tag_name': tag,
          'body': 'Release notes',
          'assets': assets ??
              [
                {
                  'name': 'nexus-linux-x64.tar.gz',
                  'browser_download_url': 'https://example.com/n.tar.gz'
                },
                {
                  'name': 'nexus.apk',
                  'browser_download_url': 'https://example.com/n.apk'
                },
              ],
        });

    test('returns update info when a newer release exists', () async {
      final info = await check(release('v0.2.0'), '0.1.1');
      expect(info, isNotNull);
      expect(info!.version, '0.2.0');
      // downloadUrl should be set for at least one platform asset.
      expect(info.downloadUrl, isNotNull);
    });

    test('returns null when the release is not newer', () async {
      expect(await check(release('v0.1.1'), '0.1.1'), isNull);
      expect(await check(release('v0.1.0'), '0.1.1'), isNull);
    });

    test('returns null when there is no release yet or GitHub errors',
        () async {
      expect(await check('404: Not Found', '0.1.1'), isNull);
      expect(await check('not json at all', '0.1.1'), isNull);
    });

    test('returns null when the archive asset is missing', () async {
      final info = await check(release('v0.2.0', assets: []), '0.1.1');
      expect(info, isNotNull);
      expect(info!.downloadUrl, isNull);
    });
  });
}
