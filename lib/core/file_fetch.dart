// The file-fetch vertical, in core.
//
// "get report.pdf from my pc" is parsed locally into `file.fetch`. This is the
// part that makes it real: resolve the paired device, look for the named file
// on it, stream it back into a local save path, and report honestly.
//
// Core stays transport-free by construction. [FileFetchMesh] is the seam —
// list a directory and pull one file — and `mesh/mesh_service.dart` implements
// it on top of the existing `listRemoteFiles` / `pullRemoteFile` primitives.
// Nothing here opens a socket, and nothing leaves the local network: the whole
// transfer runs over the same encrypted mesh the Files tab already uses.
//
// A fake mesh drives the tests, so the success path is proven by bytes
// actually landing at the save path rather than by a promise that they did.
import 'answers.dart';

/// One file found on a paired device, in the fetch's own vocabulary so core
/// never depends on the mesh's `FileEntry`.
class RemoteFile {
  final String name;

  /// The absolute path on the peer, used for the pull.
  final String path;
  final bool isDir;

  const RemoteFile({
    required this.name,
    required this.path,
    this.isDir = false,
  });
}

/// The mesh operations a fetch needs. Implemented by `MeshService` (which may
/// import core); faked wholesale in tests. Method names are distinct from the
/// mesh's own so the two vocabularies never collide.
abstract class FileFetchMesh {
  /// Why the last list or pull failed, in the mesh's own words, or null when
  /// nothing has failed. The fetch reads it only to tell a **local save**
  /// failure (a write on this device) apart from a transfer failure, so the
  /// answer names the thing that actually went wrong.
  String? get lastFileError;

  /// The entries directly under [dir] on [peerId], or null when the device
  /// cannot be reached. An empty directory is an empty list, never null.
  Future<List<RemoteFile>?> filesOnDevice(String peerId, String dir);

  /// Streams [remotePath] on [peerId] into [savePath]. Returns the path it
  /// was saved to, or null when the transfer or the write failed.
  ///
  /// [onProgress] is called as chunks land, with the bytes so far and the
  /// peer's total (0 when it never said) — enough for the caller to show a
  /// live line during a long pull without knowing anything about the
  /// transport.
  Future<String?> fetchFileFromDevice(
    String peerId,
    String remotePath, {
    required String savePath,
    void Function(int received, int total)? onProgress,
  });
}

/// What one fetch concluded: whether the bytes landed, and what to say.
class FileFetchResult {
  final bool ok;
  final String message;

  const FileFetchResult(this.ok, this.message);
}

/// How deep the name search descends. The user names a file, not a path
/// ("get report.pdf"), while the remote listing reads one directory at a time.
const int _fetchSearchDepth = 3;

/// Resolves the named file on [peerId], pulls it into [savePath], and returns
/// what happened in the catalog's own words.
///
/// A breadth-first search from the served root finds the file wherever it sits
/// (up to [_fetchSearchDepth] levels); a match in the root never descends.
Future<FileFetchResult> fetchFile({
  required FileFetchMesh mesh,
  required String peerId,
  required String peerName,
  required String filename,
  required String savePath,
  void Function(int received, int total)? onProgress,
}) async {
  final wanted = filename.trim().toLowerCase();
  final queue = <(String dir, int depth)>[('', 0)];
  RemoteFile? found;
  while (queue.isNotEmpty) {
    final (dir, depth) = queue.removeAt(0);
    final entries = await mesh.filesOnDevice(peerId, dir);
    if (entries == null) {
      // An unreachable root means the device is gone; a subdirectory that
      // fails is skipped — the device is still there and the rest of the
      // tree may still hold the file.
      if (depth == 0) {
        return FileFetchResult(false, FileFetchWords.unreachable(peerName));
      }
      continue;
    }
    for (final entry in entries) {
      if (!entry.isDir && entry.name.toLowerCase() == wanted) {
        found = entry;
        break;
      }
    }
    if (found != null) break;
    if (depth >= _fetchSearchDepth) continue;
    for (final entry in entries) {
      if (entry.isDir) queue.add((entry.path, depth + 1));
    }
  }

  if (found == null) {
    return FileFetchResult(false, FileFetchWords.notFound(filename, peerName));
  }

  final saved = await mesh.fetchFileFromDevice(
    peerId,
    found.path,
    savePath: savePath,
    onProgress: onProgress,
  );
  if (saved == null) {
    // The file was found, so the failure is either the transfer or the local
    // write. The mesh reports the write as "Could not save the file: …";
    // naming the real problem beats a generic "couldn't download it" that
    // sends the user to check the network when their disk is full.
    //
    // Deliberately still a string match: [FileFetchMesh] is a seam whose only
    // production implementation is `MeshService`, and "Could not save the
    // file: …" is already that class's public error vocabulary (it sets
    // `lastFileError` to it when the destination write throws). A typed kind
    // would add a second vocabulary to translate between, for one call site.
    // The real-pull failure test in `test/mesh_test.dart` ("a failed local
    // save is named as storage…") pins this: if the message ever stops
    // matching, that test fails rather than the user getting the wrong blame.
    final localSave = (mesh.lastFileError ?? '').toLowerCase().contains(
      'could not save',
    );
    return FileFetchResult(
      false,
      localSave
          ? FileFetchWords.saveFailed(filename, peerName)
          : FileFetchWords.downloadFailed(filename, peerName),
    );
  }
  return FileFetchResult(true, FileFetchWords.saved(filename, peerName, saved));
}
