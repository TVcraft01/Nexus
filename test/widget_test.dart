import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/mesh/mesh_service.dart';
import 'package:nexus/ui/home_shell.dart';
import 'package:nexus/ui/theme.dart';

/// MeshService is never started here: starting it opens real sockets, which
/// never complete under the fake async a widget test runs in.
MeshService _mesh() {
  final store = NexusStore(
    explicitPath: '${Directory.systemTemp.createTempSync('w').path}/s.json',
  );
  store.autoUpdate = false; // a shell test must not reach the network
  return MeshService(
    identity: DeviceInfo(id: 'test-device', name: 'Test PC', platform: 'linux'),
    store: store,
  );
}

void main() {
  testWidgets('the shell opens on the assistant, not a device list', (
    tester,
  ) async {
    final mesh = _mesh();

    await tester.pumpWidget(
      MaterialApp(theme: buildNexusTheme(), home: HomeShell(mesh: mesh)),
    );
    await tester.pump();

    // The first thing anyone sees is what Nexus is and where to talk to it.
    expect(find.text('Nexus'), findsOneWidget);
    expect(
      find.textContaining('Ready'),
      findsOneWidget,
      reason: 'the presence line must say what Nexus is doing',
    );
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byTooltip('Send'), findsOneWidget);

    await mesh.stop();
  });

  testWidgets('the devices tab teaches the first step when nothing is paired', (
    tester,
  ) async {
    final mesh = _mesh();

    await tester.pumpWidget(
      MaterialApp(theme: buildNexusTheme(), home: HomeShell(mesh: mesh)),
    );
    await tester.pump();

    await tester.tap(find.text('Devices').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    expect(find.text('Devices'), findsWidgets);
    expect(find.text('Everything Nexus can work across.'), findsOneWidget);
    // Phone-only mode: nothing paired means this phone, complete on its
    // own, plus the one way to pair — never an empty graph.
    expect(find.text('This phone'), findsOneWidget);
    expect(find.text('Pair another device'), findsOneWidget);
    expect(find.text('No devices yet'), findsNothing);

    await mesh.stop();
  });
}
