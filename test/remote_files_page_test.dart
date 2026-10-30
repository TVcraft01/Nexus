// The Files tab's other devices are a door, and what is behind it.
//
// The remote browser was a finished screen (lib/ui/files_view.dart) with no way
// to reach it from the shipped shell: the Files tab listed paired devices as
// statements, and the browser was only mounted by the old HomeShell. These
// tests pin the wiring — a peer the mesh holds opens its folders from its row,
// and a row the mesh does not hold stays a statement — and then drive the four
// verbs the row exists for: browse, download, rename, delete.
//
// The mesh is a map of path -> listing, not a network: no socket is opened, no
// port is assumed, and nothing is read from or written to the machine running
// the suite (the download folder is injected).
import 'dart:io';

import 'package:flutter/cupertino.dart'
    show CupertinoAlertDialog, CupertinoDialogAction, CupertinoTextField;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/local_library.dart';
import 'package:nexus/core/paired_devices.dart'
    as shell
    show PairedDevice, PairedDevices;
import 'package:nexus/core/store.dart';
import 'package:nexus/main_ui.dart' show FilesTab, NexusChevron;
import 'package:nexus/mesh/mesh_service.dart';
import 'package:nexus/ui/components/nexus_ui.dart' show NexusPressable;
import 'package:nexus/ui/files_view.dart' show FilesView;
import 'package:nexus/ui/remote_files_page.dart' show RemoteFilesPage;
import 'package:nexus/ui/theme.dart' show buildNexusTheme;

/// A mesh that answers from maps instead of a socket.
class _RemoteMesh extends MeshService {
  _RemoteMesh(
    this._devices, {
    required super.store,
    this.listings = const <String, List<FileEntry>>{},
    this.online = const <String>{},
  }) : super(
         identity: DeviceInfo(id: 'pc-1', name: 'This PC', platform: 'linux'),
       );

  final List<PairedDevice> _devices;

  /// Absolute path on the (fake) peer -> what it holds.
  final Map<String, List<FileEntry>> listings;

  /// The ids that are answering right now.
  final Set<String> online;

  /// Every folder the screen asked for, in order, and the peer it asked.
  final List<String> listed = <String>[];
  String? listedFrom;

  /// Every remote path the screen pulled, and where it was told to put it.
  final List<String> pulled = <String>[];
  final List<String> savedTo = <String>[];

  /// Every filesystem operation the screen asked the peer to run.
  final List<({String operation, String source, String destination})>
  operations = <({String operation, String source, String destination})>[];

  /// Every remote path the screen asked the peer to delete.
  final List<String> deleted = <String>[];

  @override
  List<PairedDevice> get pairedDevices => _devices;

  @override
  bool isPaired(String id) => _devices.any((PairedDevice p) => p.id == id);

  @override
  bool isOnline(String id) => online.contains(id);

  @override
  Future<List<FileEntry>?> listRemoteFiles(
    PairedDevice peer,
    String path,
  ) async {
    listedFrom = peer.id;
    listed.add(path);
    return listings[path] ?? const <FileEntry>[];
  }

  @override
  Future<File?> pullRemoteFile(
    PairedDevice peer,
    String path, {
    required String savePath,
    void Function(int received, int total)? onProgress,
  }) async {
    pulled.add(path);
    savedTo.add(savePath);
    onProgress?.call(11, 11);
    // No bytes are written: the page's contract here is *where* the transfer
    // was told to land, and a test host that wrote them would be writing into a
    // folder it was told not to touch.
    return File(savePath);
  }

  @override
  Future<String?> operateRemoteFile(
    PairedDevice peer, {
    required String operation,
    String source = '',
    required String destination,
  }) async {
    operations.add((
      operation: operation,
      source: source,
      destination: destination,
    ));
    return destination;
  }

  @override
  Future<bool> deleteRemoteFile(PairedDevice peer, String path) async {
    deleted.add(path);
    return true;
  }
}

PairedDevice _meshPeer(String id, String name) => PairedDevice(
  id: id,
  name: name,
  platform: 'linux',
  address: '10.0.0.2',
  port: 51820,
  pairingSecret: 'secret-$id',
);

FileEntry _folder(String name) => FileEntry(
  name: name,
  path: '/home/neo/$name',
  size: 0,
  isDir: true,
  modified: DateTime(2026, 3, 14),
);

FileEntry _file(String name, {String at = ''}) => FileEntry(
  name: name,
  path: at.isEmpty ? '/home/neo/$name' : '$at/$name',
  size: 11,
  isDir: false,
  modified: DateTime(2026, 3, 14),
);

/// One folder holding nothing interesting: the Files tab is here for its device
/// rows, not its local files.
class _EmptyLibrary implements LocalLibrary {
  const _EmptyLibrary();

  @override
  Future<List<LocalFolder>> read() async => const <LocalFolder>[];
}

void main() {
  late Directory tmp;
  late NexusStore store;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('nexus-remote-files-');
    store = NexusStore(explicitPath: '${tmp.path}/store.json');
    await store.save();
    addTearDown(() {
      shell.PairedDevices.override = null;
      LocalLibrary.override = null;
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
  });

  void seedShell(List<shell.PairedDevice> devices) {
    shell.PairedDevices.override = () => shell.PairedDevices(seed: devices);
  }

  Future<void> pumpFilesTab(WidgetTester tester, MeshService mesh) async {
    LocalLibrary.override = () => const _EmptyLibrary();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildNexusTheme(),
        home: Scaffold(body: FilesTab(mesh: mesh)),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> pumpBrowser(WidgetTester tester, MeshService mesh) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildNexusTheme(),
        home: RemoteFilesPage(mesh: mesh, deviceId: 'peer-a'),
      ),
    );
    // The post-frame callback picks the device, then the (instant) listing
    // lands.
    await tester.pump();
    await tester.pump();
  }

  /// The row for [name] — the surface a finger touches.
  Finder rowFor(String name) => find
      .ancestor(of: find.text(name), matching: find.byType(NexusPressable))
      .first;

  /// Drags [name]'s row aside, which is how this screen reveals Rename/Delete.
  Future<void> reveal(WidgetTester tester, String name) async {
    final Finder row = rowFor(name);
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(row),
    );
    await gesture.moveBy(const Offset(-100, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
  }

  /// The button inside the open dialog — not the row's own copy of the word,
  /// and not the dialog's title when the two happen to agree (a rename says
  /// "Rename" over a button that also says it).
  Finder dialogAction(String label) =>
      find.widgetWithText(CupertinoDialogAction, label);

  group('a row on the Files tab opens that device', () {
    testWidgets('a peer the mesh holds is a door, and opens on that peer', (
      tester,
    ) async {
      seedShell(<shell.PairedDevice>[
        shell.PairedDevice(id: 'peer-a', name: 'Kit', publicKey: 'k1'),
      ]);
      final _RemoteMesh mesh = _RemoteMesh(
        <PairedDevice>[_meshPeer('peer-a', 'Kit')],
        store: store,
        online: <String>{'peer-a'},
        listings: <String, List<FileEntry>>{
          '': <FileEntry>[_file('notes.txt')],
        },
      );
      addTearDown(mesh.stop);
      await pumpFilesTab(tester, mesh);

      // The chevron is the row's promise that the tap goes somewhere…
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('files-device-peer-a')),
          matching: find.byType(NexusChevron),
        ),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('files-device-peer-a')),
      );
      await tester.pumpAndSettle();

      // …and it does: the browser, opened on the peer whose row was tapped,
      // with that peer's folder in it.
      expect(find.text('Browse devices'), findsOneWidget);
      expect(find.text('notes.txt'), findsOneWidget);
      expect(mesh.listedFrom, 'peer-a');
      expect(mesh.listed, <String>['']);
    });

    testWidgets('a peer that is not answering stays a statement', (
      tester,
    ) async {
      seedShell(<shell.PairedDevice>[
        shell.PairedDevice(id: 'peer-a', name: 'Kit', publicKey: 'k1'),
      ]);
      final MeshService mesh = _RemoteMesh(<PairedDevice>[
        _meshPeer('peer-a', 'Kit'),
      ], store: store);
      addTearDown(mesh.stop);
      await pumpFilesTab(tester, mesh);

      expect(find.text('Offline'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('files-device-peer-a')),
          matching: find.byType(NexusChevron),
        ),
        findsNothing,
        reason: 'no chevron where there is nowhere to go',
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('files-device-peer-a')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(find.text('Browse devices'), findsNothing);
    });

    testWidgets('a row the mesh never paired stays a statement', (
      tester,
    ) async {
      // The demo build's example PC: a row that says online, with no pairing
      // behind it for the mesh to dial.
      seedShell(<shell.PairedDevice>[
        shell.PairedDevice(
          id: 'example-pc',
          name: 'My PC',
          publicKey: '',
          online: true,
          platform: 'linux',
        ),
      ]);
      final MeshService mesh = _RemoteMesh(
        const <PairedDevice>[],
        store: store,
      );
      addTearDown(mesh.stop);
      await pumpFilesTab(tester, mesh);

      expect(find.text('Online'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('files-device-example-pc')),
          matching: find.byType(NexusChevron),
        ),
        findsNothing,
        reason: 'online is the row\u2019s memory, not something to browse',
      );
      // A row with no target is a row the tap passes through, which is the
      // finding: nothing can open a browser from here.
      await tester.tap(
        find.byKey(const ValueKey<String>('files-device-example-pc')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(find.text('Browse devices'), findsNothing);
    });
  });

  group('what the browser does with a peer folder', () {
    Future<_RemoteMesh> pumpWithListing(WidgetTester tester) async {
      final _RemoteMesh mesh = _RemoteMesh(
        <PairedDevice>[_meshPeer('peer-a', 'Kit')],
        store: store,
        online: <String>{'peer-a'},
        listings: <String, List<FileEntry>>{
          '': <FileEntry>[_folder('docs'), _file('readme.txt')],
          '/home/neo/docs': <FileEntry>[
            _file('notes.txt', at: '/home/neo/docs'),
          ],
        },
      );
      addTearDown(mesh.stop);
      await pumpBrowser(tester, mesh);
      return mesh;
    }

    testWidgets('walking into a folder asks the peer for that folder', (
      tester,
    ) async {
      final _RemoteMesh mesh = await pumpWithListing(tester);
      expect(find.text('docs'), findsOneWidget);

      await tester.tap(rowFor('docs'));
      await tester.pumpAndSettle();

      expect(mesh.listed, <String>['', '/home/neo/docs']);
      expect(find.text('notes.txt'), findsOneWidget);
    });

    testWidgets('a tap on a file downloads it, and says where it went', (
      tester,
    ) async {
      final _RemoteMesh mesh = _RemoteMesh(
        <PairedDevice>[_meshPeer('peer-a', 'Kit')],
        store: store,
        online: <String>{'peer-a'},
        listings: <String, List<FileEntry>>{
          '': <FileEntry>[_file('readme.txt')],
        },
      );
      addTearDown(mesh.stop);
      final String inbox = '${tmp.path}/downloads';
      // The save path is the page's, not the machine's: no Downloads folder of
      // the test host is touched.
      await tester.pumpWidget(
        MaterialApp(
          theme: buildNexusTheme(),
          home: Scaffold(
            body: FilesView(
              mesh: mesh,
              initialDeviceId: 'peer-a',
              downloadPath: (String name) async => '$inbox/$name',
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.tap(rowFor('readme.txt'));
      await tester.pumpAndSettle();

      expect(mesh.pulled, <String>['/home/neo/readme.txt']);
      expect(mesh.savedTo, <String>[
        '$inbox/readme.txt',
      ], reason: 'the page names the destination; the mesh writes it');
      expect(find.textContaining('Saved readme.txt'), findsOneWidget);
    });

    testWidgets('a rename is one operation on the folder the file is in', (
      tester,
    ) async {
      final _RemoteMesh mesh = await pumpWithListing(tester);
      await tester.tap(rowFor('docs'));
      await tester.pumpAndSettle();

      await reveal(tester, 'notes.txt');
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();

      expect(find.text('New name'), findsOneWidget);
      await tester.enterText(
        find.descendant(
          of: find.byType(CupertinoAlertDialog),
          matching: find.byType(CupertinoTextField),
        ),
        'final-notes.txt',
      );
      await tester.tap(dialogAction('Rename'));
      await tester.pumpAndSettle();

      expect(mesh.operations, hasLength(1));
      expect(mesh.operations.single.operation, 'rename');
      expect(mesh.operations.single.source, '/home/neo/docs/notes.txt');
      expect(
        mesh.operations.single.destination,
        '/home/neo/docs/final-notes.txt',
        reason: 'the name changes, the folder does not',
      );
      expect(mesh.deleted, isEmpty, reason: 'a rename deletes nothing');
    });

    testWidgets('deleting asks first, and Cancel sends nothing', (
      tester,
    ) async {
      final _RemoteMesh mesh = await pumpWithListing(tester);

      await reveal(tester, 'readme.txt');
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(find.text('Delete readme.txt?'), findsOneWidget);
      await tester.tap(dialogAction('Cancel'));
      await tester.pumpAndSettle();
      expect(mesh.deleted, isEmpty, reason: 'nothing goes before the answer');
    });

    testWidgets('and answering Delete removes it on the peer', (tester) async {
      final _RemoteMesh mesh = await pumpWithListing(tester);

      await reveal(tester, 'readme.txt');
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      // The dialog's own Delete, not the revealed verb that opened it.
      await tester.tap(dialogAction('Delete'));
      await tester.pumpAndSettle();

      expect(mesh.deleted, <String>['/home/neo/readme.txt']);
      expect(mesh.operations, isEmpty);
    });
  });
}
