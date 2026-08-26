import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart'
    show EventChannel, MethodChannel;

/// A physical serial port a microcontroller could be plugged into.
class SerialPortInfo {
  final String port; // e.g. /dev/ttyUSB0 on Linux, a USB device id on Android
  final String label; // human-readable name shown in the UI

  const SerialPortInfo({required this.port, required this.label});

  @override
  bool operator ==(Object other) =>
      other is SerialPortInfo && other.port == port;

  @override
  int get hashCode => port.hashCode;
}

/// An opened serial connection. Read side delivers raw bytes; callers feed
/// them into [SerialLineDecoder]. Write side sends raw bytes.
abstract class SerialPort {
  /// Stream of bytes read from the device. Backpressure-free: the platform
  /// transports (Linux `cat`, Android broadcast) deliver what they get.
  Stream<List<int>> get bytes;

  /// Whether the port is still believed to be open.
  bool get isOpen;

  /// Write raw bytes to the device.
  Future<void> write(List<int> data);

  /// Close the port and release it.
  Future<void> close();
}

/// Finds and opens serial ports on this machine.
abstract class SerialTransport {
  /// Lists candidate serial ports. A plain microcontroller board plugged in
  /// over USB shows up as /dev/ttyUSB* or /dev/ttyACM* on Linux and as a
  /// CDC-ACM device on Android.
  Future<List<SerialPortInfo>> listPorts();

  /// Opens [info] at [baudRate] (8N1). Throws on failure.
  Future<SerialPort> open(SerialPortInfo info, {int baudRate = 115200});
}

/// Linux serial transport, zero extra dependencies.
///
/// - Enumeration scans `/dev/ttyUSB*` and `/dev/ttyACM*` (the names Linux
///   gives USB serial adapters and native-USB boards like the ESP32-S3).
/// - Configuration uses the `stty` tool that ships with every Linux.
/// - Reads stream from a spawned `cat` on the port; writes go through a
///   `RandomAccessFile` on the same device (Linux allows both).
class LinuxSerialTransport implements SerialTransport {
  /// Where to look for device nodes. Injectable for tests.
  final String devDir;
  final Future<ProcessResult> Function(String, List<String>) _run;
  final Future<Process> Function(String, List<String>) _start;
  final File Function(String) _openFile;

  LinuxSerialTransport({
    this.devDir = '/dev',
    Future<ProcessResult> Function(String, List<String>)? run,
    Future<Process> Function(String, List<String>)? start,
    File Function(String)? openFile,
  }) : _run = run ?? Process.run,
       _start = start ?? Process.start,
       _openFile = openFile ?? File.new;

  @override
  Future<List<SerialPortInfo>> listPorts() async {
    final dir = Directory(devDir);
    final out = <SerialPortInfo>[];
    try {
      await for (final e in dir.list(followLinks: false)) {
        final name = e.path.split('/').last;
        if (name.startsWith('ttyUSB') || name.startsWith('ttyACM')) {
          out.add(SerialPortInfo(port: e.path, label: name));
        }
      }
    } catch (_) {
      // /dev may not exist (container, non-Linux) — nothing to list.
    }
    out.sort((a, b) => a.port.compareTo(b.port));
    return out;
  }

  @override
  Future<SerialPort> open(SerialPortInfo info, {int baudRate = 115200}) async {
    final path = info.port;
    final cfg = await _run('stty', ['-F', path, '$baudRate', 'raw', '-echo']);
    if (cfg.exitCode != 0) {
      throw StateError('stty failed on $path: ${cfg.stderr}');
    }
    final cat = await _start('cat', [path]);
    final file = _openFile(path).openSync(mode: FileMode.writeOnly);
    return LinuxSerialPort._(path: path, read: cat, file: file);
  }
}

class LinuxSerialPort implements SerialPort {
  final String path;
  final Process _cat;
  final RandomAccessFile _file;
  bool _closed = false;

  LinuxSerialPort._({
    required this.path,
    required Process read,
    required this._file,
  }) : _cat = read;

  @override
  Stream<List<int>> get bytes => _cat.stdout;

  @override
  bool get isOpen => !_closed;

  @override
  Future<void> write(List<int> data) async {
    if (_closed) return;
    await _file.writeFrom(data);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      _cat.kill();
    } catch (_) {}
    await _file.close();
  }
}

/// Android USB-OTG serial transport.
///
/// Talks to the native side (MainActivity) over the `dev.nexus.nexus/usb_serial`
/// channel for commands and the `dev.nexus.nexus/usb_serial_events` event
/// channel for streamed bytes. The native side enumerates USB CDC-ACM
/// devices, asks the user for permission to open them, and pushes bytes as
/// `{deviceId, data}` events (data is base64).
class AndroidUsbSerialTransport implements SerialTransport {
  static const _channel = MethodChannel('dev.nexus.nexus/usb_serial');
  static const _events = EventChannel('dev.nexus.nexus/usb_serial_events');

  final Stream<dynamic> _eventStream;
  AndroidUsbSerialTransport._(this._eventStream);

  factory AndroidUsbSerialTransport.defaultInstance() =>
      AndroidUsbSerialTransport._(_events.receiveBroadcastStream());

  final Map<String, _AndroidPort> _ports = {};
  StreamSubscription<dynamic>? _sub;

  @override
  Future<List<SerialPortInfo>> listPorts() async {
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('list') ?? const [];
      return raw
          .whereType<Map<dynamic, dynamic>>()
          .map((m) => SerialPortInfo(
                port: m['deviceId'].toString(),
                label: (m['name'] as String?) ?? 'USB device',
              ))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<SerialPort> open(SerialPortInfo info, {int baudRate = 115200}) async {
    final ok = await _channel.invokeMethod<bool>('open', {
      'deviceId': int.tryParse(info.port) ?? 0,
      'baudRate': baudRate,
    });
    if (ok != true) throw StateError('Could not open USB device ${info.label}');
    final port = _AndroidPort(info.port, this);
    _ports[info.port] = port;
    _sub ??= _eventStream.listen((event) {
      if (event is Map) {
        final deviceId = event['deviceId']?.toString();
        final data = event['data'] as String?;
        if (deviceId != null && data != null) {
          _ports[deviceId]?._onData(base64Decode(data));
        } else if (event['disconnected'] == true && deviceId != null) {
          _ports.remove(deviceId);
        }
      }
    });
    return port;
  }

  void _close(String deviceId) => _ports.remove(deviceId);
}

class _AndroidPort implements SerialPort {
  final String deviceId;
  final AndroidUsbSerialTransport _transport;
  final StreamController<List<int>> _bytes = StreamController.broadcast();
  bool _closed = false;

  _AndroidPort(this.deviceId, this._transport);

  void _onData(List<int> bytes) {
    if (!_closed) _bytes.add(bytes);
  }

  @override
  Stream<List<int>> get bytes => _bytes.stream;

  @override
  bool get isOpen => !_closed;

  @override
  Future<void> write(List<int> data) async {
    if (_closed) return;
    try {
      await AndroidUsbSerialTransport._channel.invokeMethod('write', {
        'deviceId': deviceId,
        'data': base64Encode(data),
      });
    } catch (_) {}
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _bytes.close();
    try {
      await AndroidUsbSerialTransport._channel.invokeMethod('close', {'deviceId': deviceId});
    } catch (_) {}
    _transport._close(deviceId);
  }
}
