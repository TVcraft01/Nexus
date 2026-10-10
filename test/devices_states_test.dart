// What the Devices page says, measured on the real widgets.
//
// Two things the phone caught that nothing here had:
//
//  1. With exactly one paired device the status strip read "None of your 1
//     devices are reachable right now." — a count that only makes sense once
//     there is more than one thing to count, said to the person most likely
//     to be running a single device.
//  2. Every row announced its status three times: once in the row's own
//     composed label, once from a label on the status dot, once as the dot's
//     tooltip. A dot reinforces the words; it does not get to repeat them.
//
//  3. A device the connection supervisor has declared down and is retrying
//     said "Offline · last seen …" like any other absent device — the one
//     state the mesh cannot see on its own, because its own window is 25 s
//     wide and the supervisor notices in 9. That row now says Reconnecting…
//
// The mesh is a list here, not a network: every state a phone can be in
// (nothing paired, one device, two devices, reachable or not, retrying) is set
// up directly, so no socket is opened and no port is assumed. The real service
// loads its paired devices from the same store this fake stands in for, and
// the retrying rows are driven by the real `ConnectionSupervisor` over a
// transport that never answers — the state under test is the supervisor's own
// verdict, not a hand-made one.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsAction;
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/mesh/connection_supervisor.dart';
import 'package:nexus/mesh/mesh_service.dart';
import 'package:nexus/mesh/mesh_transport.dart';
import 'package:nexus/ui/components/nexus_ui.dart' show NexusRow;
import 'package:nexus/ui/devices_view.dart';
import 'package:nexus/ui/theme.dart';

/// A mesh that answers from a list instead of a network.
class _FakeMesh extends MeshService {
  _FakeMesh(this._devices, {this.online = const {}, this.supervisor})
    : super(
        identity: DeviceInfo(
          id: 'test-device',
          name: 'Test PC',
          platform: 'linux',
        ),
        store: NexusStore(
          explicitPath:
              '${Directory.systemTemp.createTempSync('dev').path}/s.json',
        ),
      );

  final List<PairedDevice> _devices;
  final Set<String> online;

  /// The supervisor the mesh would have had if it had been started. Null in
  /// every test that predates the link state: no supervisor, no change.
  @override
  final ConnectionSupervisor? supervisor;

  @override
  List<PairedDevice> get pairedDevices => _devices;

  @override
  int get onlineCount => _devices.where((d) => online.contains(d.id)).length;

  @override
  bool isPaired(String id) => _devices.any((d) => d.id == id);

  @override
  bool isOnline(String id) => online.contains(id);

  @override
  bool isVisible(String id) => online.contains(id);

  @override
  DateTime? lastSeenAt(String id) => null;
}

PairedDevice _device(String id, String name) => PairedDevice(
  id: id,
  name: name,
  platform: 'linux',
  address: '10.0.0.2',
  port: 51820,
  pairingSecret: 'secret-$id',
);

/// The graph arrives on a spring, and a node that has not arrived yet is
/// transparent: its semantics, and the words under it, are genuinely absent
/// until it settles. Past the response time by a wide margin.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 900));
}

Future<void> _pumpDevices(WidgetTester tester, MeshService mesh) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildNexusTheme(),
      home: DevicesView(mesh: mesh),
    ),
  );
  await tester.pump();
}

/// A transport with one peer. With [answers] false that peer never proves it
/// is there, so the supervisor's own retry curve reads exactly as it does for
/// a device that went away; with [answers] true the link is healthy.
class _TestTransport implements MeshTransport {
  _TestTransport(this.ids, {this.answers = false});

  final List<String> ids;
  final bool answers;

  @override
  List<TransportPeer> peers() => [
    for (final id in ids) TransportPeer(id: id, name: id),
  ];

  @override
  DateTime? lastHeardAt(String peerId) => answers ? DateTime.now() : null;

  @override
  Future<void> beat() async {}
}

/// A clock far enough in the past that a retry's next-attempt time is behind
/// it, so the row renders the plain words instead of a countdown.
DateTime _fixedClock() => DateTime(2000, 1, 1, 12);

/// A real supervisor watching one peer, driven by hand: [start] takes the
/// first look, the tick after it finds silence past the timeout with an
/// attempt already recorded — the exact condition a row turns into
/// "Reconnecting…". Its tick timer is an hour long, so no assertion here
/// depends on wall-clock time passing; callers stop it after the pump.
Future<ConnectionSupervisor> _watching(
  String peerId, {
  bool answers = false,
  DateTime Function()? clock,
}) async {
  final supervisor = ConnectionSupervisor(
    transport: _TestTransport([peerId], answers: answers),
    clock: clock,
    tickInterval: const Duration(hours: 1),
  );
  await supervisor.start();
  if (!answers) await supervisor.tick();
  return supervisor;
}

void main() {
  testWidgets('one paired device is spoken about in the singular', (
    tester,
  ) async {
    await _pumpDevices(tester, _FakeMesh([_device('a', 'Nova')]));

    // A device that is already paired is on screen straight away: the store is
    // read synchronously, so the tab never flashes "nothing here" at someone
    // who has something here.
    //
    // Found by its row rather than by its name, because the graph names it too
    // now: one node above, one row below, and the row is the rendering of
    // record. Exactly one of those is the invariant.
    expect(find.widgetWithText(NexusRow, 'Nova'), findsOneWidget);
    expect(
      find.text('No devices yet'),
      findsNothing,
      reason: 'a paired device must never be shown an empty state',
    );

    expect(find.text("Your device isn't reachable right now."), findsOneWidget);
    expect(
      find.textContaining('None of your 1 devices'),
      findsNothing,
      reason: 'a count of one is not a count worth printing',
    );
  });

  testWidgets('one paired device that is reachable says so, in the singular', (
    tester,
  ) async {
    await _pumpDevices(
      tester,
      _FakeMesh([_device('a', 'Nova')], online: {'a'}),
    );

    expect(find.text('Your device is reachable right now.'), findsOneWidget);
    expect(find.textContaining('All 1 devices'), findsNothing);
  });

  testWidgets('two paired devices still get the count', (tester) async {
    await _pumpDevices(
      tester,
      _FakeMesh([_device('a', 'Nova'), _device('b', 'Ridge')]),
    );

    expect(find.widgetWithText(NexusRow, 'Nova'), findsOneWidget);
    expect(find.widgetWithText(NexusRow, 'Ridge'), findsOneWidget);
    expect(
      find.text('None of your 2 devices are reachable right now.'),
      findsOneWidget,
    );
    expect(
      find.textContaining("isn't reachable"),
      findsNothing,
      reason: 'the singular line belongs to the single-device case only',
    );
  });

  testWidgets('one of two devices reachable still names both', (tester) async {
    await _pumpDevices(
      tester,
      _FakeMesh([_device('a', 'Nova'), _device('b', 'Ridge')], online: {'a'}),
    );

    expect(find.text('1 of 2 devices reachable right now.'), findsOneWidget);
  });

  testWidgets(
    'the link state is read once: on the graph, not again in the row',
    (tester) async {
      final handle = tester.ensureSemantics();

      await _pumpDevices(tester, _FakeMesh([_device('a', 'Nova')]));
      await _settle(tester);

      // The row is the device index: what the device is, and the way into it.
      final row = tester.getSemantics(
        find.bySemanticsLabel(RegExp(r'^Nova\.')),
      );
      expect(row.label, 'Nova. Linux');
      expect(
        row.label.contains('Offline'),
        isFalse,
        reason:
            'the picture above is where the link state is read; a row that '
            'repeats it gives the same fact two homes, and two homes disagree',
      );
      expect(
        row.tooltip,
        isEmpty,
        reason: 'and the state is not hidden behind a hover hint either',
      );

      // It is read where it belongs: under the node, in words, beside the line
      // the painter draws for it.
      expect(find.text('Offline'), findsOneWidget);
      expect(
        find.textContaining('Offline'),
        findsOneWidget,
        reason: 'exactly one reading of the state on the whole screen',
      );

      handle.dispose();
    },
  );

  testWidgets('a peer the supervisor is retrying says Reconnecting', (
    tester,
  ) async {
    final supervisor = await _watching('a', clock: _fixedClock);

    await _pumpDevices(
      tester,
      _FakeMesh([_device('a', 'Nova')], supervisor: supervisor),
    );
    // The row has spoken; the timer must not outlive the test.
    await supervisor.stop();

    await _settle(tester);

    expect(find.text('Reconnecting…'), findsOneWidget);
    expect(
      find.textContaining('Offline'),
      findsNothing,
      reason: 'a link being retried is not the same thing as an absent device',
    );
    expect(
      find.textContaining('Reconnecting'),
      findsOneWidget,
      reason: 'the state is read once — under the node it belongs to',
    );
  });

  testWidgets('a retrying peer says how long until the next try', (
    tester,
  ) async {
    // A real clock: the supervisor schedules its next attempt seconds from
    // now, which is the only case where a countdown means anything.
    final supervisor = await _watching('a');

    await _pumpDevices(
      tester,
      _FakeMesh([_device('a', 'Nova')], supervisor: supervisor),
    );
    await supervisor.stop();

    await _settle(tester);

    expect(
      find.textContaining(RegExp(r'Reconnecting · next try in \d+s')),
      findsOneWidget,
      reason: 'the wait shown is the backoff the supervisor is actually on',
    );
  });

  testWidgets('a link the supervisor has heard from still reads Online', (
    tester,
  ) async {
    final supervisor = await _watching('a', answers: true);
    expect(supervisor.links.single.up, isTrue);

    await _pumpDevices(
      tester,
      _FakeMesh([_device('a', 'Nova')], online: {'a'}, supervisor: supervisor),
    );
    await supervisor.stop();
    await _settle(tester);

    expect(find.textContaining('Online'), findsOneWidget);
    expect(find.textContaining('Reconnecting'), findsNothing);
  });

  testWidgets('a peer the supervisor is not retrying still reads Offline', (
    tester,
  ) async {
    // A healthy link, but the mesh has never verified this device: the row
    // must keep saying Offline, so the new state never swallows the old one.
    final supervisor = await _watching('a', answers: true);

    await _pumpDevices(
      tester,
      _FakeMesh([_device('a', 'Nova')], supervisor: supervisor),
    );
    await supervisor.stop();
    await _settle(tester);

    // The node is where this device's state is read now, and it must keep
    // saying Offline: the supervisor's new state never swallows the old one.
    expect(find.text('Offline'), findsOneWidget);
    expect(find.textContaining('Reconnecting'), findsNothing);
  });

  // The graph is a picture of the same links, drawn from the same two sources
  // the rows read: the mesh's own reachability and the supervisor's retry. What
  // is pinned here is that a screen reader gets that state from a node — the
  // only place on the picture it can be read, since a dashed line cannot be
  // heard — and that the picture gives way to the list when it cannot carry
  // the mesh any more.
  group('the graph', () {
    testWidgets(
      'a node names its device and the state the supervisor reports',
      (tester) async {
        final supervisor = await _watching('a', clock: _fixedClock);
        final handle = tester.ensureSemantics();

        await _pumpDevices(
          tester,
          _FakeMesh([_device('a', 'Nova')], supervisor: supervisor),
        );
        await _settle(tester);
        await supervisor.stop();

        final node = tester.getSemantics(
          find.bySemanticsLabel(RegExp(r'^Nova,')),
        );
        expect(
          node.label,
          'Nova, Reconnecting',
          reason:
              'the node draws the link from the same verdict the row prints',
        );

        handle.dispose();
      },
    );

    testWidgets(
      'the centre node is this device, and is not a device to act on',
      (tester) async {
        final handle = tester.ensureSemantics();

        await _pumpDevices(tester, _FakeMesh([_device('a', 'Nova')]));
        await _settle(tester);

        final self = tester.getSemantics(
          find.bySemanticsLabel(RegExp(r'^Test PC,')),
        );
        expect(self.label, 'Test PC, this device');
        expect(
          self.getSemanticsData().hasAction(SemanticsAction.longPress),
          isFalse,
          reason: 'there is no unpairing this device from itself',
        );
        // The paired device's node does take the gesture.
        expect(
          tester
              .getSemantics(find.bySemanticsLabel(RegExp(r'^Nova,')))
              .getSemanticsData()
              .hasAction(SemanticsAction.longPress),
          isTrue,
        );

        handle.dispose();
      },
    );

    testWidgets('a fourth peer opens a second ring instead of piling up', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      // A window tall enough to build the whole page: the graph is a two-ring
      // picture now, so on the default test window the list below it never
      // comes into view, and would be missing for a reason that has nothing to
      // do with what is being measured.
      tester.view.physicalSize = const Size(420, 1500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final four = [
        for (final id in ['a', 'b', 'c', 'd']) _device(id, 'Device $id'),
      ];

      await _pumpDevices(tester, _FakeMesh(four));
      await _settle(tester);

      // Every device is on the picture and in the list — the two rings exist
      // so the fourth device has somewhere to go, rather than the graph giving
      // up and handing the mesh to the list.
      expect(find.byType(NexusRow), findsNWidgets(four.length));
      for (final id in ['a', 'b', 'c', 'd']) {
        expect(
          find.bySemanticsLabel(RegExp('^Device $id,')),
          findsOneWidget,
          reason: 'Device $id has a node of its own',
        );
      }

      // And the ring really is a ring. Measured between peers, not from the
      // centre node: a node's box is taller than its disc (it holds the name
      // and the state under it), and the centre node's box is a different size
      // again, so distances from it are distances between boxes, not between
      // discs. Peers share one box size, so their distances to each other are
      // the ring's own chords — which for three on a circle are equal.
      Offset centreOf(String id) =>
          tester.getCenter(find.bySemanticsLabel(RegExp('^Device $id,')));
      double chord(String a, String b) => (centreOf(a) - centreOf(b)).distance;
      final sides = [chord('a', 'b'), chord('b', 'c'), chord('c', 'a')];
      final widest = sides.reduce((a, b) => a > b ? a : b);
      final narrowest = sides.reduce((a, b) => a < b ? a : b);
      expect(
        widest - narrowest,
        lessThan(1.0),
        reason: 'the first three sit on one ring — an even triangle',
      );
      expect(
        chord('d', 'a'),
        greaterThan(widest),
        reason: 'and the fourth is on a ring outside them',
      );

      handle.dispose();
    });

    testWidgets('past twelve devices the list carries the mesh on its own', (
      tester,
    ) async {
      final many = [
        for (final id in [
          'a',
          'b',
          'c',
          'd',
          'e',
          'f',
          'g',
          'h',
          'i',
          'j',
          'k',
          'l',
          'm',
        ])
          _device(id, 'Device $id'),
      ];

      await _pumpDevices(tester, _FakeMesh(many));
      await _settle(tester);

      // Thirteen rows and not one node: past what two rings can carry, the
      // list is the honest rendering — and it says the state itself, because
      // there is no picture left to read it from.
      expect(find.byType(NexusRow), findsNWidgets(many.length));
      expect(find.text('Device a'), findsOneWidget);
      expect(
        find.textContaining('Offline'),
        findsNWidgets(many.length),
        reason: 'with no graph, every row carries its own state words',
      );
    });

    testWidgets('with the picture up, the rows do not say the state again', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(420, 1500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await _pumpDevices(
        tester,
        _FakeMesh(
          [_device('a', 'Nova'), _device('b', 'Pulsar')],
          online: {'a'},
        ),
      );
      await _settle(tester);

      // The picture is up, and it is where the state lives: the online node
      // says so. The list below it used to say the same thing twice over —
      // once in words and once as a dot — which is what a graph makes
      // redundant.
      expect(
        tester.getSemantics(find.bySemanticsLabel(RegExp(r'^Nova,'))).label,
        'Nova, Online',
      );
      for (final word in ['Online', 'Offline', 'Reconnecting']) {
        expect(
          find.descendant(
            of: find.byType(NexusRow),
            matching: find.textContaining(word),
          ),
          findsNothing,
          reason: 'the node already says $word; the row does not repeat it',
        );
      }

      // What the row keeps is the thing the picture cannot draw: what kind of
      // device this is. Two rows, two subtitles, no state words either side.
      expect(
        find.descendant(
          of: find.byType(NexusRow),
          matching: find.text('Linux'),
        ),
        findsNWidgets(2),
      );
    });

    testWidgets('the picture pans and zooms, so a wide mesh is still reachable', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(420, 1500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      // Six peers: two full rings, which is a canvas wider than the page — the
      // case panning exists for.
      final six = [
        for (final id in ['a', 'b', 'c', 'd', 'e', 'f'])
          _device(id, 'Device $id'),
      ];

      await _pumpDevices(tester, _FakeMesh(six));
      await _settle(tester);

      final viewer = find.byType(InteractiveViewer);
      expect(viewer, findsOneWidget, reason: 'the picture is a canvas now');

      Offset nodeAt(String id) =>
          tester.getCenter(find.bySemanticsLabel(RegExp('^Device $id,')));
      final frame = tester.getRect(viewer);

      // A drag on the picture moves the picture. Started away from the nodes,
      // because a finger that lands on a node is a finger on that node.
      final before = nodeAt('a');
      final drag = await tester.startGesture(
        Offset(frame.left + 12, frame.center.dy),
      );
      for (var i = 0; i < 6; i++) {
        await drag.moveBy(const Offset(-14, 0));
        await tester.pump();
      }
      await drag.up();
      await tester.pump();
      final after = nodeAt('a');
      expect(
        after.dx,
        lessThan(before.dx - 20),
        reason: 'the canvas followed the finger instead of resisting it',
      );

      // And a pinch zooms the same picture. Two fingers, apart: a node off the
      // pinch's own centre must travel further from it, which is what zooming
      // means on a picture.
      double spread() => (nodeAt('a') - tester.getCenter(viewer)).distance;
      final spreadBefore = spread();
      final centre = tester.getCenter(viewer);
      final left = await tester.startGesture(centre - const Offset(24, 0));
      final right = await tester.startGesture(centre + const Offset(24, 0));
      for (var i = 0; i < 8; i++) {
        await left.moveBy(const Offset(-10, 0));
        await right.moveBy(const Offset(10, 0));
        await tester.pump();
      }
      await left.up();
      await right.up();
      await tester.pumpAndSettle();
      expect(
        spread(),
        greaterThan(spreadBefore + 4),
        reason: 'the picture grew under the pinch',
      );
    });
  });
}
