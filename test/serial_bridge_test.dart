import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/serial_protocol.dart';
import 'package:nexus/core/serial_transport.dart';
import 'package:nexus/mesh/serial_bridge.dart';

class FakePort implements SerialPort {
  final StreamController<List<int>> _in = StreamController.broadcast();
  final List<List<int>> written = [];
  bool closed = false;

  @override
  Stream<List<int>> get bytes => _in.stream;

  @override
  bool get isOpen => !closed;

  @override
  Future<void> write(List<int> data) async {
    written.add(data);
  }

  @override
  Future<void> close() async {
    closed = true;
    await _in.close();
  }

  void feed(String line) => _in.add(utf8.encode(line));
}

class FakeTransport implements SerialTransport {
  final List<SerialPortInfo> ports;
  final List<FakePort> opened = [];
  int openCalls = 0;
  bool failOpen = false;

  FakeTransport(List<SerialPortInfo> ports) : ports = List.of(ports);

  @override
  Future<List<SerialPortInfo>> listPorts() async => ports;

  @override
  Future<SerialPort> open(SerialPortInfo info, {int baudRate = 115200}) async {
    openCalls++;
    if (failOpen) throw StateError('no device');
    final port = FakePort();
    opened.add(port);
    return port;
  }
}

/// Lets queued stream events from the fake ports be delivered.
Future<void> settle() => Future<void>.delayed(Duration.zero);

/// Polls until [cond] is true (with a timeout).
Future<void> _waitFor(bool Function() cond,
    {Duration timeout = const Duration(seconds: 2)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('condition not met within $timeout');
}

void main() {
  test('a node announcing itself appears as a device with its caps', () async {
    final transport = FakeTransport(
      [const SerialPortInfo(port: '/dev/ttyUSB0', label: 'ttyUSB0')],
    );
    var changes = 0;
    final bridge = SerialBridge(transport: transport, onChanged: () => changes++);

    await bridge.startScan();
    expect(transport.openCalls, 1);
    // The bridge asks for an identify right after opening.
    expect(
      transport.opened.single.written.single,
      utf8.encode(SerialMessage.helloMsg().encode()),
    );

    transport.opened.single.feed(
      '{"t":"ann","id":"esp32-abc","name":"Nexus ESP32","caps":["ping","msg"],"fw":"0.1.0"}\n',
    );
    await settle();
    expect(changes, greaterThan(0));
    final device = bridge.byId('esp32-abc');
    expect(device, isNotNull);
    expect(device!.name, 'Nexus ESP32');
    expect(device.port, '/dev/ttyUSB0');
    expect(device.can('msg'), isTrue);
    expect(device.can('clipboard'), isFalse);
  });

  test('sendMessage writes a msg line to the right port', () async {
    final transport = FakeTransport(
      [const SerialPortInfo(port: '/dev/ttyUSB0', label: 'ttyUSB0')],
    );
    final bridge = SerialBridge(transport: transport, onChanged: () {});

    await bridge.startScan();
    final port = transport.opened.single;
    port.feed('{"t":"ann","id":"esp32-abc","name":"ESP"}\n');
    await settle();
    port.written.clear(); // forget the hello

    final ok = await bridge.sendMessage('esp32-abc', {'blink': true});
    expect(ok, isTrue);
    final line = utf8.decode(port.written.single);
    final json = jsonDecode(line) as Map<String, dynamic>;
    expect(json['t'], 'msg');
    expect(json['data'], {'blink': true});
  });

  test('sendMessage to an unknown node fails', () async {
    final transport = FakeTransport(
      [const SerialPortInfo(port: '/dev/ttyUSB0', label: 'ttyUSB0')],
    );
    final bridge = SerialBridge(transport: transport, onChanged: () {});
    await bridge.startScan();
    expect(await bridge.sendMessage('nope', {'x': 1}), isFalse);
  });

  test('pair marks the device and tells the node', () async {
    final transport = FakeTransport(
      [const SerialPortInfo(port: '/dev/ttyUSB0', label: 'ttyUSB0')],
    );
    var pairedId = '';
    final bridge = SerialBridge(
      transport: transport,
      onChanged: () {},
      onPaired: (d) async => pairedId = d.id,
    );
    await bridge.startScan();
    final port = transport.opened.single;
    port.feed('{"t":"ann","id":"esp32-abc","name":"ESP"}\n');
    await settle();
    port.written.clear();

    await bridge.pair('esp32-abc');
    expect(bridge.byId('esp32-abc')!.paired, isTrue);
    expect(pairedId, 'esp32-abc');
    final line = utf8.decode(port.written.single);
    expect(line, contains('"t":"pair"'));
    expect(line, contains('"ok":true'));
  });

  test('up payloads fire the onUp callback with device id and data', () async {
    final transport = FakeTransport(
      [const SerialPortInfo(port: '/dev/ttyUSB0', label: 'ttyUSB0')],
    );
    String? upId;
    Map<String, dynamic>? upData;
    final bridge = SerialBridge(
      transport: transport,
      onChanged: () {},
      onUp: (id, data) {
        upId = id;
        upData = data;
      },
    );
    await bridge.startScan();
    final port = transport.opened.single;
    port.feed('{"t":"ann","id":"esp32-abc","name":"ESP"}\n');
    await settle();

    port.feed('{"t":"up","id":"esp32-abc","data":{"echo":"ok"}}\n');
    await settle();
    expect(upId, 'esp32-abc');
    expect(upData, {'echo': 'ok'});
  });

  test('unplugged node stays listed as offline, not vanished', () async {
    final transport = FakeTransport(
      [const SerialPortInfo(port: '/dev/ttyUSB0', label: 'ttyUSB0')],
    );
    var changes = 0;
    final bridge = SerialBridge(transport: transport, onChanged: () => changes++);
    await bridge.startScan();
    final port = transport.opened.single;
    port.feed('{"t":"ann","id":"esp32-abc","name":"ESP"}\n');
    await settle();
    expect(bridge.devices, hasLength(1));
    expect(bridge.devices.single.online, isTrue);
    expect(bridge.liveDevices, hasLength(1));

    await port.close(); // simulates unplug: stream done, node goes offline
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(bridge.devices, hasLength(1)); // remembered, not deleted
    expect(bridge.devices.single.online, isFalse);
    expect(bridge.liveDevices, isEmpty); // peers must not see it for relay
  });

  test('startScan skips ports already open', () async {
    final transport = FakeTransport(
      [const SerialPortInfo(port: '/dev/ttyUSB0', label: 'ttyUSB0')],
    );
    final bridge = SerialBridge(transport: transport, onChanged: () {});
    await bridge.startScan();
    await bridge.startScan();
    expect(transport.openCalls, 1);
  });

  test('failing to open a port does not crash the scan', () async {
    final transport = FakeTransport(
      [const SerialPortInfo(port: '/dev/ttyUSB0', label: 'ttyUSB0')],
    )..failOpen = true;
    final bridge = SerialBridge(transport: transport, onChanged: () {});
    await bridge.startScan(); // must not throw
    expect(bridge.devices, isEmpty);
  });

  test('a board plugged in after the first scan shows up via the rescan', () async {
    final transport = FakeTransport(const []);
    final bridge = SerialBridge(
      transport: transport,
      onChanged: () {},
      rescanInterval: const Duration(milliseconds: 40),
    );
    await bridge.startScan();
    expect(transport.openCalls, 0);

    // Board plugged in now — the periodic rescan picks it up on its own.
    transport.ports.add(
      const SerialPortInfo(port: '/dev/ttyUSB0', label: 'ttyUSB0'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(transport.openCalls, 1);
    transport.opened.single.feed('{"t":"ann","id":"esp32-abc","name":"ESP"}\n');
    await settle();
    expect(bridge.byId('esp32-abc'), isNotNull);

    await bridge.dispose();
  });

  test('unplugging and replugging the same board rediscovers it', () async {
    final transport = FakeTransport(
      [const SerialPortInfo(port: '/dev/ttyUSB0', label: 'ttyUSB0')],
    );
    final bridge = SerialBridge(
      transport: transport,
      onChanged: () {},
      rescanInterval: const Duration(milliseconds: 40),
    );
    await bridge.startScan();
    final port = transport.opened.single;
    port.feed('{"t":"ann","id":"esp32-abc","name":"ESP"}\n');
    await settle();
    expect(bridge.devices, hasLength(1));

    // Unplug: the read stream closes; the node stays listed but offline.
    await port.close();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(bridge.devices, hasLength(1));
    expect(bridge.devices.single.online, isFalse);

    // Replug: the periodic rescan opens the same port name again and the
    // node re-announces, flipping it back online.
    await _waitFor(() => transport.opened.length >= 2);
    final replugged = transport.opened.last;
    replugged.feed('{"t":"ann","id":"esp32-abc","name":"ESP"}\n');
    await settle();
    expect(bridge.byId('esp32-abc'), isNotNull);
    expect(bridge.byId('esp32-abc')!.online, isTrue);

    await bridge.dispose();
  });
}
