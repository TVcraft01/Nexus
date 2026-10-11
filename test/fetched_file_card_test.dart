// A fetched file is an object the user can act on, not a path string.
//
// "get report.pdf" used to answer with a sentence carrying
// /storage/emulated/0/Download/report.pdf — a string nobody could tap, share
// or delete, so opening the file meant leaving the app. The success card is
// now the file itself: its type glyph, its name, its size with the peer it
// came from. Tap opens it; long-press offers the rest. And the Files tab
// remembers what this device fetched. These drive the real AssistantView,
// the real executor and the real FilesView — only the mesh's byte transfer
// and the platform's open handler are posed.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nexus/core/file_fetch.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/query_log.dart';
import 'package:nexus/core/storage_roots.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/mesh/mesh_service.dart';
import 'package:nexus/ui/assistant_view.dart';
import 'package:nexus/ui/device_executor.dart';
import 'package:nexus/ui/files_view.dart';
import 'package:nexus/ui/theme.dart';

/// A mesh that poses as a paired PC serving one file over a pull — and the
/// file really lands on disk, because the card is about a file that exists.
class _FetchMesh extends MeshService {
  _FetchMesh({required super.identity, required super.store});

  @override
  List<PairedDevice> get pairedDevices => [
    PairedDevice(
      id: 'pc1',
      name: 'My PC',
      platform: 'linux',
      address: '127.0.0.1',
      port: 41500,
      pairingSecret: 'test-secret',
    ),
  ];

  @override
  bool isOnline(String id) => true;

  @override
  Future<List<RemoteFile>?> filesOnDevice(String peerId, String dir) async =>
      dir.isEmpty
      ? const [RemoteFile(name: 'report.pdf', path: '/pc/report.pdf')]
      : const [];

  @override
  Future<String?> fetchFileFromDevice(
    String peerId,
    String remotePath, {
    required String savePath,
    void Function(int received, int total)? onProgress,
  }) async {
    onProgress?.call(4096, 4096);
    File(savePath).writeAsBytesSync(List.filled(4096, 7));
    return savePath;
  }
}

/// A mesh with nothing paired — the Files tab's Recent must stand on its own.
class _PlainMesh extends MeshService {
  _PlainMesh({required super.identity, required super.store});

  @override
  List<PairedDevice> get pairedDevices => const [];

  @override
  bool isOnline(String id) => false;
}

/// One test-owned sandbox: a temp store, a fake peer, a temp downloads
/// folder, and the real executor wired to them.
({Directory root, NexusStore store, _FetchMesh mesh, DeviceExecutor executor,
    Directory downloads}) _rig() {
  final root = Directory.systemTemp.createTempSync('fetched_card');
  addTearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });
  final store = NexusStore(explicitPath: '${root.path}/s.json');
  final mesh = _FetchMesh(
    identity: DeviceInfo(id: 'me', name: 'This phone', platform: 'android'),
    store: store,
  );
  final downloads = Directory('${root.path}/downloads')..createSync();
  final executor = DeviceExecutor(
    fileMesh: mesh,
    // The pull is a fake, but the save path must still be a real one —
    // never the user's own Downloads folder.
    fileDownloadRoot: ({String? override}) async =>
        StorageRoot(downloads.path),
  );
  return (root: root, store: store, mesh: mesh, executor: executor, downloads: downloads);
}

Widget _app(
  MeshService mesh,
  DeviceExecutor executor, {
  Future<bool> Function(String path)? openFile,
  Future<bool> Function(String path)? shareFile,
  VoidCallback? onShowFiles,
}) => MaterialApp(
  theme: buildNexusTheme(),
  home: Scaffold(
    body: AssistantView(
      mesh: mesh,
      executor: executor,
      openFile: openFile,
      shareFile: shareFile,
      onShowFiles: onShowFiles,
    ),
  ),
);

/// Asks for the file the way a user would and waits for the card to land.
Future<void> _fetchReportPdf(WidgetTester tester) async {
  await tester.enterText(find.byType(TextField), 'get report.pdf from my pc');
  await tester.testTextInput.receiveAction(TextInputAction.done);
  for (var i = 0; i < 5; i++) {
    await tester.pump();
  }
}

void main() {
  testWidgets(
    'a fetched file renders as the file — glyph, name, size, peer — with '
    'no raw path',
    (tester) async {
      final rig = _rig();
      try {
        await tester.pumpWidget(_app(rig.mesh, rig.executor));
        await tester.pump();
        await _fetchReportPdf(tester);

        // The card is the file itself: its type glyph (a pdf is a
        // description), its name as the primary text, and its size with the
        // peer it came from. The raw path it used to be is nowhere.
        expect(find.text('report.pdf'), findsOneWidget);
        expect(find.text('4.0 KB · from My PC'), findsOneWidget);
        expect(find.byIcon(Icons.description_outlined), findsOneWidget);
        expect(find.textContaining(rig.downloads.path), findsNothing);
        expect(find.textContaining(' to '), findsNothing);
      } finally {
        QueryLog.i.resetForTest();
      }
    },
  );

  testWidgets('tapping the card opens that exact file', (tester) async {
    final rig = _rig();
    final opened = <String>[];
    try {
      await tester.pumpWidget(
        _app(
          rig.mesh,
          rig.executor,
          openFile: (path) async {
            opened.add(path);
            return true;
          },
        ),
      );
      await tester.pump();
      await _fetchReportPdf(tester);

      await tester.tap(find.text('report.pdf'));
      await tester.pump();

      expect(opened, hasLength(1));
      expect(
        opened.single,
        '${rig.downloads.path}${Platform.pathSeparator}report.pdf',
      );
      expect(File(opened.single).existsSync(), isTrue);
    } finally {
      QueryLog.i.resetForTest();
    }
  });

  testWidgets(
    'long-press offers Share, Save as…, Show in Files and Delete',
    (tester) async {
      final rig = _rig();
      var showedFiles = 0;
      try {
        await tester.pumpWidget(
          _app(
            rig.mesh,
            rig.executor,
            onShowFiles: () => showedFiles++,
          ),
        );
        await tester.pump();
        await _fetchReportPdf(tester);

        await tester.longPress(find.text('report.pdf'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));

        expect(find.text('Share'), findsOneWidget);
        expect(find.text('Save as…'), findsOneWidget);
        expect(find.text('Show in Files'), findsOneWidget);
        expect(find.text('Delete'), findsOneWidget);
        expect(find.text('Cancel'), findsOneWidget);

        // The verb that leaves the app actually leaves for the Files tab.
        await tester.tap(find.text('Show in Files'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        expect(showedFiles, 1);
      } finally {
        QueryLog.i.resetForTest();
      }
    },
  );

  testWidgets('a successful fetch is remembered for the Files tab', (
    tester,
  ) async {
    final rig = _rig();
    try {
      await tester.pumpWidget(_app(rig.mesh, rig.executor));
      await tester.pump();
      await _fetchReportPdf(tester);

      final recent = rig.store.recentFetched;
      expect(recent, hasLength(1));
      final entry = recent.single;
      expect(entry['name'], 'report.pdf');
      expect(entry['size'], 4096);
      expect(entry['peer'], 'My PC');
      expect(entry['fetchedAt'], isNotNull);
      final path = entry['path'] as String;
      expect(
        path,
        '${rig.downloads.path}${Platform.pathSeparator}report.pdf',
      );
      expect(File(path).existsSync(), isTrue);
    } finally {
      QueryLog.i.resetForTest();
    }
  });

  testWidgets('the Files tab lists the fetch under Recent, and a tap opens it', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('fetched_recent');
    addTearDown(() async {
      if (root.existsSync()) await root.delete(recursive: true);
    });
    final store = NexusStore(explicitPath: '${root.path}/s.json');
    final mesh = _PlainMesh(
      identity: DeviceInfo(id: 'me', name: 'This phone', platform: 'android'),
      store: store,
    );
    final file = File('${root.path}/report.pdf')
      ..writeAsBytesSync(List.filled(4096, 7));
    store.recordFetchedFile({
      'path': file.path,
      'name': 'report.pdf',
      'size': 4096,
      'peer': 'My PC',
    });
    final opened = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        theme: buildNexusTheme(),
        home: Scaffold(
          body: FilesView(
            mesh: mesh,
            openFile: (path) async {
              opened.add(path);
              return true;
            },
          ),
        ),
      ),
    );
    await tester.pump();

    // Recent stands even with no device paired — the fetched file is local.
    expect(find.text('Recent'), findsOneWidget);
    expect(find.text('report.pdf'), findsOneWidget);
    expect(find.text('4.0 KB · from My PC'), findsOneWidget);
    expect(find.byIcon(Icons.description_outlined), findsOneWidget);

    await tester.tap(find.text('report.pdf'));
    await tester.pump();
    expect(opened, [file.path]);
  });
}
