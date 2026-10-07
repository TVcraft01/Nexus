// What the Files screen offers, measured on the real widgets.
//
// The screen used to spend four equal-weight controls on one row — Up, Home,
// Send file…, Refresh — under a header tile that carried no state. The design
// system asks for one prominent action per view, so the only control here that
// creates something (Send file…) kept the button, and the other three moved
// behind the overflow menu. These tests pin that shape so it cannot quietly
// grow a second row of buttons again, and pin the two things a careless
// refactor would break: the Up/Home enablement rule and the teaching states.
//
// The mesh is a map of path -> listing, not a network: no socket is opened and
// no port is assumed.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/mesh/mesh_service.dart';
import 'package:nexus/ui/files_view.dart';
import 'package:nexus/ui/theme.dart';

/// A mesh that answers a listing from a map instead of a peer.
class _FakeMesh extends MeshService {
  _FakeMesh(this._devices, {this.listings = const {}, this.failing = false})
    : super(
        identity: DeviceInfo(
          id: 'test-device',
          name: 'Test Phone',
          platform: 'android',
        ),
        store: NexusStore(
          explicitPath:
              '${Directory.systemTemp.createTempSync('files').path}/s.json',
        ),
      );

  final List<PairedDevice> _devices;

  /// Absolute path on the (fake) peer -> what it holds.
  final Map<String, List<FileEntry>> listings;

  /// When true every listing fails, the way an unreachable device does.
  final bool failing;

  @override
  List<PairedDevice> get pairedDevices => _devices;

  @override
  bool isOnline(String id) => true;

  @override
  Future<List<FileEntry>?> listRemoteFiles(
    PairedDevice peer,
    String path,
  ) async {
    if (failing) {
      lastFileError = 'Could not reach ${peer.name}.';
      return null;
    }
    return listings[path] ?? const [];
  }
}

PairedDevice _device(String name) => PairedDevice(
  id: 'peer-1',
  name: name,
  platform: 'linux',
  address: '10.0.0.2',
  port: 51820,
  pairingSecret: 'secret',
);

FileEntry _folder(String name) => FileEntry(
  name: name,
  path: '/home/neo/$name',
  size: 0,
  isDir: true,
  modified: DateTime(2026, 3, 14),
);

FileEntry _file(String name) => FileEntry(
  name: name,
  path: '/home/neo/$name',
  size: 2048,
  isDir: false,
  modified: DateTime(2026, 3, 14),
);

Future<void> _pumpFiles(WidgetTester tester, MeshService mesh) async {
  // The tab is a child of HomeShell's Scaffold, which is what supplies the
  // Material the chips and buttons paint on.
  await tester.pumpWidget(
    MaterialApp(
      theme: buildNexusTheme(),
      home: Scaffold(body: FilesView(mesh: mesh)),
    ),
  );
  await tester.pump(); // the post-frame callback picks the first device
  await tester.pump(); // the (instant) listing lands
}

Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(find.byTooltip('More'));
  await tester.pumpAndSettle();
}

PopupMenuItem<String> _item(WidgetTester tester, String label) =>
    tester.widget<PopupMenuItem<String>>(
      find.widgetWithText(PopupMenuItem<String>, label),
    );

void main() {
  testWidgets('the toolbar is one action and one menu, not four buttons', (
    tester,
  ) async {
    await _pumpFiles(tester, _FakeMesh([_device('TVcraft01')]));

    expect(find.widgetWithText(FilledButton, 'Send file…'), findsOneWidget);
    expect(
      find.byType(PopupMenuButton<String>),
      findsOneWidget,
      reason: 'the overflow menu is the only other control on the row',
    );

    // The three controls the menu swallowed must not still be standing on the
    // row — that is the whole point of the refactor.
    expect(find.byTooltip('Refresh'), findsNothing);
    expect(find.byTooltip('Up'), findsNothing);
    expect(find.byTooltip('Home'), findsNothing);
    expect(find.byIcon(Icons.refresh_rounded), findsNothing);

    // Rows are hairline-separated on the page, not a rounded card each.
    expect(find.byType(Card), findsNothing);

    // Title, device chips and the action row all share the one page margin.
    // Before the refactor the title started at x=194 while the chrome below it
    // started at x=53: a decorative tile had pushed it right, so the header
    // lined up with nothing.
    final margin = tester.getTopLeft(find.text('Files')).dx;
    expect(
      tester.getTopLeft(find.byType(ChoiceChip).first).dx,
      margin,
      reason: 'the device chips sit on the page margin, not inside the title',
    );
    expect(
      tester.getTopLeft(find.text('TVcraft01 · Home')).dx,
      margin,
      reason: 'the path line sits on the page margin too',
    );
  });

  testWidgets('the menu holds Up, Home and Refresh — inert at the device root', (
    tester,
  ) async {
    await _pumpFiles(tester, _FakeMesh([_device('TVcraft01')]));
    await _openMenu(tester);

    expect(find.text('Up one level'), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Refresh'), findsOneWidget);

    expect(
      _item(tester, 'Up one level').enabled,
      isFalse,
      reason: 'there is nothing above the home folder',
    );
    expect(
      _item(tester, 'Home').enabled,
      isFalse,
      reason: 'already at home — the control has nothing left to do',
    );
    expect(_item(tester, 'Refresh').enabled, isTrue);
  });

  testWidgets('inside a folder the menu walks back up', (tester) async {
    await _pumpFiles(
      tester,
      _FakeMesh(
        [_device('TVcraft01')],
        listings: {
          '': [_folder('Docs')],
          // One level down, holding the same folder — so "up" has somewhere
          // real to land other than the root shortcut.
          '/home/neo': [_folder('Docs')],
          '/home/neo/Docs': const [],
        },
      ),
    );

    await tester.tap(find.text('Docs'));
    await tester.pump();
    await tester.pump();
    expect(
      find.text('/home/neo/Docs'),
      findsOneWidget,
      reason: 'the path line is where you are',
    );

    await _openMenu(tester);
    expect(_item(tester, 'Up one level').enabled, isTrue);
    await tester.tap(find.text('Up one level'));
    await tester.pumpAndSettle();

    expect(
      find.text('Docs'),
      findsOneWidget,
      reason: 'up lands in the folder that holds it',
    );
  });

  testWidgets('a listing is hairline rows on the page, not a card each', (
    tester,
  ) async {
    await _pumpFiles(
      tester,
      _FakeMesh(
        [_device('TVcraft01')],
        listings: {
          '': [_folder('Docs'), _file('notes.txt')],
        },
      ),
    );

    expect(find.text('Docs'), findsOneWidget);
    expect(find.text('notes.txt'), findsOneWidget);

    // The assertions the empty state cannot make: rows exist and are still
    // rows. A `Card findsNothing` over an empty listing would prove nothing.
    expect(
      find.byType(Card),
      findsNothing,
      reason: 'a row is a row on the page, not a rounded card each',
    );
    // One hairline under the toolbar, one between the two rows.
    expect(find.byType(Divider), findsNWidgets(2));
    final palette = NexusPalette.of(tester.element(find.byType(FilesView)));
    for (final divider in tester.widgetList<Divider>(find.byType(Divider))) {
      expect(
        divider.color,
        palette.separator,
        reason: 'a hairline is the separator token, not a literal',
      );
    }

    // The row controls are per-row and still a pair each — the toolbar stays
    // the only place with a prominent action.
    expect(find.widgetWithText(FilledButton, 'Send file…'), findsOneWidget);
    expect(find.byTooltip('File actions'), findsNWidgets(2));
    expect(
      find.byTooltip('Download'),
      findsOneWidget,
      reason: 'only a file gets a download button; a folder is opened',
    );
  });

  testWidgets('nothing paired teaches instead of showing a dead toolbar', (
    tester,
  ) async {
    await _pumpFiles(tester, _FakeMesh(const []));

    expect(find.text('No devices yet'), findsOneWidget);
    expect(find.text('Send file…'), findsNothing);
    expect(
      find.byTooltip('More'),
      findsNothing,
      reason: 'a menu with nothing to act on is noise',
    );
  });

  testWidgets('an unreachable device keeps the action and offers a retry', (
    tester,
  ) async {
    await _pumpFiles(tester, _FakeMesh([_device('TVcraft01')], failing: true));

    expect(find.text('Could not reach TVcraft01.'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Try again'), findsOneWidget);
    // The one place two prominent buttons share this screen: the toolbar's
    // action does not stand down while the body offers a retry.
    expect(find.widgetWithText(FilledButton, 'Send file…'), findsOneWidget);
  });
}
