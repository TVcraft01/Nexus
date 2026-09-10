// Boot merge: a rename synced over the mesh while this device was closed
// sits in the store (the mesh's headless fallback) and must be known after
// the next boot. Lives in its own file because the profile store needs a
// SharedPreferences mock, which must not leak into other view tests.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/brain.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/mesh/mesh_service.dart';
import 'package:nexus/core/query_log.dart';
import 'package:nexus/ui/assistant_view.dart';
import 'package:nexus/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('a rename synced while closed is known after boot',
      (tester) async {
    // Onboarded locally already, with untouched names — so no first-run UI
    // opens and the boot merge has pristine defaults to fill.
    SharedPreferences.setMockInitialValues({'nexus.profile.onboarded': true});
    final store = NexusStore(
      explicitPath: '${Directory.systemTemp.createTempSync('boot').path}/s.json',
    )..clipboardSync = true;
    // Another device renamed the user AND the assistant while this one was
    // off — the mesh stored the fallback; the local profile is untouched.
    store.profileUserName = 'Sam';
    store.profileAssistantName = 'Atlas';
    final mesh = MeshService(
      identity: DeviceInfo(id: 'test-device', name: 'Test PC', platform: 'linux'),
      store: store,
    );
    final brain = _ProbeBrain();

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildNexusTheme(),
          home: Scaffold(body: AssistantView(mesh: mesh, brain: brain)),
        ),
      );
      await tester.pump();
      await tester.pump(); // profile load + boot merge settle

      // The persona speaks as the synced assistant, to the synced user.
      await tester.enterText(find.byType(TextField), 'i had a rough day today');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('memory received'), findsOneWidget);
      expect(brain.lastSystem, contains('You are Atlas'));
      expect(brain.lastSystem, contains('Sam'));
      expect(brain.lastSystem, isNot(contains('Nexus')));
    } finally {
      QueryLog.i.resetForTest();
      await mesh.stop();
    }
  });
}

/// Records the real prompt the view assembled — the observable proof that
/// the boot-merged names reached the conversation.
class _ProbeBrain extends LocalBrain {
  String? lastSystem;

  @override
  Future<String?> availableModel({bool refresh = false}) async => 'llama3.2:3b';

  @override
  Future<BrainReply> reply({
    required String system,
    required List<ChatTurn> history,
    double temperature = 0.7,
    int maxTokens = 300,
  }) async {
    lastSystem = system;
    return (text: 'memory received', reachable: true);
  }
}