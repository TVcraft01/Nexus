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
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/mesh/connection_supervisor.dart';
import 'package:nexus/mesh/mesh_service.dart';
import 'package:nexus/mesh/mesh_transport.dart';
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

Future<void> _pumpDevices(WidgetTester tester, MeshService mesh) async {
  await tester.pumpWidget(
    MaterialApp(theme: buildNexusTheme(), home: DevicesView(mesh: mesh)),
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
    expect(find.text('Nova'), findsOneWidget);
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

    expect(find.text('Nova'), findsOneWidget);
    expect(find.text('Ridge'), findsOneWidget);
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

  testWidgets('a device row names its status exactly once', (tester) async {
    final handle = tester.ensureSemantics();

    await _pumpDevices(tester, _FakeMesh([_device('a', 'Nova')]));

    final row = tester.getSemantics(find.bySemanticsLabel(RegExp(r'^Nova\.')));
    expect(row.label, 'Nova. Linux · Offline · last seen never');
    expect(
      row.label.split('Offline').length - 1,
      1,
      reason: 'the dot must not add a second reading of the status',
    );
    expect(
      row.tooltip,
      isEmpty,
      reason: 'the status is in the row, not hidden behind a hover hint',
    );

    handle.dispose();
  });

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

    expect(find.text('Linux · Reconnecting…'), findsOneWidget);
    expect(
      find.textContaining('Offline'),
      findsNothing,
      reason: 'a link being retried is not the same thing as an absent device',
    );
    expect(
      find.textContaining('Reconnecting'),
      findsOneWidget,
      reason: 'the state is read once, in the row',
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

    expect(find.text('Linux · Offline · last seen never'), findsOneWidget);
    expect(find.textContaining('Reconnecting'), findsNothing);
  });
}
