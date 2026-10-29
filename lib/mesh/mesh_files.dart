part of 'mesh_service.dart';

/// Remote file access: listing, reading, writing, moving and deleting files
/// on this device for a paired peer, plus the requesting half the Files tab
/// and the assistant's `file.fetch` both go through.
///
/// Split out of `mesh_service.dart` without touching the code. Everything a
/// transfer needs while it is in flight lives here; the peer, the socket and
/// the session key it rides on stay shared on [_MeshBase].

class _FilePull {
  final String savePath;
  final String peerName;
  final void Function(int received, int total)? onProgress;
  final Completer<File?> done = Completer<File?>();
  RandomAccessFile? sink;
  int received = 0;
  int total = 0;
  Timer? watchdog;

  /// Chunks arrive as separately-dispatched frames and can overlap; all disk
  /// writes go through this chain so a second write never starts mid-write.
  Future<void> chain = Future.value();

  _FilePull({required this.savePath, required this.peerName, this.onProgress});
}

/// State of one in-flight file transfer arriving on this device. Mirrors
/// [_FilePull] on the receiving side: chunks overlap, so all writes go
/// through [chain]; on the final chunk the file is closed and an ack is sent
/// back so the sender knows it landed.
class _FilePush {
  final String name; // sanitized basename, safe to write under [dir]
  final String dir; // the "Nexus Incoming" folder under the served root
  final String peerName;
  final bool overwrite;
  RandomAccessFile? sink;
  String savedPath = '';
  int received = 0;
  int total = 0;
  Timer? watchdog;
  Future<void> chain = Future.value();

  _FilePush({
    required this.name,
    required this.dir,
    required this.peerName,
    this.overwrite = false,
  });
}

/// Small abstraction over the platform clipboard so the mesh logic can be
/// unit-tested without a device.

mixin _MeshFiles on _MeshBase {
  /// Why the last file request failed ("could not reach", "access denied",
  /// timeouts). Read by the Files UI to show an honest error, and by the
  /// file-fetch seam ([FileFetchMesh]) to tell a local save failure apart
  /// from a transfer one.
  @override
  String? lastFileError;

  final Map<String, Completer<List<FileEntry>?>> _pendingLists =
      {}; // req -> list
  final Map<String, _FilePull> _pendingPulls = {}; // req -> download state
  final Map<String, _FilePush> _incomingPushes = {}; // req -> upload state
  Future<void> _filePushChain = Future.value();
  final Map<String, Completer<String?>> _outgoingPushes =
      {}; // req -> saved path on peer
  final Map<String, Completer<Uint8List?>> _pendingRanges =
      {}; // req -> byte range read
  final Map<String, Completer<bool>> _pendingDeletes = {}; // req -> deleted ok?
  final Map<String, Completer<String?>> _pendingOperations =
      {}; // req -> result path

  // ---------------------------------------------------------------------
  // Remote file access (encrypted, served from this device's home folder)
  // ---------------------------------------------------------------------

  /// The folder this device serves. Desktop: the home directory. Android:
  /// the real shared storage when the user granted "All files access" (so the
  /// PC file manager sees every photo, download and music file), otherwise
  /// the app's own external dir. Tests inject their own root; a non-empty
  /// `NEXUS_SERVED_ROOT` env var overrides the default too, so an unattended
  /// harness can serve a scratch directory instead of the real home.
  Future<String> _servedRoot() async =>
      (await storage.serveRoot(override: fileRoot)).path;

  /// Maps a peer-supplied path onto the served root, collapsing `.`/`..` and
  /// refusing anything that escapes the root. Returns null = access denied.
  String? _resolveServedPath(String path, String root) {
    final separator = Platform.pathSeparator;
    final requested = path.replaceAll(separator == '/' ? '\\' : '/', separator);
    if (requested.isEmpty || requested == separator) return root;
    // Relative destinations are rooted in the shared folder. Normalize after
    // anchoring so `../` cannot be used to escape it.
    final candidate = requested.startsWith(separator)
        ? requested
        : '$root$separator$requested';
    final clean = _normalizePath(candidate);
    if (clean != root && !clean.startsWith('$root$separator')) return null;
    return clean;
  }

  static String _normalizePath(String path) {
    final parts = <String>[];
    for (final seg in path.split(Platform.pathSeparator)) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') {
        if (parts.isNotEmpty) parts.removeLast();
      } else {
        parts.add(seg);
      }
    }
    final prefix = path.startsWith(Platform.pathSeparator)
        ? Platform.pathSeparator
        : '';
    return prefix + parts.join(Platform.pathSeparator);
  }

  /// Lexical containment is not enough when a user-created symlink points
  /// outside the shared root. Existing path segments must resolve inside it;
  /// a missing leaf is checked through its nearest existing parent.
  Future<bool> _isInsideServedRoot(String path, String root) async {
    try {
      final realRoot = await Directory(root).resolveSymbolicLinks();
      var candidate = path;
      while (FileSystemEntity.typeSync(candidate) ==
          FileSystemEntityType.notFound) {
        final parent = Directory(candidate).parent.path;
        if (parent == candidate) return false;
        candidate = parent;
      }
      final realCandidate =
          FileSystemEntity.typeSync(candidate) == FileSystemEntityType.directory
          ? await Directory(candidate).resolveSymbolicLinks()
          : await File(candidate).resolveSymbolicLinks();
      return realCandidate == realRoot ||
          realCandidate.startsWith('$realRoot${Platform.pathSeparator}');
    } catch (_) {
      return false;
    }
  }

  Future<void> _handleFileListRequest(NexusMessage msg) async {
    final req = msg.payload['req'];
    final peer = _paired[msg.from];
    if (peer == null || req is! String) return;
    if (!store.fileShare) {
      await _sendFileError(peer, req, 'File sharing is off on this device.');
      return;
    }
    final path = msg.payload['path'] as String? ?? '';
    final root = await _servedRoot();
    final resolved = _resolveServedPath(path, root);
    if (resolved == null || !await _isInsideServedRoot(resolved, root)) {
      await _sendFileError(
        peer,
        req,
        'Access denied — that folder is outside your home directory.',
      );
      return;
    }
    final entries = await _listDir(resolved);
    if (entries == null) {
      await _sendFileError(
        peer,
        req,
        lastFileError ?? 'Could not read that folder.',
      );
      return;
    }
    await _sendEnc(
      peer,
      NexusMessage(
        type: NexusMessage.fileListResult,
        from: identity.id,
        to: peer.id,
        payload: {
          'req': req,
          'entries': entries
              .map(
                (e) => {
                  'name': e.name,
                  'path': e.path,
                  'size': e.size,
                  'dir': e.isDir,
                  'modified': e.modified.toIso8601String(),
                },
              )
              .toList(),
        },
        id: _newId(),
        ts: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  /// Lists [resolved] (a path already validated against the served root),
  /// skipping unreadable entries. Returns null on failure — [lastFileError]
  /// says why.
  Future<List<FileEntry>?> _listDir(String resolved) async {
    try {
      final dir = Directory(resolved);
      if (!await dir.exists()) {
        lastFileError = 'That folder does not exist on this device.';
        return null;
      }
      final children = await dir.list().toList();
      final listed = <FileEntry>[];
      for (final child in children) {
        try {
          final isDir = child is Directory;
          final stat = await child.stat();
          final segments = child.path
              .split(Platform.pathSeparator)
              .where((s) => s.isNotEmpty)
              .toList();
          listed.add(
            FileEntry(
              name: segments.isEmpty ? child.path : segments.last,
              path: child.path,
              size: isDir ? 0 : stat.size,
              isDir: isDir,
              modified: stat.modified,
            ),
          );
        } catch (_) {
          // Unreadable entry (permission, vanished mid-listing) — skip it.
        }
      }
      listed.sort((a, b) {
        if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      return listed;
    } catch (_) {
      lastFileError = 'Could not read that folder.';
      return null;
    }
  }

  Future<void> _handleFileGetRequest(NexusMessage msg) async {
    final req = msg.payload['req'];
    final peer = _paired[msg.from];
    if (peer == null || req is! String) return;
    if (!store.fileShare) {
      await _sendFileError(peer, req, 'File sharing is off on this device.');
      return;
    }
    final path = msg.payload['path'] as String? ?? '';
    final root = await _servedRoot();
    final resolved = _resolveServedPath(path, root);
    if (resolved == null || !await _isInsideServedRoot(resolved, root)) {
      await _sendFileError(
        peer,
        req,
        'Access denied — that file is outside your home directory.',
      );
      return;
    }
    RandomAccessFile raf;
    try {
      raf = await File(resolved).open();
    } catch (_) {
      await _sendFileError(peer, req, 'Could not open that file.');
      return;
    }
    try {
      final total = await raf.length();
      final offset = (msg.payload['offset'] as num?)?.toInt() ?? 0;
      final length = (msg.payload['length'] as num?)?.toInt() ?? 0;
      if (offset < 0 || length < 0) {
        await _sendFileError(peer, req, 'That byte range is not valid.');
        return;
      }
      if (length > 0) {
        // Range read (the FUSE gateway asks for exact byte ranges when the
        // file manager reads a file): one seeked chunk, done — no stream.
        try {
          if (offset > 0) await raf.setPosition(offset);
          final data = await raf.read(length);
          await _sendEnc(
            peer,
            NexusMessage(
              type: NexusMessage.fileChunk,
              from: identity.id,
              to: peer.id,
              payload: {
                'req': req,
                'offset': offset,
                'data': base64Encode(data),
                'total': length,
                'done': true,
              },
              id: _newId(),
              ts: DateTime.now().millisecondsSinceEpoch,
            ),
          );
        } catch (_) {
          await _sendFileError(peer, req, 'Could not read that range.');
        }
        return;
      }
      // Whole-file stream in 256 KiB chunks — small enough to stay well under
      // the 1 MiB frame guard, large enough that big files don't become a
      // message zoo.
      const chunkSize = 256 * 1024;
      var sent = 0;
      while (true) {
        final data = await raf.read(chunkSize);
        final done = sent + data.length >= total;
        final ok = await _sendEnc(
          peer,
          NexusMessage(
            type: NexusMessage.fileChunk,
            from: identity.id,
            to: peer.id,
            payload: {
              'req': req,
              'offset': sent,
              'data': base64Encode(data),
              'total': total,
              'done': done,
            },
            id: _newId(),
            ts: DateTime.now().millisecondsSinceEpoch,
          ),
        );
        if (!ok) break; // peer went away mid-transfer
        sent += data.length;
        if (done) break;
      }
    } catch (_) {
      await _sendFileError(peer, req, 'The file changed while reading it.');
    } finally {
      await raf.close();
    }
  }

  Future<void> _sendFileError(
    PairedDevice peer,
    String req,
    String message,
  ) async {
    lastFileError = message;
    await _sendEnc(
      peer,
      NexusMessage(
        type: NexusMessage.fileError,
        from: identity.id,
        to: peer.id,
        payload: {'req': req, 'message': message},
        id: _newId(),
        ts: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  Future<void> _handleFileListResult(NexusMessage msg) async {
    final req = msg.payload['req'];
    final completer = req is String ? _pendingLists.remove(req) : null;
    if (completer == null) return;
    final raw = (msg.payload['entries'] as List?) ?? const [];
    final entries = raw
        .whereType<Map<String, dynamic>>()
        .map(
          (e) => FileEntry(
            name: e['name'] as String? ?? '?',
            path: e['path'] as String? ?? '',
            size: (e['size'] as num?)?.toInt() ?? 0,
            isDir: e['dir'] == true,
            modified:
                DateTime.tryParse(e['modified'] as String? ?? '') ??
                DateTime.fromMillisecondsSinceEpoch(0),
          ),
        )
        .toList();
    if (!completer.isCompleted) completer.complete(entries);
  }

  Future<void> _handleFileChunk(NexusMessage msg) async {
    final req = msg.payload['req'];
    if (req is! String) return;
    // A range request gets exactly one chunk — hand it straight to the
    // caller (the FUSE gateway) instead of a pull state machine.
    final range = _pendingRanges.remove(req);
    if (range != null) {
      final data = base64Decode(msg.payload['data'] as String? ?? '');
      if (!range.isCompleted) range.complete(data);
      return;
    }
    final pull = _pendingPulls[req];
    if (pull == null) return;
    pull.chain = pull.chain.then((_) => _applyChunk(pull, req, msg));
    await pull.chain.catchError((_) {});
  }

  Future<void> _applyChunk(_FilePull pull, String req, NexusMessage msg) async {
    final data = base64Decode(msg.payload['data'] as String? ?? '');
    final total = (msg.payload['total'] as num?)?.toInt() ?? 0;
    final done = msg.payload['done'] == true;
    try {
      pull.sink ??= await File(pull.savePath).open(mode: FileMode.write);
      if (data.isNotEmpty) {
        await pull.sink!.writeFrom(data);
        pull.received += data.length;
      }
      if (pull.total == 0) pull.total = total;
      pull.onProgress?.call(pull.received, pull.total);
      // Any chunk proves the peer is alive — reset the watchdog.
      pull.watchdog?.cancel();
      pull.watchdog = Timer(const Duration(seconds: 15), () {
        _failPull(
          req,
          'The transfer stalled — the connection to ${pull.peerName} was lost.',
        );
      });
      if (done) {
        await pull.sink!.flush();
        await pull.sink!.close();
        pull.sink = null;
        pull.watchdog?.cancel();
        _pendingPulls.remove(req);
        if (!pull.done.isCompleted) pull.done.complete(File(pull.savePath));
      }
    } catch (e) {
      _failPull(req, 'Could not save the file: $e');
    }
  }

  /// First frame of an incoming push carries the file name; every frame
  /// carries data. Frames are dispatched concurrently, so all disk writes
  /// chain onto the push's [chain] — the same serialization that fixed the
  /// pull-side overlap bug.
  Future<void> _handleFilePush(NexusMessage msg) async {
    _filePushChain = _filePushChain.then((_) => _handleFilePushNow(msg));
    await _filePushChain.catchError((_) {});
  }

  Future<void> _handleFilePushNow(NexusMessage msg) async {
    final req = msg.payload['req'];
    final peer = _paired[msg.from];
    if (peer == null || req is! String) return;
    if (!store.fileShare) {
      await _sendFileError(peer, req, 'File sharing is off on this device.');
      return;
    }
    var push = _incomingPushes[req];
    if (push == null) {
      final name = (msg.payload['name'] as String?) ?? '';
      final root = await _servedRoot();
      final requestedDestination = msg.payload['destination'] as String?;
      final destination = requestedDestination == null
          ? '$root${Platform.pathSeparator}Nexus Incoming${Platform.pathSeparator}$name'
          : _resolveServedPath(requestedDestination, root);
      if (destination == null ||
          destination == root ||
          (requestedDestination == null && !_safeIncomingName(name))) {
        await _sendFileError(
          peer,
          req,
          'Access denied — invalid destination path.',
        );
        return;
      }
      final incomingDirectory = Directory(
        '$root${Platform.pathSeparator}Nexus Incoming',
      );
      final containmentPath = requestedDestination == null
          ? incomingDirectory
          : FileSystemEntity.typeSync(destination) !=
                FileSystemEntityType.notFound
          ? File(destination)
          : Directory(destination).parent;
      if (await containmentPath.exists() &&
          !await _isInsideServedRoot(containmentPath.path, root)) {
        await _sendFileError(
          peer,
          req,
          'Access denied — invalid destination path.',
        );
        return;
      }
      final destinationName = destination.split(Platform.pathSeparator).last;
      if (!_safeIncomingName(destinationName)) {
        await _sendFileError(peer, req, 'Refused file with an invalid name.');
        return;
      }
      push = _FilePush(
        name: destinationName,
        dir: Directory(destination).parent.path,
        peerName: peer.name,
        overwrite: msg.payload['overwrite'] == true,
      );
      _incomingPushes[req] = push;
    }
    final active = push;
    active.chain = active.chain.then(
      (_) => _applyPushChunk(active, peer, req, msg),
    );
    await active.chain.catchError((_) {});
  }

  Future<void> _applyPushChunk(
    _FilePush push,
    PairedDevice peer,
    String req,
    NexusMessage msg,
  ) async {
    final data = base64Decode(msg.payload['data'] as String? ?? '');
    final total = (msg.payload['total'] as num?)?.toInt() ?? 0;
    final done = msg.payload['done'] == true;
    try {
      push.sink ??= await _openIncoming(push);
      if (data.isNotEmpty) {
        await push.sink!.writeFrom(data);
        push.received += data.length;
      }
      if (push.total == 0) push.total = total;
      // Any chunk proves the sender is alive — reset the watchdog.
      push.watchdog?.cancel();
      push.watchdog = Timer(const Duration(seconds: 15), () {
        _failPush(
          peer,
          req,
          'The transfer stalled — the connection to ${push.peerName} was lost.',
        );
      });
      if (done) {
        await push.sink!.flush();
        await push.sink!.close();
        push.sink = null;
        push.watchdog?.cancel();
        _incomingPushes.remove(req);
        await _sendEnc(
          peer,
          NexusMessage(
            type: NexusMessage.filePushAck,
            from: identity.id,
            to: peer.id,
            payload: {'req': req, 'path': push.savedPath},
            id: _newId(),
            ts: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      }
    } catch (e) {
      _failPush(peer, req, 'Could not save the file: $e');
    }
  }

  /// A file name may only be a plain basename — anything with path separators
  /// or dot-dots is refused so a push can never escape the incoming folder.
  static bool _safeIncomingName(String name) {
    if (name.isEmpty || name == '.' || name == '..') return false;
    if (name.contains('/') || name.contains('\\')) return false;
    return true;
  }

  /// Opens the destination file under the incoming folder, creating the
  /// folder if needed and giving collisions a `(n)` suffix (like downloads).
  Future<RandomAccessFile> _openIncoming(_FilePush push) async {
    await Directory(push.dir).create(recursive: true);
    final path = '${push.dir}${Platform.pathSeparator}${push.name}';
    final existing = FileSystemEntity.typeSync(path);
    if (existing != FileSystemEntityType.notFound) {
      if (!push.overwrite || existing == FileSystemEntityType.directory) {
        throw StateError('A file with that name already exists.');
      }
      await File(path).delete();
    }
    push.savedPath = path;
    return File(path).open(mode: FileMode.write);
  }

  void _failPush(PairedDevice peer, String req, String message) {
    final push = _incomingPushes.remove(req);
    if (push == null) return;
    push.watchdog?.cancel();
    push.sink?.close().catchError((_) {});
    push.sink = null;
    unawaited(_sendFileError(peer, req, message));
  }

  Future<void> _handleFileError(NexusMessage msg) async {
    final req = msg.payload['req'];
    final message =
        (msg.payload['message'] as String?) ??
        'The device refused the request.';
    final pull = req is String ? _pendingPulls.remove(req) : null;
    if (pull != null) {
      pull.watchdog?.cancel();
      pull.sink?.close().catchError((_) {});
      pull.sink = null;
      lastFileError = message;
      if (!pull.done.isCompleted) pull.done.complete(null);
      return;
    }
    final push = req is String ? _outgoingPushes.remove(req) : null;
    if (push != null) {
      lastFileError = message;
      if (!push.isCompleted) push.complete(null);
      return;
    }
    final completer = req is String ? _pendingLists.remove(req) : null;
    if (completer != null) {
      lastFileError = message;
      if (!completer.isCompleted) completer.complete(null);
    }
    final del = req is String ? _pendingDeletes.remove(req) : null;
    if (del != null) {
      lastFileError = message;
      if (!del.isCompleted) del.complete(false);
      return;
    }
    final operation = req is String ? _pendingOperations.remove(req) : null;
    if (operation != null) {
      lastFileError = message;
      if (!operation.isCompleted) operation.complete(null);
    }
  }

  Future<void> _handleFilePushAck(NexusMessage msg) async {
    final req = msg.payload['req'];
    final completer = req is String ? _outgoingPushes.remove(req) : null;
    if (completer == null) return;
    final saved = msg.payload['path'] as String?;
    if (!completer.isCompleted) completer.complete(saved);
  }

  /// Deletes a file (or empty folder) on this device at the peer's request.
  /// The path must resolve inside the served root — the same sandbox that
  /// governs listing and reading — and the root itself is never deletable.
  Future<void> _handleFileOperation(NexusMessage msg) async {
    final req = msg.payload['req'];
    final peer = _paired[msg.from];
    if (peer == null || req is! String) return;
    if (!store.fileShare) {
      await _sendFileError(peer, req, 'File sharing is off on this device.');
      return;
    }
    final operation = msg.payload['operation'] as String?;
    final source = msg.payload['source'] as String? ?? '';
    final destination = msg.payload['destination'] as String? ?? '';
    final root = await _servedRoot();
    final sourcePath = _resolveServedPath(source, root);
    final destinationPath = _resolveServedPath(destination, root);
    final destinationName =
        destinationPath?.split(Platform.pathSeparator).last ?? '';
    if (destinationPath == null ||
        destinationPath == root ||
        !_safeIncomingName(destinationName) ||
        (operation != 'mkdir' && (sourcePath == null || sourcePath == root))) {
      await _sendFileError(
        peer,
        req,
        'Access denied — the path is outside the shared folder.',
      );
      return;
    }
    if (!await _isInsideServedRoot(destinationPath, root) ||
        operation != 'mkdir' && !await _isInsideServedRoot(sourcePath!, root)) {
      await _sendFileError(
        peer,
        req,
        'Access denied — the path is outside the shared folder.',
      );
      return;
    }
    try {
      if (operation == 'mkdir') {
        if (FileSystemEntity.typeSync(destinationPath) !=
            FileSystemEntityType.notFound) {
          await _sendFileError(
            peer,
            req,
            'A file with that name already exists.',
          );
          return;
        }
        await Directory(destinationPath).create(recursive: true);
      } else {
        final sourcePathValue = sourcePath!;
        final sourceType = FileSystemEntity.typeSync(sourcePathValue);
        if (sourceType == FileSystemEntityType.notFound) {
          await _sendFileError(peer, req, 'That file no longer exists.');
          return;
        }
        if (operation == 'rename' || operation == 'move') {
          if (FileSystemEntity.typeSync(destinationPath) !=
              FileSystemEntityType.notFound) {
            await _sendFileError(
              peer,
              req,
              'A file with that name already exists.',
            );
            return;
          }
          if (sourceType == FileSystemEntityType.directory &&
              (destinationPath == sourcePathValue ||
                  destinationPath.startsWith(
                    '$sourcePathValue${Platform.pathSeparator}',
                  ))) {
            await _sendFileError(
              peer,
              req,
              'A folder cannot be moved inside itself.',
            );
            return;
          }
          await Directory(destinationPath).parent.create(recursive: true);
          if (sourceType == FileSystemEntityType.directory) {
            await Directory(sourcePathValue).rename(destinationPath);
          } else {
            await File(sourcePathValue).rename(destinationPath);
          }
        } else if (operation == 'copy') {
          if (FileSystemEntity.typeSync(destinationPath) !=
              FileSystemEntityType.notFound) {
            await _sendFileError(
              peer,
              req,
              'A file with that name already exists.',
            );
            return;
          }
          await Directory(destinationPath).parent.create(recursive: true);
          if (sourceType == FileSystemEntityType.directory) {
            await _copyDirectory(
              Directory(sourcePathValue),
              Directory(destinationPath),
            );
          } else {
            await File(sourcePathValue).copy(destinationPath);
          }
        } else {
          await _sendFileError(peer, req, 'Unsupported file operation.');
          return;
        }
      }
    } catch (_) {
      await _sendFileError(
        peer,
        req,
        'Could not complete that file operation.',
      );
      return;
    }
    await _sendEnc(
      peer,
      NexusMessage(
        type: NexusMessage.fileOperationAck,
        from: identity.id,
        to: peer.id,
        payload: {'req': req, 'path': destinationPath},
        id: _newId(),
        ts: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  Future<void> _copyDirectory(Directory source, Directory destination) async {
    await destination.create(recursive: true);
    await for (final child in source.list()) {
      final name = child.path.split(Platform.pathSeparator).last;
      final target = '${destination.path}${Platform.pathSeparator}$name';
      if (child is Directory) {
        await _copyDirectory(child, Directory(target));
      } else if (child is File) {
        await child.copy(target);
      }
    }
  }

  Future<void> _handleFileDelete(NexusMessage msg) async {
    final req = msg.payload['req'];
    final peer = _paired[msg.from];
    if (peer == null || req is! String) return;
    if (!store.fileShare) {
      await _sendFileError(peer, req, 'File sharing is off on this device.');
      return;
    }
    final path = msg.payload['path'] as String? ?? '';
    final root = await _servedRoot();
    final resolved = _resolveServedPath(path, root);
    if (resolved == null ||
        resolved == root ||
        !await _isInsideServedRoot(resolved, root)) {
      await _sendFileError(
        peer,
        req,
        'Access denied — that is outside the shared folder.',
      );
      return;
    }
    try {
      final entity = FileSystemEntity.typeSync(resolved);
      if (entity == FileSystemEntityType.notFound) {
        await _sendFileError(peer, req, 'That file no longer exists.');
        return;
      }
      if (entity == FileSystemEntityType.directory) {
        if (Directory(resolved).listSync().isNotEmpty) {
          await _sendFileError(peer, req, 'The folder is not empty.');
          return;
        }
        await Directory(resolved).delete();
      } else {
        await File(resolved).delete();
      }
    } catch (_) {
      await _sendFileError(peer, req, 'Could not delete that file.');
      return;
    }
    await _sendEnc(
      peer,
      NexusMessage(
        type: NexusMessage.fileDeleteAck,
        from: identity.id,
        to: peer.id,
        payload: {'req': req},
        id: _newId(),
        ts: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  Future<void> _handleFileDeleteAck(NexusMessage msg) async {
    final req = msg.payload['req'];
    final completer = req is String ? _pendingDeletes.remove(req) : null;
    if (completer != null && !completer.isCompleted) completer.complete(true);
  }

  Future<void> _handleFileOperationAck(NexusMessage msg) async {
    final req = msg.payload['req'];
    final completer = req is String ? _pendingOperations.remove(req) : null;
    if (completer != null && !completer.isCompleted) {
      completer.complete(msg.payload['path'] as String?);
    }
  }

  /// Asks [peer] to perform a filesystem operation on its served root.
  /// [operation] is `rename`, `move`, `copy`, or `mkdir`; [source] is omitted
  /// for `mkdir`. Returns the resulting path or null on failure.
  Future<String?> operateRemoteFile(
    PairedDevice peer, {
    required String operation,
    String source = '',
    required String destination,
  }) async {
    final req = _newId();
    final completer = Completer<String?>();
    _pendingOperations[req] = completer;
    final sent = await _sendEnc(
      peer,
      NexusMessage(
        type: NexusMessage.fileOperation,
        from: identity.id,
        to: peer.id,
        payload: {
          'req': req,
          'operation': operation,
          'source': source,
          'destination': destination,
        },
        id: _newId(),
        ts: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    if (!sent) {
      _pendingOperations.remove(req);
      lastFileError = 'Could not reach ${peer.name}.';
      return null;
    }
    final timer = Timer(const Duration(seconds: 15), () {
      if (!completer.isCompleted) {
        _pendingOperations.remove(req);
        lastFileError = 'Timed out performing that file operation.';
        completer.complete(null);
      }
    });
    final result = await completer.future;
    timer.cancel();
    return result;
  }

  /// Copies or moves a remote file or directory between two paired devices.
  /// Directories are transferred recursively; a move removes the source only
  /// after every child has arrived at the destination.
  Future<String?> transferRemoteFile(
    PairedDevice source,
    String sourcePath,
    PairedDevice target,
    String destinationPath, {
    bool move = false,
  }) async {
    if (source.id == target.id) {
      return operateRemoteFile(
        target,
        operation: move ? 'move' : 'copy',
        source: sourcePath,
        destination: destinationPath,
      );
    }
    final temp = File(
      '${Directory.systemTemp.path}/nexus-transfer-${_newId()}',
    );
    try {
      final entries = await listRemoteFiles(source, sourcePath);
      if (entries != null) {
        final created = await operateRemoteFile(
          target,
          operation: 'mkdir',
          destination: destinationPath,
        );
        if (created == null) return null;
        for (final entry in entries) {
          final childDestination = _joinFilePath(destinationPath, entry.name);
          final copied = await transferRemoteFile(
            source,
            entry.path,
            target,
            childDestination,
            move: move,
          );
          if (copied == null) return null;
        }
        if (move && await deleteRemoteFile(source, sourcePath)) {
          return destinationPath;
        }
        if (move) return null;
        return destinationPath;
      }
      final pulled = await pullRemoteFile(
        source,
        sourcePath,
        savePath: temp.path,
      );
      if (pulled == null) return null;
      final saved = await pushLocalFile(
        target,
        temp.path,
        destinationPath: destinationPath,
      );
      if (saved == null) return null;
      if (move && !await deleteRemoteFile(source, sourcePath)) return null;
      return saved;
    } finally {
      try {
        if (await temp.exists()) await temp.delete();
      } catch (_) {}
    }
  }

  static String _joinFilePath(String directory, String name) {
    if (directory.isEmpty) return name;
    final separator = Platform.pathSeparator;
    return '${directory.endsWith(separator) ? directory.substring(0, directory.length - 1) : directory}$separator$name';
  }

  /// Asks [peer] to delete the file at [path] on its served root. Returns
  /// false on failure — [lastFileError] says why (a folder that is not empty
  /// is refused, so a deleted folder is always an empty one).
  Future<bool> deleteRemoteFile(PairedDevice peer, String path) async {
    final req = _newId();
    final completer = Completer<bool>();
    _pendingDeletes[req] = completer;
    final sent = await _sendEnc(
      peer,
      NexusMessage(
        type: NexusMessage.fileDelete,
        from: identity.id,
        to: peer.id,
        payload: {'req': req, 'path': path},
        id: _newId(),
        ts: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    if (!sent) {
      _pendingDeletes.remove(req);
      lastFileError = 'Could not reach ${peer.name}.';
      return false;
    }
    final timer = Timer(const Duration(seconds: 15), () {
      if (!completer.isCompleted) {
        _pendingDeletes.remove(req);
        lastFileError =
            'Timed out deleting ${path.split(RegExp(r'[/\\]')).last}.';
        completer.complete(false);
      }
    });
    final ok = await completer.future;
    timer.cancel();
    return ok;
  }

  void _failPull(String req, String message) {
    final pull = _pendingPulls.remove(req);
    if (pull == null) return;
    pull.watchdog?.cancel();
    pull.sink?.close().catchError((_) {});
    pull.sink = null;
    lastFileError = message;
    if (!pull.done.isCompleted) pull.done.complete(null);
  }

  /// Requests a directory listing from [peer]. `path` is an absolute path on
  /// the peer ('' or '/' = its home). Returns null on failure — [lastFileError]
  /// says why.
  Future<List<FileEntry>?> listRemoteFiles(
    PairedDevice peer,
    String path,
  ) async {
    final req = _newId();
    final completer = Completer<List<FileEntry>?>();
    _pendingLists[req] = completer;
    final sent = await _sendEnc(
      peer,
      NexusMessage(
        type: NexusMessage.fileList,
        from: identity.id,
        to: peer.id,
        payload: {'req': req, 'path': path},
        id: _newId(),
        ts: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    if (!sent) {
      _pendingLists.remove(req);
      lastFileError = 'Could not reach ${peer.name}.';
      return null;
    }
    final timer = Timer(const Duration(seconds: 15), () {
      if (!completer.isCompleted) {
        _pendingLists.remove(req);
        lastFileError = 'Timed out reading ${path.isEmpty ? 'home' : path}.';
        completer.complete(null);
      }
    });
    final result = await completer.future;
    timer.cancel();
    return result;
  }

  /// Streams a file from [peer] into [savePath], reporting progress via
  /// [onProgress] (received, total). Returns the saved file, or null on
  /// failure — [lastFileError] says why.
  Future<File?> pullRemoteFile(
    PairedDevice peer,
    String path, {
    required String savePath,
    void Function(int received, int total)? onProgress,
  }) async {
    final req = _newId();
    final pull = _FilePull(
      savePath: savePath,
      onProgress: onProgress,
      peerName: peer.name,
    );
    _pendingPulls[req] = pull;
    // Watchdog covers the whole transfer: waiting for the first chunk counts
    // too, and any chunk resets it.
    pull.watchdog = Timer(const Duration(seconds: 15), () {
      _failPull(req, 'Timed out waiting for ${peer.name}.');
    });
    final sent = await _sendEnc(
      peer,
      NexusMessage(
        type: NexusMessage.fileGet,
        from: identity.id,
        to: peer.id,
        payload: {'req': req, 'path': path},
        id: _newId(),
        ts: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    if (!sent) {
      _failPull(req, 'Could not reach ${peer.name}.');
    }
    return pull.done.future;
  }

  // --- File-fetch seam (core/file_fetch.dart) ------------------------------
  // The assistant's `file.fetch` runs on the requesting device and pulls
  // through these two primitives, so the transfer is exactly the one the
  // Files tab already uses — same peer, same encryption, same chunking. The
  // adapter only maps core's vocabulary onto this class's; no new transport.

  @override
  Future<List<RemoteFile>?> filesOnDevice(String peerId, String dir) async {
    final peer = _paired[peerId];
    if (peer == null) return null;
    final entries = await listRemoteFiles(peer, dir);
    if (entries == null) return null;
    return [
      for (final entry in entries)
        RemoteFile(name: entry.name, path: entry.path, isDir: entry.isDir),
    ];
  }

  @override
  Future<String?> fetchFileFromDevice(
    String peerId,
    String remotePath, {
    required String savePath,
    void Function(int received, int total)? onProgress,
  }) async {
    final peer = _paired[peerId];
    if (peer == null) return null;
    final file = await pullRemoteFile(
      peer,
      remotePath,
      savePath: savePath,
      onProgress: onProgress,
    );
    return file?.path;
  }

  /// Reads one exact byte range [offset, offset+length) from a file on
  /// [peer] — what the FUSE gateway needs for arbitrary file-manager reads.
  /// Returns the bytes (possibly shorter than requested near EOF, empty past
  /// it), or null on failure — [lastFileError] says why.
  Future<Uint8List?> pullRemoteRange(
    PairedDevice peer,
    String path, {
    required int offset,
    required int length,
  }) async {
    final req = _newId();
    final completer = Completer<Uint8List?>();
    _pendingRanges[req] = completer;
    final sent = await _sendEnc(
      peer,
      NexusMessage(
        type: NexusMessage.fileGet,
        from: identity.id,
        to: peer.id,
        payload: {'req': req, 'path': path, 'offset': offset, 'length': length},
        id: _newId(),
        ts: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    if (!sent) {
      _pendingRanges.remove(req);
      lastFileError = 'Could not reach ${peer.name}.';
      return null;
    }
    final timer = Timer(const Duration(seconds: 15), () {
      if (!completer.isCompleted) {
        _pendingRanges.remove(req);
        lastFileError = 'Timed out reading that range.';
        completer.complete(null);
      }
    });
    final result = await completer.future;
    timer.cancel();
    return result;
  }

  /// Streams a local file to [peer] over the
  /// encrypted mesh. The peer writes it into its "Nexus Incoming" folder and
  /// acks when every chunk has landed; returns the path it was saved to on
  /// the peer, or null on failure — [lastFileError] says why.
  Future<String?> pushLocalFile(
    PairedDevice peer,
    String localPath, {
    String? destinationPath,
    bool overwrite = false,
    void Function(int sent, int total)? onProgress,
  }) async {
    final req = _newId();
    final completer = Completer<String?>();
    _outgoingPushes[req] = completer;
    RandomAccessFile raf;
    try {
      raf = await File(localPath).open();
    } catch (_) {
      _failOutgoingPush(req, 'Could not open that file on this device.');
      return null;
    }
    var watchdog = Timer(const Duration(seconds: 15), () {
      _failOutgoingPush(req, 'Timed out sending to ${peer.name}.');
    });
    try {
      final total = await raf.length();
      final name = localPath.split(RegExp(r'[/\\]')).last;
      // Same chunk size as the pull side — well under the frame guard.
      const chunkSize = 256 * 1024;
      var offset = 0;
      var first = true;
      while (true) {
        final data = await raf.read(chunkSize);
        final done = offset + data.length >= total;
        final ok = await _sendEnc(
          peer,
          NexusMessage(
            type: NexusMessage.filePush,
            from: identity.id,
            to: peer.id,
            payload: {
              'req': req,
              if (first) 'name': name,
              if (first && destinationPath != null)
                'destination': destinationPath,
              if (first && destinationPath != null) 'overwrite': overwrite,
              'offset': offset,
              'data': base64Encode(data),
              'total': total,
              'done': done,
            },
            id: _newId(),
            ts: DateTime.now().millisecondsSinceEpoch,
          ),
        );
        if (!ok) {
          _failOutgoingPush(req, 'Could not reach ${peer.name}.');
          return null;
        }
        first = false;
        offset += data.length;
        onProgress?.call(offset, total);
        // Any sent chunk proves the connection is alive — reset the watchdog.
        watchdog.cancel();
        watchdog = Timer(const Duration(seconds: 15), () {
          _failOutgoingPush(req, 'Timed out sending to ${peer.name}.');
        });
        if (done) break;
      }
    } catch (_) {
      _failOutgoingPush(req, 'Could not read the file while sending.');
      return null;
    } finally {
      await raf.close();
    }
    final saved = await completer.future;
    watchdog.cancel();
    return saved;
  }

  void _failOutgoingPush(String req, String message) {
    final completer = _outgoingPushes.remove(req);
    if (completer == null) return;
    lastFileError = message;
    if (!completer.isCompleted) completer.complete(null);
  }
}
