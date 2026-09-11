import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/mesh/discovery.dart';
import 'package:nexus/mesh/mesh_service.dart';
import 'package:nexus/ui/pair_sheet.dart';
import 'package:nexus/ui/theme.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// The recovery paths a user actually depends on when pairing goes wrong.
///
/// Each test here drives real sockets and the real widgets, because the bugs
/// they guard against were all invisible to the rest of the suite:
///
/// * discovery that falls back to another port is deaf for its whole lifetime
///   unless it takes its port back on its own, and it must say so rather than
///   look healthy in the UI;
/// * a code that was already used must be refused in milliseconds instead of
///   stalling the full "no answer" wait, and the pairing that already exists
///   must keep working afterwards;
/// * the sheet must stop drawing a QR once its code is spent, and the code it
///   offers in its place must actually pair.
class FakeClipboard implements ClipboardBackend {
  String? value;
  @override
  Future<String?> readText() async => value;
  @override
  Future<void> writeText(String text) async => value = text;
}

Future<void> _waitFor(bool Function() cond,
    {Duration timeout = const Duration(seconds: 10)}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    if (cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail('condition not met within $timeout');
}

void main() {
  late Directory tmp;
  late NexusStore storeA, storeB, storeC;
  late MeshService meshA, meshB, meshC;

  MeshService makeMesh(String id, String name, NexusStore store) => MeshService(
        identity: DeviceInfo(id: id, name: name, platform: 'linux'),
        store: store,
        clipboard: FakeClipboard(),
        onlineWindow: const Duration(seconds: 4),
        visibleWindow: const Duration(seconds: 4),
        heartbeatInterval: const Duration(seconds: 2),
        connectTimeout: const Duration(milliseconds: 400),
      );

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('nexus_recovery');
    storeA = NexusStore(explicitPath: '${tmp.path}/a.json')..port = 53260;
    storeB = NexusStore(explicitPath: '${tmp.path}/b.json')..port = 53261;
    storeC = NexusStore(explicitPath: '${tmp.path}/c.json')..port = 53262;
    await storeA.save();
    await storeB.save();
    await storeC.save();
    meshA = makeMesh('device-a', 'Recovery PC', storeA);
    meshB = makeMesh('device-b', 'Recovery Phone', storeB);
    meshC = makeMesh('device-c', 'Recovery Tablet', storeC);
  });

  tearDown(() async {
    await meshA.stop();
    await meshB.stop();
    await meshC.stop();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('a busy discovery port is reported, then self-heals to receive again',
      () async {
    // A port of its own: the canonical one is shared with every other Nexus on
    // this machine and with the suites running in parallel, so a test that had
    // to hold it would sometimes have to skip — and a skipped test proves
    // nothing. The fallback and the recovery are the same machinery either way.
    const probePort = 51999;

    // The way a dying sibling instance holds it: without SO_REUSEADDR.
    final blocker = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      probePort,
      reuseAddress: false,
    );

    final heard = <DiscoveredDevice>[];
    final svc = DiscoveryService(
      identity: DeviceInfo(id: 'recovery-probe', name: 'Probe', platform: 'linux'),
      onDiscovered: heard.add,
      port: probePort,
    );
    try {
      await svc.start();
      expect(svc.status.boundPort, isNot(probePort),
          reason: 'a busy port must fall back, not claim it anyway');
      expect(svc.status.canReceive, isFalse);
      expect(svc.status.describe(), contains('cannot hear other devices'),
          reason: svc.status.describe());
      // Degraded is not dead: it still announces while it waits for the port.
      await _waitFor(() => svc.status.announced > 0);
      expect(svc.status.announcing, isTrue);

      // On a fallback port, another device's hello cannot reach us.
      final sender =
          await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      void hail(int port) => sender.send(
            utf8.encode(jsonEncode({
              'v': 1,
              'id': 'recovery-peer',
              'name': 'Recovery Peer',
              'platform': 'linux',
              'port': 51820,
            })),
            InternetAddress.loopbackIPv4,
            port,
          );
      hail(probePort);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      // Scoped to the payload under test: other suites running in parallel are
      // real Nexus instances on this machine, and their replies to our own
      // announces are not this assertion's business.
      expect(heard.where((d) => d.id == 'recovery-peer'), isEmpty,
          reason: 'a datagram sent to $probePort cannot reach a socket that '
              'fell back to another port');

      // Free the port: the service must take it back on its own, without the
      // user restarting the app for the rest of the process's life.
      blocker.close();
      await _waitFor(
        () => svc.status.boundPort == probePort,
        timeout: const Duration(seconds: 40),
      );
      expect(svc.status.canReceive, isTrue);
      expect(svc.status.describe(), isNot(contains('cannot hear')));

      // And the receive path really came back — not just the port number.
      hail(probePort);
      await _waitFor(() => heard.any((d) => d.id == 'recovery-peer'));
      final mine =
          heard.where((d) => d.id == 'recovery-peer').toList(growable: false);
      expect(mine.first.name, 'Recovery Peer');
      expect(mine.first.port, 51820);
      sender.close();
    } finally {
      await svc.stop();
      try {
        blocker.close();
      } catch (_) {}
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a spent code is refused at once and the pairing survives it',
      () async {
    await meshA.start();
    await meshB.start();
    await meshC.start();

    // A shows a code; B pairs through it, trying a stale address first.
    final first = meshA.beginPairing();
    final staleFirst = await meshB.pairWithCandidates(
      addresses: ['192.0.2.1', '127.0.0.1'],
      port: meshA.port,
      code: first.code,
    );
    expect(staleFirst.ok, isTrue, reason: staleFirst.error);
    expect(meshA.isPaired('device-b'), isTrue);
    expect(meshB.isPaired('device-a'), isTrue);
    expect(meshA.pairedDevices, hasLength(1));

    // C scans the same still-visible code. It must be told why, at once:
    // silence here reads to a user as "Nexus can only pair one device".
    final spent = Stopwatch()..start();
    final refused = await meshC.pairWithCandidates(
      addresses: ['127.0.0.1'],
      port: meshA.port,
      code: first.code,
    );
    spent.stop();
    expect(refused.ok, isFalse);
    expect(refused.reached, isTrue,
        reason: 'a refusal is an answer from the device, not a timeout');
    expect(refused.error, contains('already been used'),
        reason: refused.error);
    expect(spent.elapsed, lessThan(const Duration(seconds: 5)),
        reason: 'a spent code must not burn the "no answer" wait '
            '(took ${spent.elapsed})');

    // The pairing established before the refused attempt still carries real
    // encrypted traffic, and nothing new was paired by it.
    await meshA.broadcastProfile(userName: 'After Refusal');
    await _waitFor(() => storeB.profileUserName == 'After Refusal');
    expect(storeB.profileUserName, 'After Refusal');
    expect(meshA.pairedDevices, hasLength(1));
    expect(meshA.isPaired('device-c'), isFalse);

    // A fresh code lets the second device in without displacing the first,
    // and each device keeps its own secret.
    final second = meshA.beginPairing();
    expect(second.code, isNot(first.code));
    final joined = await meshC.pairWithCandidates(
      addresses: ['127.0.0.1'],
      port: meshA.port,
      code: second.code,
    );
    expect(joined.ok, isTrue, reason: joined.error);
    expect(meshA.pairedDevices.map((d) => d.id).toSet(),
        {'device-b', 'device-c'});
    expect(meshB.pairedDevices.single.pairingSecret, first.code);
    expect(meshC.pairedDevices.single.pairingSecret, second.code);

    // Durability: B restarts from its own store and still knows A.
    await meshB.stop();
    final restarted = makeMesh('device-b', 'Recovery Phone', storeB);
    await restarted.start();
    expect(restarted.isPaired('device-a'), isTrue,
        reason: 'a paired device must survive a restart');
    await restarted.broadcastProfile(userName: 'After Restart');
    await _waitFor(() => storeA.profileUserName == 'After Restart');
    expect(storeA.profileUserName, 'After Restart');
    await restarted.stop();
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('the sheet stops showing a QR once its code is spent',
      (tester) async {
    // A small phone (360dp) and the app's own theme: the surface a user gets,
    // not Material's defaults.
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    // Sockets and the mesh heartbeat live outside the fake clock, so I/O runs
    // in runAsync and frames are pumped by hand.
    await tester.runAsync(() async {
      await meshA.start();
      await meshB.start();
      await meshC.start();
    });

    await tester.pumpWidget(MaterialApp(
      theme: buildNexusTheme(),
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showPairSheet(ctx, mesh: meshA),
              child: const Text('open pairing'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open pairing'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(QrImageView), findsOneWidget,
        reason: 'a fresh code must show its QR');
    final shownCode = meshA.pendingCode!;

    // Another device scans and spends it.
    late PairResult paired;
    await tester.runAsync(() async {
      paired = await meshB.pairWithCandidates(
        addresses: ['127.0.0.1'],
        port: meshA.port,
        code: shownCode,
      );
    });
    expect(paired.ok, isTrue, reason: paired.error);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Code no longer usable'), findsOneWidget,
        reason: 'the sheet must stop pretending the spent code works');
    expect(find.byType(QrImageView), findsNothing,
        reason: 'a dead QR must not stay on screen to be scanned');

    // The offered recovery produces a code that actually pairs.
    await tester.ensureVisible(find.text('Show a new code'));
    await tester.pump();
    await tester.tap(find.text('Show a new code'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(QrImageView), findsOneWidget,
        reason: 'a new code must show a QR again');
    final freshCode = meshA.pendingCode!;
    expect(freshCode, isNot(shownCode));

    late PairResult withFresh;
    await tester.runAsync(() async {
      withFresh = await meshC.pairWithCandidates(
        addresses: ['127.0.0.1'],
        port: meshA.port,
        code: freshCode,
      );
    });
    expect(withFresh.ok, isTrue, reason: withFresh.error);
    expect(meshA.pairedDevices.map((d) => d.id).toSet(),
        {'device-b', 'device-c'});

    await tester.runAsync(() async {
      await meshA.stop();
      await meshB.stop();
      await meshC.stop();
    });
  }, timeout: const Timeout(Duration(minutes: 2)));
}
