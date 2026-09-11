import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/network_info.dart';
import 'package:nexus/core/pair_payload.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/mesh/mesh_service.dart';

/// Live probe for the real QR flow: this device shows a code, a second mesh
/// reads the QR it just built, and pairs through the addresses the QR
/// advertises — over the actual LAN interface, not loopback.
///
/// Run with:
///   flutter test test/live_qr_scan_probe_test.dart --dart-define=LIVE_QR=1
///
/// Skipped by default: it binds real ports and needs a real network.
void main() {
  test('a QR pairs through the addresses it advertises, stale ones first',
      () async {
    if (const String.fromEnvironment('LIVE_QR').isEmpty) {
      markTestSkipped('LIVE_QR not set');
      return;
    }

    final tmp = await Directory.systemTemp.createTemp('nexus_qr_probe');
    final showStore = NexusStore(explicitPath: '${tmp.path}/show.json')
      ..port = 53240;
    final scanStore = NexusStore(explicitPath: '${tmp.path}/scan.json')
      ..port = 53241;
    await showStore.save();
    await scanStore.save();

    final shower = MeshService(
      identity: DeviceInfo(
        id: 'qr-show',
        name: 'Showing Device',
        platform: 'linux',
      ),
      store: showStore,
      heartbeatInterval: const Duration(seconds: 1),
      connectTimeout: const Duration(seconds: 3),
    );
    final scanner = MeshService(
      identity: DeviceInfo(
        id: 'qr-scan',
        name: 'Scanning Device',
        platform: 'linux',
      ),
      store: scanStore,
      connectTimeout: const Duration(seconds: 3),
    );
    await shower.start();
    await scanner.start();
    // Let the heartbeat resolve this machine's interfaces into the IP cache.
    await Future<void>.delayed(const Duration(seconds: 2));

    final session = shower.beginPairing();
    final payload = PairPayload.parse(session.qrPayload);
    expect(payload, isNotNull, reason: 'the QR must parse as a Nexus payload');
    debugPrint('LIVE-QR qr=${session.qrPayload}');

    // Exactly what the scanning UI builds: primary ip, then every announced
    // address, then anything already known for that device id.
    final candidates = <String>[];
    void add(String a) {
      if (a.isNotEmpty && !candidates.contains(a)) candidates.add(a);
    }

    add(payload!.ip ?? '');
    for (final a in payload.ips) {
      add(a);
    }

    final ownIps = await detectAllIpv4s();
    final realLan = ownIps.where((ip) => ip.startsWith('192.168.')).toList();
    expect(candidates, isNotEmpty,
        reason: 'the QR must advertise at least one address to connect to');
    expect(
      candidates.any(realLan.contains),
      isTrue,
      reason: 'QR addresses $candidates must include a real LAN address '
          '($realLan) — otherwise scanning can only work by luck',
    );

    // A stale address (RFC 5737 TEST-NET, never routable) first, as a QR
    // scanned after the device changed networks would carry.
    final result = await scanner.pairWithCandidates(
      addresses: ['192.0.2.1', ...candidates],
      port: payload.port,
      code: payload.code,
    );
    debugPrint('LIVE-QR result ok=${result.ok} reached=${result.reached} '
        'error=${result.error}');
    expect(result.ok, isTrue, reason: result.error);
    expect(shower.isPaired('qr-scan'), isTrue);
    expect(scanner.isPaired('qr-show'), isTrue);

    await shower.stop();
    await scanner.stop();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  }, timeout: const Timeout(Duration(minutes: 2)));
}
