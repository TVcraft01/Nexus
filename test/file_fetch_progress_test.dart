// Live progress for the assistant's fetch, driven through the real widget.
//
// "get big.bin from my pc" used to wear the generic working chip from the
// moment the request was understood until the file landed, so a slow transfer
// looked stuck. The chip now carries the fetch's own line — the bytes that
// arrived, and a percentage once the peer has said how big the file is — and
// the finished result replaces it. This drives the real AssistantView: type
// the request, watch the chip, release the transfer.
import 'dart:async';
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
import 'package:nexus/ui/theme.dart';

/// A mesh that poses as a paired PC serving one file over a pull the test can
/// hold halfway — no sockets, no discovery, no peer on the other end.
class _FakeFetchMesh extends MeshService {
  _FakeFetchMesh({required super.identity, required super.store});

  /// Released by the test, so the mid-transfer state can be observed.
  final Completer<void> gate = Completer<void>();

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
      ? const [RemoteFile(name: 'big.bin', path: '/pc/big.bin')]
      : const [];

  @override
  Future<String?> fetchFileFromDevice(
    String peerId,
    String remotePath, {
    required String savePath,
    void Function(int received, int total)? onProgress,
  }) async {
    // A 30 MB pull, reported the way the mesh reports one: as it goes.
    onProgress?.call(0, 31457280);
    onProgress?.call(15728640, 31457280);
    await gate.future;
    onProgress?.call(31457280, 31457280);
    return savePath;
  }
}

void main() {
  testWidgets(
    'a long fetch shows its bytes on the chip while it runs, and the result '
    'replaces them',
    (tester) async {
      final root = Directory.systemTemp.createTempSync('fetch_progress');
      addTearDown(() async {
        if (root.existsSync()) await root.delete(recursive: true);
      });
      final store = NexusStore(explicitPath: '${root.path}/s.json');
      final mesh = _FakeFetchMesh(
        identity: DeviceInfo(id: 'me', name: 'This PC', platform: 'linux'),
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
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildNexusTheme(),
            home: Scaffold(body: AssistantView(mesh: mesh, executor: executor)),
          ),
        );
        await tester.pump();

        await tester.enterText(
          find.byType(TextField),
          'get big.bin from my pc',
        );
        await tester.testTextInput.receiveAction(TextInputAction.done);
        // The request is understood, the fetch runs, and the pull reports
        // twice before it is held at the gate.
        await tester.pump();
        await tester.pump();
        await tester.pump();

        // The live line is on screen — the exact chip text, not the "working"
        // placeholder it replaced, and not the plain confirmation bubble.
        expect(
          find.text('Getting big.bin from My PC… 50% (15 MB of 30 MB)'),
          findsOneWidget,
        );

        mesh.gate.complete();
        await tester.pump();
        await tester.pump();
        await tester.pump();

        expect(find.textContaining('Saved big.bin from My PC'), findsWidgets);
        // The last percentage never stands in for the outcome.
        expect(
          find.textContaining('Getting big.bin from My PC… 50%'),
          findsNothing,
        );
      } finally {
        // The ask is logged with a debounce timer; the test owns cancelling
        // it, exactly as the rest of the assistant suite does.
        QueryLog.i.resetForTest();
      }
    },
  );

  testWidgets('the last percentage never outlives the finished transfer', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('fetch_quiet');
    addTearDown(() async {
      if (root.existsSync()) await root.delete(recursive: true);
    });
    final store = NexusStore(explicitPath: '${root.path}/s.json');
    final mesh = _FakeFetchMesh(
      identity: DeviceInfo(id: 'me', name: 'This PC', platform: 'linux'),
      store: store,
    )..gate.complete();
    final executor = DeviceExecutor(
      fileMesh: mesh,
      fileDownloadRoot: ({String? override}) async => StorageRoot(root.path),
    );
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildNexusTheme(),
          home: Scaffold(body: AssistantView(mesh: mesh, executor: executor)),
        ),
      );
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'get big.bin from my pc');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('Saved big.bin from My PC'), findsWidgets);
      // Nothing is left claiming work in flight, and no percentage is left
      // standing where the outcome belongs.
      expect(find.textContaining('100%'), findsNothing);
      expect(find.textContaining('of 30 MB'), findsNothing);
    } finally {
      QueryLog.i.resetForTest();
    }
  });
}
