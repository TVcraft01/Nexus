import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/mesh/mesh_service.dart';
import 'package:nexus/ui/assistant_view.dart';
import 'package:nexus/ui/theme.dart';

void main() {
  testWidgets('command bar lists devices and rejects unknown commands', (tester) async {
    final store = NexusStore(
      explicitPath: '${Directory.systemTemp.createTempSync('avt').path}/s.json',
    )..clipboardSync = true;
    final mesh = MeshService(
      identity: DeviceInfo(id: 'test-device', name: 'Test PC', platform: 'linux'),
      store: store,
    );

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildNexusTheme(),
          home: Scaffold(body: AssistantView(mesh: mesh)),
        ),
      );
      await tester.pump();

      // Input field is present.
      expect(find.byType(TextField), findsOneWidget);

      // "show my devices" with no paired devices → empty list.
      await tester.enterText(find.byType(TextField), 'show my devices');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(find.text('Done'), findsOneWidget);
      expect(find.text('No devices found.'), findsOneWidget);

      // Unknown command → the assistant asks what it should mean (teachable).
      await tester.enterText(find.byType(TextField), 'bring me home');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(find.text('Question'), findsOneWidget);
      expect(find.textContaining('don\'t understand'), findsOneWidget);

      // Blink with no matching device → Unavailable (not an approval prompt).
      await tester.enterText(find.byType(TextField), 'blink the esp32');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(find.text('Unavailable'), findsOneWidget);
      expect(find.text('Approve'), findsNothing);
    } finally {
      await mesh.stop();
    }
  });
}
