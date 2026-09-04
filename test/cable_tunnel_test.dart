import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/mesh/mesh_service.dart';

/// Regression test for cable pairing: the phone pairs by dialing the PC
/// through a one-way link (adb reverse), so only the phone holds an outbound
/// socket and the PC has no dial route to it. The phone keeps its socket to
/// the PC alive with heartbeats, and the PC must send on that inbound socket
/// for the cable to work in BOTH directions.
void main() {
  late Directory tmp;
  late NexusStore storePc;
  late NexusStore storePhone;
  late MeshService pc;
  late MeshService phone;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('nexus_cable');
    storePc = NexusStore(explicitPath: '${tmp.path}/pc.json')..port = 53310;
    storePhone = NexusStore(explicitPath: '${tmp.path}/phone.json')
      ..port = 53311;
    await storePc.save();
    await storePhone.save();

    pc = MeshService(
      identity: DeviceInfo(id: 'cable-pc', name: 'PC', platform: 'linux'),
      store: storePc,
      // The PC never dials the phone on its own — exactly like a real cable,
      // where only the phone has a route back to the PC (adb reverse).
      heartbeatInterval: const Duration(days: 1),
      connectTimeout: const Duration(milliseconds: 300),
      onlineWindow: const Duration(seconds: 3),
      visibleWindow: const Duration(seconds: 3),
    );
    phone = MeshService(
      identity: DeviceInfo(
        id: 'cable-phone',
        name: 'Phone',
        platform: 'android',
      ),
      store: storePhone,
      // The phone heartbeats over its tunnel socket every second, opening
      // it quickly and keeping it warm.
      heartbeatInterval: const Duration(seconds: 1),
      connectTimeout: const Duration(milliseconds: 300),
      onlineWindow: const Duration(seconds: 3),
      visibleWindow: const Duration(seconds: 3),
    );
  });

  tearDown(() async {
    await pc.stop();
    await phone.stop();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('PC can send to a phone that paired through a one-way tunnel', () async {
    await pc.start();
    await phone.start();

    // The phone pairs by dialing the PC (the PC shows the code) — the shape
    // of an adb-reverse pairing.
    final session = pc.beginPairing();
    final result = await phone.pairWith(
      address: '127.0.0.1',
      port: pc.port,
      code: session.code,
    );
    expect(result.ok, isTrue, reason: result.error);

    final learned = Completer<void>();
    phone.onLearnedPhraseReceived = (phrase, meaning) {
      if (phrase == 'cable-hi' && meaning == 'cable-hello') {
        if (!learned.isCompleted) learned.complete();
      }
    };

    // Sever every address the PC could dial to the phone: it is only
    // reachable through the socket it opened toward the PC. TEST-NET-1
    // (192.0.2.0/24) is unroutable by design.
    //
    // The PC only holds a live inbound socket for the phone after the
    // phone's first heartbeat (both sides mark each other online during
    // pairing itself, so "online" is not a usable signal), so keep
    // re-sending until the phone's heartbeats have opened the tunnel socket
    // — each attempt re-severs the dial route in case a heartbeat refreshed
    // it in the meantime.
    var delivered = false;
    for (var attempt = 0; attempt < 15 && !delivered; attempt++) {
      final peer = pc.pairedDevices.single;
      peer.address = '192.0.2.1';
      peer.addresses = ['192.0.2.1'];
      await pc.broadcastLearnedPhrase('cable-hi', 'cable-hello');
      try {
        await learned.future.timeout(const Duration(seconds: 1));
        delivered = true;
      } on TimeoutException {
        // Heartbeat not there yet — re-sever the route and send again.
      }
    }
    expect(
      delivered,
      isTrue,
      reason: 'PC could not reach the phone through its tunnel socket',
    );
  });
}
