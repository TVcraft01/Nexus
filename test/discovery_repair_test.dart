// The repair path, driven by a fake socket.
//
// A socket that binds, announces and never receives is the failure the phone
// reported: its own loopback probe never came back, while a socket bound a
// second later in the same process heard one. A real deaf socket cannot be made
// on a test machine, so the seam is `DiscoverySocketFactory` and these are the
// three promises that hang off it — a deaf socket is replaced, a socket that
// stays deaf is declared unavailable, and a network change makes the test run
// again.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/mesh/discovery.dart';

final _identity = DeviceInfo(
  id: 'repair-test-device',
  name: 'Repair Test',
  platform: 'linux',
);

/// Waits for [check], so a test never depends on one sleep being long enough.
Future<void> _waitFor(
  bool Function() check, {
  Duration limit = const Duration(seconds: 5),
}) async {
  final DateTime deadline = DateTime.now().add(limit);
  while (!check() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// A bound socket that never hears anything — the phone's launch socket.
class _DeafSocket implements DiscoverySocket {
  _DeafSocket(this.port);

  @override
  final int port;

  @override
  InternetAddress get address => InternetAddress.anyIPv4;

  bool closed = false;

  @override
  int send(List<int> data, InternetAddress target, int targetPort) =>
      data.length;

  @override
  void close() => closed = true;

  @override
  void joinMulticast(InternetAddress group, [NetworkInterface? iface]) {}

  @override
  void listen(
    void Function(List<int> data, InternetAddress from, int fromPort) onData,
  ) {}
}

/// A socket whose loopback datagrams come straight back: a healthy one.
///
/// [deaf] can be flipped mid-test to model an interface that went away under a
/// socket that was healthy a second earlier.
class _LoopbackSocket implements DiscoverySocket {
  _LoopbackSocket(this.port);

  @override
  final int port;

  @override
  InternetAddress get address => InternetAddress.anyIPv4;

  bool deaf = false;
  bool closed = false;

  void Function(List<int> data, InternetAddress from, int fromPort)? _onData;

  @override
  void listen(
    void Function(List<int> data, InternetAddress from, int fromPort) onData,
  ) {
    _onData = onData;
  }

  @override
  int send(List<int> data, InternetAddress target, int targetPort) {
    if (!deaf) _onData?.call(data, InternetAddress.loopbackIPv4, targetPort);
    return data.length;
  }

  @override
  void joinMulticast(InternetAddress group, [NetworkInterface? iface]) {}

  @override
  void close() => closed = true;
}

/// A service whose probe is fast enough for a unit test.
DiscoveryService _service(
  DiscoverySocketFactory factory, {
  Future<Set<String>> Function()? addresses,
  Duration watch = Duration.zero,
}) => DiscoveryService(
  identity: _identity,
  onDiscovered: (_) {},
  port: 45999,
  socketFactory: factory,
  probeWait: const Duration(milliseconds: 1),
  probeTries: 3,
  repairBackoff: Duration.zero,
  networkWatchInterval: watch,
  interfaceAddresses: addresses,
);

void main() {
  test('a deaf socket is replaced by a rebind and recovers', () async {
    final List<DiscoverySocket> sockets = <DiscoverySocket>[];
    final DiscoveryService service = _service((address, port) async {
      final DiscoverySocket socket = sockets.isEmpty
          ? _DeafSocket(port)
          : _LoopbackSocket(port);
      sockets.add(socket);
      return socket;
    });
    addTearDown(service.stop);

    await service.start();
    await _waitFor(() => service.repairSuccesses >= 1);

    expect(service.repairs, 1, reason: 'one rebind is all a healthy bind needs');
    expect(service.repairSuccesses, 1);
    expect(service.status.selfCheck, isTrue);
    expect(service.status.udpUnavailable, isFalse);
    expect(service.status.canReceive, isTrue);
    expect(sockets, hasLength(2), reason: 'the deaf socket was replaced');
    expect(sockets.first, isA<_DeafSocket>());
    expect((sockets.first as _DeafSocket).closed, isTrue);
  });

  test('a socket that stays deaf after every rebind marks UDP unavailable',
      () async {
    var binds = 0;
    final DiscoveryService service = _service((address, port) async {
      binds++;
      return _DeafSocket(port);
    });
    addTearDown(service.stop);

    await service.start();
    await _waitFor(() => service.status.udpUnavailable);

    expect(service.repairs, DiscoveryService.repairAttempts);
    expect(service.repairSuccesses, 0);
    expect(binds, 1 + DiscoveryService.repairAttempts);
    expect(service.status.selfCheck, isFalse);
    expect(service.status.canReceive, isFalse);
    expect(service.status.describe(), contains('cannot receive UDP discovery'));
    expect(service.status.describe(), contains('TCP'));
  });

  test('a network change re-tests the socket and repairs it when it went deaf',
      () async {
    var ips = <String>{'192.168.1.8'};
    final List<_LoopbackSocket> sockets = <_LoopbackSocket>[];
    final DiscoveryService service = _service(
      (address, port) async {
        final _LoopbackSocket socket = _LoopbackSocket(port);
        // Only the very first socket starts healthy; every replacement is
        // healthy too, which is what a rebind on a real machine does.
        sockets.add(socket);
        return socket;
      },
      addresses: () async => ips,
      watch: const Duration(milliseconds: 10),
    );
    addTearDown(service.stop);

    await service.start();
    await _waitFor(() => service.status.selfCheck == true);
    expect(service.repairs, 0);

    // The interface went away under the socket that was healthy a moment ago,
    // and the device is now on a different address.
    sockets.single.deaf = true;
    ips = <String>{'192.168.10.4'};

    await _waitFor(() => service.repairs >= 1 && service.status.selfCheck == true);
    expect(service.repairs, greaterThanOrEqualTo(1));
    expect(sockets.length, greaterThan(1));
    expect(service.status.udpUnavailable, isFalse);
  });
}
