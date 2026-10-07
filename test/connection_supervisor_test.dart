import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/mesh/connection_supervisor.dart';
import 'package:nexus/mesh/mesh_service.dart';
import 'package:nexus/mesh/mesh_transport.dart';

/// A clock the test moves by hand, so a 60 s backoff costs no real time and
/// the retry curve can be read off exactly.
class FakeClock {
  DateTime now = DateTime.utc(2026, 1, 1, 12);
  DateTime call() => now;
  void advance(Duration by) => now = now.add(by);
}

/// A paired peer with a reachability switch — the transport the supervisor
/// sees when the link is a plain TCP mesh session.
///
/// It models the two things the real mesh does: the supervisor's own presence
/// exchanges ([beat]), which answer only while the peer is reachable, and the
/// mesh's independent heartbeat traffic ([meshTraffic]), which is how a peer
/// that comes back is noticed between retries.
class FakeMeshTransport implements MeshTransport {
  FakeMeshTransport({required this.clock, List<String> ids = const ['peer-1']})
    : _peers = [for (final id in ids) TransportPeer(id: id, name: 'Device $id')],
      _reachable = {for (final id in ids) id: true};

  final FakeClock clock;
  final List<TransportPeer> _peers;
  final Map<String, bool> _reachable;
  final Map<String, DateTime> _seen = {};

  /// Every presence exchange the supervisor asked for, at the clock time it
  /// asked — the retry times, with no real waiting.
  final List<DateTime> beats = [];

  @override
  List<TransportPeer> peers() => List.of(_peers);

  @override
  DateTime? lastHeardAt(String peerId) => _seen[peerId];

  @override
  Future<void> beat() async {
    beats.add(clock.now);
    meshTraffic();
  }

  /// The peer's side of the link is alive: any frame from it moves
  /// last-seen, whether the supervisor asked for it or the mesh's own
  /// heartbeat did. A peer that is gone moves nothing and fails silently —
  /// the whole reason the supervisor has to notice silence itself.
  void meshTraffic() {
    for (final peer in _peers) {
      if (_reachable[peer.id] ?? false) _seen[peer.id] = clock.now;
    }
  }

  /// The peer stops answering (radio off, asleep, process killed).
  void setReachable(String peerId, bool reachable) =>
      _reachable[peerId] = reachable;

  /// The device is unpaired or forgotten.
  void forget(String peerId) =>
      _peers.removeWhere((peer) => peer.id == peerId);
}

/// A *second* transport — a cable link — with a deliberately different shape:
/// one switch for the whole cable, no per-peer state. The supervisor is handed
/// it with no change anywhere in the supervisor: that is the seam test.
class FakeCableTransport implements MeshTransport {
  FakeCableTransport({required this.clock, this.peerId = 'cable-peer'});

  final FakeClock clock;
  final String peerId;

  /// Whether the cable is unplugged, and whether the node is still paired.
  bool pluggedIn = true;
  bool present = true;
  DateTime? seen;
  int beats = 0;

  @override
  List<TransportPeer> peers() =>
      present ? [TransportPeer(id: peerId, name: 'Cable node')] : const [];

  @override
  DateTime? lastHeardAt(String id) => seen;

  @override
  Future<void> beat() async {
    beats += 1;
    peerTraffic();
  }

  /// The node talking on its own, which the cable carries without the
  /// supervisor doing anything.
  void peerTraffic() {
    if (pluggedIn) seen = clock.now;
  }
}

/// A transport whose presence exchange can stop answering *without* ever
/// completing: a dial blocked inside the OS. The supervisor cannot tell that
/// apart from one that is merely slow, which is the whole difficulty.
class HangingTransport implements MeshTransport {
  HangingTransport({required this.clock, this.peerId = 'peer-1'});

  final FakeClock clock;
  final String peerId;

  /// When true, [beat] returns a future that never completes.
  bool hangs = false;

  /// How many times the supervisor asked for an exchange, hung or not.
  int beats = 0;

  @override
  List<TransportPeer> peers() => [
    TransportPeer(id: peerId, name: 'Device $peerId'),
  ];

  /// Never heard from: the peer is down, which is the state a retry schedule
  /// exists for.
  @override
  DateTime? lastHeardAt(String id) => null;

  @override
  Future<void> beat() {
    beats += 1;
    return hangs ? Completer<void>().future : Future<void>.value();
  }
}

/// Drives [supervisor.tick] once per [step] of fake time, exactly as its real
/// timer would if the clock were the fake one.
Future<void> driveTicks(
  ConnectionSupervisor supervisor,
  FakeClock clock,
  Duration span, {
  Duration step = const Duration(seconds: 1),
}) async {
  final end = clock.now.add(span);
  while (!clock.now.isAfter(end)) {
    await supervisor.tick();
    clock.advance(step);
  }
}

/// The beats, in seconds from the first one.
List<int> _offsets(List<DateTime> beats) => [
  for (final beat in beats) beat.difference(beats.first).inSeconds,
];

/// A loopback port the system has just handed back, so two meshes in one test
/// never fight over a port (the same helper `mesh_test.dart` uses).
Future<int> loopbackPort() async {
  final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = probe.port;
  await probe.close();
  return port;
}

/// Waits until [condition] holds, up to [timeout]. Real sockets and a real
/// clock: used only by the end-to-end case, where fakes cannot stand in for a
/// peer that actually goes away.
Future<bool> waitFor(bool Function() condition, Duration timeout) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return condition();
}

/// A clipboard that needs no platform channel.
class FakeClipboard implements ClipboardBackend {
  String? value;
  @override
  Future<String?> readText() async => value;
  @override
  Future<void> writeText(String text) async => value = text;
}

void main() {
  late FakeClock clock;
  late FakeMeshTransport transport;
  late ConnectionSupervisor supervisor;

  // A long tick interval: these tests drive tick() by hand, so no real timer
  // may fire and no assertion may depend on wall-clock time passing.
  const handDriven = Duration(hours: 1);

  setUp(() {
    clock = FakeClock();
    transport = FakeMeshTransport(clock: clock);
    supervisor = ConnectionSupervisor(
      transport: transport,
      clock: clock.call,
      tickInterval: handDriven,
    );
  });

  tearDown(() async {
    await supervisor.stop();
  });

  group('retry backoff', () {
    test('an unreachable peer is retried 2s→60s, capped', () async {
      transport.setReachable('peer-1', false); // never answers
      await supervisor.start();
      await driveTicks(supervisor, clock, const Duration(seconds: 200));

      // 2, 4, 8, 16, 32 and then 60 forever: the doubling stops at the cap.
      // With the cap removed this reads 0, 2, 6, 14, 30, 62, 126, 254 and the
      // test fails — that is why the whole curve is asserted, not just that
      // some retry happened.
      expect(_offsets(transport.beats), [0, 2, 6, 14, 30, 62, 122, 182]);
      expect(supervisor.links.single.up, isFalse);
      expect(supervisor.links.single.attempts, transport.beats.length);
      // One call a minute is the cost of a device that is off.
      expect(transport.beats.last.difference(transport.beats[transport.beats.length - 2]), const Duration(seconds: 60));
    });

    test('a peer that answers again goes back up and the curve starts over', () async {
      transport.setReachable('peer-1', false);
      await supervisor.start();
      await driveTicks(supervisor, clock, const Duration(seconds: 35));
      expect(supervisor.links.single.up, isFalse);
      expect(supervisor.links.single.attempts, greaterThan(1));

      // The peer is back — and the mesh's own heartbeat hearing it is enough;
      // the supervisor does not have to reach the end of its backoff.
      transport.setReachable('peer-1', true);
      transport.meshTraffic();
      await supervisor.tick();
      expect(supervisor.links.single.up, isTrue);
      expect(supervisor.links.single.attempts, 0);
      expect(supervisor.links.single.nextAttemptAt, isNull);
      expect(supervisor.links.single.lastHeard, isNotNull);
    });

    test('each peer keeps its own curve', () async {
      final two = FakeMeshTransport(clock: clock, ids: ['peer-1', 'peer-2']);
      final sup = ConnectionSupervisor(
        transport: two,
        clock: clock.call,
        tickInterval: handDriven,
      );
      await sup.start();
      two.setReachable('peer-2', false);
      await driveTicks(sup, clock, const Duration(seconds: 30));

      final healthy = sup.links.firstWhere((link) => link.id == 'peer-1');
      final gone = sup.links.firstWhere((link) => link.id == 'peer-2');
      expect(healthy.up, isTrue); // a dead peer never drags a live one down
      expect(healthy.attempts, 0);
      expect(gone.up, isFalse);
      expect(gone.attempts, greaterThan(1));

      await sup.stop();
      expect(sup.links, isEmpty); // stopping forgets what it was watching
    });
  });

  group('heartbeat', () {
    test('a healthy peer is held up by the supervisor\'s own heartbeat', () async {
      // Defaults, not overrides: the shipped cadence is what is tested here.
      supervisor = ConnectionSupervisor(
        transport: transport,
        clock: clock.call,
        tickInterval: handDriven,
      );
      await supervisor.start();
      await driveTicks(supervisor, clock, const Duration(seconds: 30));

      expect(supervisor.links.single.up, isTrue);
      // One exchange every 3s, not one per tick: silence can only mean
      // something if the supervisor asks often enough to hear an answer.
      expect(_offsets(transport.beats), [
        0,
        3,
        6,
        9,
        12,
        15,
        18,
        21,
        24,
        27,
        30,
      ]);
    });

    test('silence is called a drop inside the heartbeat timeout', () async {
      // The shipped 3 s beat and 9 s timeout, written out in the assertions
      // below rather than passed in, so changing either default fails here.
      supervisor = ConnectionSupervisor(
        transport: transport,
        clock: clock.call,
        tickInterval: handDriven,
      );
      await supervisor.start();
      clock.advance(const Duration(seconds: 3));
      await supervisor.tick();
      expect(supervisor.links.single.up, isTrue);
      expect(transport.lastHeardAt('peer-1'), clock.now);

      // The peer goes quiet. The last thing heard from it was right now.
      transport.setReachable('peer-1', false);
      final quietAt = clock.now;

      // Still up at exactly the timeout: three missed beats, not two.
      clock.advance(const Duration(seconds: 9));
      await supervisor.tick();
      expect(clock.now.difference(quietAt).inSeconds, 9);
      expect(supervisor.links.single.up, isTrue);

      // One second past it the link is down and a retry has gone out. With
      // the timeout removed, the peer would still read "up" here — and would
      // stay up while it was gone.
      clock.advance(const Duration(seconds: 1));
      await supervisor.tick();
      expect(supervisor.links.single.up, isFalse);
      expect(supervisor.links.single.attempts, 1);
      expect(transport.beats.last, clock.now);
    });
  });

  group('a transport that stops answering', () {
    test('a beat that never completes cannot stop the retry loop', () async {
      // The shape measured on a real phone on 2026-10-07: the app's process
      // alive (pid unchanged for hours), the Android foreground service still
      // holding its notification, and not one dial for 51 minutes. This is the
      // one way the supervisor's own schedule can stop: `tick()` held
      // `_ticking` across `await transport.beat()`, so a beat that never
      // returned made every later tick return at the guard on its first line —
      // and because the mesh's sweep leaves a supervised peer alone
      // (`MeshService._presenceSweep`), the peer was then dialled by nobody.
      final hanging = HangingTransport(clock: clock);
      final sup = ConnectionSupervisor(
        transport: hanging,
        clock: clock.call,
        tickInterval: handDriven,
      );
      addTearDown(sup.stop);

      // Starting must not wait on a dial either: the mesh awaits this (see
      // MeshService.start), so a transport that blocks would hang the mesh's
      // own start rather than merely stop a retry.
      hanging.hangs = true;
      await expectLater(
        sup.start().timeout(const Duration(seconds: 2)),
        completes,
      );

      final before = sup.links.single.attempts;
      expect(before, greaterThan(0), reason: 'the peer never answers');

      // Ten minutes of ticks. With the latch held across the beat, `attempts`
      // stays exactly here and the reconnect never happens again — a frozen
      // schedule is a reconnect that never happens.
      await driveTicks(sup, clock, const Duration(minutes: 10));
      expect(
        sup.links.single.attempts,
        greaterThan(before + 5),
        reason: 'a beat that never completes must not freeze the schedule',
      );
      expect(sup.links.single.up, isFalse);
      // It kept being asked, too: the schedule is what stopped, not the
      // willingness to dial.
      expect(hanging.beats, greaterThan(before + 5));
    });
  });

  group('network change', () {
    test('reconnects at once instead of waiting out the backoff', () async {
      transport.setReachable('peer-1', false);
      await supervisor.start();
      await driveTicks(supervisor, clock, const Duration(seconds: 200));
      // The peer is deep in the 60s-capped wait: the next attempt is far off.
      final before = transport.beats.length;
      expect(
        supervisor.links.single.nextAttemptAt!.isAfter(
          clock.now.add(const Duration(seconds: 30)),
        ),
        isTrue,
      );

      clock.advance(const Duration(seconds: 5));
      await supervisor.onNetworkChanged();

      // A presence exchange went out the moment the network changed…
      expect(transport.beats.length, before + 1);
      expect(transport.beats.last, clock.now);
      // …and the curve restarted at the first wait, not where it had got to:
      // waiting out a backoff measured against the old network would be the
      // silent delay this exists to remove.
      expect(
        supervisor.links.single.nextAttemptAt!.difference(clock.now),
        const Duration(seconds: 2),
      );
      expect(supervisor.links.single.attempts, 1);

      clock.advance(const Duration(seconds: 2));
      await supervisor.tick();
      expect(transport.beats.length, before + 2);
    });

    test('a network change while the link is healthy beats straight away', () async {
      await supervisor.start();
      final before = transport.beats.length;
      clock.advance(const Duration(seconds: 1));
      await supervisor.onNetworkChanged();
      expect(transport.beats.length, before + 1);
      expect(transport.beats.last, clock.now);
    });
  });

  group('start and stop', () {
    test('stop ends the watching, start begins it again', () async {
      await supervisor.start();
      expect(supervisor.running, isTrue);
      transport.setReachable('peer-1', false);
      await driveTicks(supervisor, clock, const Duration(seconds: 10));
      expect(transport.beats, isNotEmpty);

      await supervisor.stop();
      expect(supervisor.running, isFalse);
      expect(supervisor.links, isEmpty);

      // Nothing is watched, redialled or noticed while stopped: the mesh —
      // and with it the Android foreground service — has gone.
      final stoppedAt = transport.beats.length;
      clock.advance(const Duration(minutes: 5));
      await supervisor.tick();
      await supervisor.onNetworkChanged();
      expect(transport.beats.length, stoppedAt);

      // Starting again watches from what the transport reports.
      await supervisor.start();
      expect(supervisor.running, isTrue);
      expect(supervisor.links.single.up, isFalse);
      expect(transport.beats.length, stoppedAt + 1);
    });
  });

  group('transport seam', () {
    test('a second transport drives the same supervisor unchanged', () async {
      final cableClock = FakeClock();
      final cable = FakeCableTransport(clock: cableClock);
      final sup = ConnectionSupervisor(
        transport: cable,
        clock: cableClock.call,
        tickInterval: handDriven,
      );

      await sup.start();
      expect(sup.links.single.up, isTrue);
      expect(cable.beats, 1);

      // Unplugged: silence and retries, with nothing in the supervisor that
      // knows this link is a cable rather than a socket.
      cable.pluggedIn = false;
      await driveTicks(sup, cableClock, const Duration(seconds: 35));
      expect(sup.links, hasLength(1));
      expect(sup.links.single.up, isFalse);
      expect(sup.links.single.attempts, greaterThan(1));
      expect(cable.beats, greaterThan(1));

      // Plugged back in: the node's own traffic is enough, on the very next
      // look — no user action and no waiting out the backoff.
      cable.pluggedIn = true;
      cable.peerTraffic();
      await sup.tick();
      expect(sup.links.single.up, isTrue);
      expect(sup.links.single.attempts, 0);

      // A node that is unpaired stops being watched at all.
      cable.present = false;
      await sup.tick();
      expect(sup.links, isEmpty);
      await sup.stop();
    });

    test(
      'a real paired peer that goes away and comes back is re-established, with no user action',
      () async {
        final tmp = await Directory.systemTemp.createTemp('nexus_conn_e2e');
        final storeA = NexusStore(explicitPath: '${tmp.path}/a.json');
        final storeB = NexusStore(explicitPath: '${tmp.path}/b.json');
        storeA.port = await loopbackPort();
        storeB.port = await loopbackPort();
        await storeA.save();
        await storeB.save();

        final meshA = MeshService(
          identity: DeviceInfo(
            id: 'device-a',
            name: 'Test Linux PC',
            platform: 'linux',
          ),
          store: storeA,
          clipboard: FakeClipboard(),
          onlineWindow: const Duration(seconds: 3),
          heartbeatInterval: const Duration(seconds: 1),
          connectTimeout: const Duration(milliseconds: 300),
          fileRoot: tmp.path,
        );
        final meshB = MeshService(
          identity: DeviceInfo(
            id: 'device-b',
            name: 'Test Phone',
            platform: 'android',
          ),
          store: storeB,
          clipboard: FakeClipboard(),
          onlineWindow: const Duration(seconds: 3),
          heartbeatInterval: const Duration(seconds: 1),
          connectTimeout: const Duration(milliseconds: 300),
          fileRoot: tmp.path,
        );
        await meshA.start();
        await meshB.start();
        addTearDown(() async {
          await meshA.stop();
          await meshB.stop();
          await tmp.delete(recursive: true);
        });

        final session = meshA.beginPairing();
        final paired = await meshB.pairWith(
          address: '127.0.0.1',
          port: meshA.port,
          code: session.code,
        );
        expect(paired.ok, isTrue, reason: paired.error);

        // The supervisor over the *real* mesh, on a real clock, so the two
        // halves of the promise can be watched against a real peer rather
        // than a fake: silence is called a drop, and the drop heals.
        final sup = ConnectionSupervisor(
          transport: meshA,
          clock: DateTime.now,
          tickInterval: const Duration(milliseconds: 100),
          heartbeatInterval: const Duration(milliseconds: 400),
          heartbeatTimeout: const Duration(milliseconds: 1200),
        );
        await sup.start();
        expect(meshA.isOnline('device-b'), isTrue);
        expect(
          await waitFor(() => sup.links.single.up, const Duration(seconds: 5)),
          isTrue,
          reason: 'a running peer should be up',
        );
        expect(sup.links.single.id, 'device-b');

        // Let the peer finish registering the connection the supervisor just
        // opened. `MeshService.stop()` destroys the connections it knows
        // about, and a socket still mid-handshake is one it does not know
        // about yet — a ghost that keeps answering. That is a race in this
        // simulation (a real peer that goes away closes its sockets), so give
        // the handshake a beat before pulling the plug.
        await Future<void>.delayed(const Duration(milliseconds: 600));

        // The peer goes away completely: no sockets, no answers.
        await meshB.stop();
        expect(
          await waitFor(
            () => !sup.links.single.up,
            const Duration(seconds: 6),
          ),
          isTrue,
          reason: 'silence past the heartbeat timeout is a drop',
        );
        expect(sup.links.single.attempts, greaterThan(0));

        // It comes back (same store, same pairing) — and nobody touches the
        // app: the supervisor re-establishes the session by itself.
        await meshB.start();
        expect(
          await waitFor(() => sup.links.single.up, const Duration(seconds: 15)),
          isTrue,
          reason: 'the supervisor must re-establish the paired session alone',
        );
        expect(sup.links.single.attempts, 0);
        expect(meshB.isPaired('device-a'), isTrue);
        await sup.stop();
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test(
      'the mesh sweep leaves a peer the supervisor holds down to the supervisor',
      () async {
        final tmp = await Directory.systemTemp.createTemp('nexus_one_dialer');
        addTearDown(() => tmp.delete(recursive: true));

        // A real socket in place of the paired peer, so a dial is something
        // countable: one accepted connection per dial. It answers nothing, so
        // no presence is ever *verified* and the supervisor has to declare the
        // link down — the state a retry schedule is for.
        final peer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final dials = <DateTime>[];
        peer.listen((socket) {
          dials.add(DateTime.now());
          socket.destroy();
        });
        addTearDown(peer.close);

        final store = NexusStore(explicitPath: '${tmp.path}/state.json');
        await store.load();
        store.port = await loopbackPort();
        // Paired before the mesh starts, so it is a link the supervisor
        // watches from its very first tick.
        store.upsertPaired({
          'id': 'device-b',
          'name': 'Test Phone',
          'platform': 'android',
          'localName': false,
          'address': '127.0.0.1',
          'addresses': <String>['127.0.0.1'],
          'port': peer.port,
          'pairingSecret': 'shared-secret',
          'lastVerified': null,
        });
        await store.save();

        final mesh = MeshService(
          identity: DeviceInfo(
            id: 'device-a',
            name: 'Test Linux PC',
            platform: 'linux',
          ),
          store: store,
          clipboard: FakeClipboard(),
          // A 100 ms sweep: if the mesh still dialled paired peers from here,
          // it would do it many times over inside the window below.
          heartbeatInterval: const Duration(milliseconds: 100),
          connectTimeout: const Duration(milliseconds: 200),
        );
        await mesh.start();
        addTearDown(mesh.stop);

        // Something does dial a paired peer — the supervisor's own first
        // tick — so the counts below are about who dials, not about a socket
        // nothing ever reached.
        expect(
          await waitFor(() => dials.isNotEmpty, const Duration(seconds: 3)),
          isTrue,
          reason: 'the supervisor dials a paired peer',
        );
        final sup = mesh.supervisor!;
        expect(
          await waitFor(
            () => sup.links.single.attempts > 0 && !sup.links.single.up,
            const Duration(seconds: 8),
          ),
          isTrue,
          reason: 'a peer that never answers past the timeout is down',
        );

        // The peer is down and the retry curve is at its first wait, so a few
        // seconds of this window can hold at most the one attempt the
        // supervisor owes. The mesh's own 100 ms sweep would put ~15 dials in
        // it if it still dialled paired peers: the two are an order of
        // magnitude apart on purpose, so this tolerates the supervisor's
        // attempt landing here and still fails loudly on a second dialer.
        final before = dials.length;
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        expect(
          dials.length - before,
          lessThanOrEqualTo(2),
          reason: 'the mesh sweep must not re-dial a peer the supervisor holds',
        );

        // The other half of the ownership rule: stop scheduling it and the
        // sweep takes the peer back, so the quiet above came from the
        // supervisor owning the peer and not from a sweep that never ran.
        await sup.stop();
        final afterStop = dials.length;
        expect(
          await waitFor(
            () => dials.length > afterStop,
            const Duration(seconds: 2),
          ),
          isTrue,
          reason: 'with nobody scheduling it, the mesh sweep dials again',
        );
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test('the mesh itself is the WiFi transport', () async {
      final tmp = await Directory.systemTemp.createTemp('nexus_supervisor');
      final store = NexusStore(explicitPath: '${tmp.path}/state.json');
      await store.save();
      final mesh = MeshService(
        identity: DeviceInfo(
          id: 'device-a',
          name: 'Test Linux PC',
          platform: 'linux',
        ),
        store: store,
        clipboard: FakeClipboard(),
      );
      // No adapter, no wrapper: the mesh *is* the implementation the
      // supervisor talks to, the same way it implements its file-fetch seam.
      final MeshTransport seam = mesh;
      expect(seam.peers(), isEmpty);
      expect(seam.lastHeardAt('nobody'), isNull);
      await seam.beat(); // safe with nothing to ping
      await mesh.stop();
      await tmp.delete(recursive: true);
    });
  });
}
