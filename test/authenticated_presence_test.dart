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
import 'dart:typed_data';

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

/// A connection a paired peer has already opened honestly, plus the key it
/// shares with the device it dialled — everything a real peer holds, and all
/// that is needed to write someone else's id in `from`.
class _PeerConnection {
  _PeerConnection(this._socket, this._key);

  final Socket _socket;
  final Uint8List _key;

  Future<void> send(Map<String, dynamic> frame) async {
    final enc = await encryptToB64(encodeJson(frame), _key);
    _socket.add(FrameDecoder.encodeFrame(encodeJson({'enc': enc})));
    await _socket.flush();
  }

  Future<void> close() => _socket.close();
}

/// Opens a connection to [toId] as [from] really is, using the session key
/// [from] genuinely shares with it, and waits until [target] has identified
/// the connection as [from]. The honest opener is what makes a forged `from`
/// on a later frame reachable at all — which is why the attacks below start
/// here rather than with a stranger, and why the wait is part of the helper:
/// a forged frame that arrives before the connection is attributed is dropped
/// by the identify step, and would prove nothing about the sender check.
Future<_PeerConnection> _openHonestly({
  required MeshService from,
  required MeshService target,
  required String toId,
  required int targetPort,
  String host = '127.0.0.1',
}) async {
  final peer = from.pairedDevices.singleWhere((d) => d.id == toId);
  final key = await deriveSessionKey(
    pairingSecret: peer.pairingSecret,
    myId: from.identity.id,
    peerId: toId,
  );
  final socket = await Socket.connect(
    host,
    targetPort,
    timeout: const Duration(seconds: 3),
  );
  final connection = _PeerConnection(socket, key);
  await connection.send({
    'type': NexusMessage.ping,
    'from': from.identity.id,
    'payload': {
      'name': from.identity.name,
      'port': from.store.port,
      'platform': from.identity.platform,
    },
    'id': 'open-${from.identity.id}',
    'ts': DateTime.now().millisecondsSinceEpoch,
  });
  await _waitFor(() => target.isOnline(from.identity.id));
  return connection;
}

/// One frame, with a sender of the caller's choosing — the shape a malicious
/// peer sends: a real key, and somebody else's id.
Map<String, dynamic> _encrypted({
  required String from,
  required String type,
  required Map<String, dynamic> payload,
}) => {
  'type': type,
  'from': from,
  'payload': payload,
  'id': '$type-$from-${DateTime.now().microsecondsSinceEpoch}',
  'ts': DateTime.now().millisecondsSinceEpoch,
};

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

  group('a paired peer cannot speak as another device', () {
    // A paired peer holds a real session key, so it can always produce frames
    // that decrypt. What it must not be able to do is write a *different*
    // device's id in `from` and have that believed: presence, routes, learned
    // phrases, facts and device-addressed answers all hang off that field, so a
    // believable claim is a forged device. The identity a frame may speak as is
    // the one the channel proved, and these are the attacks that check it.

    /// A: paired with B, and separately with C. C then goes away, so anything
    /// C is later seen to do can only have come from somewhere else.
    Future<({MeshService a, MeshService b, MeshService c, Directory tmp})>
    pairedWithTwo({required int portA, required int portB, required int portC}) async {
      final tmp = await Directory.systemTemp.createTemp('nexus_impostor');
      final storeA = NexusStore(explicitPath: '${tmp.path}/a.json')..port = portA;
      final storeB = NexusStore(explicitPath: '${tmp.path}/b.json')..port = portB;
      final storeC = NexusStore(explicitPath: '${tmp.path}/c.json')..port = portC;
      await storeA.save();
      await storeB.save();
      await storeC.save();

      MeshService mk(NexusStore store, String id, String name, String platform) =>
          MeshService(
            identity: DeviceInfo(id: id, name: name, platform: platform),
            store: store,
            onlineWindow: const Duration(seconds: 2),
            visibleWindow: const Duration(seconds: 2),
            heartbeatInterval: const Duration(seconds: 60),
            connectTimeout: const Duration(milliseconds: 300),
          );

      final a = mk(storeA, 'device-a', 'PC', 'linux');
      final b = mk(storeB, 'device-b', 'Phone', 'android');
      final c = mk(storeC, 'device-c', 'Tablet', 'android');
      await a.start();
      await b.start();
      await c.start();

      final first = a.beginPairing();
      expect(
        (await b.pairWith(
          address: '127.0.0.1',
          port: a.port,
          code: first.code,
        )).ok,
        isTrue,
      );
      final second = a.beginPairing();
      expect(
        (await c.pairWith(
          address: '127.0.0.1',
          port: a.port,
          code: second.code,
        )).ok,
        isTrue,
      );
      await _waitFor(() => a.isPaired('device-b') && a.isPaired('device-c'));
      await c.stop();
      await _waitFor(() => !a.isOnline('device-c'));
      return (a: a, b: b, c: c, tmp: tmp);
    }

    test('it cannot make another paired device look online', () async {
      final h = await pairedWithTwo(
        portA: 53480,
        portB: 53481,
        portC: 53482,
      );
      expect(h.a.isOnline('device-c'), isFalse, reason: 'C is away');

      final impostor = await _openHonestly(
        from: h.b,
        target: h.a,
        toId: 'device-a',
        targetPort: h.a.port,
      );

      await impostor.send(
        _encrypted(
          from: 'device-c',
          type: NexusMessage.ping,
          payload: {'name': 'Tablet', 'port': 59997, 'platform': 'android'},
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 700));

      expect(
        h.a.isOnline('device-c'),
        isFalse,
        reason: 'a claim cannot put a device online',
      );

      await impostor.close();
      await h.a.stop();
      await h.b.stop();
    });

    test('it cannot move where another paired device is reached', () async {
      final lan = await _reachableIpv4();
      final h = await pairedWithTwo(
        portA: 53490,
        portB: 53491,
        portC: 53492,
      );
      final before = h.a.pairedDevices.singleWhere((d) => d.id == 'device-c');
      final addressBefore = before.address;
      final portBefore = before.port;

      // Dialled over the LAN address, so the announced route is one the peer
      // could really be reached at — the strongest version of the claim.
      final impostor = await _openHonestly(
        from: h.b,
        target: h.a,
        toId: 'device-a',
        targetPort: h.a.port,
        host: lan,
      );
      await impostor.send(
        _encrypted(
          from: 'device-c',
          type: NexusMessage.ping,
          payload: {'name': 'Tablet', 'port': 59997, 'platform': 'android'},
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 700));

      final after = h.a.pairedDevices.singleWhere((d) => d.id == 'device-c');
      expect(
        after.port,
        portBefore,
        reason: 'only the device itself may move its own route',
      );
      expect(after.address, addressBefore);

      await impostor.close();
      await h.a.stop();
      await h.b.stop();
    });

    test('it cannot land a fact or a phrase as another device', () async {
      final h = await pairedWithTwo(
        portA: 53500,
        portB: 53501,
        portC: 53502,
      );
      final impostor = await _openHonestly(
        from: h.b,
        target: h.a,
        toId: 'device-a',
        targetPort: h.a.port,
      );

      // Sent while the connection is still honestly identified as B, which is
      // the whole attack: the bytes are B's, the claim is C's.
      await impostor.send(
        _encrypted(
          from: 'device-c',
          type: NexusMessage.agentFact,
          payload: {'text': 'the safe code is 1234'},
        ),
      );
      await impostor.send(
        _encrypted(
          from: 'device-c',
          type: NexusMessage.agentLearned,
          payload: {'phrase': 'bring me home', 'meaning': 'show my devices'},
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 700));

      expect(
        h.a.store.agentFacts,
        isEmpty,
        reason: 'memory must not adopt a fact under another device\'s name',
      );
      expect(
        h.a.store.agentLearned,
        isEmpty,
        reason: 'a phrase that changes behaviour must not be adoptable as '
            'another device',
      );

      await impostor.close();
      await h.a.stop();
      await h.b.stop();
    });

    test('the peer that owns the connection is still believed', () async {
      // The counterweight: the guard keys on identity, not on "this connection
      // is now suspicious". B's own frames must still land, with B's name on
      // them, on the very connection it used for the refused claim.
      final h = await pairedWithTwo(
        portA: 53510,
        portB: 53511,
        portC: 53512,
      );
      final impostor = await _openHonestly(
        from: h.b,
        target: h.a,
        toId: 'device-a',
        targetPort: h.a.port,
      );

      await impostor.send(
        _encrypted(
          from: 'device-c',
          type: NexusMessage.agentFact,
          payload: {'text': 'the safe code is 1234'},
        ),
      );
      await impostor.send(
        _encrypted(
          from: 'device-b',
          type: NexusMessage.agentFact,
          payload: {'text': 'the bin day is tuesday'},
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 700));

      expect(h.a.store.agentFacts, hasLength(1));
      final landed = h.a.store.agentFacts.single;
      expect(landed.text, 'the bin day is tuesday');
      expect(
        landed.sentence,
        contains('Phone'),
        reason: 'attributed to the device that really sent it',
      );
      expect(
        landed.sentence,
        isNot(contains('Tablet')),
        reason: 'and never to the device whose id was claimed',
      );
      expect(h.a.isOnline('device-b'), isTrue);

      await impostor.close();
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
