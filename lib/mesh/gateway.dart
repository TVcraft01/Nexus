import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'mesh_service.dart';

/// Localhost gateway that lets a companion process (the Linux FUSE mount,
/// `tools/nexusfs.py`) browse and read files on paired devices through the
/// app's own mesh — no reimplementation of the crypto or addressing.
///
/// Bound to loopback and protected by a random per-launch token (kept in the
/// store, which the mount script reads), so nothing else on the machine can
/// use it. Protocol: newline-delimited JSON, one request per line:
///
///   {"token": "...", "cmd": "devices"}                       -> device list
///   {"token": "...", "cmd": "list", "device": id, "path": p} -> dir listing
///   {"token": "...", "cmd": "get",  "device": id, "path": p,
///    "offset": o, "length": n}                               -> byte range
///   {"token": "...", "cmd": "del",  "device": id, "path": p}       -> delete file
///   {"token": "...", "cmd": "op",   "device": id, "operation": op,
///    "source": p, "destination": p}                              -> move/copy/rename/mkdir
///   {"token": "...", "cmd": "put",  "device": id, "local": p,
///    "destination": p}                                           -> upload exact path
///   {"token": "...", "cmd": "transfer", "sourceDevice": id,
///    "source": p, "destinationDevice": id, "destination": p,
///    "operation": "copy"|"move"}                                -> cross-device file transfer
///
/// Every response is a single JSON object on its own line.
class MeshGateway {
  final MeshService mesh;
  final String token;
  final int port;
  ServerSocket? _server;
  final _bufs = <Socket, BytesBuilder>{};
  bool _stopped = false;

  MeshGateway({required this.mesh, required this.token, required this.port});

  static String newToken() {
    final rng = Random.secure();
    return List.generate(32, (_) => rng.nextInt(16).toRadixString(16)).join();
  }

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    _server!.listen(_onClient, onError: (_) {});
  }

  Future<void> stop() async {
    _stopped = true;
    await _server?.close();
    _server = null;
  }

  void _onClient(Socket socket) {
    _bufs[socket] = BytesBuilder(copy: false);
    socket.listen(
      (chunk) {
        final buf = _bufs[socket]!..add(chunk);
        final text = String.fromCharCodes(buf.toBytes());
        final lines = text.split('\n');
        _bufs[socket] = BytesBuilder(copy: false)
          ..add(utf8.encode(lines.removeLast()));
        for (final line in lines) {
          if (line.trim().isEmpty) continue;
          unawaited(_respond(socket, line));
        }
      },
      onError: (_) => _drop(socket),
      onDone: () => _drop(socket),
    );
  }

  void _drop(Socket socket) {
    _bufs.remove(socket);
    socket.destroy();
  }

  Future<void> _respond(Socket socket, String line) async {
    final Map<String, dynamic> req;
    try {
      req = (jsonDecode(line) as Map<String, dynamic>?) ?? const {};
    } catch (_) {
      _write(socket, {'ok': false, 'error': 'bad request'});
      return;
    }
    if (req['token'] != token) {
      await _write(socket, {'ok': false, 'error': 'unauthorized'});
      socket.destroy();
      return;
    }
    final cmd = req['cmd'] as String?;
    switch (cmd) {
      case 'devices':
        await _write(socket, {
          'ok': true,
          'devices': [
            for (final d in mesh.pairedDevices)
              {
                'id': d.id,
                'name': d.name,
                'platform': d.platform,
                'online': mesh.isOnline(d.id),
              },
          ],
        });
        return;
      case 'list':
        final device = _device(req);
        if (device == null) {
          await _write(socket, {'ok': false, 'error': 'unknown device'});
          return;
        }
        final path = (req['path'] as String?) ?? '';
        final entries = await mesh.listRemoteFiles(device, path);
        if (entries == null) {
          await _write(socket, {
            'ok': false,
            'error': mesh.lastFileError ?? 'could not read',
          });
          return;
        }
        await _write(socket, {
          'ok': true,
          'entries': [
            for (final e in entries)
              {
                'name': e.name,
                'path': e.path,
                'size': e.size,
                'dir': e.isDir,
                'modified': e.modified.toIso8601String(),
              },
          ],
        });
        return;
      case 'get':
        final device = _device(req);
        if (device == null) {
          await _write(socket, {'ok': false, 'error': 'unknown device'});
          return;
        }
        final path = (req['path'] as String?) ?? '';
        final offset = (req['offset'] as num?)?.toInt() ?? 0;
        final length = (req['length'] as num?)?.toInt() ?? 0;
        if (length <= 0) {
          await _write(socket, {
            'ok': false,
            'error': 'length must be positive',
          });
          return;
        }
        final data = await mesh.pullRemoteRange(
          device,
          path,
          offset: offset,
          length: length,
        );
        if (data == null) {
          await _write(socket, {
            'ok': false,
            'error': mesh.lastFileError ?? 'could not read',
          });
          return;
        }
        await _write(socket, {'ok': true, 'data': base64Encode(data)});
        return;
      case 'del':
        final device = _device(req);
        if (device == null) {
          await _write(socket, {'ok': false, 'error': 'unknown device'});
          return;
        }
        final path = (req['path'] as String?) ?? '';
        final ok = await mesh.deleteRemoteFile(device, path);
        await _write(
          socket,
          ok
              ? {'ok': true}
              : {
                  'ok': false,
                  'error': mesh.lastFileError ?? 'could not delete',
                },
        );
        return;
      case 'op':
        final device = _device(req);
        if (device == null) {
          await _write(socket, {'ok': false, 'error': 'unknown device'});
          return;
        }
        final operation = req['operation'] as String?;
        if (operation == null ||
            !const {'rename', 'move', 'copy', 'mkdir'}.contains(operation)) {
          await _write(socket, {
            'ok': false,
            'error': 'invalid file operation',
          });
          return;
        }
        final result = await mesh.operateRemoteFile(
          device,
          operation: operation,
          source: (req['source'] as String?) ?? '',
          destination: (req['destination'] as String?) ?? '',
        );
        await _write(
          socket,
          result != null
              ? {'ok': true, 'path': result}
              : {
                  'ok': false,
                  'error': mesh.lastFileError ?? 'could not complete operation',
                },
        );
        return;
      case 'put':
        final device = _device(req);
        final local = req['local'] as String?;
        final destination = req['destination'] as String?;
        if (device == null || local == null || destination == null) {
          await _write(socket, {
            'ok': false,
            'error': 'invalid upload request',
          });
          return;
        }
        final result = await mesh.pushLocalFile(
          device,
          local,
          destinationPath: destination,
          overwrite: req['overwrite'] == true,
        );
        await _write(
          socket,
          result != null
              ? {'ok': true, 'path': result}
              : {
                  'ok': false,
                  'error': mesh.lastFileError ?? 'could not upload file',
                },
        );
        return;
      case 'transfer':
        final source = _deviceById(req['sourceDevice'] as String?);
        final target = _deviceById(req['destinationDevice'] as String?);
        final sourcePath = req['source'] as String?;
        final destination = req['destination'] as String?;
        final operation = req['operation'] as String?;
        if (source == null ||
            target == null ||
            sourcePath == null ||
            destination == null ||
            (operation != 'copy' && operation != 'move')) {
          await _write(socket, {
            'ok': false,
            'error': 'invalid transfer request',
          });
          return;
        }
        if (source.id == target.id) {
          final result = await mesh.operateRemoteFile(
            source,
            operation: operation!,
            source: sourcePath,
            destination: destination,
          );
          await _write(
            socket,
            result != null
                ? {'ok': true, 'path': result}
                : {
                    'ok': false,
                    'error':
                        mesh.lastFileError ?? 'could not complete operation',
                  },
          );
          return;
        }
        final result = await _transfer(
          source,
          target,
          sourcePath,
          destination,
          operation! == 'move',
        );
        await _write(
          socket,
          result != null
              ? {'ok': true, 'path': result}
              : {
                  'ok': false,
                  'error': mesh.lastFileError ?? 'could not transfer file',
                },
        );
        return;
      default:
        await _write(socket, {'ok': false, 'error': 'unknown command'});
        return;
    }
  }

  PairedDevice? _device(Map<String, dynamic> req) =>
      _deviceById(req['device'] as String?);

  PairedDevice? _deviceById(String? id) {
    if (id == null) return null;
    for (final d in mesh.pairedDevices) {
      if (d.id == id) return d;
    }
    return null;
  }

  Future<String?> _transfer(
    PairedDevice source,
    PairedDevice target,
    String sourcePath,
    String destination,
    bool move,
  ) => mesh.transferRemoteFile(
    source,
    sourcePath,
    target,
    destination,
    move: move,
  );

  Future<void> _write(Socket socket, Map<String, dynamic> json) async {
    if (_stopped) return;
    try {
      socket.add(utf8.encode('${jsonEncode(json)}\n'));
      await socket.flush();
    } catch (_) {
      _drop(socket);
    }
  }
}
