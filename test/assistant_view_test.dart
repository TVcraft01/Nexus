import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent_contract.dart';
import 'package:nexus/core/brain.dart';
import 'package:nexus/core/device_actions.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/mesh/mesh_service.dart';
import 'package:nexus/core/query_log.dart';
import 'package:nexus/ui/assistant_view.dart';
import 'package:nexus/ui/device_executor.dart';
import 'package:nexus/ui/nexus_core.dart';
import 'package:nexus/ui/theme.dart';

/// An executor whose only behaviour is to fail the way real platform code can:
/// by throwing out of the awaited call. This is the one path a widget test
/// cannot otherwise reach, and it is exactly the path that used to strand the
/// core's "working" state.
class _ThrowingExecutor extends DeviceExecutor {
  int runs = 0;

  @override
  Future<ActionResult> run(AgentRequest request) async {
    runs++;
    throw StateError('the platform call exploded');
  }
}

/// An executor that refuses the way the real one does when the request is
/// missing something the user has to supply: it says what it needs.
class _AskingExecutor extends DeviceExecutor {
  int runs = 0;

  @override
  Future<ActionResult> run(AgentRequest request) async {
    runs++;
    return const ActionResult(
      false,
      'Where should I take you?',
      needsDetail: true,
    );
  }
}

/// An executor whose action genuinely cannot run on this device.
class _FailingExecutor extends DeviceExecutor {
  int runs = 0;

  @override
  Future<ActionResult> run(AgentRequest request) async {
    runs++;
    return const ActionResult(false, 'This device has no maps app.');
  }
}

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

  testWidgets('the core follows the real pipeline, not a mood', (tester) async {
    final store = NexusStore(
      explicitPath: '${Directory.systemTemp.createTempSync('core1').path}/s.json',
    );
    final mesh = MeshService(
      identity: DeviceInfo(id: 'test-device', name: 'Test PC', platform: 'linux'),
      store: store,
    );

    NexusCoreState coreState() =>
        tester.widget<NexusCore>(find.byType(NexusCore)).state;

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildNexusTheme(),
          home: Scaffold(body: AssistantView(mesh: mesh)),
        ),
      );
      await tester.pump();

      // Nothing asked, no paired devices: Nexus is here and idle. It is not
      // "offline", because with nothing paired there is nothing to be
      // offline from.
      expect(coreState(), NexusCoreState.idle);

      // A real ask that Nexus genuinely cannot carry out on this device — the
      // pipeline returns `unavailable`, and that is the one failure the core
      // reports.
      await tester.enterText(find.byType(TextField), 'blink the esp32');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(find.text('Unavailable'), findsOneWidget);
      expect(coreState(), NexusCoreState.error);

      // Nexus answering for itself clears it: a successful ask is not a
      // failure, so the core rests again.
      await tester.enterText(find.byType(TextField), 'what time is it');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(coreState(), NexusCoreState.idle);

      // A denied approval is the user's own choice, not an error.
      await tester.enterText(find.byType(TextField), 'copy hello to my phone');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(find.text('Approval needed'), findsOneWidget);
      expect(coreState(), NexusCoreState.idle);
    } finally {
      QueryLog.i.resetForTest();
      await mesh.stop();
    }
  });

  testWidgets('New conversation starts a fresh thread instead of returning '
      'to the greeting', (tester) async {
    final store = NexusStore(
      explicitPath: '${Directory.systemTemp.createTempSync('core2').path}/s.json',
    );
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

      // First run, nothing paired and no thread yet: the greeting card is
      // what a device that has never talked to Nexus would show.
      expect(find.text('Hello! I am Nexus.'), findsOneWidget);

      // Have a conversation.
      await tester.enterText(find.byType(TextField), 'what time is it');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(find.textContaining("It's "), findsOneWidget);
      expect(find.text('Hello! I am Nexus.'), findsNothing);

      await tester.tap(find.byTooltip('New conversation'));
      await tester.pump();

      // The thread is gone, the composer is empty and ready...
      expect(find.textContaining("It's "), findsNothing);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          isEmpty);
      final focus = tester.widget<TextField>(find.byType(TextField)).focusNode;
      expect(focus?.hasFocus, isTrue,
          reason: 'a new conversation should land in the composer');

      // ...and it is a new conversation, not a device reset: the greeting the
      // user has already read must not come back.
      expect(find.text('Hello! I am Nexus.'), findsNothing);
      expect(find.text('Ask me anything — I listen and do.'), findsOneWidget);

      // And it still works: the next ask runs against the same Nexus.
      await tester.enterText(find.byType(TextField), 'what time is it');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(find.textContaining("It's "), findsOneWidget);
    } finally {
      QueryLog.i.resetForTest();
      await mesh.stop();
    }
  });

  testWidgets('an action that throws cannot strand the core on Working',
      (tester) async {
    final store = NexusStore(
      explicitPath: '${Directory.systemTemp.createTempSync('throw').path}/s.json',
    );
    final mesh = MeshService(
      identity: DeviceInfo(id: 'test-device', name: 'Test PC', platform: 'linux'),
      store: store,
    );
    final executor = _ThrowingExecutor();

    NexusCoreState coreState() =>
        tester.widget<NexusCore>(find.byType(NexusCore)).state;

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildNexusTheme(),
          home: Scaffold(
            body: AssistantView(mesh: mesh, executor: executor),
          ),
        ),
      );
      await tester.pump();

      // A command this device runs itself, so it goes through the executor.
      await tester.enterText(find.byType(TextField), 'take me home');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      // Let the action start, throw, and unwind: the future is unawaited, so
      // its error is delivered on a later turn of the loop, not inline.
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      await tester.idle();

      expect(
        executor.runs,
        greaterThan(0),
        reason: 'the command must reach the executor for this to prove anything',
      );

      // Nothing escapes: no unhandled async error, which is what used to
      // happen and what made the failure invisible to the user.
      expect(tester.takeException(), isNull);

      // The user is told, in the thread, with the reason attached.
      expect(
        find.textContaining("didn't run"),
        findsOneWidget,
        reason: 'a failed action must say so',
      );

      // And it leaves no claim behind: nothing is running now, so the core
      // must not say that it is. Before the `finally`, `_sending` stayed true
      // here and the core reported "Working" indefinitely — a state outliving
      // the work it describes.
      expect(
        coreState(),
        isNot(NexusCoreState.working),
        reason: 'the action threw; nothing is in flight',
      );
    } finally {
      QueryLog.i.resetForTest();
      await mesh.stop();
    }
  });

  testWidgets('a device action missing a detail is a question, not a failure',
      (tester) async {
    // The defect this guards: "Who should I call?" arrived as
    // `unavailable`, so the chip read "Unavailable" over a question and the
    // core reported an error for a request it had merely asked about.
    final store = NexusStore(
      explicitPath: '${Directory.systemTemp.createTempSync('asking').path}/s.json',
    );
    final mesh = MeshService(
      identity: DeviceInfo(id: 'ask-device', name: 'Ask PC', platform: 'linux'),
      store: store,
    );
    final executor = _AskingExecutor();

    NexusCoreState coreState() =>
        tester.widget<NexusCore>(find.byType(NexusCore)).state;

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildNexusTheme(),
          home: Scaffold(body: AssistantView(mesh: mesh, executor: executor)),
        ),
      );
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'take me home');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      await tester.idle();

      expect(
        executor.runs,
        greaterThan(0),
        reason: 'the command must reach the executor for this to prove anything',
      );

      // The chip names the kind of card and shows the question itself.
      expect(find.text('Question'), findsOneWidget);
      expect(find.text('Where should I take you?'), findsOneWidget);
      expect(find.text('Unavailable'), findsNothing);

      // And the core is not blamed: nothing failed, a detail is missing.
      expect(
        coreState(),
        isNot(NexusCoreState.error),
        reason: 'a question is not an error',
      );
    } finally {
      QueryLog.i.resetForTest();
      await mesh.stop();
    }
  });

  testWidgets('a genuine failure still reads as Unavailable and errors',
      (tester) async {
    // The counterweight to the test above: the taxonomy must not have hidden
    // real failures behind the word "Question".
    final store = NexusStore(
      explicitPath:
          '${Directory.systemTemp.createTempSync('failing').path}/s.json',
    );
    final mesh = MeshService(
      identity: DeviceInfo(id: 'fail-device', name: 'Fail PC', platform: 'linux'),
      store: store,
    );
    final executor = _FailingExecutor();

    NexusCoreState coreState() =>
        tester.widget<NexusCore>(find.byType(NexusCore)).state;

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildNexusTheme(),
          home: Scaffold(body: AssistantView(mesh: mesh, executor: executor)),
        ),
      );
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'take me home');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      await tester.idle();

      expect(find.text('Unavailable'), findsOneWidget);
      expect(find.text('This device has no maps app.'), findsOneWidget);
      expect(find.text('Question'), findsNothing);
      expect(coreState(), NexusCoreState.error);
    } finally {
      QueryLog.i.resetForTest();
      await mesh.stop();
    }
  });

  testWidgets('a pending approval and the user\'s own no are not errors',
      (tester) async {
    // Both are the user in control: one is a gate they have not answered,
    // the other a no they gave. Neither may put the core into its error state.
    final store = NexusStore(
      explicitPath: '${Directory.systemTemp.createTempSync('deny').path}/s.json',
    )..clipboardSync = true;
    final mesh = MeshService(
      identity: DeviceInfo(id: 'deny-device', name: 'Deny PC', platform: 'linux'),
      store: store,
    );

    NexusCoreState coreState() =>
        tester.widget<NexusCore>(find.byType(NexusCore)).state;

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildNexusTheme(),
          home: Scaffold(body: AssistantView(mesh: mesh)),
        ),
      );
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'copy hello to my phone');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      // Waiting for the user: a question only they can answer.
      expect(find.text('Approval needed'), findsOneWidget);
      expect(coreState(), isNot(NexusCoreState.error));

      await tester.tap(find.text('Deny'));
      await tester.pump();

      // Answered "no": their choice, reported as one.
      expect(find.text('Denied'), findsOneWidget);
      expect(find.text('Unavailable'), findsNothing);
      expect(coreState(), isNot(NexusCoreState.error));
    } finally {
      QueryLog.i.resetForTest();
      await mesh.stop();
    }
  });

  testWidgets('a new conversation drops the question it left open',
      (tester) async {
    final store = NexusStore(
      explicitPath: '${Directory.systemTemp.createTempSync('core3').path}/s.json',
    );
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

      // An unknown phrase opens a teach question.
      await tester.enterText(find.byType(TextField), 'teleport me to mars');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(find.text('Question'), findsOneWidget);

      await tester.tap(find.byTooltip('New conversation'));
      await tester.pump();
      expect(find.text('Question'), findsNothing);

      // A command typed after the reset must run as itself. The abandoned
      // question is gone, so "what time is it" can never be learned as the
      // meaning of "teleport me to mars".
      await tester.enterText(find.byType(TextField), 'what time is it');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(find.textContaining("It's "), findsOneWidget);
      expect(find.text('Question'), findsNothing);
    } finally {
      QueryLog.i.resetForTest();
      await mesh.stop();
    }
  });

}
