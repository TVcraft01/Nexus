// Nearby discovery, unit-tested where it can be: the honest status it
// reports, and the receive path itself on a real loopback socket.
//
// The bug this pins down: discovery used to claim success unconditionally.
// When the canonical port was busy it fell back to an ephemeral one — after
// which no announcement could ever reach that socket — and the announce log
// printed from *outside* the send loop, so a device that could not send a
// single packet still reported "announced". On Android the Wi-Fi multicast
// lock was never taken either, so nothing incoming got through the firmware.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/mesh/discovery.dart';

final _identity = DeviceInfo(
  id: 'test-discovery-device',
  name: 'Test Device',
  platform: 'linux',
);

/// Waits for [check] to become true, so a socket test never depends on one
/// sleep being long enough.
Future<void> _waitFor(bool Function() check, {Duration limit = const Duration(seconds: 3)}) async {
  final deadline = DateTime.now().add(limit);
  while (!check() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  group('discovery status is honest', () {
    test('a socket on the canonical port that can send is healthy', () {
      const status = DiscoveryStatus(
        boundPort: DiscoveryService.discoveryPort,
        announced: 4,
        failedSends: 0,
        received: 0,
      );
      expect(status.canReceive, isTrue);
      expect(status.announcing, isTrue);
      expect(status.describe(), contains('listening'));
      expect(status.describe(), contains('no other Nexus device'));
    });

    test('a fallback port is reported as deaf, not as working', () {
      const status = DiscoveryStatus(
        boundPort: 45123,
        announced: 4,
        failedSends: 0,
        received: 0,
      );
      expect(status.canReceive, isFalse);
      expect(status.describe(), contains('45123'));
      expect(status.describe(), contains('cannot hear'));
    });

    test('a socket that never sent is reported as invisible', () {
      const status = DiscoveryStatus(
        boundPort: DiscoveryService.discoveryPort,
        announced: 0,
        failedSends: 3,
        received: 0,
        lastSendError: 'SocketException: Network is unreachable',
      );
      expect(status.canReceive, isFalse);
      expect(status.describe(), contains('Network is unreachable'));
      expect(status.describe(), contains('firewall'));
    });

    test('no socket at all is reported as off', () {
      const status = DiscoveryStatus(
        boundPort: null,
        announced: 0,
        failedSends: 0,
        received: 0,
      );
      expect(status.canReceive, isFalse);
      expect(status.describe(), contains('no network socket'));
    });

    test('hearing someone is reported with the counts', () {
      const status = DiscoveryStatus(
        boundPort: DiscoveryService.discoveryPort,
        announced: 5,
        failedSends: 0,
        received: 2,
      );
      expect(status.canReceive, isTrue);
      expect(status.describe(), contains('2 announcement'));
      expect(status.describe(), contains('announced 5'));
    });
  });

  group('the receive path', () {
    test('a started service binds a port and says which', () async {
      final service = DiscoveryService(identity: _identity, onDiscovered: (_) {});
      await service.start();
      addTearDown(service.stop);

      final status = service.status;
      expect(status.boundPort, isNotNull);
      expect(status.boundPort, greaterThan(0));
      // A busy port (another test suite running in parallel) is a fallback,
      // and the status must say so rather than claiming the canonical one.
      if (status.boundPort != DiscoveryService.discoveryPort) {
        expect(status.canReceive, isFalse);
      }
    });

    test('an announcement sent to the bound port is heard', () async {
      final heard = <DiscoveredDevice>[];
      final service = DiscoveryService(identity: _identity, onDiscovered: heard.add);
      await service.start();
      addTearDown(service.stop);

      final port = service.status.boundPort!;
      final sender = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(sender.close);
      final payload = utf8.encode(jsonEncode({
        'v': 1,
        'id': 'peer-device',
        'name': 'Peer',
        'platform': 'linux',
        'port': 51820,
      }));
      sender.send(payload, InternetAddress.loopbackIPv4, port);

      // Assert about the payload under test, not the device count: another
      // test suite's Nexus may be announcing on this machine in parallel.
      await _waitFor(() => heard.any((d) => d.id == 'peer-device'));
      final ours = heard.where((d) => d.id == 'peer-device').toList();
      expect(ours, hasLength(1));
      expect(ours.single.name, 'Peer');
      expect(ours.single.port, 51820);
      expect(service.status.received, greaterThanOrEqualTo(1));
    });

    // Note: a real Nexus instance may be announcing on this machine while the
    // suite runs, so these assert about the payloads under test rather than
    // about a device count that the environment can change.
    test('its own announcement is never reported as a peer', () async {
      final heard = <DiscoveredDevice>[];
      final service = DiscoveryService(identity: _identity, onDiscovered: heard.add);
      await service.start();
      addTearDown(service.stop);

      // Announce onto loopback, where this very socket will receive it.
      await Future<void>.delayed(const Duration(seconds: 3, milliseconds: 500));
      expect(heard.where((d) => d.id == _identity.id), isEmpty,
          reason: 'a device must never discover itself');
      expect(service.status.announced, greaterThan(0),
          reason: 'it did announce — the status must reflect that');
    });

    test('a malformed datagram is ignored', () async {
      final heard = <DiscoveredDevice>[];
      final service = DiscoveryService(identity: _identity, onDiscovered: heard.add);
      await service.start();
      addTearDown(service.stop);

      final sender = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(sender.close);
      for (final junk in [
        'not json',
        '{}',
        '{"id":42}',
        '{"id":"peer-device"}', // no port
        '{"id":"peer-device","port":0}', // unusable port
      ]) {
        sender.send(utf8.encode(junk), InternetAddress.loopbackIPv4, service.status.boundPort!);
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(heard.where((d) => d.id == 'peer-device'), isEmpty);
    });
  });
}
