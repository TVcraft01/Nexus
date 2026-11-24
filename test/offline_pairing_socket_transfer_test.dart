// Real two-instance file transfer over a socket, with keys made by the offline
// handshake.
//
// Every test here starts two [MeshService]s that really bind loopback ports and
// really exchange frames; the pairing is the no-network one (QR1 / QR2 / six
// digits), not the old code scheme, so this is the path a person gets when they
// pair in airplane mode and meet on a network later. A file is hashed on both
// sides, a third device holding the wrong key is refused, and a tampered or
// truncated frame is dropped without taking the link down.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/crypto.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/identity_seed_store.dart';
import 'package:nexus/core/protocol.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/mesh/mesh_service.dart';
import 'package:nexus/mesh/offline_pairing.dart';

class _MemorySeedStore implements IdentitySeedStore {
  final Map<String, Map<String, dynamic>> values = {};

  @override
  Future<Map<String, dynamic>?> read() async => values['seed'] == null
      ? null
      : Map<String, dynamic>.of(values['seed']!);

  @override
  Future<void> write(Map<String, dynamic> identity) async {
    values['seed'] = Map<String, dynamic>.of(identity);
  }

  @override
  Future<void> delete() async => values.remove('seed');
}

/// One device: its store, its served folder, its mesh.
class _Node {
  _Node(this.id, this.name, this.store, this.root, this.mesh);

  final String id;
  final String name;
  final NexusStore store;
  final Directory root;
  final MeshService mesh;

  PairedDevice peerOf(_Node other) =>
      mesh.pairedDevices.firstWhere((p) => p.id == other.id);

  Future<String> hashOf(String path) async {
    final bytes = await File(path).readAsBytes();
    final hash = await Sha256().hash(bytes);
    return hash.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<void> stop() async {
    await mesh.stop();
  }
}

Future<int> _freePort() async {
  final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = probe.port;
  await probe.close();
  return port;
}

Future<_Node> _node(Directory tmp, String id, String name) async {
  final store = NexusStore(explicitPath: '${tmp.path}/$id.json')
    ..port = await _freePort()
    ..pairingEnabled = true
    ..fileShare = true;
  await store.save();
  final root = Directory('${tmp.path}/$id-root')..createSync(recursive: true);
  final mesh = MeshService(
    identity: DeviceInfo(id: id, name: name, platform: 'linux'),
    store: store,
    fileRoot: root.path,
    heartbeatInterval: const Duration(seconds: 2),
    onlineWindow: const Duration(seconds: 10),
    visibleWindow: const Duration(seconds: 10),
    connectTimeout: const Duration(milliseconds: 500),
  )..useIdentitySeedStoreForTest(_MemorySeedStore());
  return _Node(id, name, store, root, mesh);
}

/// The whole offline handshake between two real nodes, confirmed on both
/// sides with the address each can actually be reached at.
///
/// This is exactly what the two pair screens do: one shows QR1, the other
/// answers with QR2, both show a code, and only the "they match" tap stores
/// anything.
Future<void> _pairOffline(_Node host, _Node guest) async {
  final session = await host.mesh.beginOfflinePairing();
  final answered = await guest.mesh.answerOfflinePairing(session.qr1);
  final offer = await session.acceptAnswer(answered.qr2);

  expect(offer.confirmationCode, answered.offer.confirmationCode);
  await host.mesh.confirmOfflinePairing(
    offer,
    address: '127.0.0.1',
    port: guest.store.port,
  );
  await guest.mesh.confirmOfflinePairing(
    answered.offer,
    address: '127.0.0.1',
    port: host.store.port,
  );
}

Future<void> _waitFor(
  FutureOr<bool> Function() condition, {
  Duration timeout = const Duration(seconds: 12),
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail(reason ?? 'condition was not met in ${timeout.inSeconds}s');
}

void main() {
  late Directory tmp;
  late _Node a;
  late _Node b;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('nexus_socket_e2e');
    a = await _node(tmp, 'device-a', 'Study PC');
    b = await _node(tmp, 'device-b', 'Kitchen phone');
    await a.mesh.start();
    await b.mesh.start();
  });

  tearDown(() async {
    await a.stop();
    await b.stop();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test(
    'a file crossed a real socket with the key the offline pairing made',
    () async {
      await _pairOffline(a, b);

      final peerB = a.peerOf(b);
      final peerA = b.peerOf(a);
      expect(peerB.pairingProtocol, offlinePairingVersion);
      expect(peerA.pairingProtocol, offlinePairingVersion);
      expect(peerB.pairingSecret, peerA.pairingSecret);

      // Both sides derive the same session key from that one secret, which is
      // the thing that makes the transfer work at all.
      final keyA = await deriveSessionKey(
        pairingSecret: peerB.pairingSecret,
        myId: a.id,
        peerId: b.id,
      );
      final keyB = await deriveSessionKey(
        pairingSecret: peerA.pairingSecret,
        myId: b.id,
        peerId: a.id,
      );
      expect(
        keyA.map((e) => e.toRadixString(16)).join(),
        keyB.map((e) => e.toRadixString(16)).join(),
      );

      final source = File('${tmp.path}/photo.bin');
      final payload = Uint8List.fromList(
        List<int>.generate(256 * 1024 + 77, (i) => (i * 31) % 251),
      );
      await source.writeAsBytes(payload);
      final wantHash = await a.hashOf(source.path);

      final saved = await a.mesh.pushLocalFile(
        peerB,
        source.path,
        destinationPath: 'incoming/photo.bin',
      );
      expect(saved, isNotNull, reason: a.mesh.lastFileError);
      final received = File('${b.root.path}/incoming/photo.bin');
      expect(await received.exists(), isTrue);
      expect(await b.hashOf(received.path), wantHash);
      expect(
        await received.length(),
        payload.length,
        reason: 'the whole file arrived, not just the first chunk',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'a receiver holding a different key refuses the transfer',
    () async {
      // The honest mismatch: the receiver stored this peer with a secret the
      // sender never had, which is what a tampered handshake leaves behind.
      final c = await _node(tmp, 'device-c', 'Stranger');
      await c.mesh.start();
      addTearDown(c.stop);

      final session = await a.mesh.beginOfflinePairing();
      final answered = await c.mesh.answerOfflinePairing(session.qr1);
      final realOffer = await session.acceptAnswer(answered.qr2);

      await a.mesh.confirmOfflinePairing(
        realOffer,
        address: '127.0.0.1',
        port: c.store.port,
      );
      // C keeps a key of its own choosing instead of the one they agreed on.
      final wrongKey = Uint8List(32);
      wrongKey[0] = 7;
      await c.mesh.confirmOfflinePairing(
        OfflinePairingOffer(
          channelKey: wrongKey,
          confirmationCode: realOffer.confirmationCode,
          peerIdentityKey: realOffer.peerIdentityKey,
          peerName: realOffer.peerName,
          peerDeviceId: realOffer.peerDeviceId,
        ),
        address: '127.0.0.1',
        port: a.store.port,
      );

      final source = File('${tmp.path}/secret.txt');
      await source.writeAsString('not for you');

      final saved = await a.mesh.pushLocalFile(
        a.peerOf(c),
        source.path,
        destinationPath: 'incoming/secret.txt',
      );

      expect(saved, isNull, reason: 'a wrong key must not deliver a file');
      expect(a.mesh.lastFileError, isNotNull);
      expect(
        File('${c.root.path}/incoming/secret.txt').existsSync(),
        isFalse,
        reason: 'nothing may be written for a frame C cannot decrypt',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'a tampered frame is dropped and a truncated one does not take the link down',
    () async {
      await _pairOffline(a, b);

      final key = await deriveSessionKey(
        pairingSecret: a.peerOf(b).pairingSecret,
        myId: a.id,
        peerId: b.id,
      );
      final good = await encryptToB64(
        utf8.encode('{"t":"presence"}'),
        key,
      );
      // A single flipped character is enough: AES-GCM authenticates.
      final tampered = good.substring(0, 12) +
          (good[12] == 'A' ? 'B' : 'A') +
          good.substring(13);
      await expectLater(
        decryptFromB64(tampered, key),
        throwsA(anything),
      );

      // And over a real socket: a tampered frame, then a connection that dies
      // mid-frame. Neither may be believed, and neither may stop the receiver.
      final tamperedSocket =
          await Socket.connect('127.0.0.1', b.store.port);
      tamperedSocket.add(
        FrameDecoder.encodeFrame(Uint8List.fromList(utf8.encode('{"enc":"$tampered"}'))),
      );
      await tamperedSocket.flush();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      tamperedSocket.destroy();

      final truncated = await Socket.connect('127.0.0.1', b.store.port);
      final frame = FrameDecoder.encodeFrame(
        Uint8List.fromList(
          utf8.encode('{"enc":"${good.substring(0, good.length ~/ 2)}"}'),
        ),
      );
      truncated.add(frame.sublist(0, frame.length - 6));
      await truncated.flush();
      truncated.destroy();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // The real link still works after both.
      final source = File('${tmp.path}/after-attack.txt');
      await source.writeAsString('still here');
      final saved = await a.mesh.pushLocalFile(
        a.peerOf(b),
        source.path,
        destinationPath: 'incoming/after-attack.txt',
      );
      expect(saved, isNotNull, reason: a.mesh.lastFileError);
      expect(
        File('${b.root.path}/incoming/after-attack.txt').existsSync(),
        isTrue,
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('both devices are online to each other after the offline pairing',
      () async {
    await _pairOffline(a, b);
    await _waitFor(
      () => a.mesh.isOnline(b.id) && b.mesh.isOnline(a.id),
      reason: 'the two paired devices never proved each other',
    );
    expect(a.mesh.isOnline(b.id), isTrue);
    expect(b.mesh.isOnline(a.id), isTrue);
  }, timeout: const Timeout(Duration(minutes: 2)));
}

