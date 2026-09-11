import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/mesh/mesh_service.dart';
import 'package:nexus/ui/home_shell.dart';
import 'package:nexus/ui/theme.dart';

void main() {
  testWidgets('shell renders the devices view with no paired devices', (tester) async {
    final store = NexusStore(explicitPath: '${Directory.systemTemp.createTempSync('w').path}/s.json');
    final mesh = MeshService(
      identity: DeviceInfo(id: 'test-device', name: 'Test PC', platform: 'linux'),
      store: store,
    );

    await tester.pumpWidget(MaterialApp(theme: buildNexusTheme(), home: HomeShell(mesh: mesh)));
    await tester.pump();

    expect(find.text('Nexus'), findsOneWidget);

    // The shell opens on the assistant; devices is one destination over.
    await tester.tap(find.byIcon(Icons.devices_other_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Everything connected to Nexus.'), findsOneWidget);
    expect(find.text('No devices yet'), findsOneWidget);

    await mesh.stop();
  });
}
