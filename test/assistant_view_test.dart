import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/mesh/mesh_service.dart';
import 'package:nexus/core/query_log.dart';
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
      await tester.enterText(find.byType(TextField), 'teleport me to mars');
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

      // "what time is it" → a local answer card.
      await tester.enterText(find.byType(TextField), 'what time is it');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(find.text('Done'), findsOneWidget);
      expect(find.textContaining("It's "), findsOneWidget);

      // "copy hello" → approval prompt, then the Copy-now plan after approval.
      await tester.enterText(find.byType(TextField), 'copy hello to my phone');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(find.text('Approval needed'), findsOneWidget);
      await tester.tap(find.text('Approve'));
      await tester.pump();
      expect(find.text('Copy to my devices'), findsOneWidget);
      expect(find.text('Copy now'), findsOneWidget);
      // Approving replaced the approval card in place — no stale card remains.
      expect(find.text('Approval needed'), findsNothing);
    } finally {
      QueryLog.i.resetForTest();
      await mesh.stop();
    }
  });

  testWidgets('the conversation thread keeps every exchange, newest last', (tester) async {
    final store = NexusStore(
      explicitPath: '${Directory.systemTemp.createTempSync('avt2').path}/s.json',
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

      Future<void> ask(String text) async {
        await tester.enterText(find.byType(TextField), text);
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
      }

      // User bubbles render at 13.5px, suggestion chips at 12px — this
      // finder picks the bubble, not the chip.
      Finder bubble(String t) => find.byWidgetPredicate(
            (w) => w is Text && w.data == t && w.style?.fontSize == 13.5,
          );

      // Two exchanges in a row: both user bubbles survive, but only the
      // newest exchange still carries its status chip (history stays calm).
      await ask('what time is it');
      expect(bubble('what time is it'), findsOneWidget);
      await ask('show my devices');
      expect(bubble('what time is it'), findsOneWidget);
      expect(bubble('show my devices'), findsOneWidget);
      expect(find.text('No devices found.'), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
      // The older "what time" answer is still in the thread, frozen.
      expect(find.textContaining("It's "), findsOneWidget);
    } finally {
      QueryLog.i.resetForTest();
      await mesh.stop();
    }
  });
}
