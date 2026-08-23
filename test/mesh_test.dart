import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/mesh/mesh_service.dart';

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
      identity: DeviceInfo(id: 'device-a', name: 'Test Linux PC', platform: 'linux'),
      store: storeA,
      clipboard: clipA,
      onlineWindow: const Duration(seconds: 3),
      visibleWindow: const Duration(seconds: 3),
      heartbeatInterval: const Duration(seconds: 2),
      connectTimeout: const Duration(milliseconds: 300),
    );
    meshB = MeshService(
      identity: DeviceInfo(id: 'device-b', name: 'Test Phone', platform: 'android'),
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

    final result = await meshB.pairWith(address: '127.0.0.1', port: meshA.port, code: session.code);
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
    final result = await meshB.pairWith(address: '127.0.0.1', port: meshA.port, code: wrong);
    expect(result.ok, isFalse);
    expect(meshA.isPaired('device-b'), isFalse);
    expect(meshB.isPaired('device-a'), isFalse);
  });

  test('encrypted clipboard travels from phone to PC after pairing', () async {
    await meshA.start();
    await meshB.start();

    final session = meshA.beginPairing();
    final result = await meshB.pairWith(address: '127.0.0.1', port: meshA.port, code: session.code);
    expect(result.ok, isTrue);

    await meshB.broadcastClipboard('hello from the phone');

    // Give the encrypted frame a moment to arrive.
    var found = false;
    for (var i = 0; i < 20 && !found; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final clip = meshA.lastIncomingClip;
      found = clip != null && clip.text == 'hello from the phone' && clip.fromName == 'Test Phone';
    }
    expect(found, isTrue, reason: 'PC never received the clipboard message');

    // Clipboard sync is ON by default: the text lands directly in the PC's
    // clipboard, ready to paste anywhere.
    expect(clipA.value, 'hello from the phone');
  });

  test('with clipboard sync off, incoming clips are not applied', () async {
    storeA.clipboardSync = false;
    await storeA.save();
    await meshA.start();
    await meshB.start();

    final session = meshA.beginPairing();
    final result = await meshB.pairWith(address: '127.0.0.1', port: meshA.port, code: session.code);
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

  test('pairs persist across restarts', () async {
    await meshA.start();
    await meshB.start();
    final session = meshA.beginPairing();
    await meshB.pairWith(address: '127.0.0.1', port: meshA.port, code: session.code);

    await meshB.stop();
    final restarted = MeshService(
      identity: DeviceInfo(id: 'device-b', name: 'Test Phone', platform: 'android'),
      store: storeB,
      clipboard: clipB,
    );
    await restarted.start();
    expect(restarted.isPaired('device-a'), isTrue);
    expect(restarted.pairedDevices.single.pairingSecret, session.code);
    await restarted.stop();
  });

  test('renaming a device propagates the new name to paired devices', () async {
    await meshA.start();
    await meshB.start();

    final session = meshA.beginPairing();
    final result = await meshB.pairWith(address: '127.0.0.1', port: meshA.port, code: session.code);
    expect(result.ok, isTrue);

    // Rename A; the next heartbeat ping carries the new name, and B must
    // learn it without a restart.
    await meshA.renameDevice('New PC Name');

    // The renaming device's own in-memory identity updates immediately.
    expect(meshA.identity.name, 'New PC Name');

    var learned = false;
    for (var i = 0; i < 30 && !learned; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      learned = meshB.pairedDevices.any((d) => d.id == 'device-a' && d.name == 'New PC Name');
    }
    expect(learned, isTrue, reason: 'B never learned A\'s new name');

    // The new name is persisted in B's store, not just in memory.
    final reloaded = NexusStore(explicitPath: storeB.explicitPath);
    await reloaded.load();
    final stored = reloaded.pairedDevices.firstWhere((d) => d['id'] == 'device-a');
    expect(stored['name'], 'New PC Name');
  });

  test('falls back across multiple addresses and self-heals to the working one', () async {
    // A (the PC) serves a folder; B (the phone) browses it. The observable is
    // B's outbound path — a file request — because presence pings still
    // bounce both ways while B's listener works, even if B cannot initiate.
    final root = Directory('${tmp.path}/served')..createSync();
    File('${root.path}/hello.txt').writeAsStringSync('hello from A');

    await meshA.stop();
    meshA = MeshService(
      identity: DeviceInfo(id: 'device-a', name: 'Test Linux PC', platform: 'linux'),
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
    final result = await meshB.pairWith(address: '127.0.0.1', port: meshA.port, code: session.code);
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
  });

  test('address list is persisted with the paired device', () async {
    await meshA.start();
    await meshB.start();

    final session = meshA.beginPairing();
    final result = await meshB.pairWith(address: '127.0.0.1', port: meshA.port, code: session.code);
    expect(result.ok, isTrue);

    // B's copy of A remembers where A lives, and the announced address list
    // survives a reload of the store (what powers remote access after restart).
    final reloaded = NexusStore(explicitPath: storeB.explicitPath);
    await reloaded.load();
    final stored = reloaded.pairedDevices.singleWhere((d) => d['id'] == 'device-a');
    expect(stored['address'], '127.0.0.1');
    expect((stored['addresses'] as List).contains('127.0.0.1'), isTrue);
  });

  test('files: list, navigate, pull (incl. multi-chunk), and root is enforced', () async {
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
      identity: DeviceInfo(id: 'device-a', name: 'Test Linux PC', platform: 'linux'),
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
    final result = await meshB.pairWith(address: '127.0.0.1', port: meshA.port, code: session.code);
    expect(result.ok, isTrue);
    final peerA = meshB.pairedDevices.single;

    // List the served root.
    final rootEntries = await meshB.listRemoteFiles(peerA, '');
    expect(rootEntries, isNotNull, reason: meshB.lastFileError);
    final names = rootEntries!.map((e) => e.name).toSet();
    expect(names, containsAll(['hello.txt', 'docs', 'empty.bin', 'big.bin']));
    expect(rootEntries.firstWhere((e) => e.name == 'big.bin').size, 700 * 1024);

    // Navigate into a subfolder using the path A reported.
    final docs = rootEntries.firstWhere((e) => e.name == 'docs');
    expect(docs.isDir, isTrue);
    final docsEntries = await meshB.listRemoteFiles(peerA, docs.path);
    expect(docsEntries, isNotNull, reason: meshB.lastFileError);
    expect(docsEntries!.single.name, 'readme.md');

    // Pull a small file.
    final hello = rootEntries.firstWhere((e) => e.name == 'hello.txt');
    final saved = await meshB.pullRemoteFile(peerA, hello.path, savePath: '${tmp.path}/dl.txt');
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
    final emptySaved = await meshB.pullRemoteFile(peerA, empty.path, savePath: '${tmp.path}/dl_empty.bin');
    expect(emptySaved, isNotNull, reason: meshB.lastFileError);
    expect(File(emptySaved!.path).lengthSync(), 0);

    // Anything outside the served root is refused.
    final denied = await meshB.listRemoteFiles(peerA, tmp.path);
    expect(denied, isNull);
    expect(meshB.lastFileError, contains('Access denied'));
  });

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
      identity: DeviceInfo(id: 'device-a', name: 'Test Linux PC', platform: 'linux'),
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
      identity: DeviceInfo(id: 'device-b', name: 'Test Phone', platform: 'android'),
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
    final result = await meshB.pairWith(address: '127.0.0.1', port: meshA.port, code: session.code);
    expect(result.ok, isTrue);
    final peerA = meshB.pairedDevices.single;

    // B browses its own served folder (the "This device" view).
    final localEntries = await meshB.listLocalFiles('');
    expect(localEntries, isNotNull, reason: meshB.lastFileError);
    final names = localEntries!.map((e) => e.name).toSet();
    expect(names, containsAll(['photo.jpg', 'empty.bin']));

    // Multi-chunk push: A acks only after every chunk has landed.
    final photo = localEntries.firstWhere((e) => e.name == 'photo.jpg');
    var lastProgress = 0.0;
    final saved = await meshB.pushLocalFile(
      peerA,
      photo.path,
      onProgress: (sent, total) {
        if (total > 0) lastProgress = sent / total;
      },
    );
    expect(saved, isNotNull, reason: meshB.lastFileError);
    expect(saved!.endsWith('${Platform.pathSeparator}Nexus Incoming${Platform.pathSeparator}photo.jpg'), isTrue);
    expect(File(saved).readAsStringSync(), content.toString());
    expect(lastProgress, 1.0);

    // A zero-byte file still completes.
    final empty = localEntries.firstWhere((e) => e.name == 'empty.bin');
    final emptySaved = await meshB.pushLocalFile(peerA, empty.path);
    expect(emptySaved, isNotNull, reason: meshB.lastFileError);
    expect(File(emptySaved!).lengthSync(), 0);
  });

  test('unreachable device reports honestly as offline', () async {
    await meshA.start();

    // Pair device-b into A's store without ever starting B's service.
    final session = meshA.beginPairing();
    final result = await meshB.pairWith(address: '127.0.0.1', port: meshA.port, code: session.code);
    expect(result.ok, isTrue);
    await meshB.stop(); // B goes away

    // A can no longer reach B — once the verified window lapses (no pong
    // arrives), B is honestly reported offline.
    await Future<void>.delayed(const Duration(milliseconds: 3500));
    expect(meshA.isOnline('device-b'), isFalse);
    expect(meshA.onlineCount, 0);
  });
}
