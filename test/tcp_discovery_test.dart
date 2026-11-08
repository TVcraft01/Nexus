// The TCP fallback, without a mesh and without a network of phones.
//
// The pairing handshake is a seam here (`PeerVerifier`): these tests prove the
// pass itself — stored addresses first, own /24 only when those fail, only the
// private range, a bare open port is not a find, a cap on concurrency, a
// deadline, and a cancel that actually stops it.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/mesh/local_subnet.dart';
import 'package:nexus/mesh/tcp_discovery.dart';

/// A TCP server that answers `ok` only to the key it was made with — the
/// minimal stand-in for the pairing handshake, so a wrong key on an open port
/// is observable.
class _KeyServer {
  _KeyServer(this.key);

  final String key;
  late final ServerSocket _server;
  int accepted = 0;

  int get port => _server.port;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((Socket socket) {
      accepted++;
      final List<int> seen = <int>[];
      socket.listen((List<int> chunk) {
        seen.addAll(chunk);
        if (String.fromCharCodes(seen) == key) socket.write('ok');
      }, onError: (_) {});
    });
  }

  Future<void> stop() => _server.close();
}

/// Connects, offers [keys] for the peer, and only believes an `ok`.
PeerVerifier _handshake(Map<String, String> keys) =>
    (String peerId, String address, int port) async {
      final String? key = keys[peerId];
      if (key == null) return false;
      Socket? socket;
      try {
        socket = await Socket.connect(
          address,
          port,
          timeout: const Duration(milliseconds: 300),
        );
        final List<int> answer = <int>[];
        final Completer<bool> proven = Completer<bool>();
        final Socket live = socket;
        live.listen(
          (List<int> chunk) {
            answer.addAll(chunk);
            if (String.fromCharCodes(answer) == 'ok' && !proven.isCompleted) {
              proven.complete(true);
            }
          },
          onError: (_) {
            if (!proven.isCompleted) proven.complete(false);
          },
          onDone: () {
            if (!proven.isCompleted) proven.complete(false);
          },
        );
        live.write(key);
        return await proven.future.timeout(
          const Duration(milliseconds: 500),
          onTimeout: () => false,
        );
      } catch (_) {
        return false;
      } finally {
        socket?.destroy();
      }
    };

void main() {
  group('stored addresses', () {
    test('finds a paired device over TCP when UDP is gone', () async {
      final _KeyServer server = _KeyServer('RIGHT-KEY');
      await server.start();
      addTearDown(server.stop);

      final TcpDiscovery discovery = TcpDiscovery(
        peers: () => <TcpPeer>[
          TcpPeer(
            id: 'pc',
            name: 'Study PC',
            addresses: <String>['127.0.0.1'],
            port: server.port,
          ),
        ],
        verify: _handshake(<String, String>{'pc': 'RIGHT-KEY'}),
        ownAddresses: () async => <String>[],
      );

      final Map<String, TcpFoundPeer> found = await discovery.find(sweep: false);

      expect(found.keys, <String>['pc']);
      expect(found['pc']!.address, '127.0.0.1');
      expect(found['pc']!.port, server.port);
    });

    test('an open port with the wrong pairing key is not a peer', () async {
      final _KeyServer server = _KeyServer('RIGHT-KEY');
      await server.start();
      addTearDown(server.stop);

      final TcpDiscovery discovery = TcpDiscovery(
        peers: () => <TcpPeer>[
          TcpPeer(
            id: 'pc',
            name: 'Study PC',
            addresses: <String>['127.0.0.1'],
            port: server.port,
          ),
        ],
        verify: _handshake(<String, String>{'pc': 'WRONG-KEY'}),
        ownAddresses: () async => <String>[],
      );

      final Map<String, TcpFoundPeer> found = await discovery.find(sweep: false);

      expect(found, isEmpty,
          reason: 'a listener that cannot prove the pairing is not the device');
      expect(server.accepted, greaterThanOrEqualTo(1),
          reason: 'the port really was open — only the proof failed');
    });
  });

  group('subnet sweep', () {
    test('only private ranges are ever swept', () {
      expect(subnetHosts('8.8.8.8'), isEmpty, reason: 'public: refused');
      expect(subnetHosts('100.120.66.13'), isEmpty,
          reason: 'CGNAT/Tailscale is not RFC1918');
      expect(subnetHosts('2001:db8::1'), isEmpty);

      final List<String> hosts = subnetHosts('192.168.1.8');
      expect(hosts, hasLength(253), reason: '.1-.254 minus this device itself');
      expect(hosts, contains('192.168.1.1'));
      expect(hosts, isNot(contains('192.168.1.8')),
          reason: 'the device itself is not a sweep target');
      expect(isPrivateIPv4('10.0.0.5'), isTrue);
      expect(isPrivateIPv4('172.20.1.1'), isTrue);
      expect(isPrivateIPv4('172.32.1.1'), isFalse);
    });

    test('a public host in a caller-supplied sweep list is never dialled',
        () async {
      final List<String> dialled = <String>[];
      final TcpDiscovery discovery = TcpDiscovery(
        peers: () => <TcpPeer>[
          TcpPeer(
            id: 'pc',
            name: 'Study PC',
            addresses: <String>['192.168.1.99'],
            port: 51820,
          ),
        ],
        verify: (peerId, address, port) async {
          dialled.add(address);
          // Only the swept host answers: the stored address is stale, which is
          // what makes the sweep run at all.
          return address == '192.168.1.77';
        },
        ownAddresses: () async => <String>[],
        sweepHosts: () async => <String>['8.8.8.8', '192.168.1.77'],
      );

      final Map<String, TcpFoundPeer> found = await discovery.find();

      expect(dialled, isNot(contains('8.8.8.8')),
          reason: 'nothing may leave the local network');
      expect(dialled, contains('192.168.1.77'));
      expect(found['pc']?.address, '192.168.1.77',
          reason: 'the stale stored address was replaced by the swept one');
    });

    test('the device does not sweep its own address', () async {
      final List<String> dialled = <String>[];
      final TcpDiscovery discovery = TcpDiscovery(
        peers: () => <TcpPeer>[
          TcpPeer(
            id: 'pc',
            name: 'Study PC',
            addresses: <String>['192.168.1.99'],
            port: 51820,
          ),
        ],
        verify: (peerId, address, port) async {
          dialled.add(address);
          return address == '192.168.1.9';
        },
        ownAddresses: () async => <String>['192.168.1.8'],
        sweepHosts: () async => <String>['192.168.1.8', '192.168.1.9'],
      );

      await discovery.find();

      expect(dialled, contains('192.168.1.9'));
      expect(dialled, isNot(contains('192.168.1.8')));
    });
  });

  group('bounds', () {
    test('the concurrency cap holds under a full sweep', () async {
      final TcpDiscovery discovery = TcpDiscovery(
        peers: () => <TcpPeer>[
          TcpPeer(
            id: 'pc',
            name: 'Study PC',
            addresses: <String>['192.168.1.99'],
            port: 51820,
          ),
        ],
        verify: (peerId, address, port) async {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          return false;
        },
        ownAddresses: () async => <String>[],
        sweepHosts: () async => <String>[
          for (var i = 1; i <= 40; i++) '192.168.1.$i',
        ],
        maxConcurrent: 4,
        budget: const Duration(seconds: 10),
      );

      await discovery.find();

      expect(discovery.peakInFlight, lessThanOrEqualTo(4));
      expect(discovery.peakInFlight, greaterThan(1),
          reason: 'the sweep is concurrent, not one host at a time');
    });

    test('the budget ends a sweep that would otherwise run long', () async {
      final DateTime started = DateTime.now();
      final TcpDiscovery discovery = TcpDiscovery(
        peers: () => <TcpPeer>[
          TcpPeer(
            id: 'pc',
            name: 'Study PC',
            addresses: <String>['192.168.1.99'],
            port: 51820,
          ),
        ],
        verify: (peerId, address, port) async {
          await Future<void>.delayed(const Duration(milliseconds: 80));
          return false;
        },
        ownAddresses: () async => <String>[],
        sweepHosts: () async => <String>[
          for (var i = 1; i <= 250; i++) '192.168.1.$i',
        ],
        maxConcurrent: 8,
        budget: const Duration(milliseconds: 400),
      );

      final Map<String, TcpFoundPeer> found = await discovery.find();

      expect(found, isEmpty);
      expect(DateTime.now().difference(started),
          lessThan(const Duration(seconds: 3)),
          reason: '250 hosts at 80 ms each would be 20 s without a deadline');
    });

    test('cancel stops the pass at its next check', () async {
      final TcpDiscovery discovery = TcpDiscovery(
        peers: () => <TcpPeer>[
          TcpPeer(
            id: 'pc',
            name: 'Study PC',
            addresses: <String>['192.168.1.99'],
            port: 51820,
          ),
        ],
        verify: (peerId, address, port) async {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          return false;
        },
        ownAddresses: () async => <String>[],
        sweepHosts: () async => <String>[
          for (var i = 1; i <= 200; i++) '192.168.1.$i',
        ],
        maxConcurrent: 4,
        budget: const Duration(seconds: 20),
      );

      final Future<Map<String, TcpFoundPeer>> pass = discovery.find();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      discovery.cancel();
      final Map<String, TcpFoundPeer> found = await pass;

      expect(discovery.cancelled, isTrue);
      expect(found, isEmpty);
    });
  });
}
