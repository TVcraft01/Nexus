// What "Online" means on Devices and Files: what the mesh is hearing now.
//
// Both screens used to draw the `online` flag the row was *written* with. For a
// device the mesh has paired that is the wrong answer twice over:
//
//  1. A peer that paired *into* this device (it scanned our code) has no row in
//     the shell's list at all, so the row the Devices screen builds for it came
//     out of `PairedDevice`'s default of `online: false` — a device talking to
//     us, drawn Offline, with Send File / Ping / Remote greyed out.
//  2. A shell row written `online: false` that the mesh has since verified was
//     also excluded from Files' "Send to...", which answers "No paired device is
//     online right now" about a device that would have taken the file.
//
// The rule these tests pin: the mesh answers when it has the device, and the
// stored flag answers only when it does not (the example rows of a build with
// no mesh, and a row whose pairing never reached the mesh).
//
// The mesh is a set of ids here, not a network: no socket is opened, and the
// shell's own list and the folder listing are injected through the same seams
// the app leaves for exactly this.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/local_library.dart';
import 'package:nexus/core/paired_devices.dart'
    as shell
    show PairedDevice, PairedDevices;
import 'package:nexus/core/store.dart';
import 'package:nexus/main_ui.dart' show DevicesTab, FilesTab, NexusTheme;
import 'package:nexus/mesh/mesh_service.dart' show MeshService, PairedDevice;

/// A mesh that answers from a list instead of a socket.
class _PresenceMesh extends MeshService {
  _PresenceMesh({
    required List<PairedDevice> peers,
    required this.online,
    required NexusStore store,
  }) : _peers = peers,
       super(
         identity: DeviceInfo(id: 'pc-1', name: 'This PC', platform: 'linux'),
         store: store,
       );

  final List<PairedDevice> _peers;

  /// The ids that are proving themselves right now.
  final Set<String> online;

  @override
  List<PairedDevice> get pairedDevices => _peers;

  @override
  bool isPaired(String id) => _peers.any((PairedDevice p) => p.id == id);

  @override
  bool isOnline(String id) => online.contains(id);

  @override
  int get onlineCount =>
      _peers.where((PairedDevice p) => online.contains(p.id)).length;

  @override
  DateTime? lastSeenAt(String id) => null;
}

/// The mesh's record for the peer these tests are about. Deliberately built
/// without any shell row behind it in the "paired into us" cases.
PairedDevice _meshPeer(String id, String name) => PairedDevice(
  id: id,
  name: name,
  platform: 'linux',
  address: '10.0.0.2',
  port: 51820,
  pairingSecret: 'secret-$id',
);

/// One folder holding one text file, named by the test rather than read off the
/// machine running the suite.
class _OneFileLibrary implements LocalLibrary {
  _OneFileLibrary(this.folder);

  final LocalFolder folder;

  @override
  Future<List<LocalFolder>> read() async => <LocalFolder>[folder];
}

LocalFolder _documentsHolding(String path) => LocalFolder(
  label: 'Documents',
  path: '/tmp/nexus-presence',
  entries: <LocalFileEntry>[
    LocalFileEntry(
      name: 'notes.txt',
      path: path,
      bytes: 12,
      modified: DateTime(2026, 3, 14),
    ),
  ],
);

void main() {
  late Directory tmp;
  late NexusStore store;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('nexus-presence-');
    store = NexusStore(explicitPath: '${tmp.path}/store.json');
    await store.save();
    addTearDown(() {
      shell.PairedDevices.override = null;
      LocalLibrary.override = null;
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
  });

  /// The shell's own list, seeded with exactly what each test needs.
  void seedShell(List<shell.PairedDevice> devices) {
    shell.PairedDevices.override = () => shell.PairedDevices(seed: devices);
  }

  Future<void> pumpDevices(WidgetTester tester, MeshService mesh) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: NexusTheme.light(),
        home: Scaffold(body: DevicesTab(mesh: mesh)),
      ),
    );
    await tester.pump();
  }

  Future<void> pumpFiles(WidgetTester tester, MeshService? mesh) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: NexusTheme.light(),
        home: Scaffold(body: FilesTab(mesh: mesh)),
      ),
    );
    await tester.pump();
    // The folder read is a future; a few frames is enough for a list that was
    // never on disk.
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// Whether the action behind [key] can be tapped at all.
  bool _enabled(WidgetTester tester, String key) {
    final Finder ink = find.descendant(
      of: find.byKey(ValueKey<String>(key)),
      matching: find.byType(InkWell),
    );
    return tester.widget<InkWell>(ink).onTap != null;
  }

  group('a peer only the mesh knows takes its state from the mesh', () {
    testWidgets('verified online is Online, with its actions live', (
      tester,
    ) async {
      // Nothing in the shell's list: this is the peer that scanned our code, so
      // no row was ever written for it.
      seedShell(<shell.PairedDevice>[]);
      final MeshService mesh = _PresenceMesh(
        peers: <PairedDevice>[_meshPeer('peer-a', 'Kit')],
        online: <String>{'peer-a'},
        store: store,
      );
      addTearDown(mesh.stop);
      await pumpDevices(tester, mesh);

      expect(find.text('Kit'), findsOneWidget);
      expect(find.text('Online'), findsOneWidget);
      expect(find.text('Offline'), findsNothing);
      // The state and the buttons are one fact: a row that says Online with a
      // dead Send File is the old bug wearing the new label.
      expect(_enabled(tester, 'send-peer-a'), isTrue);
    });

    testWidgets('a peer the mesh has gone quiet on is Offline', (tester) async {
      seedShell(<shell.PairedDevice>[]);
      final MeshService mesh = _PresenceMesh(
        peers: <PairedDevice>[_meshPeer('peer-a', 'Kit')],
        online: const <String>{},
        store: store,
      );
      addTearDown(mesh.stop);
      await pumpDevices(tester, mesh);

      // Twice on purpose: the row's own status, and the capability chip that
      // says what a device that has gone quiet can be asked to do. Neither may
      // read Online.
      expect(find.text('Offline'), findsWidgets);
      expect(find.text('Online'), findsNothing);
      expect(_enabled(tester, 'send-peer-a'), isFalse);
    });
  });

  group('a stored row the mesh has verified is a file destination', () {
    testWidgets('Files says Online and offers it in Send to...', (
      tester,
    ) async {
      seedShell(<shell.PairedDevice>[
        shell.PairedDevice(
          id: 'peer-a',
          name: 'Kit',
          publicKey: 'k1',
          online: false, // what the pairing wrote; the mesh disagrees
        ),
      ]);
      final MeshService mesh = _PresenceMesh(
        peers: <PairedDevice>[_meshPeer('peer-a', 'Kit')],
        online: <String>{'peer-a'},
        store: store,
      );
      addTearDown(mesh.stop);
      final String path = '${tmp.path}/notes.txt';
      LocalLibrary.override = () => _OneFileLibrary(_documentsHolding(path));
      await pumpFiles(tester, mesh);

      expect(find.text('Online'), findsOneWidget);

      await tester.tap(find.byKey(ValueKey<String>('file-menu-$path')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Send to...'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        find.byKey(const ValueKey<String>('send-to-peer-a')),
        findsOneWidget,
      );
    });

    testWidgets('a peer the mesh has not met keeps the flag its row carries', (
      tester,
    ) async {
      // The example PC of a demo build: no mesh pairing behind it, and a row
      // that says online. Its state must not change with this fix.
      seedShell(<shell.PairedDevice>[
        shell.PairedDevice(
          id: 'example-pc',
          name: 'My PC',
          publicKey: '',
          online: true,
          platform: 'linux',
        ),
      ]);
      final MeshService mesh = _PresenceMesh(
        peers: const <PairedDevice>[],
        online: const <String>{},
        store: store,
      );
      addTearDown(mesh.stop);
      final String path = '${tmp.path}/notes.txt';
      LocalLibrary.override = () => _OneFileLibrary(_documentsHolding(path));
      await pumpFiles(tester, mesh);

      expect(find.text('Online'), findsOneWidget);

      await tester.tap(find.byKey(ValueKey<String>('file-menu-$path')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Send to...'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        find.byKey(const ValueKey<String>('send-to-example-pc')),
        findsOneWidget,
      );
    });
  });
}
