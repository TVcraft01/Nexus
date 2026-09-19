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
// The mesh is a list here, not a network: every state a phone can be in
// (nothing paired, one device, two devices, reachable or not) is set up
// directly, so no socket is opened and no port is assumed. The real service
// loads its paired devices from the same store this fake stands in for.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/mesh/mesh_service.dart';
import 'package:nexus/ui/devices_view.dart';
import 'package:nexus/ui/theme.dart';

/// A mesh that answers from a list instead of a network.
class _FakeMesh extends MeshService {
  _FakeMesh(this._devices, {this.online = const {}})
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
}
