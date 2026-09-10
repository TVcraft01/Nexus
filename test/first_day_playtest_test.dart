// The integrated first-day journey: one user, one device, every phase
// working together through the real surface — onboarding and rename
// (profile), teach + fast path (commands), the brain answering with memory
// in the prompt (Phases 1–2), and the skill loop reordering what the user
// sees (Phase 3). Lives in its own file because the profile store needs a
// SharedPreferences mock, which must not leak into the other playtest tests.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nexus/core/brain.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/query_log.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/mesh/mesh_service.dart';
import 'package:nexus/ui/assistant_view.dart';
import 'package:nexus/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A brain that answers instantly and records everything it was given — the
/// stand-in for the real Ollama-backed [LocalBrain], proving what actually
/// reaches the model: the persona, the memory, and the history.
class _RecordingBrain extends LocalBrain {
  String? lastSystem;
  List<ChatTurn>? lastHistory;
  int replyCalls = 0;

  @override
  Future<String?> availableModel({bool refresh = false}) async => 'llama3.2:3b';

  @override
  Future<BrainReply> reply({
    required String system,
    required List<ChatTurn> history,
    double temperature = 0.7,
    int maxTokens = 300,
  }) {
    replyCalls++;
    lastSystem = system;
    lastHistory = history;
    return Future.value((text: 'brain answer: rough days are allowed.', reachable: true));
  }
}

void main() {
  Future<void> ask(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
  }

  Future<(NexusStore, MeshService)> boot() async {
    final store = NexusStore(
      explicitPath: '${Directory.systemTemp.createTempSync('firstday').path}/s.json',
    )..clipboardSync = true;
    final mesh = MeshService(
      identity: DeviceInfo(
        id: 'first-day-device',
        name: 'First Day PC',
        platform: 'linux',
      ),
      store: store,
    );
    return (store, mesh);
  }

  Widget harness(MeshService mesh, {Key? key, LocalBrain? brain}) => MaterialApp(
    theme: buildNexusTheme(),
    home: Scaffold(
      body: AssistantView(key: key, mesh: mesh, brain: brain),
    ),
  );

  testWidgets('mid-onboarding typing cannot submit or close setup; the '
      'composer returns after Start', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final (store, mesh) = await boot();
    final brain = _RecordingBrain();
    try {
      await tester.pumpWidget(harness(mesh, brain: brain));
      await tester.pump();
      await tester.pump();
      expect(find.text('Set me up — 30 seconds.'), findsOneWidget);

      // The composer and every chat affordance are out of the tree while
      // setup is open — only the two setup fields remain.
      expect(find.byType(TextField), findsNWidgets(2));
      expect(find.byIcon(Icons.send_rounded), findsNothing);
      expect(find.byIcon(Icons.mic_none_rounded), findsNothing);

      // Typing in a setup field and pressing done must not submit anything:
      // no command runs, no brain call, setup stays open.
      await tester.enterText(find.widgetWithText(TextField, 'Your name'), 'sam');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(find.text('Set me up — 30 seconds.'), findsOneWidget);
      expect(brain.replyCalls, 0);
      expect(find.byIcon(Icons.send_rounded), findsNothing);

      // Complete setup — the composer comes back and works normally.
      await tester.enterText(
        find.widgetWithText(TextField, 'What should I be called?'),
        'Atlas',
      );
      await tester.tap(find.text('Start'));
      await tester.pump();
      await tester.pump();
      await tester.pump(); // the save + mesh broadcast settle
      expect(find.textContaining("I'm Atlas"), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget); // just the composer
      await ask(tester, 'what time is it');
      expect(find.textContaining("It's "), findsWidgets);
    } finally {
      QueryLog.i.resetForTest();
      await mesh.stop();
    }
  });

  testWidgets('first day on one device: onboard, teach, fast path, brain '
      'with memory, skill chips', (tester) async {
    // A brand-new user: no saved profile anywhere, so the first-run
    // onboarding must open.
    SharedPreferences.setMockInitialValues({});
    // Wide viewport so every horizontal skill chip is built.
    tester.view.physicalSize = const Size(2000, 1200);
    tester.view.devicePixelRatio = 1.0;
    final (store, mesh) = await boot();
    final brain = _RecordingBrain();
    String askLine(String input, String route) => jsonEncode({
      'ts': '2026-09-05T10:00:00.000',
      'kind': 'ask',
      'input': input,
      'status': 'succeeded',
      'route': route,
      'detail': '',
    });
    try {
      await tester.pumpWidget(harness(mesh, brain: brain));
      await tester.pump();
      await tester.pump();

      // 1) First-run onboarding: name the assistant and yourself, then
      //    start. The greeting carries both names.
      expect(find.text('Set me up — 30 seconds.'), findsOneWidget);
      // Label-based: the chat composer's TextField also exists in the tree
      // during onboarding, so positional finders are ambiguous.
      await tester.enterText(
        find.widgetWithText(TextField, 'What should I be called?'),
        'Atlas',
      );
      await tester.enterText(find.widgetWithText(TextField, 'Your name'), 'sam');
      await tester.tap(find.text('Start'));
      await tester.pump();
      await tester.pump();
      await tester.pump(); // the save + mesh broadcast settle
      await tester.pump();
      expect(find.textContaining("I'm Atlas"), findsOneWidget);
      expect(find.textContaining('Sam'), findsWidgets);

      // 2) Fast path: a known command answers instantly — the brain is
      //    never consulted.
      await ask(tester, 'what time is it');
      expect(find.textContaining("It's "), findsWidgets);
      expect(brain.replyCalls, 0);

      // 3) Teach: an unknown phrase goes to the brain — and the quiet
      //    "teach me" affordance on its answer opens the real teach loop.
      //    The taught phrase then runs on the fast path, brain untouched.
      await ask(tester, 'blorble');
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('brain answer'), findsWidgets);
      expect(find.text('Or teach me what this means'), findsOneWidget);
      await tester.tap(find.text('Or teach me what this means'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Teach "blorble"'), findsOneWidget);
      // The dialog's field is the last TextField in the tree (the composer
      // is still behind it).
      await tester.enterText(find.byType(TextField).last, 'what time is it');
      await tester.tap(find.text('Teach'));
      await tester.pump();
      await tester.pump();
      await ask(tester, 'blorble');
      expect(find.text('Question'), findsNothing); // learned — no teach card
      expect(find.textContaining("It's "), findsWidgets);
      expect(brain.replyCalls, 1); // fast path — the brain was never asked

      // 4) The brain answers an unknown phrase — and the memory actually
      //    informs the conversation: the persona, the names, and the
      //    taught phrase all reach the prompt.
      await ask(tester, 'i had a rough day today');
      await tester.pump();
      await tester.pump();
      expect(brain.replyCalls, 2); // the new unknown phrase reached the brain
      expect(find.textContaining('brain answer'), findsWidgets);
      expect(brain.lastSystem, contains('You are Atlas'));
      expect(brain.lastSystem, contains("Sam's own devices"));
      expect(
        brain.lastSystem,
        contains('Commands Sam has taught: "blorble" means "what time is it"'),
      );

      // 5) Real usage feeds the skill loop. The asks above went through
      //    the real _logAsk (enriched routes); the log FILE cannot flush in
      //    widget tests, so the read seam is stubbed with the lines those
      //    asks wrote — the same convention the dream tests use. The chips
      //    then lead with the skills this user actually reaches for, and
      //    the brain's context names them.
      await ask(tester, 'set a timer for 5 minutes');
      await ask(tester, 'set a timer for 10 minutes');
      await ask(tester, 'search for cats');
      QueryLog.readAllOverride = () async => [
        askLine('set a timer for 5 minutes', 'timer.set'),
        askLine('set a timer for 10 minutes', 'timer.set'),
        askLine('search for cats', 'search.web'),
      ];
      // One more ask triggers the refresh that re-ranks the chips.
      await ask(tester, 'what time is it');
      await tester.pump();
      await tester.pump();
      final chipTexts = tester
          .widgetList<ActionChip>(find.byType(ActionChip))
          .map((chip) => (chip.label as Text).data)
          .toList();
      expect(
        chipTexts,
        ['what can you do', 'set a timer for 5 minutes', 'search for cats'],
      );

      // The brain hears the same ranking.
      await ask(tester, 'i had a long day');
      await tester.pump();
      await tester.pump();
      expect(brain.lastSystem, contains('Skills Sam reaches for most:'));
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