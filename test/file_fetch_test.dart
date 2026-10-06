// The file-fetch slice, driven by a fake mesh.
//
// "get report.pdf from my pc" must drive a real local-only fetch: the service
// resolves the paired device, the orchestrator locates the file with the
// remote listing call and pulls it with the pull call into a save path. A fake
// mesh stands in for the transport so the suite can prove the bytes actually
// land, and cover the failures a real user will hit (unpaired device, missing
// file, unreachable peer, a failed transfer, a failed local save).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent_contract.dart';
import 'package:nexus/core/answers.dart';
import 'package:nexus/core/command_service.dart';
import 'package:nexus/core/file_fetch.dart';

/// A mesh that serves an in-memory tree and "downloads" a file by writing its
/// bytes to the requested save path — the same effect the real pull has, minus
/// the socket.
class _FakeMesh implements FileFetchMesh {
  _FakeMesh({this.tree = const {}, this.bytes = const {}, this.reports = const []});

  /// Directory path -> its entries. The root is the empty-string key.
  final Map<String, List<RemoteFile>> tree;

  /// Remote file path -> its bytes.
  final Map<String, List<int>> bytes;

  /// The (received, total) pairs the pull reports before it finishes, so a
  /// test can script a transfer that is halfway through.
  final List<(int, int)> reports;

  bool reachable = true;
  bool pullFails = false;
  String? pulledFrom;

  @override
  String? lastFileError;

  @override
  Future<List<RemoteFile>?> filesOnDevice(String peerId, String dir) async {
    if (!reachable) return null;
    return tree[dir] ?? const [];
  }

  @override
  Future<String?> fetchFileFromDevice(
    String peerId,
    String remotePath, {
    required String savePath,
    void Function(int received, int total)? onProgress,
  }) async {
    if (pullFails) return null;
    pulledFrom = remotePath;
    for (final (received, total) in reports) {
      onProgress?.call(received, total);
    }
    await File(savePath).writeAsBytes(bytes[remotePath] ?? const <int>[]);
    return savePath;
  }
}

void main() {
  group('fetchFile, through a fake mesh', () {
    late Directory tmp;
    String save(String name) => '${tmp.path}${Platform.pathSeparator}$name';

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('file_fetch_test');
    });

    tearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    test('the bytes actually land at the save path', () async {
      final mesh = _FakeMesh(
        tree: {
          '': [
            const RemoteFile(name: 'notes.txt', path: '/home/u/notes.txt'),
            const RemoteFile(name: 'report.pdf', path: '/home/u/report.pdf'),
          ],
        },
        bytes: {
          '/home/u/report.pdf': const [37, 80, 68, 70, 1, 2, 3],
        },
      );
      final path = save('report.pdf');

      final result = await fetchFile(
        mesh: mesh,
        peerId: 'pc1',
        peerName: 'My PC',
        filename: 'report.pdf',
        savePath: path,
      );

      expect(result.ok, isTrue);
      expect(result.message, contains('Saved report.pdf from My PC'));
      expect(result.message, contains(path));
      expect(mesh.pulledFrom, '/home/u/report.pdf');
      // The real proof: the bytes are on disk where the user will look.
      expect(await File(path).readAsBytes(), const [37, 80, 68, 70, 1, 2, 3]);
    });

    test('a file nested under a folder is found by name alone', () async {
      final mesh = _FakeMesh(
        tree: {
          '': [const RemoteFile(name: 'docs', path: '/home/u/docs', isDir: true)],
          '/home/u/docs': [
            const RemoteFile(name: 'report.pdf', path: '/home/u/docs/report.pdf'),
          ],
        },
        bytes: {
          '/home/u/docs/report.pdf': const [9, 9],
        },
      );

      final result = await fetchFile(
        mesh: mesh,
        peerId: 'pc1',
        peerName: 'My PC',
        filename: 'report.pdf',
        savePath: save('found.pdf'),
      );

      expect(result.ok, isTrue);
      expect(mesh.pulledFrom, '/home/u/docs/report.pdf');
    });

    test('a pull reports its bytes while it runs, so a long fetch can say so', () async {
      final mesh = _FakeMesh(
        tree: {
          '': [const RemoteFile(name: 'report.pdf', path: '/home/u/report.pdf')],
        },
        bytes: {
          '/home/u/report.pdf': const [1, 2, 3],
        },
        // A 4 KB transfer, reported the way the mesh reports one: as it goes.
        reports: const [(0, 4096), (2048, 4096), (4096, 4096)],
      );
      final seen = <String>[];

      final result = await fetchFile(
        mesh: mesh,
        peerId: 'pc1',
        peerName: 'My PC',
        filename: 'report.pdf',
        savePath: save('report.pdf'),
        onProgress: (received, total) => seen.add(
          FileFetchWords.progress('report.pdf', 'My PC', received, total),
        ),
      );

      expect(result.ok, isTrue);
      expect(seen, [
        'Getting report.pdf from My PC… 0% (0 B of 4.0 KB)',
        'Getting report.pdf from My PC… 50% (2.0 KB of 4.0 KB)',
        'Getting report.pdf from My PC… 100% (4.0 KB of 4.0 KB)',
      ]);
    });

    test('a peer that never said how big the file is gets bytes, not a fake percent', () async {
      expect(
        FileFetchWords.progress('report.pdf', 'My PC', 512, 0),
        'Getting report.pdf from My PC… 512 B',
      );
      expect(
        FileFetchWords.progress('video.mov', 'My PC', 31457280, 62914560),
        'Getting video.mov from My PC… 50% (30 MB of 60 MB)',
      );
    });

    test('a device with no such file says so', () async {
      final mesh = _FakeMesh(
        tree: {
          '': [const RemoteFile(name: 'other.txt', path: '/home/u/other.txt')],
        },
      );

      final result = await fetchFile(
        mesh: mesh,
        peerId: 'pc1',
        peerName: 'My PC',
        filename: 'report.pdf',
        savePath: save('nothing.pdf'),
      );

      expect(result.ok, isFalse);
      expect(result.message, 'My PC has no file named report.pdf.');
      expect(File(save('nothing.pdf')).existsSync(), isFalse);
    });

    test('an unreachable device is named, not blamed', () async {
      final mesh = _FakeMesh()..reachable = false;

      final result = await fetchFile(
        mesh: mesh,
        peerId: 'pc1',
        peerName: 'My PC',
        filename: 'report.pdf',
        savePath: save('x.pdf'),
      );

      expect(result.ok, isFalse);
      expect(result.message, "I couldn't reach My PC.");
    });

    test('a failed transfer reports the file was found but not moved', () async {
      final mesh = _FakeMesh(
        tree: {
          '': [const RemoteFile(name: 'report.pdf', path: '/home/u/report.pdf')],
        },
      )..pullFails = true;

      final result = await fetchFile(
        mesh: mesh,
        peerId: 'pc1',
        peerName: 'My PC',
        filename: 'report.pdf',
        savePath: save('x.pdf'),
      );

      expect(result.ok, isFalse);
      expect(result.message, "I found report.pdf on My PC but couldn't download it.");
    });

    test('a local save failure names the real problem, not the network', () async {
      // The file was found and arrived; the write on this device failed. The
      // mesh says so ("Could not save the file: …"), and the answer must
      // repeat that instead of blaming the download.
      final mesh = _FakeMesh(
        tree: {
          '': [const RemoteFile(name: 'report.pdf', path: '/home/u/report.pdf')],
        },
      )
        ..pullFails = true
        ..lastFileError = 'Could not save the file: Permission denied';

      final result = await fetchFile(
        mesh: mesh,
        peerId: 'pc1',
        peerName: 'My PC',
        filename: 'report.pdf',
        savePath: save('x.pdf'),
      );

      expect(result.ok, isFalse);
      expect(result.message, contains("couldn't save it here"));
      expect(result.message, isNot(contains("couldn't download it")));
    });
  });

  group('the service resolves which paired device to fetch from', () {
    const phone = AgentDeviceSnapshot(
      id: 'phone1',
      name: 'My Phone',
      online: true,
      platform: 'android',
    );
    const pc = AgentDeviceSnapshot(
      id: 'pc1',
      name: 'My PC',
      online: true,
      platform: 'linux',
    );

    test('a kind name ("my pc") resolves to the paired computer', () {
      final service = CommandService(devices: () => const [pc], local: phone);
      final result = service.execute('get report.pdf from my pc');

      expect(result.status, AgentResultStatus.succeeded);
      final message = result.dispatch! as AgentMessage;
      expect(message.action, AgentActions.fileFetch);
      expect(message.arguments!['peerId'], 'pc1');
      expect(message.arguments!['peerName'], 'My PC');
      expect(message.arguments!['filename'], 'report.pdf');
      expect(message.text, contains('Getting report.pdf from My PC'));
    });

    test('an unpaired device is answered honestly, not sent nowhere', () {
      final service = CommandService(devices: () => const [], local: phone);
      final result = service.execute('get report.pdf from my pc');

      expect(result.status, AgentResultStatus.unavailable);
      expect(result.message, 'I don\'t see a paired device named "pc".');
    });

    test('an exact device name works too', () {
      const named = AgentDeviceSnapshot(
        id: 'pc1',
        name: 'pc',
        online: true,
        platform: 'linux',
      );
      final service = CommandService(devices: () => const [named], local: phone);
      final result = service.execute('get budget.xlsx from pc');

      expect(result.status, AgentResultStatus.succeeded);
      final message = result.dispatch! as AgentMessage;
      expect(message.arguments!['peerId'], 'pc1');
      expect(message.arguments!['filename'], 'budget.xlsx');
    });
  });
}
