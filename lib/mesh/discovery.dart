import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/identity.dart';

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
class DiscoveryService {
  static const int discoveryPort = 51822;
  static final InternetAddress group = InternetAddress('239.255.0.250');

  final DeviceInfo identity;
  final void Function(DiscoveredDevice device) onDiscovered;

  RawDatagramSocket? _socket;
  Timer? _broadcastTimer;
  bool _started = false;

  DiscoveryService({required this.identity, required this.onDiscovered});

  Future<void> start() async {
    if (_started) return;
    _started = true;

    try {
      _socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        discoveryPort,
        reuseAddress: true,
      );
    } catch (_) {
      // Port busy (e.g. a second Nexus instance on this machine) — bind an
      // ephemeral port. We can still receive and announce.
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0, reuseAddress: true);
    }

    await _joinGroups();
    _socket!.listen(_onDatagram);
    _broadcastTimer = Timer.periodic(const Duration(seconds: 3), (_) => unawaited(_announce()));
    unawaited(_announce());
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

    // Announce on the multicast group, and also unicast to loopback so two
    // instances on the same machine can find each other (useful for testing).
    for (final target in [group, InternetAddress('127.0.0.1')]) {
      try {
        socket.send(payload, target, discoveryPort);
      } catch (_) {
        // A filtered network or a dead interface — try the next target.
      }
    }
  }

  void _onDatagram(RawSocketEvent event) {
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
      onDiscovered(device);

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
    _socket?.close();
    _socket = null;
  }
}
