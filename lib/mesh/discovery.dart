import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import '../core/identity.dart';

class DiscoveredDevice {
  final String id;
  final String name;
  final String platform;
  final String address;
  final int port;
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
        lastSeen: seen,
      );
}

/// Finds other Nexus devices on the local network.
///
/// Devices announce over multicast and, where supported, IPv4 broadcast.
/// Once a device is heard, the sender replies directly so discovery can heal
/// itself even when multicast delivery is filtered by the access point.
class DiscoveryService {
  static const int discoveryPort = 51822;
  static final InternetAddress group = InternetAddress('239.255.0.250');
  static final InternetAddress broadcast = InternetAddress('255.255.255.255');

  final DeviceInfo identity;
  final FutureOr<void> Function(DiscoveredDevice device) onDiscovered;
  final List<({String address, int port})> knownAddresses = [];
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
      );
    } catch (_) {
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    }

    if (canBroadcast) {
      try {
        _socket!.broadcastEnabled = true;
      } catch (_) {}
    }

    await _joinGroups();
    _socket!.listen(_onDatagram, onError: (_) {});
    _broadcastTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => unawaited(_announce()),
    );
    unawaited(_announce());
    debugPrint(
      'NEXUS discovery: listening on ${_socket!.address.address}:${_socket!.port}',
    );
  }

  Future<void> _joinGroups() async {
    final socket = _socket;
    if (socket == null) return;
    try {
      socket.joinMulticast(group);
    } catch (_) {}
    try {
      for (final iface in await NetworkInterface.list()) {
        final hasIpv4 = iface.addresses.any(
          (a) => a.type == InternetAddressType.IPv4,
        );
        if (!hasIpv4) continue;
        try {
          socket.joinMulticast(group, iface);
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> _announce() async {
    final payload = utf8.encode(
      jsonEncode({
        'v': 1,
        'id': identity.id,
        'name': identity.name,
        'platform': identity.platform,
        'port': _tcpPort,
      }),
    );
    final socket = _socket;
    if (socket == null) return;

    final targets = <InternetAddress>{
      group,
      InternetAddress('127.0.0.1'),
      for (final known in knownAddresses) InternetAddress(known.address),
      if (canBroadcast) broadcast,
    };
    for (final target in targets) {
      try {
        socket.send(payload, target, discoveryPort);
      } catch (_) {}
    }
    debugPrint(
      'NEXUS discovery: announced id=${identity.id} port=$_tcpPort '
      '(multicast + ${knownAddresses.length} known + loopback'
      '${canBroadcast ? ' + broadcast' : ''})',
    );
  }

  Future<void> _onDatagram(RawSocketEvent event) async {
    final socket = _socket;
    if (socket == null || event != RawSocketEvent.read) return;
    final datagram = socket.receive();
    if (datagram == null) return;
    try {
      final decoded = jsonDecode(utf8.decode(datagram.data));
      if (decoded is! Map<String, dynamic>) return;
      final id = decoded['id'];
      if (id is! String || id == identity.id) return;
      final port = (decoded['port'] as num?)?.toInt();
      if (port == null || port <= 0 || port > 65535) return;
      final device = DiscoveredDevice(
        id: id,
        name: (decoded['name'] as String?) ?? 'Unknown device',
        platform: (decoded['platform'] as String?) ?? 'other',
        address: datagram.address.address,
        port: port,
        lastSeen: DateTime.now(),
      );
      await onDiscovered(device);
      debugPrint(
        'NEXUS discovery: heard ${device.name} (${device.id}) '
        'at ${device.address}:${device.port}',
      );
      final reply = utf8.encode(
        jsonEncode({
          'v': 1,
          'id': identity.id,
          'name': identity.name,
          'platform': identity.platform,
          'port': _tcpPort,
        }),
      );
      try {
        socket.send(reply, datagram.address, datagram.port);
      } catch (_) {}
    } catch (_) {}
  }

  int _tcpPort = 51820;
  set tcpPort(int value) => _tcpPort = value;

  Future<void> stop() async {
    _started = false;
    _broadcastTimer?.cancel();
    _broadcastTimer = null;
    _socket?.close();
    _socket = null;
  }
}
