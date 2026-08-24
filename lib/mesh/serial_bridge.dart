import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/serial_protocol.dart';
import '../core/serial_transport.dart';

/// A microcontroller (ESP32, …) attached to this machine over a USB cable
/// that has announced itself to the Nexus app.
///
/// It is a mesh-visible device, but a limited one: the node itself can only
/// do what it advertises in [caps] (`ping`, `msg`). The host never offers it
/// things it cannot do — that is the "full mesh, minus what the device can't
/// do" rule.
class SerialDevice {
  final String id;
  final String name;
  final String port;
  final List<String> caps;
  DateTime lastSeen;
  bool paired;

  SerialDevice({
    required this.id,
    required this.name,
    required this.port,
    this.caps = const ['ping', 'msg'],
    required this.lastSeen,
    this.paired = false,
  });

  bool get online =>
      DateTime.now().difference(lastSeen) < const Duration(seconds: 15);

  bool can(String cap) => caps.contains(cap);

  @override
  bool operator ==(Object other) => other is SerialDevice && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// Scans the cable for serial nodes and keeps their presence up to date.
///
/// Owned by [MeshService] so the rest of the app sees serial devices next to
/// network-paired ones. Nothing here auto-connects: scanning starts when the
/// user opens the "Pair over cable" flow.
class SerialBridge {
  final SerialTransport transport;
  final void Function() onChanged;

  /// Called when the user picks a node in the UI and the host confirms the
  /// pairing — lets the node persist the fact (LED, EEPROM flag).
  final Future<void> Function(SerialDevice device)? onPaired;

  /// Called when a node sends an `up` status payload (a sensor reading, an
  /// echo, a button press). The host relays it to whoever asked. Settable so
  /// tests can attach a plain bridge and the mesh wires the relay in.
  void Function(String deviceId, Map<String, dynamic> data)? onUp;

  final Map<String, SerialDevice> _devices = {};
  final Map<String, _OpenPort> _ports = {};
  bool _scanning = false;

  SerialBridge({
    required this.transport,
    required this.onChanged,
    this.onPaired,
    this.onUp,
  });

  List<SerialDevice> get devices {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 15));
    _devices.removeWhere((_, d) => d.lastSeen.isBefore(cutoff));
    final list = _devices.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return list;
  }

  SerialDevice? byId(String id) => _devices[id];

  /// Starts listening on every serial port currently present. Safe to call
  /// repeatedly — ports already open are skipped.
  Future<void> startScan() async {
    if (_scanning) return;
    _scanning = true;
    try {
      final ports = await transport.listPorts();
      for (final info in ports) {
        if (_ports.containsKey(info.port)) continue;
        await _openPort(info);
      }
    } catch (e) {
      debugPrint('NEXUS serial: scan failed: $e');
    } finally {
      _scanning = false;
    }
  }

  Future<void> _openPort(SerialPortInfo info) async {
    SerialPort port;
    try {
      port = await transport.open(info);
    } catch (e) {
      debugPrint('NEXUS serial: could not open ${info.port}: $e');
      return;
    }
    final open = _OpenPort(info, port);
    _ports[info.port] = open;
    final decoder = SerialLineDecoder();
    open.sub = port.bytes.listen((chunk) {
      for (final msg in decoder.add(chunk)) {
        _handleMessage(info.port, msg);
      }
    }, onError: (_) => _dropPort(info.port), onDone: () => _dropPort(info.port));
    // Ask whatever is on the cable to identify itself right away instead of
    // waiting up to the announce interval.
    port.write(SerialMessage.helloMsg().encode().codeUnits);
  }

  void _handleMessage(String port, SerialMessage msg) {
    switch (msg.t) {
      case SerialMessage.ann:
        if (msg.id.isEmpty) return;
        final existing = _devices[msg.id];
        _devices[msg.id] = SerialDevice(
          id: msg.id,
          name: msg.name.isNotEmpty ? msg.name : (existing?.name ?? msg.id),
          port: port,
          caps: msg.caps.isNotEmpty ? msg.caps : const ['ping', 'msg'],
          lastSeen: DateTime.now(),
          paired: existing?.paired ?? false,
        );
        onChanged();
      case SerialMessage.up:
        final data = msg.fields['data'];
        if (data is Map<String, dynamic>) {
          onUp?.call(msg.id, data);
        }
        onChanged();
      case SerialMessage.pong:
        final d = _devices.values.where((x) => x.port == port).firstOrNull;
        if (d != null) {
          d.lastSeen = DateTime.now();
          onChanged();
        }
      default:
        break;
    }
  }

  /// Marks [id] as paired and tells the node so it can persist the state.
  Future<void> pair(String id) async {
    final device = _devices[id];
    if (device == null) return;
    device.paired = true;
    final port = _ports[device.port];
    if (port != null) {
      await port.port.write(SerialMessage.pairOk(device.name).encode().codeUnits);
    }
    await onPaired?.call(device);
    onChanged();
  }

  /// Sends a small command payload to the node. The node decides what to do
  /// with it (blink an LED, echo on a display, …).
  Future<bool> sendMessage(String id, Map<String, dynamic> data) async {
    final device = _devices[id];
    if (device == null) return false;
    final port = _ports[device.port];
    if (port == null) return false;
    try {
      await port.port.write(
        SerialMessage.msgTo(null, data).encode().codeUnits,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  void _dropPort(String port) {
    final open = _ports.remove(port);
    if (open == null) return;
    open.sub?.cancel();
    open.port.close();
    _devices.removeWhere((_, d) => d.port == port);
    onChanged();
  }

  Future<void> dispose() async {
    for (final open in _ports.values) {
      open.sub?.cancel();
      await open.port.close();
    }
    _ports.clear();
    _devices.clear();
  }
}

class _OpenPort {
  final SerialPortInfo info;
  final SerialPort port;
  StreamSubscription<List<int>>? sub;

  _OpenPort(this.info, this.port);
}
