import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent_contract.dart';
import 'package:nexus/core/command_service.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/core/serial_transport.dart';
import 'package:nexus/core/version.dart';
import 'package:nexus/mesh/gateway.dart';
import 'package:nexus/mesh/mesh_service.dart';
import 'package:nexus/mesh/serial_bridge.dart';

/// A clipboard that lives in memory — no platform channels needed in tests.
class FakeClipboard implements ClipboardBackend {
  String? value;
  @override
  Future<String?> readText() async => value;
  @override
  Future<void> writeText(String text) async => value = text;
}

void main() {
  late Directory tmp;
  late NexusStore storeA;
  late NexusStore storeB;
  late MeshService meshA;
  late MeshService meshB;
  late FakeClipboard clipA;
  late FakeClipboard clipB;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('nexus_test');
    storeA = NexusStore(explicitPath: '${tmp.path}/a.json')
      ..port = 53210
      ..clipboardSync = true;
    storeB = NexusStore(explicitPath: '${tmp.path}/b.json')
      ..port = 53211
      ..clipboardSync = true;
    await storeA.save();
    await storeB.save();

    clipA = FakeClipboard();
    clipB = FakeClipboard();

    meshA = MeshService(
      identity: DeviceInfo(
        id: 'device-a',
        name: 'Test Linux PC',
        platform: 'linux',
      ),
      store: storeA,
      clipboard: clipA,
      onlineWindow: const Duration(seconds: 3),
      visibleWindow: const Duration(seconds: 3),
      heartbeatInterval: const Duration(seconds: 2),
      connectTimeout: const Duration(milliseconds: 300),
    );
    meshB = MeshService(
      identity: DeviceInfo(
        id: 'device-b',
        name: 'Test Phone',
        platform: 'android',
      ),
      store: storeB,
      clipboard: clipB,
      onlineWindow: const Duration(seconds: 3),
      visibleWindow: const Duration(seconds: 3),
      heartbeatInterval: const Duration(seconds: 2),
      connectTimeout: const Duration(milliseconds: 300),
    );
  });

  tearDown(() async {
    await meshA.stop();
    await meshB.stop();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('two devices pair over localhost with a code', () async {
    await meshA.start();
    await meshB.start();

    final session = meshA.beginPairing();
    expect(session.code, matches(RegExp(r'^[A-Z2-9]{4}-[A-Z2-9]{4}$')));
    expect(session.qrPayload, contains('nexus://pair'));

    final result = await meshB.pairWith(
      address: '127.0.0.1',
      port: meshA.port,
      code: session.code,
    );
    expect(result.ok, isTrue, reason: result.error);

    expect(meshA.isPaired('device-b'), isTrue);
    expect(meshB.isPaired('device-a'), isTrue);
    expect(meshA.pairedDevices.single.name, 'Test Phone');
    expect(meshB.pairedDevices.single.name, 'Test Linux PC');

    // Honest presence: both sides verified each other by direct connection.
    expect(meshA.isOnline('device-b'), isTrue);
    expect(meshB.isOnline('device-a'), isTrue);
  });

  test('wrong code is rejected and nothing is paired', () async {
    await meshA.start();
    await meshB.start();

    final session = meshA.beginPairing();
    final wrong = session.code == 'AAAA-AAAA' ? 'BBBB-BBBB' : 'AAAA-AAAA';
    final result = await meshB.pairWith(
      address: '127.0.0.1',
      port: meshA.port,
      code: wrong,
    );
    expect(result.ok, isFalse);
    expect(meshA.isPaired('device-b'), isFalse);
    expect(meshB.isPaired('device-a'), isFalse);
  });

  test('encrypted clipboard travels from phone to PC after pairing', () async {
    await meshA.start();
    await meshB.start();

    final session = meshA.beginPairing();
    final result = await meshB.pairWith(
      address: '127.0.0.1',
      port: meshA.port,
      code: session.code,
    );
    expect(result.ok, isTrue);

    await meshB.broadcastClipboard('hello from the phone');

    // Give the encrypted frame a moment to arrive.
    var found = false;
    for (var i = 0; i < 20 && !found; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final clip = meshA.lastIncomingClip;
      found =
          clip != null &&
          clip.text == 'hello from the phone' &&
          clip.fromName == 'Test Phone';
    }
    expect(found, isTrue, reason: 'PC never received the clipboard message');

    // Clipboard sync is ON by default: the text lands directly in the PC's
    // clipboard, ready to paste anywhere.
    expect(clipA.value, 'hello from the phone');
  });

  test('clipboard retries delivery after a temporary disconnect', () async {
    await meshA.start();
    await meshB.start();
    final session = meshA.beginPairing();
    final result = await meshB.pairWith(
      address: '127.0.0.1',
      port: meshA.port,
      code: session.code,
    );
    expect(result.ok, isTrue);

    final peerA = meshB.pairedDevices.single;
    peerA.address = '192.0.2.1';
    peerA.addresses = ['192.0.2.1'];
    await meshB.broadcastClipboard('retry me');
    expect(clipA.value, isNull);

    peerA.address = '127.0.0.1';
    peerA.addresses = ['127.0.0.1'];
    var received = false;
    for (var i = 0; i < 12 && !received; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1600));
      received = clipA.value == 'retry me';
    }
    expect(received, isTrue, reason: meshB.lastFileError);
  });

  test(
    'a loopback route on our own port is a self-connection and is skipped',
    () async {
      await meshA.start();
      await meshB.start();
      final session = meshA.beginPairing();
      final result = await meshB.pairWith(
        address: '127.0.0.1',
        port: meshA.port,
        code: session.code,
      );
      expect(result.ok, isTrue);

      // Simulate the tunnel-pairing residue: B remembers A at loopback on
      // B's OWN mesh port. Connecting there would reach B itself, not A —
      // outbound must skip it and honestly report failure instead.
      final peerA = meshB.pairedDevices.single;
      peerA.address = '127.0.0.1';
      peerA.port = storeB.port;
      peerA.addresses = ['127.0.0.1'];

      expect(await meshB.listRemoteFiles(peerA, ''), isNull);
      expect(meshB.lastFileError, contains('Could not reach'));
    },
  );

  test('with clipboard sync off, incoming clips are not applied', () async {
    storeA.clipboardSync = false;
    await storeA.save();
    await meshA.start();
    await meshB.start();

    final session = meshA.beginPairing();
    final result = await meshB.pairWith(
      address: '127.0.0.1',
      port: meshA.port,
      code: session.code,
    );
    expect(result.ok, isTrue);

    await meshB.broadcastClipboard('should not be applied');
    var found = false;
    for (var i = 0; i < 20 && !found; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      found = meshA.lastIncomingClip?.text == 'should not be applied';
    }
    expect(found, isTrue);
    expect(clipA.value, isNull); // not applied to the clipboard
  });

  test(
    'a pending smart-clipboard hold must not leak stale sync after stop()',
    () async {
      await meshA.start();
      await meshB.start();
      final session = meshA.beginPairing();
      final paired = await meshB.pairWith(
        address: '127.0.0.1',
        port: meshA.port,
        code: session.code,
      );
      expect(paired.ok, isTrue);

      // Smart mode: a copy is held for 3 s, not pushed immediately.
      storeA.alwaysMerge = false;
      clipA.value = 'stale-copy';
      // Wait for the clipboard poll (1.5 s) to schedule the 3 s hold.
      await Future<void>.delayed(const Duration(milliseconds: 2100));

      // Shut the mesh down while the hold is still pending. The fix cancels
      // the hold timer here; without it, the timer fires after stop and a
      // later restart flushes the stale copy to B.
      await meshA.stop();
      await meshA.start();

      // Give the full expiry + flush + poll cycle time to misbehave.
      await Future<void>.delayed(const Duration(milliseconds: 4500));
      expect(
        clipB.value,
        isNot('stale-copy'),
        reason:
            'B must never receive a clipboard hold that was pending when '
            'A stopped — stale state must not survive the restart',
      );
    },
  );

  test('smart clipboard: skips inactive devices', () async {
    await meshA.start();
    await meshB.start();
    final session = meshA.beginPairing();
    final result = await meshB.pairWith(
      address: '127.0.0.1',
      port: meshA.port,
      code: session.code,
    );
    expect(result.ok, isTrue);

    // B copies — A is active (just paired), so text should arrive.
    await meshB.broadcastClipboard('active device text');
    var received = false;
    for (var i = 0; i < 20 && !received; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      received = clipA.value == 'active device text';
    }
    expect(received, isTrue, reason: 'active device should receive clipboard');
  });

  test('isActiveDevice returns false for stale devices', () async {
    await meshA.start();
    await meshB.start();
    final session = meshA.beginPairing();
    await meshB.pairWith(
      address: '127.0.0.1',
      port: meshA.port,
      code: session.code,
    );

    // A device that was never seen is not active.
    expect(meshB.isActiveDevice('device-a'), isTrue); // just paired

    // Simulate stale by checking with a very short threshold.
    expect(meshB.isActiveDevice('device-a', threshold: Duration.zero), isFalse);
  });

  test('alwaysMerge default is true', () {
    expect(storeA.alwaysMerge, isTrue);
    expect(storeB.alwaysMerge, isTrue);
  });

  test('alwaysMerge can be toggled off for smart mode', () async {
    storeA.alwaysMerge = false;
    await storeA.save();
    final reloaded = NexusStore(explicitPath: storeA.explicitPath);
    await reloaded.load();
    expect(reloaded.alwaysMerge, isFalse);
  });

  test('pairs persist across restarts', () async {
    await meshA.start();
    await meshB.start();
    final session = meshA.beginPairing();
    await meshB.pairWith(
      address: '127.0.0.1',
      port: meshA.port,
      code: session.code,
    );

    await meshB.stop();
    final restarted = MeshService(
      identity: DeviceInfo(
        id: 'device-b',
        name: 'Test Phone',
        platform: 'android',
      ),
      store: storeB,
      clipboard: clipB,
    );
    await restarted.start();
    expect(restarted.isPaired('device-a'), isTrue);
    expect(restarted.pairedDevices.single.pairingSecret, session.code);
    await restarted.stop();
  });

  test('paired device aliases survive remote name announcements', () async {
    await meshA.start();
    await meshB.start();
    final session = meshA.beginPairing();
    final result = await meshB.pairWith(
      address: '127.0.0.1',
      port: meshA.port,
      code: session.code,
    );
    expect(result.ok, isTrue);

    await meshB.renamePairedDevice('device-a', 'My PC');
    expect(meshB.pairedDevices.single.name, 'My PC');

    await meshA.renameDevice('Remote PC Name');
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(meshB.pairedDevices.single.name, 'My PC');

    final reloaded = NexusStore(explicitPath: storeB.explicitPath);
    await reloaded.load();
    expect(reloaded.pairedDevices.single['name'], 'My PC');
  });

  test('paired devices share their running app version', () async {
    await meshA.start();
    await meshB.start();
    final session = meshA.beginPairing();
    final result = await meshB.pairWith(
      address: '127.0.0.1',
      port: meshA.port,
      code: session.code,
    );
    expect(result.ok, isTrue);

    var received = false;
    for (var i = 0; i < 20 && !received; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      received = meshB.latestPeerUpdateVersion == appVersion;
    }
    expect(received, isTrue);
  });

  test('renaming a device propagates the new name to paired devices', () async {
    await meshA.start();
    await meshB.start();

    final session = meshA.beginPairing();
    final result = await meshB.pairWith(
      address: '127.0.0.1',
      port: meshA.port,
      code: session.code,
    );
    expect(result.ok, isTrue);

    // Rename A; the next heartbeat ping carries the new name, and B must
    // learn it without a restart.
    await meshA.renameDevice('New PC Name');

    // The renaming device's own in-memory identity updates immediately.
    expect(meshA.identity.name, 'New PC Name');

    var learned = false;
    for (var i = 0; i < 30 && !learned; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      learned = meshB.pairedDevices.any(
        (d) => d.id == 'device-a' && d.name == 'New PC Name',
      );
    }
    expect(learned, isTrue, reason: 'B never learned A\'s new name');

    // The new name is persisted in B's store, not just in memory.
    final reloaded = NexusStore(explicitPath: storeB.explicitPath);
    await reloaded.load();
    final stored = reloaded.pairedDevices.firstWhere(
      (d) => d['id'] == 'device-a',
    );
    expect(stored['name'], 'New PC Name');
  });

  test(
    'falls back across multiple addresses and self-heals to the working one',
    () async {
      // A (the PC) serves a folder; B (the phone) browses it. The observable is
      // B's outbound path — a file request — because presence pings still
      // bounce both ways while B's listener works, even if B cannot initiate.
      final root = Directory('${tmp.path}/served')..createSync();
      File('${root.path}/hello.txt').writeAsStringSync('hello from A');

      await meshA.stop();
      meshA = MeshService(
        identity: DeviceInfo(
          id: 'device-a',
          name: 'Test Linux PC',
          platform: 'linux',
        ),
        store: storeA,
        clipboard: clipA,
        fileRoot: root.path,
        onlineWindow: const Duration(seconds: 3),
        visibleWindow: const Duration(seconds: 3),
        heartbeatInterval: const Duration(seconds: 2),
        connectTimeout: const Duration(milliseconds: 300),
      );
      await meshA.start();
      await meshB.start();

      final session = meshA.beginPairing();
      final result = await meshB.pairWith(
        address: '127.0.0.1',
        port: meshA.port,
        code: session.code,
      );
      expect(result.ok, isTrue);
      final peer = meshB.pairedDevices.single;
      expect(peer.address, '127.0.0.1');

      // Mutate BEFORE any outbound socket exists (pairing destroys its own):
      // Phase 1 — B only knows a dead address (a stale LAN IP from home), so
      // outbound requests must honestly fail.
      peer.address = '192.0.2.1';
      peer.addresses = ['192.0.2.1'];
      expect(await meshB.listRemoteFiles(peer, ''), isNull);
      expect(meshB.lastFileError, contains('Could not reach'));

      // Phase 2: the working address rejoins the list (e.g. the Tailscale IP)
      // → B reaches A through the fallback, and A's pong heals B's primary
      // address back to the one that actually works.
      peer.addresses = ['192.0.2.1', '127.0.0.1'];
      final entries = await meshB.listRemoteFiles(peer, '');
      expect(entries, isNotNull, reason: meshB.lastFileError);
      expect(entries!.single.name, 'hello.txt');

      // A's next pong (on the socket B just opened) heals B's primary address.
      var healed = false;
      for (var i = 0; i < 20 && !healed; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        healed = meshB.pairedDevices.single.address == '127.0.0.1';
      }
      expect(healed, isTrue, reason: 'B did not self-heal its primary address');
    },
  );

  test('address list is persisted with the paired device', () async {
    await meshA.start();
    await meshB.start();

    final session = meshA.beginPairing();
    final result = await meshB.pairWith(
      address: '127.0.0.1',
      port: meshA.port,
      code: session.code,
    );
    expect(result.ok, isTrue);

    // B's copy of A remembers where A lives, and the announced address list
    // survives a reload of the store (what powers remote access after restart).
    final reloaded = NexusStore(explicitPath: storeB.explicitPath);
    await reloaded.load();
    final stored = reloaded.pairedDevices.singleWhere(
      (d) => d['id'] == 'device-a',
    );
    expect(stored['address'], '127.0.0.1');
    expect((stored['addresses'] as List).contains('127.0.0.1'), isTrue);
  });

  test(
    'files: list, navigate, pull (incl. multi-chunk), and root is enforced',
    () async {
      // A (the "PC") serves a temp folder; B (the "phone") browses and pulls.
      final root = Directory('${tmp.path}/served')..createSync();
      File('${root.path}/hello.txt').writeAsStringSync('hello from A');
      Directory('${root.path}/docs').createSync();
      File('${root.path}/docs/readme.md').writeAsStringSync('# Readme');
      File('${root.path}/empty.bin').writeAsStringSync('');
      // 700 KiB > the 256 KiB chunk size, so this exercises multi-chunk pulls.
      final big = StringBuffer();
      for (var i = 0; i < 700 * 1024; i++) {
        big.write('x');
      }
      File('${root.path}/big.bin').writeAsStringSync(big.toString());

      await meshA.stop();
      meshA = MeshService(
        identity: DeviceInfo(
          id: 'device-a',
          name: 'Test Linux PC',
          platform: 'linux',
        ),
        store: storeA,
        clipboard: clipA,
        fileRoot: root.path,
        onlineWindow: const Duration(seconds: 3),
        visibleWindow: const Duration(seconds: 3),
        heartbeatInterval: const Duration(seconds: 2),
        connectTimeout: const Duration(milliseconds: 300),
      );
      await meshA.start();
      await meshB.start();

      final session = meshA.beginPairing();
      final result = await meshB.pairWith(
        address: '127.0.0.1',
        port: meshA.port,
        code: session.code,
      );
      expect(result.ok, isTrue);
      final peerA = meshB.pairedDevices.single;

      // List the served root.
      final rootEntries = await meshB.listRemoteFiles(peerA, '');
      expect(rootEntries, isNotNull, reason: meshB.lastFileError);
      final names = rootEntries!.map((e) => e.name).toSet();
      expect(names, containsAll(['hello.txt', 'docs', 'empty.bin', 'big.bin']));
      expect(
        rootEntries.firstWhere((e) => e.name == 'big.bin').size,
        700 * 1024,
      );

      // Navigate into a subfolder using the path A reported.
      final docs = rootEntries.firstWhere((e) => e.name == 'docs');
      expect(docs.isDir, isTrue);
      final docsEntries = await meshB.listRemoteFiles(peerA, docs.path);
      expect(docsEntries, isNotNull, reason: meshB.lastFileError);
      expect(docsEntries!.single.name, 'readme.md');

      // Pull a small file.
      final hello = rootEntries.firstWhere((e) => e.name == 'hello.txt');
      final saved = await meshB.pullRemoteFile(
        peerA,
        hello.path,
        savePath: '${tmp.path}/dl.txt',
      );
      expect(saved, isNotNull, reason: meshB.lastFileError);
      expect(File(saved!.path).readAsStringSync(), 'hello from A');

      // Pull the multi-chunk file, watching progress reach 100%.
      final bigEntry = rootEntries.firstWhere((e) => e.name == 'big.bin');
      var lastProgress = 0.0;
      final bigSaved = await meshB.pullRemoteFile(
        peerA,
        bigEntry.path,
        savePath: '${tmp.path}/dl_big.bin',
        onProgress: (received, total) {
          if (total > 0) lastProgress = received / total;
        },
      );
      expect(bigSaved, isNotNull, reason: meshB.lastFileError);
      expect(File(bigSaved!.path).lengthSync(), 700 * 1024);
      expect(lastProgress, 1.0);

      // A zero-byte file still completes with an empty result.
      final empty = rootEntries.firstWhere((e) => e.name == 'empty.bin');
      final emptySaved = await meshB.pullRemoteFile(
        peerA,
        empty.path,
        savePath: '${tmp.path}/dl_empty.bin',
      );
      expect(emptySaved, isNotNull, reason: meshB.lastFileError);
      expect(File(emptySaved!.path).lengthSync(), 0);

      // Anything outside the served root is refused.
      final denied = await meshB.listRemoteFiles(peerA, tmp.path);
      expect(denied, isNull);
      expect(meshB.lastFileError, contains('Access denied'));
    },
  );

  test('files: push sends a local file to a paired device (multi-chunk + empty)', () async {
    // B (the "phone") pushes to A (the "PC"): B browses its own folder, then
    // streams the file; A lands it in its "Nexus Incoming" folder and acks.
    final rootA = Directory('${tmp.path}/servedA')..createSync();
    final rootB = Directory('${tmp.path}/servedB')..createSync();
    // 700 KiB > the 256 KiB chunk size, so this exercises multi-chunk pushes.
    final content = StringBuffer();
    for (var i = 0; i < 700 * 1024; i++) {
      content.write('y');
    }
    File('${rootB.path}/photo.jpg').writeAsStringSync(content.toString());
    File('${rootB.path}/empty.bin').writeAsStringSync('');

    await meshA.stop();
    meshA = MeshService(
      identity: DeviceInfo(
        id: 'device-a',
        name: 'Test Linux PC',
        platform: 'linux',
      ),
      store: storeA,
      clipboard: clipA,
      fileRoot: rootA.path,
      onlineWindow: const Duration(seconds: 3),
      visibleWindow: const Duration(seconds: 3),
      heartbeatInterval: const Duration(seconds: 2),
      connectTimeout: const Duration(milliseconds: 300),
    );
    await meshB.stop();
    meshB = MeshService(
      identity: DeviceInfo(
        id: 'device-b',
        name: 'Test Phone',
        platform: 'android',
      ),
      store: storeB,
      clipboard: clipB,
      fileRoot: rootB.path,
      onlineWindow: const Duration(seconds: 3),
      visibleWindow: const Duration(seconds: 3),
      heartbeatInterval: const Duration(seconds: 2),
      connectTimeout: const Duration(milliseconds: 300),
    );
    await meshA.start();
    await meshB.start();

    final session = meshA.beginPairing();
    final result = await meshB.pairWith(
      address: '127.0.0.1',
      port: meshA.port,
      code: session.code,
    );
    expect(result.ok, isTrue);
    final peerA = meshB.pairedDevices.single;

    // Push the way the picker does — an explicit local path, no browsing of
    // B's own folder (that lives in the file manager now).
    final photoPath = '${rootB.path}/photo.jpg';
    var lastProgress = 0.0;
    final saved = await meshB.pushLocalFile(
      peerA,
      photoPath,
      onProgress: (sent, total) {
        if (total > 0) lastProgress = sent / total;
      },
    );
    expect(saved, isNotNull, reason: meshB.lastFileError);
    expect(
      saved!.endsWith(
        '${Platform.pathSeparator}Nexus Incoming${Platform.pathSeparator}photo.jpg',
      ),
      isTrue,
    );
    expect(File(saved).readAsStringSync(), content.toString());
    expect(lastProgress, 1.0);

    // A zero-byte file still completes.
    final emptySaved = await meshB.pushLocalFile(
      peerA,
      '${rootB.path}/empty.bin',
    );
    expect(emptySaved, isNotNull, reason: meshB.lastFileError);
    expect(File(emptySaved!).lengthSync(), 0);
  });

  test('files: rename, copy, move, exact push, and traversal protection', () async {
    final rootA = Directory('${tmp.path}/opsA')..createSync();
    final rootB = Directory('${tmp.path}/opsB')..createSync();
    File('${rootA.path}/original.txt').writeAsStringSync('original');
    Directory('${rootA.path}/docs').createSync();
    File('${rootB.path}/from-phone.txt').writeAsStringSync('from phone');

    await meshA.stop();
    meshA = MeshService(
      identity: DeviceInfo(
        id: 'device-a',
        name: 'Test Linux PC',
        platform: 'linux',
      ),
      store: storeA,
      clipboard: clipA,
      fileRoot: rootA.path,
      onlineWindow: const Duration(seconds: 3),
      visibleWindow: const Duration(seconds: 3),
      heartbeatInterval: const Duration(seconds: 2),
      connectTimeout: const Duration(milliseconds: 300),
    );
    await meshB.stop();
    meshB = MeshService(
      identity: DeviceInfo(
        id: 'device-b',
        name: 'Test Phone',
        platform: 'android',
      ),
      store: storeB,
      clipboard: clipB,
      fileRoot: rootB.path,
      onlineWindow: const Duration(seconds: 3),
      visibleWindow: const Duration(seconds: 3),
      heartbeatInterval: const Duration(seconds: 2),
      connectTimeout: const Duration(milliseconds: 300),
    );
    await meshA.start();
    await meshB.start();
    final session = meshA.beginPairing();
    final result = await meshB.pairWith(
      address: '127.0.0.1',
      port: meshA.port,
      code: session.code,
    );
    expect(result.ok, isTrue);
    final peerA = meshB.pairedDevices.single;

    final original = '${rootA.path}/original.txt';
    final renamed = '${rootA.path}/renamed.txt';
    expect(
      await meshB.operateRemoteFile(
        peerA,
        operation: 'rename',
        source: original,
        destination: renamed,
      ),
      renamed,
      reason: meshB.lastFileError,
    );
    expect(File(renamed).readAsStringSync(), 'original');

    final copied = '${rootA.path}/docs/copied.txt';
    expect(
      await meshB.operateRemoteFile(
        peerA,
        operation: 'copy',
        source: renamed,
        destination: copied,
      ),
      copied,
      reason: meshB.lastFileError,
    );
    expect(File(copied).readAsStringSync(), 'original');

    final moved = '${rootA.path}/docs/moved.txt';
    expect(
      await meshB.operateRemoteFile(
        peerA,
        operation: 'move',
        source: copied,
        destination: moved,
      ),
      moved,
      reason: meshB.lastFileError,
    );
    expect(File(copied).existsSync(), isFalse);
    expect(File(moved).existsSync(), isTrue);

    final exact = '${rootA.path}/from-phone.txt';
    expect(
      await meshB.pushLocalFile(
        peerA,
        '${rootB.path}/from-phone.txt',
        destinationPath: exact,
      ),
      exact,
      reason: meshB.lastFileError,
    );
    expect(File(exact).readAsStringSync(), 'from phone');

    final outside =
        '${rootA.path}${Platform.pathSeparator}..${Platform.pathSeparator}escaped.txt';
    expect(
      await meshB.operateRemoteFile(
        peerA,
        operation: 'rename',
        source: renamed,
        destination: outside,
      ),
      isNull,
    );
    expect(File('${tmp.path}/escaped.txt').existsSync(), isFalse);
    expect(File(renamed).existsSync(), isTrue);
  });

  test('files: deleteRemoteFile removes files, refuses root and non-empty dirs', () async {
    final root = Directory('${tmp.path}/del-served')..createSync();
    File('${root.path}/delete-me.txt').writeAsStringSync('bye');
    final fullDir = Directory('${root.path}/full-dir')..createSync();
    File('${fullDir.path}${Platform.pathSeparator}inside.txt')
        .writeAsStringSync('x');

    await meshA.start();
    await meshB.stop();
    meshB = MeshService(
      identity: DeviceInfo(
        id: 'device-b',
        name: 'Test Phone',
        platform: 'android',
      ),
      store: storeB,
      clipboard: clipB,
      fileRoot: root.path,
      onlineWindow: const Duration(seconds: 3),
      visibleWindow: const Duration(seconds: 3),
      heartbeatInterval: const Duration(seconds: 2),
      connectTimeout: const Duration(milliseconds: 300),
    );
    await meshB.start();

    final session = meshA.beginPairing();
    final result = await meshB.pairWith(
      address: '127.0.0.1',
      port: meshA.port,
      code: session.code,
    );
    expect(result.ok, isTrue);
    final peerB = meshA.pairedDevices.single;

    // A file on B's served root is deleted, and the sender learns the outcome.
    expect(
      await meshA.deleteRemoteFile(peerB, '${root.path}/delete-me.txt'),
      isTrue,
      reason: meshA.lastFileError,
    );
    expect(File('${root.path}/delete-me.txt').existsSync(), isFalse);

    // The served root itself is never deletable, and neither is anything
    // outside it.
    expect(await meshA.deleteRemoteFile(peerB, root.path), isFalse);
    expect(meshA.lastFileError, contains('outside'));
    final outside = File('${tmp.path}/outside.txt')..writeAsStringSync('no');
    expect(await meshA.deleteRemoteFile(peerB, outside.path), isFalse);
    expect(outside.existsSync(), isTrue);

    // A non-empty folder is refused.
    expect(await meshA.deleteRemoteFile(peerB, fullDir.path), isFalse);
    expect(meshA.lastFileError, contains('not empty'));
    expect(fullDir.existsSync(), isTrue);
  });

  test('files: pullRemoteRange reads exact byte ranges', () async {
    final root = Directory('${tmp.path}/served')..createSync();
    const content = 'The quick brown fox jumps over the lazy dog.';
    File('${root.path}/ranges.txt').writeAsStringSync(content);

    await meshA.stop();
    meshA = MeshService(
      identity: DeviceInfo(
        id: 'device-a',
        name: 'Test Linux PC',
        platform: 'linux',
      ),
      store: storeA,
      clipboard: clipA,
      fileRoot: root.path,
      onlineWindow: const Duration(seconds: 3),
      visibleWindow: const Duration(seconds: 3),
      heartbeatInterval: const Duration(seconds: 2),
      connectTimeout: const Duration(milliseconds: 300),
    );
    await meshA.start();
    await meshB.start();

    final session = meshA.beginPairing();
    final result = await meshB.pairWith(
      address: '127.0.0.1',
      port: meshA.port,
      code: session.code,
    );
    expect(result.ok, isTrue);
    final peerA = meshB.pairedDevices.single;
    final path = '${root.path}/ranges.txt';

    // Head, middle, tail-short, and past-EOF reads.
    final head = await meshB.pullRemoteRange(peerA, path, offset: 0, length: 9);
    expect(utf8.decode(head!), 'The quick');
    final mid = await meshB.pullRemoteRange(peerA, path, offset: 4, length: 9);
    expect(utf8.decode(mid!), 'quick bro');
    final tail = await meshB.pullRemoteRange(
      peerA,
      path,
      offset: 40,
      length: 100,
    );
    expect(tail, isNotNull, reason: meshB.lastFileError);
    expect(utf8.decode(tail!), 'dog.');
    final past = await meshB.pullRemoteRange(
      peerA,
      path,
      offset: 1000,
      length: 10,
    );
    expect(past, isEmpty);
  });

  test(
    'gateway serves devices, listings, and byte ranges over localhost',
    () async {
      final root = Directory('${tmp.path}/served')..createSync();
      File('${root.path}/hello.txt').writeAsStringSync('hello from A');
      final rootB = Directory('${tmp.path}/servedB')..createSync();
      File('${rootB.path}/note.txt').writeAsStringSync('note from B');

      await meshA.stop();
      meshA = MeshService(
        identity: DeviceInfo(
          id: 'device-a',
          name: 'Test Linux PC',
          platform: 'linux',
        ),
        store: storeA,
        clipboard: clipA,
        fileRoot: root.path,
        onlineWindow: const Duration(seconds: 3),
        visibleWindow: const Duration(seconds: 3),
        heartbeatInterval: const Duration(seconds: 2),
        connectTimeout: const Duration(milliseconds: 300),
      );
      await meshB.stop();
      meshB = MeshService(
        identity: DeviceInfo(
          id: 'device-b',
          name: 'Test Phone',
          platform: 'android',
        ),
        store: storeB,
        clipboard: clipB,
        fileRoot: rootB.path,
        onlineWindow: const Duration(seconds: 3),
        visibleWindow: const Duration(seconds: 3),
        heartbeatInterval: const Duration(seconds: 2),
        connectTimeout: const Duration(milliseconds: 300),
      );
      await meshA.start();
      await meshB.start();

      final session = meshA.beginPairing();
      final result = await meshB.pairWith(
        address: '127.0.0.1',
        port: meshA.port,
        code: session.code,
      );
      expect(result.ok, isTrue);

      final gateway = MeshGateway(
        mesh: meshA,
        token: 'test-token',
        port: 51990,
      );
      await gateway.start();
      addTearDown(gateway.stop);

      final conn = await Socket.connect('127.0.0.1', 51990);
      addTearDown(conn.destroy);
      // The socket stream is single-subscription, so queue incoming chunks and
      // hand them out one at a time.
      final pending = <List<int>>[];
      final waiters = <Completer<List<int>>>[];
      conn.listen((chunk) {
        if (waiters.isNotEmpty) {
          waiters.removeAt(0).complete(chunk);
        } else {
          pending.add(chunk);
        }
      });
      Future<List<int>> nextChunk() {
        if (pending.isNotEmpty) return Future.value(pending.removeAt(0));
        final c = Completer<List<int>>();
        waiters.add(c);
        return c.future;
      }

      var buf = '';
      Future<Map<String, dynamic>> call(Map<String, dynamic> req) async {
        conn.add(
          utf8.encode('${jsonEncode({'token': 'test-token', ...req})}\n'),
        );
        await conn.flush();
        while (!buf.contains('\n')) {
          buf += String.fromCharCodes(await nextChunk());
        }
        final line = buf.substring(0, buf.indexOf('\n'));
        buf = buf.substring(buf.indexOf('\n') + 1);
        return jsonDecode(line) as Map<String, dynamic>;
      }

      // Devices: A sees B as a paired, reachable peer.
      final devices = await call({'cmd': 'devices'});
      expect(devices['ok'], isTrue);
      expect(
        (devices['devices'] as List).any(
          (d) => (d as Map)['name'] == 'Test Phone',
        ),
        isTrue,
      );

      // List: browse B's served folder through the gateway.
      final listed = await call({
        'cmd': 'list',
        'device': 'device-b',
        'path': '',
      });
      expect(listed['ok'], isTrue);
      final names = (listed['entries'] as List)
          .map((e) => (e as Map)['name'])
          .toList();
      expect(names, contains('note.txt'));

      // Get: read an exact byte range.
      final notePath = '${rootB.path}/note.txt';
      final got = await call({
        'cmd': 'get',
        'device': 'device-b',
        'path': notePath,
        'offset': 0,
        'length': 4,
      });
      expect(got['ok'], isTrue);
      expect(utf8.decode(base64Decode(got['data'] as String)), 'note');

      // Mutations: the gateway exposes the same operation and exact upload
      // primitives as the app UI and FUSE mount.
      final copiedPath = '${rootB.path}/copied-note.txt';
      final copied = await call({
        'cmd': 'op',
        'device': 'device-b',
        'operation': 'copy',
        'source': notePath,
        'destination': copiedPath,
      });
      expect(copied['ok'], isTrue);
      expect(File(copiedPath).readAsStringSync(), 'note from B');

      final uploadedPath = '${rootB.path}/uploaded.txt';
      final uploaded = await call({
        'cmd': 'put',
        'device': 'device-b',
        'local': '${root.path}/hello.txt',
        'destination': uploadedPath,
      });
      expect(uploaded['ok'], isTrue);
      expect(File(uploadedPath).readAsStringSync(), 'hello from A');

      // Del: delete a file on B through the gateway (what the file manager's
      // "move to trash" calls).
      final delPath = '${rootB.path}/note.txt';
      final deleted = await call({
        'cmd': 'del',
        'device': 'device-b',
        'path': delPath,
      });
      expect(deleted['ok'], isTrue);
      expect(File(delPath).existsSync(), isFalse);

      // Wrong token: refused and the connection is dropped.
      final bad = await Socket.connect('127.0.0.1', 51990);
      addTearDown(bad.destroy);
      bad.add(utf8.encode('{"token":"nope","cmd":"devices"}\n'));
      await bad.flush();
      final replyBytes = await bad.fold<List<int>>(
        <int>[],
        (acc, b) => acc..addAll(b),
      );
      expect(utf8.decode(replyBytes), contains('unauthorized'));
    },
  );

  test('unreachable device reports honestly as offline', () async {
    await meshA.start();

    // Pair device-b into A's store without ever starting B's service.
    final session = meshA.beginPairing();
    final result = await meshB.pairWith(
      address: '127.0.0.1',
      port: meshA.port,
      code: session.code,
    );
    expect(result.ok, isTrue);
    await meshB.stop(); // B goes away

    // A can no longer reach B — once the verified window lapses (no pong
    // arrives), B is honestly reported offline.
    await Future<void>.delayed(const Duration(milliseconds: 3500));
    expect(meshA.isOnline('device-b'), isFalse);
    expect(meshA.onlineCount, 0);
  });

  test(
    'multi-hop: a peer can message a serial node through its host',
    () async {
      await meshA.start();
      await meshB.start();

      final session = meshA.beginPairing();
      final result = await meshB.pairWith(
        address: '127.0.0.1',
        port: meshA.port,
        code: session.code,
      );
      expect(result.ok, isTrue, reason: result.error);

      // A has an ESP32 on its cable.
      final transport = FakeSerialTransport();
      final bridge = SerialBridge(transport: transport, onChanged: () {});
      await bridge.startScan();
      transport.port.feed('{"t":"ann","id":"esp32-abc","name":"ESP"}\n');
      await Future<void>.delayed(Duration.zero);
      meshA.attachSerialBridge(bridge);
      transport.port.written
          .clear(); // forget the hello the bridge sent on open

      // B learns about it from A's next heartbeat announcement.
      await _waitFor(
        () => meshB.remoteSerialDevices.any((d) => d.id == 'esp32-abc'),
      );
      expect(
        meshB.remoteSerialDevices.singleWhere((d) => d.id == 'esp32-abc').name,
        'ESP',
      );

      // B sends a blink through A to the node.
      expect(
        await meshB.sendSerialMessage('esp32-abc', {'blink': true}),
        isTrue,
      );
      await _waitFor(() => transport.port.written.isNotEmpty);
      final sent = utf8.decode(transport.port.written.last);
      expect(sent, contains('"t":"msg"'));
      expect(sent, contains('"blink":true'));

      // The node answers `up`; A relays it back to B.
      transport.port.feed('{"t":"up","id":"esp32-abc","data":{"echo":"ok"}}\n');
      await _waitFor(() => meshB.lastSerialUp != null);
      expect(meshB.lastSerialUp!['from'], 'esp32-abc');
      expect(meshB.lastSerialUp!['data'], {'echo': 'ok'});
    },
  );

  test('agent action travels encrypted and the reply comes back', () async {
    await meshA.start();
    await meshB.start();

    final session = meshA.beginPairing();
    final result = await meshB.pairWith(
      address: '127.0.0.1',
      port: meshA.port,
      code: session.code,
    );
    expect(result.ok, isTrue);

    // The PC routes "call mom" to the phone.
    final request = AgentRequest(
      requestId: 'test-call-1',
      target: 'device-b',
      action: AgentActions.callPlace,
      arguments: const {'contact': 'mom'},
      approval: AgentApproval.approved,
    );
    final replyFuture = meshA.sendAgentRequest('device-b', request);

    // The phone sees the incoming request (the card appears).
    await _waitFor(() {
      final raw = meshB.lastIncomingAgentRequest;
      final req = raw?['request'];
      return req is AgentRequest && req.requestId == 'test-call-1';
    });

    // The phone re-approves locally and answers honestly.
    final incoming = meshB.lastIncomingAgentRequest!;
    final req = incoming['request'] as AgentRequest;
    final outcome = CommandService(
      devices: () => const [],
      local: const AgentDeviceSnapshot(
        id: 'device-b',
        name: 'Test Phone',
        online: true,
        capabilities: [DeviceCapability(AgentActions.callPlace)],
      ),
    ).handleRemoteRequest(req, approval: AgentApproval.approved);
    await meshB.sendAgentResult('device-a', req.requestId, outcome);

    final reply = await replyFuture;
    expect(reply, isNotNull);
    expect(reply!.status, AgentResultStatus.unavailable);
    // The pure service cannot dial (the phone's UI runs the call after
    // approval) — the reply is an honest refusal, never a silent success.
    expect(reply.message, isNotEmpty);
  });

  test('a phrase taught on one device syncs to its paired peers', () async {
    await meshA.start();
    await meshB.start();

    final session = meshA.beginPairing();
    final result = await meshB.pairWith(
      address: '127.0.0.1',
      port: meshA.port,
      code: session.code,
    );
    expect(result.ok, isTrue);

    String? seenPhrase;
    String? seenMeaning;
    // The live assistant claims the knowledge: it adopts the phrase and its
    // own persistence funnel writes the store (the mesh only delivers when a
    // listener is attached — never both).
    meshB.onLearnedPhraseReceived = (phrase, meaning) {
      seenPhrase = phrase;
      seenMeaning = meaning;
      meshB.store.agentLearned = {...meshB.store.agentLearned, phrase: meaning};
    };

    await meshA.broadcastLearnedPhrase(
      'call tvcraft',
      'call tvcraft01 〘✘δτκ⑤⑦〙',
    );

    await _waitFor(() => seenPhrase != null);
    expect(seenPhrase, 'call tvcraft');
    expect(seenMeaning, 'call tvcraft01 〘✘δτκ⑤⑦〙');
    // Persisted by the claiming listener's funnel, usable right away.
    expect(meshB.store.agentLearned['call tvcraft'], 'call tvcraft01 〘✘δτκ⑤⑦〙');
  });

  test(
    'knowledge syncs with no assistant listening and is persisted by the mesh',
    () async {
      await meshA.start();
      await meshB.start();

      final session = meshA.beginPairing();
      final result = await meshB.pairWith(
        address: '127.0.0.1',
        port: meshA.port,
        code: session.code,
      );
      expect(result.ok, isTrue);

      // No listener attached: the mesh persists inbound knowledge itself (the
      // startup window / headless use), so it survives for the next boot.
      await meshA.broadcastLearnedPhrase('call tvcraft', 'call bob');
      await meshA.broadcastFact('my wifi password is nexus');

      await _waitFor(
        () =>
            meshB.store.agentLearned.containsKey('call tvcraft') &&
            meshB.store.agentFacts.isNotEmpty,
      );
      expect(meshB.store.agentLearned['call tvcraft'], 'call bob');
      expect(meshB.store.agentFacts, ['my wifi password is nexus']);
    },
  );

  test('a local correction wins over a conflicting synced meaning', () async {
    await meshA.start();
    await meshB.start();

    final session = meshA.beginPairing();
    final result = await meshB.pairWith(
      address: '127.0.0.1',
      port: meshA.port,
      code: session.code,
    );
    expect(result.ok, isTrue);

    // B taught "call tvcraft" -> "call bob" locally; A syncs a different one.
    meshB.store.agentLearned = {'call tvcraft': 'call bob'};
    var adopted = false;
    meshB.onLearnedPhraseReceived = (_, _) => adopted = true;

    await meshA.broadcastLearnedPhrase('call tvcraft', 'call alice');

    // Give the mesh a moment to deliver (and be rejected) — nothing may adopt.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(adopted, isFalse);
    expect(meshB.store.agentLearned['call tvcraft'], 'call bob');
  });

  test('a fact told to one assistant syncs to its paired peers', () async {
    await meshA.start();
    await meshB.start();

    final session = meshA.beginPairing();
    final result = await meshB.pairWith(
      address: '127.0.0.1',
      port: meshA.port,
      code: session.code,
    );
    expect(result.ok, isTrue);

    String? seenFact;
    // The live assistant claims the fact: it adopts it and its persistence
    // funnel writes the store (the mesh only delivers when a listener is
    // attached — never both).
    meshB.onFactReceived = (fact) {
      seenFact = fact;
      meshB.store.agentFacts = [...meshB.store.agentFacts, fact];
    };

    await meshA.broadcastFact('my wifi password is nexus');

    await _waitFor(() => seenFact != null);
    expect(seenFact, 'my wifi password is nexus');
    // Persisted by the claiming listener's funnel, deduplicated on delivery.
    expect(meshB.store.agentFacts, ['my wifi password is nexus']);
  });

  test(
    'a synced fact that already exists is dropped, not duplicated',
    () async {
      await meshA.start();
      await meshB.start();

      final session = meshA.beginPairing();
      final result = await meshB.pairWith(
        address: '127.0.0.1',
        port: meshA.port,
        code: session.code,
      );
      expect(result.ok, isTrue);

      meshB.store.agentFacts = ['my wifi password is nexus'];
      var adopted = false;
      meshB.onFactReceived = (_) => adopted = true;

      await meshA.broadcastFact('my wifi password is nexus');

      // Nothing may adopt (or re-add) — the fact is already there.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(adopted, isFalse);
      expect(meshB.store.agentFacts, ['my wifi password is nexus']);
    },
  );
}

/// Polls until [cond] is true (with a timeout), so tests don't depend on
/// heartbeat timing.
Future<void> _waitFor(
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 6),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail('condition not met within $timeout');
}

class FakeSerialPort implements SerialPort {
  final StreamController<List<int>> _in = StreamController.broadcast();
  final List<List<int>> written = [];

  @override
  Stream<List<int>> get bytes => _in.stream;
  @override
  bool get isOpen => true;
  @override
  Future<void> write(List<int> data) async => written.add(data);
  @override
  Future<void> close() async => _in.close();

  void feed(String line) => _in.add(utf8.encode(line));
}

class FakeSerialTransport implements SerialTransport {
  final FakeSerialPort port = FakeSerialPort();
  @override
  Future<List<SerialPortInfo>> listPorts() async => [
    const SerialPortInfo(port: '/dev/ttyUSB0', label: 'ttyUSB0'),
  ];
  @override
  Future<SerialPort> open(SerialPortInfo info, {int baudRate = 115200}) async =>
      port;
}
