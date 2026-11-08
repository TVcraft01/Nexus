// Discovery when UDP is not an option.
//
// The phone this was written for binds its discovery socket on 51822, announces
// every three seconds, and never receives a datagram from the network: the
// kernel counts packets sent to that port as "no port", inbound TCP on 51820
// works, and a plain `nc` listener on the same port hears them. Rebinding heals
// a deaf socket but not that network path (see docs/DECISIONS.md), so UDP is
// best-effort and this is the guaranteed one.
//
// Two passes, in the order that costs the least:
//   1. the addresses already stored for each paired device — what the mesh's
//      own dial ladder would try, on the port it stores;
//   2. only when those fail, the hosts of this device's own private /24 (see
//      local_subnet.dart), because a peer whose DHCP lease moved is otherwise
//      unreachable forever.
//
// Neither pass decides on its own that a device was found: [verify] must prove
// the pairing key. A bare open port is a listener, not a peer.
import 'dart:async';

import 'local_subnet.dart';

/// One paired device the TCP pass may try to reach.
class TcpPeer {
  final String id;
  final String name;

  /// Addresses already stored for it, most likely first — the ladder the mesh
  /// already dials, reused rather than rebuilt here.
  final List<String> addresses;

  /// The peer's stored Nexus port.
  final int port;

  const TcpPeer({
    required this.id,
    required this.name,
    required this.addresses,
    required this.port,
  });
}

/// Where a peer was found over TCP.
class TcpFoundPeer {
  final String id;
  final String address;
  final int port;

  const TcpFoundPeer({
    required this.id,
    required this.address,
    required this.port,
  });

  @override
  String toString() => '$id@$address:$port';
}

/// Proves that the device at `address:port` is [peerId], using the pairing key.
///
/// Must return false for a port that cannot prove the pairing: an open socket
/// is not a find. The mesh supplies the real one (`MeshService`), so the
/// authenticated handshake is not reimplemented in this file.
typedef PeerVerifier =
    Future<bool> Function(String peerId, String address, int port);

/// Finds paired devices over TCP, with or without working UDP discovery.
class TcpDiscovery {
  TcpDiscovery({
    required this.peers,
    required this.verify,
    required this.ownAddresses,
    this.sweepHosts,
    this.connectTimeout = const Duration(milliseconds: 700),
    this.maxConcurrent = 24,
    this.budget = const Duration(seconds: 8),
  });

  /// The paired devices to find. A function rather than a list so a pass sees
  /// a pairing that happened while the previous pass was running.
  final List<TcpPeer> Function() peers;

  /// The authenticated handshake. See [PeerVerifier].
  final PeerVerifier verify;

  /// This device's own addresses, so the sweep never dials itself.
  final Future<List<String>> Function() ownAddresses;

  /// Hosts to sweep when the stored addresses fail. Defaults to this device's
  /// own private /24 ([ownSubnetHosts]); a test passes its own list.
  final Future<List<String>> Function()? sweepHosts;

  /// How long one verification may take, connection included. Capped again in
  /// [_verified], because a verifier that hangs must not hold the pass open.
  final Duration connectTimeout;

  /// The most verifications in flight at once. A phone dialling 254 hosts one
  /// at a time would take minutes; all 254 at once would exhaust the socket
  /// table and the router's patience.
  final int maxConcurrent;

  /// The wall clock a whole pass may take, stored addresses and sweep alike.
  final Duration budget;

  bool _cancelled = false;

  /// Whether the last pass was cancelled (or the current one has been).
  bool get cancelled => _cancelled;

  /// Stops the pass at its next check. Safe at any time.
  void cancel() => _cancelled = true;

  int _inFlight = 0;

  /// The most verifications that were ever in flight at once in the last pass.
  /// Observable so the concurrency cap is a measurement, not a comment.
  int _peakInFlight = 0;
  int get peakInFlight => _peakInFlight;

  /// Runs one pass and answers what it found, by peer id.
  ///
  /// [sweep] false limits it to the stored addresses — the cheap pass the app
  /// runs while UDP discovery may still be working.
  Future<Map<String, TcpFoundPeer>> find({bool sweep = true}) async {
    _cancelled = false;
    _peakInFlight = 0;
    final Map<String, TcpFoundPeer> found = <String, TcpFoundPeer>{};
    final DateTime deadline = DateTime.now().add(budget);

    for (final TcpPeer peer in peers()) {
      if (_spent(deadline)) break;
      for (final String address in peer.addresses) {
        if (_spent(deadline)) break;
        if (await _verified(peer, address, peer.port, deadline)) {
          found[peer.id] = TcpFoundPeer(
            id: peer.id,
            address: address,
            port: peer.port,
          );
          break;
        }
      }
    }

    final List<TcpPeer> missing = <TcpPeer>[
      for (final TcpPeer peer in peers())
        if (!found.containsKey(peer.id)) peer,
    ];
    if (!sweep || missing.isEmpty || _spent(deadline)) return found;

    final Set<String> own = (await ownAddresses()).toSet();
    List<String> hosts;
    try {
      hosts = await (sweepHosts?.call() ?? ownSubnetHosts());
    } catch (_) {
      return found;
    }
    // Never dial ourselves, and never leave the local network: the host list
    // is private-range only by construction (local_subnet.dart), and this is
    // the second guard in case a caller passes its own list.
    hosts = <String>[
      for (final String host in hosts)
        if (!own.contains(host) && isPrivateIPv4(host)) host,
    ];
    if (hosts.isEmpty) return found;

    var next = 0;
    Future<void> worker() async {
      while (true) {
        if (_spent(deadline)) return;
        final int index = next++;
        if (index >= hosts.length) return;
        final String host = hosts[index];
        for (final TcpPeer peer in missing) {
          if (_spent(deadline)) return;
          if (found.containsKey(peer.id)) continue;
          if (await _verified(peer, host, peer.port, deadline)) {
            found[peer.id] = TcpFoundPeer(
              id: peer.id,
              address: host,
              port: peer.port,
            );
          }
        }
      }
    }

    final int lanes = maxConcurrent < hosts.length ? maxConcurrent : hosts.length;
    await Future.wait(<Future<void>>[for (var i = 0; i < lanes; i++) worker()]);
    return found;
  }

  bool _spent(DateTime deadline) => _cancelled || DateTime.now().isAfter(deadline);

  Future<bool> _verified(
    TcpPeer peer,
    String address,
    int port,
    DateTime deadline,
  ) async {
    if (_spent(deadline)) return false;
    _inFlight++;
    if (_inFlight > _peakInFlight) _peakInFlight = _inFlight;
    try {
      return await verify(peer.id, address, port).timeout(
        connectTimeout + const Duration(milliseconds: 300),
        onTimeout: () => false,
      );
    } catch (_) {
      // A verifier that throws is a route that does not answer, not a crash.
      return false;
    } finally {
      _inFlight--;
    }
  }
}
