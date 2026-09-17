import 'dart:convert';
import 'dart:io';

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
    Future<UpdateCheck> checked(String latest, String current) {
      return Updater.checkForUpdate(
        currentVersion: current,
        fetch: (_) async => UpdateResponse(200, latest),
      );
    }

    Future<UpdateCheck> checkStatus(int status, String body,
        {String current = '0.1.1'}) {
      return Updater.checkForUpdate(
        currentVersion: current,
        fetch: (_) async => UpdateResponse(status, body),
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

    test('reports update info when a newer release exists', () async {
      final check = await checked(release('v0.2.0'), '0.1.1');
      expect(check.failed, isFalse);
      expect(check.info, isNotNull);
      expect(check.info!.version, '0.2.0');
      // downloadUrl should be set for at least one platform asset.
      expect(check.info!.downloadUrl, isNotNull);
    });

    test('reports up to date only when the release is not newer', () async {
      for (final tag in ['v0.1.1', 'v0.1.0']) {
        final check = await checked(release(tag), '0.1.1');
        expect(check.info, isNull);
        expect(check.failed, isFalse,
            reason: 'a real answer of "nothing newer" is not a failure');
      }
    });

    test('a refused answer is a failure that names the reason, never '
        '"up to date"', () async {
      // GitHub rate-limits by network, so this is what a phone on mobile data
      // sees — and the body is JSON, so a check that ignored the status read it
      // as "no update" and told the user they were up to date.
      final limited = await checkStatus(
        403,
        '{"message":"API rate limit exceeded for 1.2.3.4"}',
      );
      expect(limited.info, isNull);
      expect(limited.failed, isTrue);
      expect(limited.failure, contains('rate-limiting'));

      final missing = await checkStatus(404, '{"message":"Not Found"}');
      expect(missing.info, isNull);
      expect(missing.failed, isTrue);
      expect(missing.failure, contains('no Nexus release'));

      final other = await checkStatus(500, 'oops');
      expect(other.info, isNull);
      expect(other.failure, contains('500'));
    });

    test('an unreadable answer is a failure, not an up-to-date one', () async {
      final check = await checked('not json at all', '0.1.1');
      expect(check.info, isNull);
      expect(check.failed, isTrue);
      expect(check.failure, contains('could not read'));
    });

    test('a network that cannot reach GitHub is a failure, not an up-to-date '
        'one', () async {
      final check = await Updater.checkForUpdate(
        currentVersion: '0.1.1',
        fetch: (_) async => throw const SocketException('no route to host'),
      );
      expect(check.info, isNull);
      expect(check.failed, isTrue);
      expect(check.failure, contains('could not reach GitHub'));
    });

    test('a release without this platform\'s build says so', () async {
      final check = await checked(release('v0.2.0', assets: []), '0.1.1');
      expect(check.info, isNull);
      expect(check.failed, isTrue);
      expect(check.failure, contains('without a'));
    });
  });

  group('updateHandoffNote', () {
    test('a hand-off that needs nothing from the user says nothing', () {
      expect(updateHandoffNote(UpdateApply.applied), isNull);
      // A failure is reported by the caller's own error, not by a note.
      expect(updateHandoffNote(UpdateApply.failed), isNull);
    });

    test('the Android permission step explains what that screen is for', () {
      final note = updateHandoffNote(UpdateApply.needsPermission);
      expect(note, isNotNull);
      expect(note, contains('Allow Nexus to install this update'));
      // The platform resumes the install by itself, and the user has to be told
      // so they don't back out thinking it failed.
      expect(note, contains('continues by itself'));
    });

    test('an open installer is acknowledged', () {
      expect(
        updateHandoffNote(UpdateApply.installerOpened),
        contains('installer is open'),
      );
    });
  });
}
