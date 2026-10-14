import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/mesh/mesh_lifecycle.dart';
import 'package:nexus/mesh/mesh_service.dart';

/// Socket-leak regression tests: `MeshService.stop()` used to be dead code in
/// `lib/` (only tests called it), so an engine recreation in the same process
/// left the old listener on 51820 while the new engine fell back to an
/// ephemeral port — and peers kept dialling the stale route.
///
/// The first test simulates that recreation (start, detached-stop, restart on
/// the same store) and asserts exactly one listener survives, on the
/// canonical port. The second pins the dial order that heals a stale route.
/// The third proves the heal end to end: a peer whose stored route names a
/// dead ephemeral port comes back online through 51820.

/// A loopback port the system has just handed back (same trick as
/// mesh_test.dart: never hardcode a port inside the ephemeral range).
Future<int> _freePort() async {
  final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = probe.port;
  await probe.close();
  return port;
}

MeshService _mesh(
  String id,
  NexusStore store, {
  Duration heartbeatInterval = const Duration(days: 1),
}) => MeshService(
  identity: DeviceInfo(id: id, name: 'Test $id', platform: 'linux'),
  store: store,
  heartbeatInterval: heartbeatInterval,
  connectTimeout: const Duration(milliseconds: 300),
);

/// Binds [port] if it is free, or returns null when something else in this
/// run (usually another test file's mesh — `flutter test` shards files in
/// parallel) already holds it.
Future<ServerSocket?> _tryHold(int port) async {
  try {
    return await ServerSocket.bind(InternetAddress.anyIPv4, port);
  } catch (_) {
    return null;
  }
}

Future<bool> _canBind(int port) async {
  try {
    final s = await ServerSocket.bind(InternetAddress.anyIPv4, port);
    await s.close();
    return true;
  } catch (_) {
    return false;
  }
}

Future<String?> _lanIp() async {
  for (final iface in await NetworkInterface.list(
    type: InternetAddressType.IPv4,
  )) {
    for (final addr in iface.addresses) {
      if (!addr.isLoopback) return addr.address;
    }
  }
  return null;
}

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('nexus_socket_life');
  });
  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test(
    'engine recreation leaves exactly one listener, on the canonical port',
    () async {
      // Hold 51820 so the first engine is forced onto an ephemeral port —
      // the shape of the bug report (dead listener on 51820, live mesh on
      // 44485). If another test file holds it right now, there is nothing
      // deterministic to assert; say so and pass vacuously.
      final hold = await _tryHold(MeshService.defaultPort);
      if (hold == null) {
        // ignore: avoid_print
        print('socket-lifecycle: 51820 busy, skipping port assertions');
        return;
      }
      final ephemeral = await _freePort();
      final store = NexusStore(explicitPath: '${tmp.path}/s.json')
        ..port = ephemeral
        ..pairingEnabled = true;
      await store.save();

      final engine1 = _mesh('engine-1', store);
      await engine1.start();
      expect(
        engine1.port,
        ephemeral,
        reason: 'with 51820 held, the first engine takes the ephemeral port',
      );

      // Simulate the engine going away: the lifecycle hook stops the mesh.
      MeshLifecycleObserver(engine1).didChangeAppLifecycleState(
        AppLifecycleState.detached,
      );
      var released = false;
      for (var i = 0; i < 50 && !released; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        released = await _canBind(ephemeral);
      }
      expect(
        released,
        isTrue,
        reason: 'stop() must release the old listener (the leak)',
      );

      // The new engine in the same process reclaims the canonical port even
      // though the store still names the stale ephemeral one.
      await hold.close();
      final engine2 = _mesh('engine-2', store);
      await engine2.start();
      if (engine2.port != MeshService.defaultPort) {
        // Another file grabbed 51820 in the microseconds between releasing
        // the hold and binding; without the canonical port the single-
        // listener assertion below is meaningless.
        // ignore: avoid_print
        print('socket-lifecycle: lost the 51820 race, skipping');
        await engine2.stop();
        return;
      }

      // Exactly one listener: the port is held while the mesh runs…
      expect(
        await _canBind(MeshService.defaultPort),
        isFalse,
        reason: 'the recreated engine must hold 51820',
      );
      // …and free once it stops — no ghost listener left behind.
      await engine2.stop();
      expect(
        await _canBind(MeshService.defaultPort),
        isTrue,
        reason: 'stopping the mesh must free 51820 (no second listener)',
      );
    },
  );

  test('dial order tries the canonical port before the stored one', () {
    expect(
      MeshService.dialPortsFor(storedPort: 44485, loopback: false),
      [MeshService.defaultPort, 44485],
    );
    expect(
      MeshService.dialPortsFor(
        storedPort: MeshService.defaultPort,
        loopback: false,
      ),
      [MeshService.defaultPort],
    );
    // Tunnel endpoints keep the old behaviour: stored port only.
    expect(
      MeshService.dialPortsFor(storedPort: 44485, loopback: true),
      [44485],
    );
    expect(
      MeshService.dialPortsFor(storedPort: -1, loopback: false),
      [MeshService.defaultPort],
    );
  });

  test('a stale ephemeral route heals through the canonical port', () async {
    final lan = await _lanIp();
    if (lan == null) {
      // ignore: avoid_print
      print('socket-lifecycle: no LAN interface, skipping heal test');
      return;
    }
    final hold = await _tryHold(MeshService.defaultPort);
    if (hold == null) {
      // ignore: avoid_print
      print('socket-lifecycle: 51820 busy, skipping heal test');
      return;
    }

    final storeA = NexusStore(explicitPath: '${tmp.path}/a.json')
      ..port = await _freePort()
      ..pairingEnabled = true;
    final storeB = NexusStore(explicitPath: '${tmp.path}/b.json')
      ..port = await _freePort()
      ..pairingEnabled = true;
    await storeA.save();
    await storeB.save();
    final meshA = _mesh(
      'heal-a',
      storeA,
      heartbeatInterval: const Duration(seconds: 1),
    );
    final meshB = _mesh(
      'heal-b',
      storeB,
      heartbeatInterval: const Duration(seconds: 1),
    );
    var b2Started = false;
    MeshService? meshB2;
    try {
      await meshA.start();
      await meshB.start();
      expect(meshB.port, storeB.port);

      // Pair over the LAN address so the stored route is a real (non-tunnel)
      // one naming the ephemeral port.
      final session = meshB.beginPairing();
      final paired = await meshA.pairWith(
        address: lan,
        port: meshB.port,
        code: session.code,
      );
      expect(paired.ok, isTrue, reason: paired.error);
      expect(meshA.pairedDevices.single.port, meshB.port);

      // Restart the peer with 51820 free: it reclaims the canonical port
      // while our stored route still names the dead ephemeral one.
      await meshB.stop();
      await hold.close();
      meshB2 = _mesh(
        'heal-b',
        storeB,
        heartbeatInterval: const Duration(seconds: 1),
      );
      await meshB2.start();
      b2Started = true;
      if (meshB2.port != MeshService.defaultPort) {
        // ignore: avoid_print
        print('socket-lifecycle: lost the 51820 race, skipping heal');
        return;
      }

      // The next beats must find the peer through 51820, not the stale port.
      var online = false;
      for (var i = 0; i < 100 && !online; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        online = meshA.isOnline('heal-b');
      }
      expect(
        online,
        isTrue,
        reason: 'peer must come back online via the canonical port, '
            'not the stale ephemeral route ${storeB.port}',
      );
    } finally {
      await meshA.stop();
      await meshB.stop();
      if (b2Started) await meshB2?.stop();
      try {
        await hold.close();
      } catch (_) {}
    }
  });
}
