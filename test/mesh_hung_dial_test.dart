// Guards the mesh's own latches (lib/mesh/mesh_service.dart).
//
// The supervisor's schedule is no longer somewhere a hung dial can freeze it
// (see connection_supervisor_test.dart), but the mesh underneath had the same
// shape twice: `_heartbeatRunning` and `_clipboardSending` were booleans
// cleared in a `finally`. The heartbeat is the important one — it is what the
// supervisor's `beat()` calls, so a latch stuck there makes every retry, and
// with it the whole reconnect promise, a silent no-op.
//
// The hang is real rather than mocked: a listener whose accept queue is already
// full never answers a connect and never refuses it, so the dial sits in
// SYN_SENT exactly as it does against a host that stopped responding. Nothing
// beyond loopback is touched.
//
// The test is two-sided on purpose. While a dial is stuck a beat must still be
// a no-op (the old boolean behaviour, kept), and after the watchdog it must dial
// again — so a latch that never lets go and a latch that is not there at all
// both fail.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/mesh/mesh_service.dart';

class _NoClipboard implements ClipboardBackend {
  @override
  Future<String?> readText() async => null;
  @override
  Future<void> writeText(String text) async {}
}

/// A loopback port the system has just handed back, so binding it in the mesh
/// does not collide with anything.
Future<int> _freePort() async {
  final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = probe.port;
  await probe.close();
  return port;
}

/// A listener that will never accept: its backlog is filled and `accept()` is
/// never called, so a connect to it stalls until its own timeout.
Future<(ServerSocket, List<Socket>)> _stalledListener() async {
  final server = await ServerSocket.bind(
    InternetAddress.loopbackIPv4,
    0,
    backlog: 1, // capacity is backlog + 1; two connections fill it
  );
  final held = [
    await Socket.connect(InternetAddress.loopbackIPv4, server.port),
    await Socket.connect(InternetAddress.loopbackIPv4, server.port),
  ];
  return (server, held);
}

/// Whether [future] completed inside [window] — without leaving it unhandled.
Future<bool> _returnsWithin(Future<void> future, Duration window) async {
  var done = false;
  unawaited(future.whenComplete(() => done = true).catchError((_) {}));
  await Future<void>.delayed(window);
  return done;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a dial that never completes cannot stop the mesh dialling again',
      () async {
    final tmp = await Directory.systemTemp.createTemp('nexus_hung_dial');
    addTearDown(() => tmp.delete(recursive: true));

    final (server, fillers) = await _stalledListener();
    addTearDown(server.close);
    addTearDown(() {
      for (final socket in fillers) {
        socket.destroy();
      }
    });

    // Prove the fixture before trusting it: if this host answers a connect to a
    // full backlog instead of stalling, everything below would pass for the
    // wrong reason, so skip rather than lie.
    var stalled = false;
    try {
      final probe = Socket.connect(
        InternetAddress.loopbackIPv4,
        server.port,
        timeout: const Duration(seconds: 5),
      );
      (await probe.timeout(const Duration(milliseconds: 200))).destroy();
    } catch (_) {
      stalled = true;
    }
    if (!stalled) {
      markTestSkipped('this host answered a connect to a full backlog');
      return;
    }

    final store = NexusStore(explicitPath: '${tmp.path}/state.json');
    await store.load();
    store.port = await _freePort();
    store.upsertPaired({
      'id': 'hung-peer',
      'name': 'Hung Peer',
      'platform': 'linux',
      'localName': false,
      'address': '127.0.0.1',
      'addresses': <String>['127.0.0.1'],
      'port': server.port,
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
      clipboard: _NoClipboard(),
      // The dial is *meant* to hang, so the connect timeout is far longer than
      // the test; only the latch's own watchdog can free it.
      connectTimeout: const Duration(seconds: 30),
      latchWatchdog: const Duration(milliseconds: 150),
    );
    addTearDown(mesh.stop);
    await mesh.start(); // its startup sweep latches and stalls straight away

    // One: while that dial is stuck a beat is a no-op — the boolean behaviour,
    // kept on purpose so a second copy of the exchange cannot stack on the
    // first.
    expect(
      await _returnsWithin(mesh.beat(), const Duration(milliseconds: 60)),
      isTrue,
      reason: 'a beat while an exchange is running must be a no-op',
    );

    // Let the watchdog do its work, then look again.
    await Future<void>.delayed(const Duration(milliseconds: 600));

    // Two: it has to dial again. With a plain boolean the stuck exchange still
    // holds the latch and this returns at once — which is exactly what "the
    // mesh stopped dialling" looked like in the field.
    expect(
      await _returnsWithin(mesh.beat(), const Duration(milliseconds: 300)),
      isFalse,
      reason: 'a hung dial must not disable every later one',
    );
  });
}
