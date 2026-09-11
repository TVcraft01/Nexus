import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import '../core/identity.dart';
import 'multicast_lock.dart';

/// A device seen on the local network via [DiscoveryService].
class DiscoveredDevice {
  final String id;
  final String name;
  final String platform;
  final String address; // IP the hello came from
  final int port; // the device's Nexus TCP port
  final DateTime lastSeen;

  const DiscoveredDevice({
    required this.id,
    required this.name,
    required this.platform,
    required this.address,
    required this.port,
    required this.lastSeen,
  });

  DiscoveredDevice withSeen(DateTime seen) => DiscoveredDevice(
      id: id,
      name: name,
      platform: platform,
      address: address,
      port: port,
      lastSeen: seen);
}

/// Finds other Nexus devices on the same network.
///
/// How it works: every device joins the Nexus multicast group and announces
/// itself every few seconds; it also unicasts a reply to any device it hears,
/// so discovery works even when multicast is filtered. Hearing an announcement
/// only makes a device *visible* — it is NOT proof it is reachable. Presence
/// is verified separately with a direct TCP ping (see [MeshService]), and the
/// UI is honest about the difference.
///
/// Multicast is used instead of broadcast because it needs no special socket
/// flag (Linux refuses broadcast sends without SO_BROADCAST, which dart:io
/// does not expose) and it is the standard approach on home Wi-Fi.
/// What discovery is actually doing, as opposed to what it hopes.
///
/// Discovery is best-effort by design, but "best-effort" must not mean
/// "silently broken": a bind that fell back to an ephemeral port, or a
/// socket whose announces never leave the device, means the app can never
/// *receive* an announcement (peers send to the port, not to us) — the user
/// sees an empty Nearby list and no explanation. This is the honest summary
/// the app and the logs report.
class DiscoveryStatus {
  /// The port the socket actually got; null when no socket was ever bound.
  final int? boundPort;

  /// Announces that made it onto the wire, and those that threw.
  final int announced;
  final int failedSends;

  /// Announcements heard from other devices.
  final int received;

  /// The last send error, verbatim, so a failure can be diagnosed from a log.
  final String? lastSendError;

  /// The port this service should have been on — [DiscoveryService.discoveryPort]
  /// unless a caller deliberately runs somewhere else.
  final int expectedPort;

  const DiscoveryStatus({
    required this.boundPort,
    required this.announced,
    required this.failedSends,
    required this.received,
    this.lastSendError,
    this.expectedPort = DiscoveryService.discoveryPort,
  });

  /// A socket on the expected port that has not failed to send: the only
  /// state in which another device's announcement can actually reach us.
  bool get canReceive => boundPort == expectedPort && failedSends == 0;

  /// Whether this device is at least announcing (true even while degraded).
  bool get announcing => announced > 0;

  /// One line a human can act on.
  String describe() {
    if (boundPort == null) {
      return 'Discovery is off — no network socket could be opened.';
    }
    if (boundPort != expectedPort) {
      return 'Discovery is running on port $boundPort instead of '
          '$expectedPort, so it cannot hear other devices. '
          'Close the other Nexus instance using that port and restart.';
    }
    if (failedSends > 0) {
      return 'Discovery could not announce on the network '
          '(${lastSendError ?? "unknown error"}) — check this device\'s Wi-Fi '
          'and firewall.';
    }
    if (received == 0) {
      return 'Discovery is listening; no other Nexus device has been heard '
          'yet.';
    }
    return 'Discovery heard $received announcement(s) and announced $announced.';
  }
}

class DiscoveryService {
  static const int discoveryPort = 51822;
  static final InternetAddress group = InternetAddress('239.255.0.250');
  static final InternetAddress broadcast = InternetAddress('255.255.255.255');

  /// How long to wait before trying the expected port again after a fallback.
  /// A port held by a dying sibling instance is a transient condition; without
  /// this retry the process stays deaf for its whole lifetime.
  static const Duration reboundInterval = Duration(seconds: 20);

  final DeviceInfo identity;
  final FutureOr<void> Function(DiscoveredDevice device) onDiscovered;

  /// The port this instance announces on and expects to hear on. Defaults to
  /// [discoveryPort]; a caller that runs on another one (a test) can own it
  /// without fighting every other Nexus on the machine for the canonical one.
  final int port;

  /// Devices we have seen before. Every announce cycle we also send a hello
  /// directly to each one (unicast), so the mesh heals itself when the router
  /// stops forwarding multicast — the most common real-world discovery
  /// failure on home Wi-Fi.
  final List<({String address, int port})> knownAddresses = [];

  /// Android permits UDP broadcast sends (desktop Linux refuses them without
  /// SO_BROADCAST), so on Android we announce by broadcast too — another path
  /// that survives flaky multicast.
  final bool canBroadcast;

  RawDatagramSocket? _socket;
  Timer? _broadcastTimer;
  Timer? _reboundTimer;
  bool _started = false;

  /// Honest counters behind [status].
  int _announced = 0;
  int _failedSends = 0;
  int _received = 0;
  String? _lastSendError;
  bool _reportedSendFailure = false;

  DiscoveryService({
    required this.identity,
    required this.onDiscovered,
    this.canBroadcast = false,
    int? port,
  }) : port = port ?? discoveryPort;

  Future<void> start() async {
    if (_started) return;
    _started = true;

    // Android's Wi-Fi firmware filters multicast frames unless the app holds
    // a WifiManager.MulticastLock — joining the group is not enough on its
    // own. Desktop platforms refuse the call, which is fine: the lock is an
    // Android-only requirement.
    await MulticastLock.acquire();

    await _bind();
    _broadcastTimer = Timer.periodic(const Duration(seconds: 3), (_) => unawaited(_announce()));
    unawaited(_announce());
  }

  /// Binds the discovery socket, preferring the canonical port. A fallback to
  /// an ephemeral port keeps *announcing* alive but cannot receive, so it is
  /// retried in the background rather than lived with silently.
  Future<void> _bind() async {
    try {
      _socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        port,
      );
    } catch (e) {
      // Port busy (usually a second Nexus instance on this machine, e.g. an
      // update restarting over the old process). Announce from an ephemeral
      // port and keep trying to get the real one back.
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      debugPrint('NEXUS discovery: port $port was busy ($e) — '
          'announcing from ${_socket!.port}, but this device cannot hear '
          'other devices until the port is free.');
      _reboundTimer ??= Timer.periodic(reboundInterval, (_) => unawaited(_rebind()));
    }

    await _joinGroups();
    // onError is swallowed: a best-effort discovery socket must never take
    // the app down (e.g. a broadcast send refused on some platforms).
    _socket!.listen(_onDatagram, onError: (_) {});
    debugPrint('NEXUS discovery: listening on ${_socket!.address.address}:${_socket!.port}');
  }

  /// Replaces a fallback socket with the canonical one once the port frees up.
  Future<void> _rebind() async {
    if (_socket?.port == port) {
      _reboundTimer?.cancel();
      _reboundTimer = null;
      return;
    }
    final previous = _socket;
    try {
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port);
    } catch (_) {
      return; // still busy — try again next tick
    }
    await _joinGroups();
    _socket!.listen(_onDatagram, onError: (_) {});
    previous?.close();
    _reboundTimer?.cancel();
    _reboundTimer = null;
    // A rebind means the peer-visible port changed, so tell the network again
    // immediately instead of waiting for the next timer tick.
    unawaited(_announce());
    debugPrint('NEXUS discovery: rebound to ${_socket!.address.address}:${_socket!.port}');
  }

  Future<void> _joinGroups() async {
    final socket = _socket;
    if (socket == null) return;
    try {
      socket.joinMulticast(group);
    } catch (_) {}
    try {
      for (final iface in await NetworkInterface.list()) {
        final hasIpv4 = iface.addresses.any((a) => a.type == InternetAddressType.IPv4);
        if (!hasIpv4) continue;
        try {
          socket.joinMulticast(group, iface);
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> _announce() async {
    final payload = utf8.encode(jsonEncode({
      'v': 1,
      'id': identity.id,
      'name': identity.name,
      'platform': identity.platform,
      'port': _tcpPort,
    }));
    final socket = _socket;
    if (socket == null) return;

    final targets = <InternetAddress>{
      group,
      InternetAddress('127.0.0.1'), // two instances on one machine can find each other
      for (final known in knownAddresses) InternetAddress(known.address),
      if (canBroadcast) broadcast,
    };
    var sent = 0;
    String? failure;
    for (final target in targets) {
      try {
        socket.send(payload, target, port);
        sent++;
      } catch (e) {
        // A filtered network or a dead interface — try the next target.
        failure = e.toString();
      }
    }
    if (sent > 0) {
      _announced++;
    } else {
      // Nothing left the device. Saying "announced" here would be a lie the
      // user pays for with an empty Nearby list and no explanation.
      _failedSends++;
      _lastSendError = failure;
      if (!_reportedSendFailure) {
        _reportedSendFailure = true;
        debugPrint('NEXUS discovery: could not announce on any target '
            '(${_lastSendError ?? 'unknown error'}) — this device is invisible '
            'to other Nexus devices.');
      }
    }
    if (sent > 0) {
      debugPrint('NEXUS discovery: announced id=${identity.id} port=$_tcpPort '
          '($sent/${targets.length} targets: multicast + ${knownAddresses.length} known + loopback'
          '${canBroadcast ? ' + broadcast' : ''})');
    }
  }

  /// The honest state of this service — see [DiscoveryStatus].
  DiscoveryStatus get status => DiscoveryStatus(
        boundPort: _socket?.port,
        announced: _announced,
        failedSends: _failedSends,
        received: _received,
        lastSendError: _lastSendError,
        expectedPort: port,
      );

  Future<void> _onDatagram(RawSocketEvent event) async {
    final socket = _socket;
    if (socket == null || event != RawSocketEvent.read) return;
    final datagram = socket.receive();
    if (datagram == null) return;
    try {
      final json = jsonDecode(utf8.decode(datagram.data));
      if (json is! Map<String, dynamic>) return;
      final id = json['id'];
      if (id is! String || id == identity.id) return;
      final port = (json['port'] as num?)?.toInt();
      if (port == null || port <= 0) return;
      final device = DiscoveredDevice(
        id: id,
        name: (json['name'] as String?) ?? 'Unknown device',
        platform: (json['platform'] as String?) ?? 'other',
        address: datagram.address.address,
        port: port,
        lastSeen: DateTime.now(),
      );
      await onDiscovered(device);
      _received++;
      debugPrint('NEXUS discovery: heard ${device.name} (${device.id}) at ${device.address}:${device.port}');

      // Reply by unicast so the sender learns about us even on networks
      // where multicast is filtered.
      final reply = utf8.encode(jsonEncode({
        'v': 1,
        'id': identity.id,
        'name': identity.name,
        'platform': identity.platform,
        'port': _tcpPort,
      }));
      socket.send(reply, datagram.address, datagram.port);
    } catch (_) {
      // Garbage on the wire (or another app using this port) — ignore.
    }
  }

  int _tcpPort = 51820;

  /// The device's Nexus TCP port (set once by the mesh service).
  set tcpPort(int value) => _tcpPort = value;

  Future<void> stop() async {
    _started = false;
    _broadcastTimer?.cancel();
    _broadcastTimer = null;
    _reboundTimer?.cancel();
    _reboundTimer = null;
    _socket?.close();
    _socket = null;
    await MulticastLock.release();
  }
}
