// Sending one file to one device, behind a seam.
//
// The seam exists because the *flow* is this screen's job and the *transport*
// is the mesh's, and the two are at different stages: the picker, the progress
// bar and the result line are finished here, while the mesh link is not wired
// into this front end yet (the real app runs a `MeshService` with its own
// identity, store and pairing secrets — `lib/mesh/mesh_service.dart`, whose
// `pushLocalFile` is what will sit behind this interface).
//
// So the shipped implementation does the part it can do honestly: it copies the
// file out of the camera's or the screenshot's cache into an outbox folder
// under this app's documents, reporting real bytes as they move, and says in
// the result line — in as many words — that nothing has left the phone. A
// progress bar that completed and a "Sent!" that lied would be the one thing
// this app cannot ship, and a silent failure would be worse.
//
// The day the mesh is wired in, `FileLink.instance` is pointed at a
// `MeshFileLink` and nothing on the screen changes: the picker, the bar and the
// sentence all keep working, and the sentence stops apologising.
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:path_provider/path_provider.dart'
    show getApplicationDocumentsDirectory;

import 'paired_devices.dart' show PairedDevice;

/// How much of the file is moved per read. Large enough that the copy is not
/// thousands of syscalls, small enough that the bar moves smoothly on a photo.
const int _chunkBytes = 64 * 1024;

/// What one send concluded: whether the bytes were prepared, and the sentence
/// the screen shows either way.
class FileSendResult {
  const FileSendResult({required this.ok, required this.message, this.path});

  /// True when the file was handed off successfully. This is *not* the same as
  /// "delivered" while the transport is staged, and [message] is where that
  /// difference is stated.
  final bool ok;

  /// The line the sheet ends on.
  final String message;

  /// Where the prepared copy lives, when there is one.
  final String? path;

  @override
  String toString() => 'FileSendResult($ok, $message)';
}

/// Sends a local file to a paired device.
class FileLink {
  FileLink({this.outbox});

  /// Test seam, in the same shape as [PairedDevices.override]: a test states
  /// where a file goes instead of writing into the real documents folder.
  @visibleForTesting
  static FileLink Function()? override;

  static FileLink? _instance;

  /// The app-wide link.
  static FileLink get instance => override?.call() ?? (_instance ??= FileLink());

  /// Forgets the app-wide instance. Tests use it; the app never does.
  @visibleForTesting
  static void debugReset() => _instance = null;

  /// Where a prepared copy is written. Null uses the app's own documents
  /// folder; a test states a temp one.
  final Future<Directory?> Function()? outbox;

  /// Moves [path] into the outbox for [device], reporting progress as 0..1.
  ///
  /// [onProgress] is called with the fraction copied, and never with 0 or 1
  /// twice — the caller draws a bar and a bar that jumps backwards reads as a
  /// restart.
  Future<FileSendResult> send({
    required String path,
    required PairedDevice device,
    void Function(double progress)? onProgress,
  }) async {
    final File source = File(path);
    if (!await source.exists()) {
      return const FileSendResult(
        ok: false,
        message: 'That file is no longer on this device.',
      );
    }
    final Directory? folder = await (outbox ?? _defaultOutbox)();
    if (folder == null) {
      return const FileSendResult(
        ok: false,
        message: 'This device has nowhere to prepare the file yet.',
      );
    }
    final String name = path.split(RegExp(r'[/\\]')).last;
    final File target = File(
      '${folder.path}/${_stamp()}-${device.id}-$name',
    );
    try {
      final int total = await source.length();
      final RandomAccessFile reader = await source.open();
      final RandomAccessFile writer = await target.open(mode: FileMode.write);
      int copied = 0;
      double last = -1;
      try {
        while (true) {
          final List<int> chunk = await reader.read(_chunkBytes);
          if (chunk.isEmpty) break;
          await writer.writeFrom(chunk);
          copied += chunk.length;
          final double progress = total <= 0 ? 1 : copied / total;
          if (progress - last >= 0.01 || progress >= 1) {
            last = progress;
            onProgress?.call(progress);
          }
        }
      } finally {
        await reader.close();
        await writer.close();
      }
      return FileSendResult(
        ok: true,
        message:
            'Prepared for ${device.name} (${_size(copied)}). The mesh link is '
            'not wired into this screen yet, so the file has not left this '
            'phone.',
        path: target.path,
      );
    } catch (error) {
      debugPrint('FILE LINK: could not prepare the file ($error)');
      return FileSendResult(
        ok: false,
        message: 'The file could not be prepared ($error).',
      );
    }
  }

  /// `<documents>/outbox`, created on first use. Null when the platform has no
  /// documents folder at all (a desktop with no path provider, a test).
  static Future<Directory?> _defaultOutbox() async {
    try {
      final Directory documents = await getApplicationDocumentsDirectory();
      return await Directory('${documents.path}/outbox').create(
        recursive: true,
      );
    } catch (error) {
      debugPrint('FILE LINK: no outbox folder ($error)');
      return null;
    }
  }

  /// A sortable stamp, so two sends of the same shot are two files rather than
  /// one file sent twice.
  static String _stamp() {
    final DateTime now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }

  /// Bytes as a person reads them.
  static String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
