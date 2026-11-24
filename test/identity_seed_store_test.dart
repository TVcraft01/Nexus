// The identity seed lives in the platform store, not in the app's plain JSON.
//
// Every store here is a fake or a temp file: the point of these tests is the
// policy (where the seed goes, what happens to the old copy, what a fallback
// may and may not do), not the plugin's own Keystore handling.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/identity_seed_store.dart';
import 'package:nexus/core/store.dart';

/// A stand-in for the platform store: a map, plus a count of writes so the
/// migration's idempotence is visible.
class _MemorySeedStore implements IdentitySeedStore {
  final Map<String, Map<String, dynamic>> values = {};
  int writes = 0;

  @override
  Future<Map<String, dynamic>?> read() async {
    final value = values['seed'];
    return value == null ? null : Map<String, dynamic>.of(value);
  }

  @override
  Future<void> write(Map<String, dynamic> identity) async {
    writes++;
    values['seed'] = Map<String, dynamic>.of(identity);
  }

  @override
  Future<void> delete() async {
    values.clear();
  }
}

/// A platform store with no keyring behind it.
class _BrokenSeedStore implements IdentitySeedStore {
  @override
  Future<Map<String, dynamic>?> read() async => throw Exception('no keyring');

  @override
  Future<void> write(Map<String, dynamic> identity) async =>
      throw Exception('no keyring');

  @override
  Future<void> delete() async => throw Exception('no keyring');
}

const _seed = {'v': 1, 'seed': 'c2VlZC1ieXRlcy10aGF0LW11c3Qtc3RheS1zZWNyZXQ='};

void main() {
  late Directory tmp;
  late NexusStore legacy;
  late String storePath;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('nexus_seed_store');
    storePath = '${tmp.path}/state.json';
    legacy = NexusStore(explicitPath: storePath);
    await legacy.load();
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  /// The plain file as it actually sits on disk, after a save.
  Future<String> storeText() async => File(storePath).readAsString();

  group('migration from the plain state file', () {
    test('moves the seed and deletes the plain copy', () async {
      legacy.offlinePairingIdentity = Map<String, dynamic>.of(_seed);
      await legacy.save();
      expect(await storeText(), contains('c2VlZC1ieXRlcy'));

      final secure = _MemorySeedStore();
      final store = MigratingIdentitySeedStore(legacy: legacy, secure: secure);

      final read = await store.read();
      expect(read, _seed);
      expect(secure.values['seed'], _seed);
      expect(secure.writes, 1);

      // Gone from the in-memory store and from the file on disk.
      expect(legacy.offlinePairingIdentity, isNull);
      expect(await storeText(), isNot(contains('c2VlZC1ieXRlcy')));
      expect(await storeText(), isNot(contains('offlinePairingIdentity')));
    });

    test('running it twice is a no-op the second time', () async {
      legacy.offlinePairingIdentity = Map<String, dynamic>.of(_seed);
      await legacy.save();

      final secure = _MemorySeedStore();
      final store = MigratingIdentitySeedStore(legacy: legacy, secure: secure);
      await store.read();
      await store.read();

      expect(secure.writes, 1, reason: 'the secure copy is found, not rewritten');
      expect(await store.read(), _seed);
      expect(legacy.offlinePairingIdentity, isNull);
    });

    test('a secure copy wins and still clears a stale plain copy', () async {
      final secure = _MemorySeedStore();
      await secure.write({'v': 1, 'seed': 'bmV3LXNlZWQ='});
      legacy.offlinePairingIdentity = Map<String, dynamic>.of(_seed);
      await legacy.save();

      final store = MigratingIdentitySeedStore(legacy: legacy, secure: secure);
      final read = await store.read();

      expect(read, {'v': 1, 'seed': 'bmV3LXNlZWQ='});
      expect(secure.writes, 1);
      expect(legacy.offlinePairingIdentity, isNull);
      expect(await storeText(), isNot(contains('c2VlZC1ieXRlcy')));
    });

    test('a write through the migrating store never lands in the plain file',
        () async {
      final secure = _MemorySeedStore();
      final store = MigratingIdentitySeedStore(legacy: legacy, secure: secure);

      await store.write(_seed);
      await legacy.save();

      expect(secure.values['seed'], _seed);
      expect(legacy.offlinePairingIdentity, isNull);
      expect(await storeText(), isNot(contains('c2VlZC1ieXRlcy')));
    });

    test('deleting forgets it in both places', () async {
      legacy.offlinePairingIdentity = Map<String, dynamic>.of(_seed);
      await legacy.save();
      final secure = _MemorySeedStore();
      final store = MigratingIdentitySeedStore(legacy: legacy, secure: secure);
      await store.read();

      await store.delete();

      expect(await store.read(), isNull);
      expect(legacy.offlinePairingIdentity, isNull);
      expect(await storeText(), isNot(contains('c2VlZC1ieXRlcy')));
    });

    test('a device with no seed at all reads null and writes nothing', () async {
      final secure = _MemorySeedStore();
      final store = MigratingIdentitySeedStore(legacy: legacy, secure: secure);

      expect(await store.read(), isNull);
      expect(secure.writes, 0);
    });
  });

  group('the platform store falling back', () {
    test('a missing keyring writes a 0600 file instead', () async {
      final file = File('${tmp.path}/config/identity.seed');
      final fallback = FileIdentitySeedStore(explicitPath: file.path);
      final store = FallbackIdentitySeedStore(
        primary: _BrokenSeedStore(),
        fallback: fallback,
      );

      await store.write(_seed);

      expect(store.usingFallback, isTrue);
      expect(await file.exists(), isTrue);
      expect(await store.read(), _seed);
      if (!Platform.isWindows) {
        expect(
          file.statSync().modeString(),
          'rw-------',
          reason: 'the seed file must not be readable by other users',
        );
      }
    });

    test('once the platform store works, the plain file is removed', () async {
      final file = File('${tmp.path}/config/identity.seed');
      final fallback = FileIdentitySeedStore(explicitPath: file.path);
      await fallback.write(_seed);

      final secure = _MemorySeedStore();
      final store = FallbackIdentitySeedStore(
        primary: secure,
        fallback: fallback,
      );

      await store.write({'v': 1, 'seed': 'bmV3LXNlZWQ='});

      expect(await file.exists(), isFalse);
      expect(secure.values['seed'], {'v': 1, 'seed': 'bmV3LXNlZWQ='});
      expect(store.usingFallback, isFalse);
    });
  });

  group('the file store on its own', () {
    test('round-trips, survives a missing directory, and deletes', () async {
      final file = File('${tmp.path}/nested/deeper/identity.seed');
      final store = FileIdentitySeedStore(explicitPath: file.path);

      expect(await store.read(), isNull);
      await store.write(_seed);
      expect(await store.read(), _seed);

      await store.delete();
      expect(await store.read(), isNull);
      expect(await file.exists(), isFalse);
    });

    test('a damaged file reads as no seed rather than throwing', () async {
      final file = File('${tmp.path}/damaged.seed');
      await file.writeAsString('not json at all');
      final store = FileIdentitySeedStore(explicitPath: file.path);
      expect(await store.read(), isNull);
    });
  });

  group('the seed never reaches a log', () {
    test('the files that hold it do not print anything', () async {
      // A deliberate, narrow check: these three files are the only ones that
      // ever hold the seed, and none of them may print a line at all, let alone
      // one containing it. (Errors only mention an exception's runtime type.)
      for (final path in [
        'lib/core/identity_seed_store.dart',
        'lib/mesh/offline_pairing.dart',
        'lib/mesh/mesh_offline.dart',
      ]) {
        final source = await File(path).readAsString();
        final lines = source.split('\n');
        for (final line in lines) {
          expect(
            line.contains('print(') && !line.contains('debugPrint('),
            isFalse,
            reason: '$path must not print: $line',
          );
          // A diagnostic may say the word ("could not set 0600 on the seed
          // file"); it may never interpolate the value. These are the names
          // that hold it.
          for (final variable in [r'$seed', r'${seed', r'$identity', r'$raw']) {
            expect(
              line.contains('debugPrint(') && line.contains(variable),
              isFalse,
              reason: '$path must not print the seed value: $line',
            );
          }
        }
      }
    });
  });
}
