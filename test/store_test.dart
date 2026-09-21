import 'dart:convert';
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

  group('agent facts', () {
    // A fact as the memory model stores it: the words plus where they came
    // from. This is `MemoryFact.toJson()` verbatim, which is what is sitting in
    // the state file on the real phone this was found on. An older Nexus stored
    // bare text, and a store can hold both at once.
    const stamped = {
      'text': 'my bicycle lock combination is four three two one',
      'stamp': {
        'origin': 'explicit',
        'source': "TVcraft01' phone",
        'learnedAt': '2026-09-20T10:03:22.050322',
      },
    };

    /// Loads a store from a state file whose facts are [facts], and hands back
    /// the file's path so the test can read what a later save wrote.
    Future<(NexusStore, String)> withFacts(List<Object?> facts) async {
      final tmp = await Directory.systemTemp.createTemp('nexus_facts');
      addTearDown(() => tmp.delete(recursive: true));
      final path = '${tmp.path}/state.json';
      await File(path).writeAsString(jsonEncode({
        'agent': {'facts': facts},
      }));
      final store = NexusStore(explicitPath: path)..clipboardSync = false;
      await store.load();
      return (store, path);
    }

    List<Object?> storedFacts(String path) {
      final json = jsonDecode(File(path).readAsStringSync());
      return ((json as Map<String, dynamic>)['agent']
          as Map<String, dynamic>)['facts'] as List<Object?>;
    }

    test('a fact stored as an object is read, not fatal', () async {
      final (store, _) = await withFacts([
        stamped,
        'my wifi password is nexus',
      ]);

      // This is the shape the memory model writes. Reading the list as bare
      // strings used to throw inside the assistant's constructor, which took
      // the whole home screen down to an error box on a real phone.
      expect(store.agentFacts, [
        'my bicycle lock combination is four three two one',
        'my wifi password is nexus',
      ]);
    });

    test('writing back keeps a stored object and its provenance', () async {
      final (store, path) = await withFacts([stamped]);
      store.agentFacts = [
        ...store.agentFacts,
        'the spare key is under the pot',
      ];
      await store.save();

      final raw = storedFacts(path);
      expect(
        raw.first,
        stamped,
        reason: 'an entry this build did not write keeps the shape it had',
      );
      expect(raw.last, 'the spare key is under the pot');
      expect(store.agentFacts.length, 2);
    });

    test('removing a fact removes it, and leaves the rest alone', () async {
      final (store, path) = await withFacts([stamped, 'keep me']);
      store.agentFacts = ['keep me'];
      await store.save();

      expect(storedFacts(path), ['keep me']);
    });

    test('an entry that cannot be read is skipped, not thrown', () async {
      final (store, _) = await withFacts([42, {'no': 'text'}, 'a real fact']);
      expect(store.agentFacts, ['a real fact']);
    });
  });
}

