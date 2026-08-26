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
}
