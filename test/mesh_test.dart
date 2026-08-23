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
      identity: const DeviceInfo(id: 'device-a', name: 'Test Linux PC', platform: 'linux'),
      store: storeA,
      clipboard: clipA,
      onlineWindow: const Duration(seconds: 3),
      visibleWindow: const Duration(seconds: 3),
      heartbeatInterval: const Duration(seconds: 2),
    );
    meshB = MeshService(
      identity: const DeviceInfo(id: 'device-b', name: 'Test Phone', platform: 'android'),
      store: storeB,
      clipboard: clipB,
      onlineWindow: const Duration(seconds: 3),
      visibleWindow: const Duration(seconds: 3),
      heartbeatInterval: const Duration(seconds: 2),
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
      found = meshA.clipTray.any((e) => e.text == 'hello from the phone' && e.fromName == 'Test Phone');
    }
    expect(found, isTrue, reason: 'PC never received the clipboard message');

    // The PC's own clipboard is untouched (auto-apply is off by default).
    expect(clipA.value, isNull);
  });

  test('pairs persist across restarts', () async {
    await meshA.start();
    await meshB.start();
    final session = meshA.beginPairing();
    await meshB.pairWith(address: '127.0.0.1', port: meshA.port, code: session.code);

    await meshB.stop();
    final restarted = MeshService(
      identity: const DeviceInfo(id: 'device-b', name: 'Test Phone', platform: 'android'),
      store: storeB,
      clipboard: clipB,
    );
    await restarted.start();
    expect(restarted.isPaired('device-a'), isTrue);
    expect(restarted.pairedDevices.single.pairingSecret, session.code);
    await restarted.stop();
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
