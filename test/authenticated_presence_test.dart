// The trust boundary around device state.
//
// Discovery is deliberately open — any device on the network must be able to
// announce itself, and a device that has never paired with us has no shared
// secret to prove anything with. What must NEVER be open is the state we act
// on: whether a paired device is online, and where we reach it. Both used to
// be writable by anyone who could open a TCP connection and send one
// plaintext "ping" claiming a device id — an id that a plaintext ping
// broadcasts anyway.
//
// These tests are the attacks, asserted as refused. Before the fix every one
// of them succeeds; the point of keeping them is that they can never quietly
// succeed again.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/crypto.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/protocol.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/mesh/mesh_service.dart';

/// One frame to [port] over a plain TCP connection — a stranger's entire
/// capability, and the only thing these tests need.
Future<void> _strangerSends(
  int port,
  Map<String, dynamic> frame, {
  String host = '127.0.0.1',
}) async {
  final socket = await Socket.connect(
    host,
    port,
    timeout: const Duration(seconds: 3),
  );
  socket.add(FrameDecoder.encodeFrame(encodeJson(frame)));
  await socket.flush();
  await socket.close();
}

/// A plaintext presence claim: "I am [from]".
Map<String, dynamic> _pingFrame({
  required String from,
  required String id,
  int port = 59999,
  String name = 'Stranger',
}) => {
  'type': 'ping',
  'from': from,
  'payload': {'name': name, 'port': port, 'platform': 'linux'},
  'id': id,
  'ts': DateTime.now().millisecondsSinceEpoch,
};

/// A plaintext pairing claim, as an unauthenticated peer would send it.
Map<String, dynamic> _pairRequestFrame({
  required String from,
  required String id,
  int port = 59998,
}) => {
  'type': 'pair-request',
  'from': from,
  'payload': {'name': 'Stranger', 'platform': 'linux', 'port': port},
  'id': id,
  'ts': DateTime.now().millisecondsSinceEpoch,
};

/// The first non-loopback IPv4 this host can be reached on. A route can only
/// be seen to move if we know the address it started from, and loopback
/// addresses are deliberately never stored as a peer's port source.
Future<String> _reachableIpv4() async {
  for (final interface in await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
    includeLinkLocal: false,
  )) {
    for (final address in interface.addresses) {
      if (!address.address.startsWith('169.254.')) return address.address;
    }
  }
  fail('this host has no non-loopback IPv4 address to be reached on');
}

typedef _Pair = ({MeshService a, MeshService b, String code, Directory tmp});

/// Two services, genuinely paired, with heartbeat quiet by default so only the
/// thing under test moves the state.
Future<_Pair> _pair({
  required int portA,
  required int portB,
  String via = '127.0.0.1',
  Duration onlineWindow = const Duration(seconds: 2),
  Duration heartbeat = const Duration(seconds: 30),
}) async {
  final tmp = await Directory.systemTemp.createTemp('nexus_presence');
  final storeA = NexusStore(explicitPath: '${tmp.path}/a.json')..port = portA;
  final storeB = NexusStore(explicitPath: '${tmp.path}/b.json')..port = portB;
  await storeA.save();
  await storeB.save();

  final a = MeshService(
    identity: DeviceInfo(id: 'device-a', name: 'PC', platform: 'linux'),
    store: storeA,
    onlineWindow: onlineWindow,
    visibleWindow: onlineWindow,
    heartbeatInterval: heartbeat,
    connectTimeout: const Duration(milliseconds: 300),
  );
  final b = MeshService(
    identity: DeviceInfo(id: 'device-b', name: 'Phone', platform: 'android'),
    store: storeB,
    onlineWindow: onlineWindow,
    visibleWindow: onlineWindow,
    heartbeatInterval: heartbeat,
    connectTimeout: const Duration(milliseconds: 300),
  );
  await a.start();
  await b.start();

  final session = a.beginPairing();
  final result = await b.pairWith(
    address: via,
    port: a.port,
    code: session.code,
  );
  expect(result.ok, isTrue, reason: result.error);
  return (a: a, b: b, code: session.code, tmp: tmp);
}

Future<void> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail('condition was still false after ${timeout.inSeconds}s');
}

void main() {
  group('presence cannot be forged', () {
    test('a stranger cannot claim a paired device is online', () async {
      final h = await _pair(portA: 53410, portB: 53411);

      // The phone goes away completely, and the online window lapses.
      await h.b.stop();
      await Future<void>.delayed(const Duration(milliseconds: 2300));
      expect(
        h.a.isOnline('device-b'),
        isFalse,
        reason: 'the phone is switched off',
      );

      // A host holding no pairing secret at all claims to be the phone.
      await _strangerSends(
        h.a.port,
        _pingFrame(from: 'device-b', id: 'stranger-presence'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(
        h.a.isOnline('device-b'),
        isFalse,
        reason: 'a host with no secret must not be able to claim presence',
      );
      expect(
        h.a.onlineCount,
        0,
        reason: 'a forged claim must not reach the "N of N reachable" count',
      );
      await h.a.stop();
    });

    test('a stranger cannot move where a paired device is reached', () async {
      final lan = await _reachableIpv4();
      final h = await _pair(portA: 53420, portB: 53421, via: lan);

      var peer = h.a.pairedDevices.singleWhere((d) => d.id == 'device-b');
      final storedAddress = peer.address;
      final storedPort = peer.port;
      expect(storedAddress, lan, reason: 'paired over the LAN address');

      // A stranger on the same network, announcing a port of its choosing.
      // (This is the one that used to silently redirect every later
      // connection to that device.)
      await _strangerSends(
        h.a.port,
        _pingFrame(from: 'device-b', id: 'stranger-port', port: 44444),
        host: lan,
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));

      peer = h.a.pairedDevices.singleWhere((d) => d.id == 'device-b');
      expect(peer.port, storedPort, reason: 'the route port must not move');
      expect(peer.address, storedAddress, reason: 'the route address must not move');

      // A stranger connecting from a different source address, same claim.
      await _strangerSends(
        h.a.port,
        _pingFrame(from: 'device-b', id: 'stranger-address', port: 44445),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));

      peer = h.a.pairedDevices.singleWhere((d) => d.id == 'device-b');
      expect(
        peer.address,
        storedAddress,
        reason: 'the address we reach a paired device at must not be moved by '
            'an unauthenticated claim',
      );
      expect(peer.port, storedPort);

      await h.a.stop();
      await h.b.stop();
    });
  });

  group('pairing cannot be hijacked', () {
    test('a stranger cannot pair by claiming, nor burn the code', () async {
      final tmp = await Directory.systemTemp.createTemp('nexus_pairdoor');
      final storeA = NexusStore(explicitPath: '${tmp.path}/a.json')..port = 53430;
      final storeB = NexusStore(explicitPath: '${tmp.path}/b.json')..port = 53431;
      await storeA.save();
      await storeB.save();

      final a = MeshService(
        identity: DeviceInfo(id: 'device-a', name: 'PC', platform: 'linux'),
        store: storeA,
        heartbeatInterval: const Duration(seconds: 30),
        connectTimeout: const Duration(milliseconds: 300),
      );
      final b = MeshService(
        identity: DeviceInfo(id: 'device-b', name: 'Phone', platform: 'android'),
        store: storeB,
        heartbeatInterval: const Duration(seconds: 30),
        connectTimeout: const Duration(milliseconds: 300),
      );
      await a.start();
      await b.start();

      // The user is pairing: a code is on screen.
      final session = a.beginPairing();

      // A stranger who never saw the code claims to be pairing.
      await _strangerSends(
        a.port,
        _pairRequestFrame(from: 'stranger', id: 'stranger-pair'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(
        a.isPaired('stranger'),
        isFalse,
        reason: 'pairing must require the code, not a claim',
      );
      expect(
        a.pendingCode,
        session.code,
        reason: 'a stranger must not spend the code the user is showing',
      );

      // And the device the user is actually pairing with still works.
      final real = await b.pairWith(
        address: '127.0.0.1',
        port: a.port,
        code: session.code,
      );
      expect(real.ok, isTrue, reason: real.error);
      expect(a.isPaired('device-b'), isTrue);

      await a.stop();
      await b.stop();
    });
  });

  group('discovery keeps working while distrusting', () {
    test('an unpaired device is still heard, just not trusted', () async {
      final tmp = await Directory.systemTemp.createTemp('nexus_discover');
      final store = NexusStore(explicitPath: '${tmp.path}/a.json')..port = 53440;
      await store.save();
      final a = MeshService(
        identity: DeviceInfo(id: 'device-a', name: 'PC', platform: 'linux'),
        store: store,
        onlineWindow: const Duration(seconds: 5),
        visibleWindow: const Duration(seconds: 5),
        heartbeatInterval: const Duration(seconds: 30),
        connectTimeout: const Duration(milliseconds: 300),
      );
      await a.start();

      await _strangerSends(
        a.port,
        _pingFrame(from: 'newcomer', id: 'newcomer-1', name: 'New Laptop'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(
        a.isVisible('newcomer'),
        isTrue,
        reason: 'Nearby discovery must still hear an unknown device',
      );
      expect(
        a.isOnline('newcomer'),
        isFalse,
        reason: 'heard is not trusted: online is for devices we can prove',
      );
      expect(a.isPaired('newcomer'), isFalse);

      await a.stop();
    });
  });

  group('frames are processed once', () {
    test('a replayed plaintext frame is dropped', () async {
      final tmp = await Directory.systemTemp.createTemp('nexus_replay');
      final store = NexusStore(explicitPath: '${tmp.path}/a.json')..port = 53450;
      await store.save();
      final a = MeshService(
        identity: DeviceInfo(id: 'device-a', name: 'PC', platform: 'linux'),
        store: store,
        onlineWindow: const Duration(seconds: 5),
        visibleWindow: const Duration(seconds: 5),
        heartbeatInterval: const Duration(seconds: 30),
        connectTimeout: const Duration(milliseconds: 300),
      );
      await a.start();

      final frame = _pingFrame(from: 'newcomer', id: 'replay-once');
      await _strangerSends(a.port, frame);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final firstHeard = a.lastSeenAt('newcomer');
      expect(firstHeard, isNotNull, reason: 'the first frame is processed');

      // The very same bytes, again — what a captured frame looks like when it
      // is replayed at the device it was captured from.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await _strangerSends(a.port, frame);
      await Future<void>.delayed(const Duration(milliseconds: 250));

      expect(
        a.lastSeenAt('newcomer'),
        firstHeard,
        reason: 'a replayed frame must be dropped, not processed again',
      );

      await a.stop();
    });

    test('a replayed encrypted frame is dropped', () async {
      final h = await _pair(portA: 53455, portB: 53456);

      var adopted = 0;
      h.a.onProfileReceived = (_, _) => adopted++;

      // A frame of the kind only a paired device can send, built with the
      // shared secret — exactly what an attacker replays after capturing it.
      final key = await deriveSessionKey(
        pairingSecret: h.code,
        myId: 'device-b',
        peerId: 'device-a',
      );
      final enc = await encryptToB64(
        encodeJson(
          NexusMessage(
            type: NexusMessage.agentProfile,
            from: 'device-b',
            to: 'device-a',
            payload: {'assistantName': 'Sophie'},
            id: 'replay-encrypted',
            ts: DateTime.now().millisecondsSinceEpoch,
          ).toJson(),
        ),
        key,
      );
      final captured = {'enc': enc};

      await _strangerSends(h.a.port, captured);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(adopted, 1, reason: 'the frame is genuine and is applied once');

      await _strangerSends(h.a.port, captured);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(
        adopted,
        1,
        reason: 'the same captured bytes must not be applied twice',
      );

      await h.a.stop();
      await h.b.stop();
    });
  });

  group('honest peers are unaffected', () {
    test('two paired devices still verify each other online', () async {
      final h = await _pair(
        portA: 53460,
        portB: 53461,
        heartbeat: const Duration(seconds: 1),
      );

      await _waitFor(
        () => h.a.isOnline('device-b') && h.b.isOnline('device-a'),
        timeout: const Duration(seconds: 15),
      );

      expect(h.a.isOnline('device-b'), isTrue);
      expect(h.b.isOnline('device-a'), isTrue);
      expect(h.a.onlineCount, 1);
      expect(h.b.onlineCount, 1);

      await h.a.stop();
      await h.b.stop();
    });

    test('a legitimate peer still refreshes its own route', () async {
      // A peer that moves: it connects from a new address and announces a new
      // port. Its own proof must still move the route — otherwise the fix
      // would break reconnecting after a network change.
      final lan = await _reachableIpv4();
      final h = await _pair(portA: 53470, portB: 53471);

      var peer = h.a.pairedDevices.singleWhere((d) => d.id == 'device-b');
      expect(peer.address, '127.0.0.1');

      // Reconnect from the LAN address, as a device that changed networks
      // would, carrying a real proof.
      final frame = await _signedPing(
        mesh: h.b,
        code: h.code,
        from: 'device-b',
        to: 'device-a',
        id: 'legit-move',
        port: 53471,
      );
      await _strangerSends(h.a.port, frame, host: lan);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      peer = h.a.pairedDevices.singleWhere((d) => d.id == 'device-b');
      expect(
        peer.address,
        lan,
        reason: 'a proven claim from the real device must still update the route',
      );
      expect(h.a.isOnline('device-b'), isTrue);

      await h.a.stop();
      await h.b.stop();
    });
  });
}

/// A ping built exactly as the peer's own heartbeat builds one, proof included
/// — tests the honest path through the same door the attacks use.
Future<Map<String, dynamic>> _signedPing({
  required MeshService mesh,
  required String code,
  required String from,
  required String to,
  required String id,
  required int port,
}) async {
  final key = await deriveSessionKey(
    pairingSecret: code,
    myId: from,
    peerId: to,
  );
  final ts = DateTime.now().millisecondsSinceEpoch;
  final tag = await presenceTag(
    key: key,
    kind: NexusMessage.ping,
    from: from,
    id: id,
    ts: ts,
  );
  return {
    'type': NexusMessage.ping,
    'from': from,
    'payload': {
      'name': 'Phone',
      'port': port,
      'platform': 'android',
      'auth': tag,
    },
    'id': id,
    'ts': ts,
  };
}
