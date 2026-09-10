import 'dart:async';
import 'dart:convert';
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

void main() {
  brainWidgetTests();

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

/// A brain that answers instantly without a server — the view's other half
/// (history building, replacing the teach card) gets exercised for real.
class _FakeBrain extends LocalBrain {
  @override
  Future<String?> availableModel({bool refresh = false}) async => 'llama3.2:3b';

  @override
  Future<BrainReply> reply({
    required String system,
    required List<ChatTurn> history,
    double temperature = 0.7,
    int maxTokens = 300,
  }) async {
    return (text: 'Hi! This is the local brain talking.', reachable: true);
  }
}

/// A brain that is never there: no model, no answer. The classic teach flow
/// must survive it untouched.
class _SilentBrain extends LocalBrain {
  @override
  Future<String?> availableModel({bool refresh = false}) async => null;

  @override
  Future<BrainReply> reply({
    required String system,
    required List<ChatTurn> history,
    double temperature = 0.7,
    int maxTokens = 300,
  }) async {
    return (text: null, reachable: false);
  }
}

/// A reachable brain that answers with nothing: the server is fine, the
/// model just produced no text. The status line must stay "online".
class _EmptyBrain extends LocalBrain {
  @override
  Future<String?> availableModel({bool refresh = false}) async => 'llama3.2:3b';

  @override
  Future<BrainReply> reply({
    required String system,
    required List<ChatTurn> history,
    double temperature = 0.7,
    int maxTokens = 300,
  }) async {
    return (text: null, reachable: true);
  }
}

/// A brain that records the context it was given — the real prompt and
/// history the view assembled, so memory injection is provable end to end.
class _RecordingBrain extends LocalBrain {
  String? lastSystem;
  List<ChatTurn>? lastHistory;

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
    lastHistory = history;
    return (text: 'memory received', reachable: true);
  }
}

/// A brain whose replies the test releases by hand, in any order — the
/// concurrency race is driven deterministically through [gates].
class _GateBrain extends LocalBrain {
  final List<Completer<BrainReply>> gates = [];

  @override
  Future<String?> availableModel({bool refresh = false}) async => 'llama3.2:3b';

  @override
  Future<BrainReply> reply({
    required String system,
    required List<ChatTurn> history,
    double temperature = 0.7,
    int maxTokens = 300,
  }) {
    final gate = Completer<BrainReply>();
    gates.add(gate);
    return gate.future;
  }
}

void brainWidgetTests() {
  testWidgets('unknown phrases get a conversational reply from the local brain',
      (tester) async {
    final store = NexusStore(
      explicitPath: '${Directory.systemTemp.createTempSync('avt_brain').path}/s.json',
    )..clipboardSync = true;
    final mesh = MeshService(
      identity: DeviceInfo(id: 'test-device', name: 'Test PC', platform: 'linux'),
      store: store,
    );

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildNexusTheme(),
          home: Scaffold(body: AssistantView(mesh: mesh, brain: _FakeBrain())),
        ),
      );
      await tester.pump();

      // The status line discovers the installed model.
      expect(find.textContaining('llama3.2:3b'), findsOneWidget);

      // A phrase the interpreter doesn't know → the brain answers instead of
      // the teach card. ("tell me a joke" is a built-in command, so the
      // phrase here must be genuinely unknown.)
      await tester.enterText(find.byType(TextField), 'i had a rough day today');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('don\'t understand'), findsNothing);
      expect(find.textContaining('local brain talking'), findsOneWidget);

      // Commands still keep their fast path — no brain involved.
      await tester.enterText(find.byType(TextField), 'what time is it');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(find.textContaining("It's "), findsOneWidget);
    } finally {
      QueryLog.i.resetForTest();
      await mesh.stop();
    }
  });

  testWidgets('when the brain is offline, the teach card comes back',
      (tester) async {
    final store = NexusStore(
      explicitPath: '${Directory.systemTemp.createTempSync('avt_silent').path}/s.json',
    )..clipboardSync = true;
    final mesh = MeshService(
      identity: DeviceInfo(id: 'test-device', name: 'Test PC', platform: 'linux'),
      store: store,
    );

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildNexusTheme(),
          home: Scaffold(body: AssistantView(mesh: mesh, brain: _SilentBrain())),
        ),
      );
      await tester.pump();

      // Status line admits there is no brain.
      expect(find.textContaining('Local brain offline'), findsOneWidget);

      // An unknown phrase must fall back to the classic teach card — and the
      // proven-offline brain must not even flash a Thinking placeholder or
      // attempt a doomed connection.
      await tester.enterText(find.byType(TextField), 'teleport me to mars');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.pump();
      expect(find.text('Thinking…'), findsNothing);
      expect(find.text('Question'), findsOneWidget);
      expect(find.textContaining('don\'t understand'), findsOneWidget);
    } finally {
      QueryLog.i.resetForTest();
      await mesh.stop();
    }
  });

  testWidgets('an empty model reply restores the teach card but keeps the '
      'brain online', (tester) async {
    final store = NexusStore(
      explicitPath: '${Directory.systemTemp.createTempSync('avt_empty').path}/s.json',
    )..clipboardSync = true;
    final mesh = MeshService(
      identity: DeviceInfo(id: 'test-device', name: 'Test PC', platform: 'linux'),
      store: store,
    );

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildNexusTheme(),
          home: Scaffold(body: AssistantView(mesh: mesh, brain: _EmptyBrain())),
        ),
      );
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'i had a rough day today');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.pump();

      // Nothing to show → the teach card returns…
      expect(find.text('Thinking…'), findsNothing);
      expect(find.textContaining('don\'t understand'), findsOneWidget);
      // …but the server answered, so the brain is NOT offline.
      expect(find.textContaining('Local brain: llama3.2:3b'), findsOneWidget);
      expect(find.textContaining('Local brain offline'), findsNothing);
    } finally {
      QueryLog.i.resetForTest();
      await mesh.stop();
    }
  });

  testWidgets('two quick questions: each reply lands on its own card',
      (tester) async {
    final store = NexusStore(
      explicitPath: '${Directory.systemTemp.createTempSync('avt_race').path}/s.json',
    )..clipboardSync = true;
    final mesh = MeshService(
      identity: DeviceInfo(id: 'test-device', name: 'Test PC', platform: 'linux'),
      store: store,
    );
    final brain = _GateBrain();

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildNexusTheme(),
          home: Scaffold(body: AssistantView(mesh: mesh, brain: brain)),
        ),
      );
      await tester.pump();

      Future<void> ask(String text) async {
        await tester.enterText(find.byType(TextField), text);
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
      }

      // Two unknown phrases in a row: both exchanges are in flight.
      // ("meaning of life" would parse as the define-word command — both
      // phrases here must be genuinely unknown.)
      await ask('i had a rough day today');
      await ask('my day was awful');
      expect(find.text('Thinking…'), findsNWidgets(2));
      expect(brain.gates, hasLength(2));

      // The SECOND reply lands first (out of order) — it must not clobber
      // the first exchange's card, and must not be clobbered by it.
      brain.gates[1].complete((text: 'answer to life', reachable: true));
      await tester.pump();
      expect(find.text('answer to life'), findsOneWidget);
      expect(find.text('Thinking…'), findsOneWidget);

      brain.gates[0].complete((text: 'sorry about your day', reachable: true));
      await tester.pump();
      expect(find.text('sorry about your day'), findsOneWidget);
      expect(find.text('answer to life'), findsOneWidget);
      expect(find.text('Thinking…'), findsNothing);
    } finally {
      QueryLog.i.resetForTest();
      await mesh.stop();
    }
  });

  testWidgets('the brain\'s context carries the shared memory',
      (tester) async {
    final store = NexusStore(
      explicitPath: '${Directory.systemTemp.createTempSync('avt_mem').path}/s.json',
    )..clipboardSync = true;
    final mesh = MeshService(
      identity: DeviceInfo(id: 'test-device', name: 'Test PC', platform: 'linux'),
      store: store,
    );
    final brain = _RecordingBrain();

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildNexusTheme(),
          home: Scaffold(body: AssistantView(mesh: mesh, brain: brain)),
        ),
      );
      await tester.pump();

      // Teach it a fact on the command fast path.
      await tester.enterText(find.byType(TextField), 'remember that my '
          'favorite color is teal');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      // A real conversation — the model must see the fact in its context.
      await tester.enterText(find.byType(TextField), 'i had a rough day today');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('memory received'), findsOneWidget);
      expect(brain.lastSystem, contains('my favorite color is teal'));
      expect(brain.lastSystem, contains('Nexus'));
      // The history ends with the real question, user role and all.
      expect(brain.lastHistory!.last.content, 'i had a rough day today');
      expect(brain.lastHistory!.last.role, 'user');
    } finally {
      QueryLog.i.resetForTest();
      await mesh.stop();
    }
  });

  testWidgets('a brain reply keeps the teaching loop one tap away',
      (tester) async {
    final store = NexusStore(
      explicitPath: '${Directory.systemTemp.createTempSync('avt_teach').path}/s.json',
    )..clipboardSync = true;
    final mesh = MeshService(
      identity: DeviceInfo(id: 'test-device', name: 'Test PC', platform: 'linux'),
      store: store,
    );

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildNexusTheme(),
          home: Scaffold(body: AssistantView(mesh: mesh, brain: _FakeBrain())),
        ),
      );
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'i had a rough day today');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('local brain talking'), findsOneWidget);

      // The affordance is there, and opens the teach dialog.
      await tester.tap(find.text('Or teach me what this means'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Teach "'), findsOneWidget);

      // Teach it a real command — the dialog validates and learns.
      await tester.enterText(find.byType(TextField).last, 'show my devices');
      await tester.tap(find.text('Teach'));
      await tester.pumpAndSettle();
      expect(find.textContaining('now means'), findsOneWidget);

      // The same phrase now runs the taught command on the fast path.
      await tester.enterText(find.byType(TextField), 'i had a rough day today');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(find.text('No devices found.'), findsOneWidget);
    } finally {
      QueryLog.i.resetForTest();
      await mesh.stop();
    }
  });

  testWidgets('skills the user actually uses lead the chips and the brain '
      'context', (tester) async {
    final store = NexusStore(
      explicitPath: '${Directory.systemTemp.createTempSync('avt_skills').path}/s.json',
    )..clipboardSync = true;
    final mesh = MeshService(
      identity: DeviceInfo(id: 'test-device', name: 'Test PC', platform: 'linux'),
      store: store,
    );
    final brain = _RecordingBrain();

    // Real ask-log lines, shaped exactly as the view writes them: two
    // different timer asks (a genuine timer pattern, but no single phrase
    // repeats into a habit) and one search ask.
    String askLine(String input, String route) => jsonEncode({
      'ts': '2026-09-05T10:00:00.000',
      'kind': 'ask',
      'input': input,
      'status': 'succeeded',
      'route': route,
      'detail': '',
    });
    QueryLog.readAllOverride = () async => [
      askLine('set a timer for 5 minutes', 'timer.set'),
      askLine('set a timer for 10 minutes', 'timer.set'),
      askLine('search for cats', 'search.web'),
    ];
    // Wide viewport so every horizontal chip is built.
    tester.view.physicalSize = const Size(2000, 1200);
    tester.view.devicePixelRatio = 1.0;

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildNexusTheme(),
          home: Scaffold(body: AssistantView(mesh: mesh, brain: brain)),
        ),
      );
      await tester.pump();
      await tester.pump();

      // Visible payoff: the one-tap chips lead with the skills in usage
      // order — discovery first, then Timers (used twice) before Search.
      final chipTexts = tester
          .widgetList<ActionChip>(find.byType(ActionChip))
          .map((chip) => (chip.label as Text).data)
          .toList();
      expect(
        chipTexts,
        ['what can you do', 'set a timer for 5 minutes', 'search for cats'],
      );

      // And the brain's context knows what matters to this user.
      await tester.enterText(find.byType(TextField), 'i had a rough day today');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('memory received'), findsOneWidget);
      expect(brain.lastSystem, contains('Skills'));
      expect(brain.lastSystem, contains('Timers'));
      expect(brain.lastSystem, contains('Search'));
    } finally {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      QueryLog.readAllOverride = null;
      QueryLog.i.resetForTest();
      await mesh.stop();
    }
  });

}
