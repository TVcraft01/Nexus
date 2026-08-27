import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/store.dart';

void main() {
  test('concurrent saves never race the temp-file rename', () async {
    final tmp = await Directory.systemTemp.createTemp('nexus_store_test');
    addTearDown(() => tmp.delete(recursive: true));
    final store = NexusStore(explicitPath: '${tmp.path}/state.json')
      ..clipboardSync = false;
    await store.save();

    // Fire many saves without awaiting between them. The old implementation
    // raced here: two writes to the same `.tmp` path, one rename deleting the
    // other's file mid-write -> FileSystemException on the losing rename.
    await Future.wait([for (var i = 0; i < 25; i++) store.save()]);

    // Everything must have landed: the file exists and holds the last state.
    final reloaded = NexusStore(explicitPath: '${tmp.path}/state.json');
    await reloaded.load();
    expect(reloaded.clipboardSync, isFalse);
  });

  test('a failed save is swallowed and later saves still persist', () async {
    final tmp = await Directory.systemTemp.createTemp('nexus_store_fail');
    addTearDown(() => tmp.delete(recursive: true));
    final path = '${tmp.path}/state.json';
    final store = NexusStore(explicitPath: path)..clipboardSync = true;
    await store.save();
    expect(File(path).existsSync(), isTrue);

    // Block the atomic rename: a directory now occupies the target path,
    // so the next save's tmp -> final rename fails on POSIX.
    await File(path).delete();
    await Directory(path).create();

    // Persistence is best-effort — a failed write must never throw at
    // callers (they save with `unawaited(...)`).
    var threw = false;
    try {
      await store.save();
    } catch (_) {
      threw = true;
    }
    expect(threw, isFalse, reason: 'best-effort save must not throw');

    // Remove the blocker: the next save must land. A poisoned chain would
    // have silently skipped every later save forever.
    await Directory(path).delete();
    store.clipboardSync = false;
    await store.save();
    final reloaded = NexusStore(explicitPath: path);
    await reloaded.load();
    expect(reloaded.clipboardSync, isFalse);
  });
}
