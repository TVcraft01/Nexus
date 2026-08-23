import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

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
  static final InternetAddress broadcast = InternetAddress('255.255.255.255');

  final DeviceInfo identity;
  final FutureOr<void> Function(DiscoveredDevice device) onDiscovered;

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
  bool _started = false;

  DiscoveryService({
    required this.identity,
    required this.onDiscovered,
    this.canBroadcast = false,
  });

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
    // onError is swallowed: a best-effort discovery socket must never take
    // the app down (e.g. a broadcast send refused on some platforms).
    _socket!.listen(_onDatagram, onError: (_) {});
    _broadcastTimer = Timer.periodic(const Duration(seconds: 3), (_) => unawaited(_announce()));
    unawaited(_announce());
    debugPrint('NEXUS discovery: listening on ${_socket!.address.address}:${_socket!.port}');
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
    for (final target in targets) {
      try {
        socket.send(payload, target, discoveryPort);
      } catch (_) {
        // A filtered network or a dead interface — try the next target.
      }
    }
    debugPrint('NEXUS discovery: announced id=${identity.id} port=$_tcpPort '
        '(multicast + ${knownAddresses.length} known + loopback${canBroadcast ? ' + broadcast' : ''})');
  }

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
    _socket?.close();
    _socket = null;
  }
}
