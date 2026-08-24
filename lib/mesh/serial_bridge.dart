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

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'port': port,
    'caps': caps,
    'lastSeen': lastSeen.toIso8601String(),
    'paired': paired,
  };

  factory SerialDevice.fromJson(Map<String, dynamic> json) => SerialDevice(
    id: json['id'] as String,
    name: json['name'] as String? ?? json['id'] as String,
    port: json['port'] as String? ?? '',
    caps: (json['caps'] as List?)?.whereType<String>().toList() ??
        const ['ping', 'msg'],
    lastSeen: DateTime.tryParse(json['lastSeen'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
    paired: json['paired'] == true,
  );

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

  /// How often the cable is re-listed for hot-plugged boards. Injectable so
  /// tests can run a fast rescan.
  final Duration rescanInterval;

  /// Called when the user picks a node in the UI and the host confirms the
  /// pairing — lets the node persist the fact (LED, EEPROM flag).
  final Future<void> Function(SerialDevice device)? onPaired;

  /// Called when a node sends an `up` status payload (a sensor reading, an
  /// echo, a button press). The host relays it to whoever asked. Settable so
  /// tests can attach a plain bridge and the mesh wires the relay in.
  void Function(String deviceId, Map<String, dynamic> data)? onUp;

  /// Seeds the bridge with serial nodes remembered from a previous run, so a
  /// board that is unplugged at startup still shows as Disconnected.
  final List<SerialDevice> Function()? loadKnown;

  /// Persists the current (pruned) list of known nodes — wired to the store
  /// by the mesh. Settable so tests can attach a plain bridge.
  void Function(List<SerialDevice> devices)? saveKnown;

  DateTime? _lastPersist;

  /// How long a node stays listed after it stops announcing (unplugged or
  /// asleep). Longer than the 15 s "online" window, so an unplugged board
  /// shows as Disconnected instead of vanishing — the UI keeps a memory of
  /// nodes we have seen, like paired devices do.
  static const _offlineWindow = Duration(hours: 24);

  final Map<String, SerialDevice> _devices = {};
  final Map<String, _OpenPort> _ports = {};
  bool _scanning = false;

  /// Re-lists the cable every few seconds so a board plugged in *after* the
  /// first scan (or replugged after being unplugged) shows up without the
  /// user having to reopen the pairing page. Cheap: listing is a directory
  /// read, and ports already open are skipped.
  Timer? _rescanTimer;

  SerialBridge({
    required this.transport,
    required this.onChanged,
    this.rescanInterval = const Duration(seconds: 5),
    this.loadKnown,
    this.saveKnown,
    this.onPaired,
    this.onUp,
  }) {
    // Re-seed from the previous run so a board that is unplugged at startup
    // still shows as Disconnected instead of being forgotten.
    for (final d in loadKnown?.call() ?? const <SerialDevice>[]) {
      _devices[d.id] = d;
    }
  }

  List<SerialDevice> get devices {
    final cutoff = DateTime.now().subtract(_offlineWindow);
    _devices.removeWhere((_, d) => d.lastSeen.isBefore(cutoff));
    final list = _devices.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return list;
  }

  /// Only nodes currently alive — what peers should hear about for relay.
  List<SerialDevice> get liveDevices =>
      _devices.values.where((d) => d.online).toList();

  SerialDevice? byId(String id) => _devices[id];

  /// Writes the current known-node list to the store. Throttled: the node
  /// announces every few seconds, so a disk write on every announce would be
  /// wasteful — the persisted list just needs to be close enough that a
  /// restart shows the right online/offline state. [dispose] always persists
  /// the final state.
  void _persist() {
    final now = DateTime.now();
    final last = _lastPersist;
    if (last != null && now.difference(last) < const Duration(seconds: 30)) {
      return;
    }
    _lastPersist = now;
    final cutoff = now.subtract(_offlineWindow);
    final list = _devices.values
        .where((d) => d.lastSeen.isAfter(cutoff))
        .toList();
    saveKnown?.call(list);
  }

  void _persistNow() {
    _lastPersist = DateTime.now();
    final cutoff = DateTime.now().subtract(_offlineWindow);
    final list = _devices.values
        .where((d) => d.lastSeen.isAfter(cutoff))
        .toList();
    saveKnown?.call(list);
  }

  /// Starts listening on every serial port currently present, and keeps
  /// re-listing the cable every few seconds so hot-plugging works. Safe to
  /// call repeatedly — ports already open are skipped.
  Future<void> startScan() async {
    _rescanTimer ??= Timer.periodic(rescanInterval, (_) {
      unawaited(_scanOnce());
    });
    await _scanOnce();
  }

  Future<void> _scanOnce() async {
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
    debugPrint('NEXUS serial: listening on ${info.port}');
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
        debugPrint('NEXUS serial: node ${msg.id} (${msg.name}) seen on $port');
        _persist(); // remember new/changed nodes (throttled)
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
    _persistNow(); // the paired flag must survive a restart
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
    debugPrint('NEXUS serial: $port went away — node(s) offline until replugged');
    open.sub?.cancel();
    open.port.close();
    // Keep the device records, but mark them offline immediately instead of
    // waiting out the 15 s online window. They go back Online when the node
    // is replugged and re-announces; `_offlineWindow` prunes them eventually.
    final stale = DateTime.now().subtract(const Duration(minutes: 1));
    for (final d in _devices.values) {
      if (d.port == port) d.lastSeen = stale;
    }
    _persistNow(); // remember the offline state before a possible restart
    onChanged();
  }

  Future<void> dispose() async {
    _rescanTimer?.cancel();
    _rescanTimer = null;
    _persistNow(); // final state, including nodes currently online
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
