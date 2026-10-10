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

import 'package:flutter/cupertino.dart'
    show CupertinoActionSheet, CupertinoSliverRefreshControl;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/mesh/mesh_service.dart';
import 'package:nexus/ui/components/nexus_ui.dart';
import 'package:nexus/ui/files_view.dart';
import 'package:nexus/ui/theme.dart';

/// A mesh that answers a listing from a map instead of a peer.
class _FakeMesh extends MeshService {
  _FakeMesh(
    this._devices, {
    this.listings = const {},
    this.failing = false,
    this.online = const {},
  })
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

  /// Which ids answer when dialled. Empty means all of them.
  final Set<String> online;

  /// How many listings have been asked for — so a test can prove that a pull
  /// which crossed the trigger actually refreshed.
  int listingCalls = 0;

  @override
  List<PairedDevice> get pairedDevices => _devices;

  @override
  bool isOnline(String id) => online.isEmpty || online.contains(id);

  @override
  Future<List<FileEntry>?> listRemoteFiles(
    PairedDevice peer,
    String path,
  ) async {
    listingCalls++;
    if (failing) {
      lastFileError = 'Could not reach ${peer.name}.';
      return null;
    }
    return listings[path] ?? const [];
  }
}

PairedDevice _device(String name, {String? id}) => PairedDevice(
  id: id ?? 'peer-$name',
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
  // The tab is a child of HomeShell's Scaffold, exactly as it is on the phone:
  // the page sits on the shell's own surface, not on one of its own.
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

/// The row that shows [name] — the pressable surface a finger touches, which
/// is what "the row" means on this screen.
Finder _row(WidgetTester tester, String name) => find
    .ancestor(of: find.text(name), matching: find.byType(NexusPressable))
    .first;

/// The same row as the widget that owns its label and its actions.
Finder _rowWidget(String name) => find
    .ancestor(of: find.text(name), matching: find.byType(NexusRow))
    .first;

void main() {
  testWidgets('the toolbar is one action and one menu, not four buttons', (
    tester,
  ) async {
    await _pumpFiles(tester, _FakeMesh([_device('TVcraft01')]));

    expect(find.widgetWithText(FilledButton, 'Send file…'), findsOneWidget);
    // The overflow is a labelled button opening a Cupertino action sheet. The
    // Material PopupMenuButton it replaced is gone: it was the last Material
    // menu sitting inside Cupertino chrome.
    expect(find.byTooltip('More'), findsOneWidget);
    expect(
      find.byType(PopupMenuButton<String>),
      findsNothing,
      reason: 'no Material menu is left on this screen',
    );
    expect(
      find.byType(PopupMenuItem<String>),
      findsNothing,
      reason: 'and no Material menu item either',
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
      tester.getTopLeft(find.byType(NexusChoicePill).first).dx,
      margin,
      reason: 'the device pills sit on the page margin, not inside the title',
    );
    // The pills are the app's own now: a Material chip asserts an ambient
    // Material, and one of these strips lives inside a sheet, where there is
    // none — it was the reason a transparent Material sat under every sheet.
    expect(
      find.byType(ChoiceChip),
      findsNothing,
      reason: 'no Material chip is left on this screen',
    );
    expect(
      tester.getTopLeft(find.text('TVcraft01 · Home')).dx,
      margin,
      reason: 'the path line sits on the page margin too',
    );
  });

  testWidgets('the overflow holds Sort, the view and Refresh — and no '
      'navigation, which the breadcrumb owns now', (tester) async {
    await _pumpFiles(tester, _FakeMesh([_device('TVcraft01')]));
    await _openMenu(tester);

    expect(
      find.byType(CupertinoActionSheet),
      findsOneWidget,
      reason: 'the overflow is Apple\u2019s sheet, not a Material menu',
    );
    expect(find.text('Sort'), findsOneWidget);
    expect(find.text('Grid view'), findsOneWidget);
    expect(find.text('Refresh'), findsOneWidget);
    // Walking the tree is the breadcrumb's job now: Up and Home each moved one
    // step, and neither could go sideways to a folder the user came from.
    expect(find.text('Up one level'), findsNothing);
    expect(find.text('Home'), findsNothing);

    // Sort is one sheet deeper, with the order in force marked — and no second
    // stack of modals to unwind, because the first has closed.
    await tester.tap(find.text('Sort'));
    await tester.pumpAndSettle();
    expect(find.text('Sort by'), findsOneWidget);
    expect(find.text('Name  ✓'), findsOneWidget, reason: 'name is the default');
    expect(find.text('Date'), findsOneWidget);
    expect(find.text('Size'), findsOneWidget);
  });

  testWidgets('the breadcrumb goes back to any folder the user was in',
      (tester) async {
    await _pumpFiles(
      tester,
      _FakeMesh(
        [_device('TVcraft01')],
        listings: {
          '': [_folder('Docs')],
          '/home/neo/Docs': [_folder('Nested')],
          '/home/neo/Nested': const [],
        },
      ),
    );

    await tester.tap(find.text('Docs'));
    await tester.pump();
    await tester.pump();
    // The crumb names the folder. The absolute path on the peer is no longer
    // printed anywhere: it is not a path this app can walk, and the old Up
    // item split it on the separator and went to a directory it had no
    // listing for.
    expect(find.text('/home/neo/Docs'), findsNothing);
    expect(find.text('Docs'), findsOneWidget);

    await tester.tap(find.text('Nested'));
    await tester.pump();
    await tester.pump();
    expect(find.text('TVcraft01 · Home'), findsOneWidget);
    expect(find.text('Docs'), findsOneWidget, reason: 'the trail is two deep');
    expect(find.text('Nested'), findsOneWidget);

    // Sideways, from two folders deep, in one tap — the move Up and Home each
    // needed a whole control of their own to approximate.
    await tester.tap(find.text('Docs'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Nested'), findsOneWidget, reason: 'the folder is listed');
    expect(find.text('TVcraft01 · Home'), findsOneWidget);

    await tester.tap(find.text('TVcraft01 · Home'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Nested'), findsNothing, reason: 'home holds only Docs');
    expect(find.text('Docs'), findsOneWidget);
  });

  testWidgets('Copy to… opens on the device you are browsing', (tester) async {
    await _pumpFiles(
      tester,
      _FakeMesh(
        // The raw pairing order puts the device that cannot answer first —
        // which is exactly where the picker used to open, on a spinner.
        [_device('TVcraft01'), _device('Rehearsal PC')],
        online: {'peer-Rehearsal PC'},
        listings: {
          '': [_file('notes.txt')],
        },
      ),
    );
    expect(find.text('Rehearsal PC · Home'), findsOneWidget);

    // The actions live behind a long press on the row itself: the row is the
    // target, and there is no button standing on every line any more.
    await tester.longPress(_row(tester, 'notes.txt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy to…'));
    await tester.pumpAndSettle();

    expect(find.text('Choose destination'), findsOneWidget);
    expect(
      find.text('TVcraft01 · Home'),
      findsNothing,
      reason: 'the sheet must open where the user is, not on the offline peer',
    );
    expect(
      find.text('Rehearsal PC · Home'),
      findsNWidgets(2),
      reason: 'the browsing device is the sheet\'s starting point too',
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

    // The drive-app shape: no control stands on a row. The toolbar's one
    // action is the only button on the screen, and its menu the only menu —
    // no download button and no per-row overflow, which is what this screen
    // used to carry on every line.
    expect(find.widgetWithText(FilledButton, 'Send file…'), findsOneWidget);
    expect(find.byType(PopupMenuButton<String>), findsNothing);
    expect(
      find.descendant(
        of: find.byType(NexusPressable),
        matching: find.byType(IconButton),
      ),
      findsNothing,
      reason: 'no row carries a button — the row is the target',
    );
    expect(find.byTooltip('File actions'), findsNothing);
    expect(find.byTooltip('Download'), findsNothing);

    // What names the type is the icon, at the size the row token asks for and
    // in one muted colour — not a per-row badge or a coloured rainbow.
    expect(find.byIcon(Icons.folder_rounded), findsOneWidget);
    expect(find.byIcon(Icons.description_outlined), findsOneWidget);
    expect(
      tester.getSize(find.byIcon(Icons.description_outlined)),
      const Size(24, 24),
    );
    final leadingIcons = tester
        .widgetList<Icon>(find.byWidgetPredicate((w) => w is Icon && w.size == 24))
        .toList();
    expect(leadingIcons, isNotEmpty, reason: 'each row leads with its type');
    for (final icon in leadingIcons) {
      expect(
        icon.color,
        palette.textSecondary,
        reason: 'one muted colour for every type',
      );
    }

    // Name first, facts under it; and only the folder leads somewhere, so only
    // the folder wears a chevron.
    expect(find.text('Folder'), findsOneWidget);
    expect(find.text('2.0 KB · 2026-03-14'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);

    // The row itself is the target, at the row token's height.
    expect(
      tester.getSize(_row(tester, 'notes.txt')).height,
      greaterThanOrEqualTo(NexusSize.row),
      reason: 'a file row is a NexusSize.row tall, like every other row',
    );
  });

  testWidgets('a long press opens the actions, and a screen reader gets them '
      'too', (tester) async {
    final mesh = _FakeMesh(
      [_device('TVcraft01')],
      listings: {
        '': [_file('notes.txt')],
      },
    );
    await _pumpFiles(tester, mesh);

    // Nothing is on screen until the gesture: no overflow glyph, no buttons.
    expect(find.text('Rename'), findsNothing);
    expect(
      find.descendant(
        of: find.byType(NexusPressable),
        matching: find.byType(IconButton),
      ),
      findsNothing,
    );

    // A long press is a gesture a screen reader cannot perform the same way,
    // so the same four actions are published on the row itself.
    final row = tester.widget<NexusRow>(_rowWidget('notes.txt'));
    expect(
      row.customActions.keys.map((a) => a.label),
      containsAll(<String>['Rename', 'Copy to…', 'Move to…', 'Delete']),
      reason: 'the row menu must reach the accessibility menu as well',
    );
    expect(row.onLongPress, isNotNull);

    await tester.longPress(_row(tester, 'notes.txt'));
    await tester.pumpAndSettle();
    // The two verbs a swipe does not carry. Rename and Delete are one swipe
    // away instead, which the swipe test below pins.
    for (final label in ['Copy to…', 'Move to…']) {
      expect(find.text(label), findsOneWidget, reason: '$label is in the menu');
    }
    expect(find.text('Rename'), findsNothing);
    expect(find.text('Delete'), findsNothing);

    // And the menu's entries are the real handlers: Copy to… opens the
    // destination picker it names.
    await tester.tap(find.text('Copy to…'));
    await tester.pumpAndSettle();
    expect(find.text('Choose destination'), findsOneWidget);

    // Closed again by hand, so the press that opened the menu can be checked.
    Navigator.of(tester.element(find.text('Choose destination'))).pop();
    await tester.pumpAndSettle();
    expect(find.text('Choose destination'), findsNothing);
    final container = tester.widget<AnimatedContainer>(
      find
          .descendant(
            of: _row(tester, 'notes.txt'),
            matching: find.byType(AnimatedContainer),
          )
          .first,
    );
    expect(
      (container.decoration as BoxDecoration?)?.color,
      Colors.transparent,
      reason: 'a long press ends with the finger, not with the menu',
    );
  });

  testWidgets('a row answers the finger on touch-DOWN, and settles on a spring',
      (tester) async {
    await _pumpFiles(
      tester,
      _FakeMesh(
        [_device('TVcraft01')],
        listings: {
          '': [_file('notes.txt')],
        },
      ),
    );

    final row = _row(tester, 'notes.txt');
    Color? tint() {
      final box = tester.widget<AnimatedContainer>(
        find.descendant(of: row, matching: find.byType(AnimatedContainer)).first,
      );
      return (box.decoration as BoxDecoration?)?.color;
    }

    // The x axis of the transform: on a scale-only matrix the z axis stays 1,
    // so `getMaxScaleOnAxis()` would report 1 whatever the press is doing.
    double scale() => tester
        .widget<Transform>(
          find.descendant(of: row, matching: find.byType(Transform)).first,
        )
        .transform
        .storage[0];

    expect(tint(), Colors.transparent, reason: 'a resting row is not tinted');
    expect(scale(), moreOrLessEquals(1, epsilon: 0.0001));

    // The finger lands. One frame later the row is already lit — no release
    // is involved, which is the whole rule.
    final gesture = await tester.startGesture(tester.getCenter(row));
    await tester.pump();
    expect(tint(), isNot(Colors.transparent),
        reason: 'the press must show on touch-down, not on touch-up');

    await tester.pump(const Duration(milliseconds: 120));
    final pressed = scale();
    expect(pressed, lessThan(1), reason: 'the row moves under the finger');

    // The finger lifts mid-flight. The row carries on from where it is — it
    // does not jump back to 1 and restart.
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 16));
    final justAfter = scale();
    expect(
      justAfter,
      lessThan(1),
      reason: 'releasing must not snap the row back',
    );
    expect(
      (justAfter - pressed).abs(),
      lessThan(0.005),
      reason: 'the row continues from the value it was at — no seam',
    );
    expect(tint(), Colors.transparent, reason: 'the press ends with the lift');

    await tester.pumpAndSettle();
    expect(scale(), moreOrLessEquals(1, epsilon: 0.0001));
  });

  testWidgets('a swipe reveals the two verbs a person reaches for most, and '
      'they are not in the tree until it does', (tester) async {
    await _pumpFiles(
      tester,
      _FakeMesh(
        [_device('TVcraft01')],
        listings: {
          '': [_file('notes.txt')],
        },
      ),
    );

    // Nothing hidden is still present: a verb that is in the tree but off
    // screen is one a screen reader reads and a test finds.
    expect(find.text('Rename'), findsNothing);
    expect(find.text('Delete'), findsNothing);

    final row = _row(tester, 'notes.txt');
    final before = tester.getTopLeft(find.text('notes.txt')).dx;
    final gesture = await tester.startGesture(tester.getCenter(row));
    await gesture.moveBy(const Offset(-100, 0));
    await tester.pump();

    expect(find.text('Rename'), findsOneWidget, reason: 'the swipe reveals them');
    expect(find.text('Delete'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('notes.txt')).dx,
      lessThan(before),
      reason: 'the row follows the finger rather than blinking open',
    );

    await gesture.up();
    await tester.pumpAndSettle();
    expect(
      find.text('Rename'),
      findsOneWidget,
      reason: 'past half way it stays open',
    );

    // The revealed verb is the real handler, not a decoration.
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    expect(find.text('New name'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('New name'), findsNothing);
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

  testWidgets('the listing refreshes from a pull, through a control that is '
      'part of the scroll', (tester) async {
    final mesh = _FakeMesh(
      [_device('TVcraft01')],
      listings: {
        '': [_file('notes.txt')],
      },
    );
    await _pumpFiles(tester, mesh);
    expect(find.text('notes.txt'), findsOneWidget);
    // The control is a sliver of the scroll, not an overlay on it. At rest it
    // has no extent — the viewport counts a zero-height sliver at its edge as
    // off stage, which is why the finder has to look off stage to see it.
    expect(
      find.byType(CupertinoSliverRefreshControl, skipOffstage: false),
      findsOneWidget,
      reason: 'the pull-to-refresh is part of the scroll view itself',
    );
    expect(
      find.byType(CupertinoSliverRefreshControl),
      findsNothing,
      reason: 'at rest the control occupies no space',
    );

    final before = mesh.listingCalls;
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(CustomScrollView)),
    );
    // Past the 100pt trigger, without letting go.
    await gesture.moveBy(const Offset(0, 220));
    await tester.pump();
    expect(
      find.byType(CupertinoSliverRefreshControl),
      findsOneWidget,
      reason: 'the control moves with the finger instead of sitting over it',
    );
    // The iOS control starts its work the moment the pull passes the trigger,
    // with the finger still down; the Material indicator waits for the
    // release. That is the behaviour the sliver buys.
    expect(
      mesh.listingCalls,
      greaterThan(before),
      reason: 'a pull past the trigger refreshes under the finger',
    );

    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('notes.txt'), findsOneWidget);
    expect(
      find.byType(CupertinoSliverRefreshControl),
      findsNothing,
      reason: 'and the control goes back to occupying no space',
    );
  });
}
