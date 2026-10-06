// The download/serve root decision, pinned without a phone.
//
// The bug this guards: on Android the save root resolved to the app's own
// external folder, which the Files app hides, so a fetched file was invisible
// to the user. These tests pin the three cases that matter — all-files access
// granted, denied, and desktop — against the pure resolvers.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/storage_roots.dart';

void main() {
  group('download root', () {
    test('Android with all-files access saves to the shared Download folder', () {
      final root = resolveDownloadRoot(
        android: true,
        allFilesAccess: true,
        sharedRoot: '/storage/emulated/0',
        platformDownloads: '/storage/emulated/0/Android/data/dev.nexus.nexus/files/Download',
        documents: '/data/user/0/dev.nexus.nexus/app_flutter',
      );
      expect(root.path, '/storage/emulated/0/Download');
      expect(root.appScoped, isFalse);
    });

    test('Android without all-files access falls back to app-scoped storage', () {
      const scoped =
          '/storage/emulated/0/Android/data/dev.nexus.nexus/files/Download';
      final root = resolveDownloadRoot(
        android: true,
        sharedRoot: '/storage/emulated/0',
        platformDownloads: scoped,
        documents: '/data/user/0/dev.nexus.nexus/app_flutter',
      );
      expect(root.path, scoped);
      expect(root.appScoped, isTrue);
    });

    test('Android without any downloads dir still lands app-scoped', () {
      final root = resolveDownloadRoot(
        android: true,
        documents: '/data/user/0/dev.nexus.nexus/app_flutter',
      );
      expect(root.path, '/data/user/0/dev.nexus.nexus/app_flutter');
      expect(root.appScoped, isTrue);
    });

    test('desktop keeps path_provider, then \$HOME/Downloads, then documents', () {
      expect(
        resolveDownloadRoot(
          android: false,
          platformDownloads: '/home/me/Downloads',
          home: '/home/me',
          documents: '/home/me/Documents',
        ).path,
        '/home/me/Downloads',
      );
      expect(
        resolveDownloadRoot(
          android: false,
          home: '/home/me',
          documents: '/home/me/Documents',
        ).path,
        '/home/me${Platform.pathSeparator}Downloads',
      );
      expect(
        resolveDownloadRoot(android: false, documents: '/home/me/Documents').path,
        '/home/me/Documents',
      );
    });
  });

  group('serve root', () {
    test('Android serves the shared storage once all-files access is granted',
        () {
      final root = resolveServeRoot(
        android: true,
        allFilesAccess: true,
        sharedRoot: '/storage/emulated/0',
        external: '/storage/emulated/0/Android/data/dev.nexus.nexus/files',
      );
      expect(root.path, '/storage/emulated/0');
      expect(root.appScoped, isFalse);
    });

    test('Android without access serves only the app-scoped folder', () {
      final root = resolveServeRoot(
        android: true,
        external: '/storage/emulated/0/Android/data/dev.nexus.nexus/files',
        documents: '/data/user/0/dev.nexus.nexus/app_flutter',
      );
      expect(
        root.path,
        '/storage/emulated/0/Android/data/dev.nexus.nexus/files',
      );
      expect(root.appScoped, isTrue);
    });

    test('desktop serves the home folder', () {
      expect(
        resolveServeRoot(android: false, home: '/home/me').path,
        '/home/me',
      );
    });
  });

  test('the app-scoped note names the folder and the fix', () {
    expect(appScopedDownloadNote, contains('app folder'));
    expect(appScopedDownloadNote, contains('All files access'));
    expect(appScopedDownloadNote, contains('Downloads'));
  });
}
