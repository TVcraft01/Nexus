// The two folders the Files tab reads, and the one place that decides what is
// in them.
//
// A file browser has to answer three questions on the first frame: which
// folders, which files, and what happens when a folder cannot be read. All
// three are decided here, behind a small seam, for the same reason the storage
// roots are: a widget test must be able to say "Documents holds these two
// files" without writing into the machine that is running the suite.
//
// Downloads comes from [downloadRoot], the same rule a fetched file follows —
// so the file a user asked the assistant to download is the file they see here,
// not a second copy in a folder the app invented for itself.
import 'dart:io';

import 'package:flutter/foundation.dart' show immutable, visibleForTesting;
import 'package:path_provider/path_provider.dart'
    show getApplicationDocumentsDirectory;

import 'storage_roots.dart' show downloadRoot;

/// One row in the local list.
@immutable
class LocalFileEntry {
  const LocalFileEntry({
    required this.name,
    required this.path,
    required this.bytes,
    this.modified,
  });

  final String name;

  /// The absolute path. This is what the reader and the opener are given, and
  /// what a test keys a row by.
  final String path;

  final int bytes;
  final DateTime? modified;

  /// The lower-case extension without the dot, or empty for a name with none.
  String get extension {
    final int dot = name.lastIndexOf('.');
    return dot <= 0 || dot == name.length - 1
        ? ''
        : name.substring(dot + 1).toLowerCase();
  }

  bool get isImage => const <String>{
    'png',
    'jpg',
    'jpeg',
    'gif',
    'webp',
    'bmp',
    'heic',
    'heif',
  }.contains(extension);

  /// Files the preview page can show. Deliberately a short list of text
  /// formats: opening a 200 MB video in a Text widget is not a preview.
  bool get isText => const <String>{
    'txt',
    'md',
    'markdown',
    'json',
    'yaml',
    'yml',
    'csv',
    'log',
    'dart',
    'py',
    'js',
    'ts',
    'html',
    'css',
    'xml',
    'sh',
    'kt',
    'java',
    'c',
    'cpp',
    'h',
    'ini',
    'toml',
  }.contains(extension);
}

/// One folder and what was read from it.
@immutable
class LocalFolder {
  const LocalFolder({
    required this.label,
    required this.path,
    this.entries = const <LocalFileEntry>[],
    this.error,
  });

  /// The word on the section header: "Documents", "Downloads".
  final String label;

  /// Where the folder is. Empty when the platform would not name one.
  final String path;

  /// Newest first, files only.
  final List<LocalFileEntry> entries;

  /// Why the folder is empty, when it is empty for a reason other than being
  /// empty — a path that could not be resolved, or a read that was refused.
  /// Null means "nothing here yet", which is a different sentence on screen.
  final String? error;

  int get count => entries.length;
}

/// Read the local folders. The seam is [override]: the app never sets it.
abstract class LocalLibrary {
  @visibleForTesting
  static LocalLibrary Function()? override;

  static LocalLibrary get current => override?.call() ?? DeviceLocalLibrary();

  /// Documents and Downloads, in that order. Never throws: a folder that cannot
  /// be read answers an empty [LocalFolder] with its [LocalFolder.error] set.
  Future<List<LocalFolder>> read();
}

/// The real one: path_provider's documents folder, and the shared Download
/// folder the rest of the app already uses.
class DeviceLocalLibrary implements LocalLibrary {
  const DeviceLocalLibrary();

  /// At most this many rows per folder. A phone's Download folder can hold
  /// thousands of files; the tab is for finding something, not for indexing a
  /// disk, and an unbounded list is a first frame that waits on the filesystem.
  static const int maxEntries = 200;

  @override
  Future<List<LocalFolder>> read() async {
    final List<LocalFolder> folders = <LocalFolder>[];
    String? documents;
    try {
      documents = (await getApplicationDocumentsDirectory()).path;
    } catch (error) {
      folders.add(
        LocalFolder(
          label: 'Documents',
          path: '',
          error: 'This device would not name its Documents folder ($error).',
        ),
      );
    }
    if (documents != null) folders.add(await readFolder('Documents', documents));

    String? downloads;
    try {
      downloads = (await downloadRoot()).path;
    } catch (error) {
      folders.add(
        LocalFolder(
          label: 'Downloads',
          path: '',
          error: 'This device would not name its Downloads folder ($error).',
        ),
      );
    }
    if (downloads != null) folders.add(await readFolder('Downloads', downloads));
    return folders;
  }

  /// One folder, newest first. Public so a test can point it at a temp
  /// directory and prove the sorting without a platform channel.
  static Future<LocalFolder> readFolder(String label, String path) async {
    if (path.isEmpty) {
      return LocalFolder(label: label, path: path, error: 'No folder path.');
    }
    final Directory directory = Directory(path);
    try {
      if (!await directory.exists()) {
        return LocalFolder(label: label, path: path);
      }
      final List<LocalFileEntry> entries = <LocalFileEntry>[];
      await for (final FileSystemEntity entity in directory.list(
        followLinks: false,
      )) {
        if (entity is! File) continue;
        try {
          final FileStat stat = await entity.stat();
          final String name = entity.uri.pathSegments.last;
          entries.add(
            LocalFileEntry(
              name: name,
              path: entity.path,
              bytes: stat.size,
              modified: stat.modified,
            ),
          );
        } catch (_) {
          // A file that vanished between the listing and the stat: skip it
          // rather than failing the whole folder over one race.
        }
      }
      entries.sort((LocalFileEntry a, LocalFileEntry b) {
        final DateTime? am = a.modified;
        final DateTime? bm = b.modified;
        if (am == null && bm == null) return a.name.compareTo(b.name);
        if (am == null) return 1;
        if (bm == null) return -1;
        return bm.compareTo(am);
      });
      return LocalFolder(
        label: label,
        path: path,
        entries: entries.take(maxEntries).toList(),
      );
    } on FileSystemException catch (error) {
      return LocalFolder(
        label: label,
        path: path,
        error: 'Nexus cannot read this folder (${error.osError?.message ?? error.message}).',
      );
    } catch (error) {
      return LocalFolder(
        label: label,
        path: path,
        error: 'Nexus cannot read this folder ($error).',
      );
    }
  }
}

/// "4.0 KB", "3.4 MB" — the size as a row says it.
String localFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

/// "Today, 14:04", "Oct 9" — enough to find a file, short enough for a row.
String localFileDate(DateTime? at) {
  if (at == null) return '';
  final DateTime now = DateTime.now();
  if (at.year == now.year && at.month == now.month && at.day == now.day) {
    final String hh = at.hour.toString().padLeft(2, '0');
    final String mm = at.minute.toString().padLeft(2, '0');
    return 'Today, $hh:$mm';
  }
  const List<String> months = <String>[
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${months[at.month - 1]} ${at.day}';
}
