// The bootstrap, end to end, on the path the shipped app takes.
//
// A unit suite can prove that `startAppServices` *constructed* a mesh. It
// cannot prove the mesh is running, reachable, pairable, or receiving what a
// peer announced — and after pass 1 no tab reads the mesh, so nothing on screen
// would tell us either. This file closes that gap: a real mesh over loopback, a
// real pairing code, and the peer's Phase 2 capability list arriving with its
// provenance.
//
// If this passes, pass 2 has a known-good foundation. If it fails, the
// bootstrap is not finished — cheap to learn now, expensive after the tabs are
// rebound.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/app_services.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/mesh/mesh_service.dart';

/// A clipboard that lives in memory — no platform channel in a test.
class _FakeClipboard implements ClipboardBackend {
  String? value;

  @override
  Future<String?> readText() async => value;

  @override
  Future<void> writeText(String text) async => value = text;
}

/// Pumps the event loop until [condition] holds, or fails the test.
///
/// The pairing exchange and the presence sweep that carries capabilities run on
/// timers; there is no future to await for "the peer has told us what it can
/// do".
Future<void> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 15),
  String reason = 'condition',
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail('timed out waiting for $reason');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The channel the foreground service is reached over (see
  // mesh/sync_service.dart and NexusSyncService.kt).
  const MethodChannel network = MethodChannel('dev.nexus.nexus/network');
  late List<String> calls;

  setUp(() {
    calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(network, (MethodCall call) async {
          calls.add(call.method);
          return true;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(network, null);
  });

  test(
    'the launched path runs a mesh that pairs and receives announced caps',
    () async {
      final Directory dataDir = Directory.systemTemp.createTempSync(
        'nexus-shell-e2e-',
      );
      final Directory peerDir = Directory.systemTemp.createTempSync(
        'nexus-shell-peer-',
      );
      addTearDown(() {
        if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
        if (peerDir.existsSync()) peerDir.deleteSync(recursive: true);
      });

      final AppServices services = await startAppServices(
        dataDir: dataDir.path,
        clipboard: _FakeClipboard(),
      );
      var stopped = false;
      addTearDown(() async {
        if (!stopped) await stopAppServices(services);
      });

      // The mesh is up, and it asked Android for the foreground service that
      // keeps it alive with the window closed.
      expect(services.mesh.port, greaterThan(0));
      expect(calls, contains('startSyncService'));

      // Pairing is off until the user turns it on — that default is deliberate
      // and this test states the decision rather than assuming it.
      services.store.pairingEnabled = true;
      await services.store.save();

      final NexusStore peerStore =
          NexusStore(explicitPath: '${peerDir.path}/state.json')
            ..pairingEnabled = true
            ..port = 53321;
      await peerStore.save();

      final MeshService peer = MeshService(
        identity: DeviceInfo(
          id: 'rehearsal-peer',
          name: 'Rehearsal PC',
          platform: 'linux',
        ),
        store: peerStore,
        clipboard: _FakeClipboard(),
        onlineWindow: const Duration(seconds: 5),
        visibleWindow: const Duration(seconds: 5),
        heartbeatInterval: const Duration(seconds: 2),
        connectTimeout: const Duration(milliseconds: 400),
      );
      addTearDown(peer.stop);
      await peer.start();

      final PairingSession session = peer.beginPairing();
      final PairResult result = await services.mesh.pairWith(
        address: '127.0.0.1',
        port: peer.port,
        code: session.code,
      );
      expect(result.ok, isTrue, reason: result.error);
      expect(services.mesh.isPaired('rehearsal-peer'), isTrue);

      // Phase 2's clause, on the shipped path: the peer's probed capabilities
      // arrive, and they arrive as verified because the frame that carried
      // them was proven.
      await _waitFor(
        () => services.mesh.pairedDevices.single.announcedCapsVerified,
        reason: 'the peer\'s announced capabilities to be verified',
      );
      expect(
        services.mesh.pairedDevices.single.announcedCaps,
        isNotEmpty,
        reason: 'the peer said it has no capabilities at all',
      );

      // The supervisor is what keeps the link through a network change; a mesh
      // without one is a mesh that pairs and then forgets.
      expect(services.mesh.supervisor, isNotNull);
      expect(services.mesh.supervisor!.running, isTrue);

      // And stopping gives the port back, which is what lets a recreated
      // engine take 51820 again instead of falling back to an ephemeral one.
      final int port = services.mesh.port;
      stopped = true;
      await peer.stop();
      await stopAppServices(services);
      final ServerSocket again = await ServerSocket.bind(
        InternetAddress.anyIPv4,
        port,
      );
      await again.close();
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
