import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'store.dart';

/// Where the long-term offline-pairing identity seed lives.
///
/// It is deliberately not [NexusStore]: that file is plain JSON holding the
/// device's history, and the one key that protects every future pairing should
/// not sit beside it. This interface is small on purpose — read, write, delete
/// one `{v, seed}` record — so the platform store can be swapped in a test
/// without a plugin.
abstract class IdentitySeedStore {
  Future<Map<String, dynamic>?> read();

  Future<void> write(Map<String, dynamic> identity);

  Future<void> delete();
}

/// The platform's own secret store: Android Keystore (via a namespaced secure
/// preference), the Keychain on iOS/macOS, libsecret on Linux, the Credential
/// Manager on Windows.
///
/// The namespace is fixed and distinct (`nexus`) so this can never collide with
/// another plugin's storage in this app — the v11 crash-loop was a namespace
/// collision, and the seeded key prefix keeps a value written by one build from
/// being read as a different one by the next.
class PlatformIdentitySeedStore implements IdentitySeedStore {
  /// The storage key. Versioned: a future scheme writes `nexus.identity.v2`
  /// rather than reinterpreting v1 bytes.
  static const String storageKey = 'nexus.identity.v1';

  /// The Android secure-storage namespace. Also the name of the preference
  /// file the OS backs up unless the backup rules exclude it (and they do:
  /// `res/xml/backup_rules.xml` and `data_extraction_rules.xml`).
  static const String storageNamespace = 'nexus';

  final FlutterSecureStorage _storage;

  PlatformIdentitySeedStore([FlutterSecureStorage? storage])
    : _storage =
          storage ??
          FlutterSecureStorage(
            aOptions: const AndroidOptions(
              storageNamespace: storageNamespace,
            ),
          );

  @override
  Future<Map<String, dynamic>?> read() async {
    final raw = await _storage.read(key: storageKey);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
    } on FormatException {
      // A value this build cannot read is not a key; treat it as absent so a
      // fresh identity can be made instead of the app failing to start.
    }
    return null;
  }

  @override
  Future<void> write(Map<String, dynamic> identity) =>
      _storage.write(key: storageKey, value: jsonEncode(identity));

  @override
  Future<void> delete() => _storage.delete(key: storageKey);
}

/// A 0600 file in the app's private config directory.
///
/// This is the Linux fallback for a machine with no keyring service running.
/// It is WEAKER than Keystore or the Keychain: it protects the seed from other
/// users on the machine, not from root and not from a copy of the whole home
/// directory. It exists so pairing works on a bare desktop instead of failing
/// with a plugin error, and it is never described as equivalent.
class FileIdentitySeedStore implements IdentitySeedStore {
  static const String fileName = 'identity.seed';

  final String? explicitPath;

  FileIdentitySeedStore({this.explicitPath});

  Future<File> _file() async {
    if (explicitPath != null) return File(explicitPath!);
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}nexus'
        '${Platform.pathSeparator}$fileName');
  }

  @override
  Future<Map<String, dynamic>?> read() async {
    final file = await _file();
    if (!await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, dynamic>) return decoded;
    } on FormatException {
      return null;
    }
    return null;
  }

  @override
  Future<void> write(Map<String, dynamic> identity) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(identity), flush: true);
    await _restrict(file.parent.path, '700');
    await _restrict(file.path, '600');
  }

  @override
  Future<void> delete() async {
    final file = await _file();
    if (await file.exists()) await file.delete();
  }

  /// Dart has no `chmod`, so the mode is set with the platform tool. A failure
  /// is logged without the path's contents (never the seed) and does not stop
  /// the write: a store that cannot be read is worse than one with a loose mode.
  Future<void> _restrict(String path, String mode) async {
    if (Platform.isWindows) return;
    try {
      final result = await Process.run('chmod', [mode, path]);
      if (result.exitCode != 0) {
        debugPrint('NEXUS identity: could not set $mode on the seed file');
      }
    } catch (_) {
      debugPrint('NEXUS identity: could not set $mode on the seed file');
    }
  }
}

/// Tries the platform store first and falls back to [fallback] when the
/// platform store is unavailable (a Linux desktop with no keyring service, or
/// a test with no plugin registered).
///
/// Only ever used where a fallback is better than a hard failure: on Android
/// and iOS the secure store IS the mechanism, and a silent downgrade to a file
/// would be the exact thing this work exists to prevent.
class FallbackIdentitySeedStore implements IdentitySeedStore {
  final IdentitySeedStore primary;
  final IdentitySeedStore fallback;

  /// Set once the primary store has failed, so one bad call does not pay the
  /// timeout twice on every later pairing.
  bool _primaryDown = false;

  FallbackIdentitySeedStore({required this.primary, required this.fallback});

  /// Whether this store had to use its fallback at least once. Read by the UI
  /// layer if it ever needs to say so; never logged with a secret.
  bool get usingFallback => _primaryDown;

  @override
  Future<Map<String, dynamic>?> read() async {
    if (!_primaryDown) {
      try {
        return await primary.read();
      } catch (e) {
        _primaryDown = true;
        debugPrint('NEXUS identity: platform store unavailable (${e.runtimeType})');
      }
    }
    return fallback.read();
  }

  @override
  Future<void> write(Map<String, dynamic> identity) async {
    if (!_primaryDown) {
      try {
        await primary.write(identity);
        // The plain file must not outlive a working secure write.
        await fallback.delete();
        return;
      } catch (e) {
        _primaryDown = true;
        debugPrint('NEXUS identity: platform store unavailable (${e.runtimeType})');
      }
    }
    await fallback.write(identity);
  }

  @override
  Future<void> delete() async {
    var failed = false;
    try {
      await primary.delete();
    } catch (_) {
      failed = true;
    }
    await fallback.delete();
    if (failed && !_primaryDown) {
      debugPrint('NEXUS identity: platform store could not delete the seed');
    }
  }
}

/// The seed store for the platform this build is running on.
///
/// Linux gets the keyring where it can and a 0600 file where it cannot; every
/// other platform gets its own secure store and nothing else.
IdentitySeedStore identitySeedStoreForThisPlatform({
  FlutterSecureStorage? storage,
  String? linuxFallbackPath,
}) {
  final secure = PlatformIdentitySeedStore(storage);
  if (Platform.isLinux) {
    return FallbackIdentitySeedStore(
      primary: secure,
      fallback: FileIdentitySeedStore(explicitPath: linuxFallbackPath),
    );
  }
  return secure;
}

/// Moves the seed out of [NexusStore]'s plain JSON and into a [secure] store.
///
/// This is the migration for every device that paired offline with the first
/// build of the feature, whose seed was written to `state.json`. Reads prefer
/// the secure copy; the plain copy is deleted as soon as the secure one exists,
/// so the file on disk stops carrying the key. Running it twice is a no-op the
/// second time, because the legacy key is gone and the secure one is found.
class MigratingIdentitySeedStore implements IdentitySeedStore {
  final NexusStore legacy;
  final IdentitySeedStore secure;

  MigratingIdentitySeedStore({required this.legacy, required this.secure});

  @override
  Future<Map<String, dynamic>?> read() async {
    final saved = await secure.read();
    if (saved != null) {
      await _forgetLegacy();
      return saved;
    }
    final old = legacy.offlinePairingIdentity;
    if (old == null) return null;
    await secure.write(old);
    await _forgetLegacy();
    return old;
  }

  @override
  Future<void> write(Map<String, dynamic> identity) async {
    await secure.write(identity);
    await _forgetLegacy();
  }

  @override
  Future<void> delete() async {
    await secure.delete();
    await _forgetLegacy();
  }

  /// Removes the plain-JSON copy and rewrites the file so the key is gone from
  /// disk, not just from the in-memory map.
  Future<void> _forgetLegacy() async {
    if (legacy.offlinePairingIdentity == null) return;
    legacy.offlinePairingIdentity = null;
    await legacy.save();
  }
}
