// What one bad stored address must not cost the device.
//
// `knownAddresses` is fed from the saved neighbour list, so its contents are
// whatever an older version or a half-written store left there — not something
// this process can trust. One unparseable entry used to throw while the send
// targets were being built, before a single datagram left, and the announce
// timer swallowed it: the device kept "listening" and never announced again.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/mesh/discovery.dart';

final _identity = DeviceInfo(
  id: 'announce-test-device',
  name: 'Announce Test',
  platform: 'linux',
);

/// A bound socket that hears its own loopback probe and records every send.
class _RecordingSocket implements DiscoverySocket {
  _RecordingSocket(this.port);

  @override
  final int port;

  @override
  InternetAddress get address => InternetAddress.anyIPv4;

  final List<InternetAddress> targets = <InternetAddress>[];

  void Function(List<int> data, InternetAddress from, int fromPort)? _onData;

  @override
  void listen(
    void Function(List<int> data, InternetAddress from, int fromPort) onData,
  ) {
    _onData = onData;
  }

  @override
  int send(List<int> data, InternetAddress target, int targetPort) {
    targets.add(target);
    // The receive probe is a loopback datagram: hand it back, so the service
    // stays healthy and this test measures announcing, not the repair path.
    if (target == InternetAddress.loopbackIPv4) {
      _onData?.call(data, InternetAddress.loopbackIPv4, targetPort);
    }
    return data.length;
  }

  @override
  void joinMulticast(InternetAddress group, [NetworkInterface? iface]) {}

  @override
  void close() {}
}

Future<void> _waitFor(
  bool Function() check, {
  Duration limit = const Duration(seconds: 5),
}) async {
  final DateTime deadline = DateTime.now().add(limit);
  while (!check() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  test('an unparseable stored address does not silence announcing', () async {
    final List<_RecordingSocket> sockets = <_RecordingSocket>[];
    final DiscoveryService service = DiscoveryService(
      identity: _identity,
      onDiscovered: (_) {},
      port: 45997,
      socketFactory: (address, port) async {
        final _RecordingSocket socket = _RecordingSocket(port);
        sockets.add(socket);
        return socket;
      },
      probeWait: const Duration(milliseconds: 1),
      probeTries: 3,
      repairBackoff: Duration.zero,
      networkWatchInterval: Duration.zero,
    );
    addTearDown(service.stop);
    service.knownAddresses.addAll(<({String address, int port})>[
      (address: '192.168.1.100', port: 51820),
      (address: 'not-an-address', port: 51820),
      (address: '', port: 51820),
    ]);

    await service.start();
    await _waitFor(() => service.status.announced >= 1);

    expect(service.status.announced, greaterThanOrEqualTo(1),
        reason: 'the good addresses and multicast must still be announced to');
    expect(service.status.failedSends, 0);
    expect(sockets.single.targets, contains(DiscoveryService.group));
    expect(
      sockets.single.targets,
      contains(InternetAddress('192.168.1.100')),
      reason: 'the parseable stored neighbour is still dialled',
    );
  });
}
