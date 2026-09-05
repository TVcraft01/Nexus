import 'dart:io';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nexus/core/identity.dart';
import 'package:nexus/core/query_log.dart';
import 'package:nexus/core/reminders.dart';
import 'package:nexus/core/speech.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/mesh/mesh_service.dart';
import 'package:nexus/ui/assistant_view.dart';
import 'package:nexus/ui/theme.dart';

/// A recognizer that "hears" a fixed utterance (or nothing) — the test
/// stand-in for Android's SpeechRecognizer.
class _FakeSpeechInput extends SpeechInput {
  _FakeSpeechInput(this.heard);
  final String? heard;

  @override
  bool get available => true;

  @override
  Future<String?> listen() async => heard;
}

/// Playtest of the assistant as a first real user drives it: the real
/// AssistantView widgets, real MeshService, real store. Covers the main
/// flow (a typo gets a "did you mean" suggestion) plus the careless
/// versions — empty submits, gibberish, wrong answers to a pending
/// question, and typing the same thing twice in a row.
void main() {
  // The chat thread is a lazy reverse ListView, so as it grows the oldest
  // entries scroll out of the widget tree — assertions must target the
  // newest exchange (its status chip), never global bubble counts.

  Future<void> ask(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
  }

  Future<(NexusStore, MeshService)> boot() async {
    final store = NexusStore(
      explicitPath: '${Directory.systemTemp.createTempSync('pt').path}/s.json',
    )..clipboardSync = true;
    final mesh = MeshService(
      identity: DeviceInfo(
        id: 'playtest-device',
        name: 'Playtest PC',
        platform: 'linux',
      ),
      store: store,
    );
    return (store, mesh);
  }

  Widget harness(MeshService mesh, {Key? key}) => MaterialApp(
    theme: buildNexusTheme(),
    home: Scaffold(
      body: AssistantView(key: key, mesh: mesh),
    ),
  );

  testWidgets('main flow: a typo is offered as "did you mean", yes learns it, '
      'and the lesson survives a restart', (tester) async {
    final (store, mesh) = await boot();
    try {
      await tester.pumpWidget(harness(mesh));
      await tester.pump();

      // Welcome view is showing (no paired devices).
      expect(find.textContaining('Hello! I am Nexus.'), findsOneWidget);

      // A typo of a known command → question card offering the meaning.
      await ask(tester, 'what time is is');
      expect(find.text('Question'), findsOneWidget);
      expect(find.textContaining('Did you mean'), findsOneWidget);
      expect(find.textContaining('what time is it'), findsWidgets);
      // The composer tells the user it is now an answer box.
      expect(find.text('Type your answer…'), findsOneWidget);

      // Confirming with "yes" runs it…
      await ask(tester, 'yes');
      expect(find.text('Question'), findsNothing);
      expect(find.text('Done'), findsOneWidget);
      expect(find.textContaining("It's "), findsOneWidget);
      // …and remembers the phrase on this device.
      expect(store.agentLearned['what time is is'], 'what time is it');

      // "Restart": a brand-new AssistantView on the same store.
      await tester.pumpWidget(harness(mesh, key: UniqueKey()));
      await tester.pump();
      await ask(tester, 'what time is is');
      expect(find.text('Question'), findsNothing);
      expect(find.textContaining("It's "), findsOneWidget);
    } finally {
      QueryLog.i.resetForTest();
      await mesh.stop();
    }
  });

  testWidgets(
    'careless: whitespace and empty sends are harmless; gibberish asks to '
    'teach; a bad answer re-asks instead of wedging',
    (tester) async {
      final (store, mesh) = await boot();
      try {
        await tester.pumpWidget(harness(mesh));
        await tester.pump();

        // Whitespace-only submit must be a no-op.
        await ask(tester, '   ');
        expect(find.byIcon(Icons.send_rounded), findsOneWidget);
        expect(find.textContaining('Hello! I am Nexus.'), findsOneWidget);

        // Empty submit via the send button must be a no-op too.
        await tester.tap(find.byIcon(Icons.send_rounded));
        await tester.pump();
        expect(find.textContaining('Hello! I am Nexus.'), findsOneWidget);

        // Gibberish → a teach question, never a crash or fake success.
        await ask(tester, 'zzz qqq xyz');
        expect(find.text('Question'), findsOneWidget);
        expect(find.textContaining('don\'t understand'), findsOneWidget);

        // A wrong answer (not yes, not a known command) re-asks the same
        // question instead of wedging the conversation.
        await ask(tester, 'no');
        expect(find.text('Question'), findsOneWidget);
        expect(find.textContaining('still don\'t understand'), findsOneWidget);

        // Teaching a real command closes the loop.
        await ask(tester, 'roll a dice');
        expect(find.text('Question'), findsNothing);
        expect(find.text('Done'), findsOneWidget);
        expect(find.textContaining(RegExp(r'Rolled a [1-6]!')), findsOneWidget);
        expect(store.agentLearned['zzz qqq xyz'], 'roll a dice');
      } finally {
        QueryLog.i.resetForTest();
        await mesh.stop();
      }
    },
  );

  testWidgets(
    'careless: rapid re-ask of the same typo stays calm and runs from memory',
    (tester) async {
      final (store, mesh) = await boot();
      try {
        await tester.pumpWidget(harness(mesh));
        await tester.pump();

        await ask(tester, 'what time is is');
        expect(find.textContaining('Did you mean'), findsOneWidget);

        // The user ignores the question and asks the same thing again —
        // the pending answer takes it, so the loop must stay sane (no crash,
        // still one open question).
        await ask(tester, 'what time is is');
        expect(find.text('Question'), findsOneWidget);

        // Now answer properly: "yes" runs the suggestion and learns it.
        await ask(tester, 'yes');
        expect(find.text('Question'), findsNothing);
        expect(find.text('Done'), findsOneWidget);
        expect(store.agentLearned['what time is is'], 'what time is it');

        // Same typo again → runs directly from memory, no question at all.
        await ask(tester, 'what time is is');
        expect(find.text('Question'), findsNothing);
        expect(find.text('Done'), findsOneWidget);
      } finally {
        QueryLog.i.resetForTest();
        await mesh.stop();
      }
    },
  );

  testWidgets(
    'first-run path: tapping a suggestion chip sends it like typing it',
    (tester) async {
      final (store, mesh) = await boot();
      try {
        await tester.pumpWidget(harness(mesh));
        await tester.pump();

        // The welcome view points at the blue chips under the input.
        await tester.tap(find.widgetWithText(ActionChip, 'what can you do'));
        await tester.pump();
        expect(find.textContaining('Here is what I can do:'), findsOneWidget);

        // A second chip keeps working after the first exchange — and the
        // memory chip answers honestly on a fresh store.
        await tester.tap(
          find.widgetWithText(ActionChip, 'what do you know about me'),
        );
        await tester.pump();
        expect(
          find.textContaining('don\'t remember anything about you yet'),
          findsOneWidget,
        );
      } finally {
        QueryLog.i.resetForTest();
        await mesh.stop();
      }
    },
  );

  testWidgets(
    'memory flow: remember a fact, recall it, restart, still remembered, '
    'then forget it',
    (tester) async {
      final (store, mesh) = await boot();
      try {
        await tester.pumpWidget(harness(mesh));
        await tester.pump();

        // Tell it something about me, like a first user would.
        await ask(tester, 'remember that my wifi password is nexus');
        expect(find.textContaining('Remembered:'), findsOneWidget);

        // Ask what it knows.
        await ask(tester, 'what do you know about me');
        expect(find.textContaining('Here is what I know:'), findsOneWidget);
        expect(find.textContaining('wifi password is nexus'), findsWidgets);

        // Restart on the same store: the fact must survive.
        await tester.pumpWidget(harness(mesh, key: UniqueKey()));
        await tester.pump();
        await ask(tester, 'what do you know about wifi');
        expect(find.textContaining('About "wifi":'), findsOneWidget);
        expect(find.textContaining('wifi password is nexus'), findsWidgets);

        // Careless: forgetting something it does not know is honest.
        await ask(tester, 'forget the moon');
        expect(
          find.textContaining('don\'t remember anything like'),
          findsOneWidget,
        );

        // Forgetting the real thing removes it for good.
        await ask(tester, 'forget my wifi password');
        expect(find.textContaining('Forgotten:'), findsOneWidget);
        await ask(tester, 'what do you know about me');
        expect(
          find.textContaining('don\'t remember anything about you yet'),
          findsOneWidget,
        );
        expect(store.agentFacts, isEmpty);
      } finally {
        QueryLog.i.resetForTest();
        await mesh.stop();
      }
    },
  );

  testWidgets(
    'dream flow: a dead-end ask lands in the dream review, teaching it '
    'closes the gap and persists',
    (tester) async {
      final (store, mesh) = await boot();
      // Real file IO never completes inside the test zone; feed the reader
      // synchronously instead — the production path is unit-tested in
      // dream_test.
      QueryLog.readAllOverride = () async => [
        '{"ts":"t","kind":"ask","input":"bring me home","status":"needsInfo","route":"teach:bring me home","detail":""}',
      ];
      try {
        await tester.pumpWidget(harness(mesh));
        await tester.pump();

        // Open the dream review from the assistant header.
        await tester.tap(find.byIcon(Icons.psychology_alt_outlined));
        await tester.pumpAndSettle();
        expect(find.text('What I still misunderstand'), findsOneWidget);
        expect(find.text('"bring me home"  ·  asked 1 time'), findsOneWidget);

        // Teach it from the sheet; the row leaves the list.
        await tester.enterText(
          find.byKey(const ValueKey('dream-meaning')),
          'show my devices',
        );
        await tester.tap(find.byIcon(Icons.check_rounded));
        await tester.pumpAndSettle();
        expect(find.text('"bring me home"  ·  asked 1 time'), findsNothing);
        expect(find.text('Sweet dreams.'), findsNothing);

        // The lesson is real: persisted, broadcast-eligible, and it runs —
        // typed straight into the composer, no question this time.
        expect(store.agentLearned['bring me home'], 'show my devices');
        await ask(tester, 'bring me home');
        expect(find.text('Question'), findsNothing);
        expect(find.text('Done'), findsOneWidget);
      } finally {
        QueryLog.readAllOverride = null;
        QueryLog.i.resetForTest();
        await mesh.stop();
      }
    },
  );

  testWidgets('dream review with a clean log is a friendly empty state', (
    tester,
  ) async {
    final (store, mesh) = await boot();
    QueryLog.readAllOverride = () async => const [];
    try {
      await tester.pumpWidget(harness(mesh));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.psychology_alt_outlined));
      await tester.pumpAndSettle();
      expect(find.text('Sweet dreams.'), findsOneWidget);
    } finally {
      QueryLog.readAllOverride = null;
      QueryLog.i.resetForTest();
      await mesh.stop();
    }
  });

  testWidgets(
    'proactive dream nudge: startup gaps surface by themselves, and '
    'teaching one clears the nudge',
    (tester) async {
      final (store, mesh) = await boot();
      // A phrase the assistant failed on twice, still untaught.
      QueryLog.readAllOverride = () async => [
        '{"ts":"t","kind":"ask","input":"bring me home","status":"needsInfo","route":"teach:bring me home","detail":""}',
        '{"ts":"t","kind":"ask","input":"bring me home","status":"needsInfo","route":"teach:bring me home","detail":""}',
      ];
      try {
        await tester.pumpWidget(harness(mesh));
        await tester.pump(); // first frame
        await tester.pump(); // post-frame log read resolves

        // The assistant says so itself, before being asked — the nudge
        // names the phrase it keeps missing.
        final nudge = find.byKey(const ValueKey('dream-nudge'));
        expect(nudge, findsOneWidget);
        expect(
          find.textContaining('"bring me home"'),
          findsWidgets,
          reason: 'the nudge should name the missed phrase',
        );

        // Tapping it opens the same dream review as the header button.
        await tester.tap(nudge);
        await tester.pumpAndSettle();
        expect(find.text('What I still misunderstand'), findsOneWidget);

        // Teach it inside the sheet; the row leaves the list.
        await tester.enterText(
          find.byKey(const ValueKey('dream-meaning')),
          'show my devices',
        );
        await tester.tap(find.byIcon(Icons.check_rounded));
        await tester.pumpAndSettle();
        expect(find.text('"bring me home"  ·  asked 1 time'), findsNothing);

        // Closing the sheet re-checks the log: no gaps left, nudge gone.
        await tester.tapAt(const Offset(10, 10)); // barrier above the sheet
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('dream-nudge')), findsNothing);
        expect(store.agentLearned['bring me home'], 'show my devices');
      } finally {
        QueryLog.readAllOverride = null;
        QueryLog.i.resetForTest();
        await mesh.stop();
      }
    },
  );

  testWidgets(
    'dream-learn: a phrase the user keeps re-asking that matches one they '
    'taught is offered as a one-tap fix',
    (tester) async {
      final (store, mesh) = await boot();
      // The user taught "text mom" once; the log shows "tex mom" failing
      // twice as a fresh ask — the dream should connect the dots itself.
      store.agentLearned = {'text mom': 'call tvcraft01'};
      QueryLog.readAllOverride = () async => [
        '{"ts":"t","kind":"ask","input":"tex mom","status":"needsInfo","route":"teach:tex mom","detail":""}',
        '{"ts":"t","kind":"ask","input":"tex mom","status":"needsInfo","route":"teach:tex mom","detail":""}',
      ];
      try {
        await tester.pumpWidget(harness(mesh));
        await tester.pump(); // first frame
        await tester.pump(); // post-frame log read resolves

        // The specific learn card appears above the composer — the fix,
        // not a generic "teach me?".
        final card = find.byKey(const ValueKey('dream-learn-card'));
        expect(card, findsOneWidget);
        expect(find.textContaining('"tex mom"'), findsWidgets);
        expect(find.textContaining('"text mom"'), findsWidgets);

        // One tap learns it through the real teach funnel — persisted,
        // broadcast-eligible, echoed in the thread.
        await tester.tap(find.byKey(const ValueKey('dream-learn-button')));
        await tester.pump();
        expect(store.agentLearned['tex mom'], 'call tvcraft01');
        expect(find.textContaining('now means'), findsOneWidget);
        expect(find.byKey(const ValueKey('dream-learn-card')), findsNothing);

        // And the lesson is real: typed straight into the composer, the
        // phrase runs without a question — it reached the phone's contact
        // on this device-less box only as far as the honest teach prompt
        // would, so assert the routing instead: no "did you mean".
        await ask(tester, 'tex mom');
        expect(find.textContaining('Did you mean'), findsNothing);
      } finally {
        QueryLog.readAllOverride = null;
        QueryLog.i.resetForTest();
        await mesh.stop();
      }
    },
  );

  testWidgets(
    'personal predictions: repeated asks replace the generic chips, and '
    'tapping one asks again',
    (tester) async {
      final (store, mesh) = await boot();
      // Three resolved asks of the same phrase — a real habit.
      QueryLog.readAllOverride = () async => [
        '{"ts":"t","kind":"ask","input":"roll a dice","status":"succeeded","route":"message","detail":""}',
        '{"ts":"t","kind":"ask","input":"roll a dice","status":"succeeded","route":"message","detail":""}',
        '{"ts":"t","kind":"ask","input":"roll a dice","status":"succeeded","route":"message","detail":""}',
      ];
      try {
        await tester.pumpWidget(harness(mesh));
        await tester.pump(); // first frame
        await tester.pump(); // log read resolves

        // The chips row predicts the user's own routine instead of the
        // generic catalog — the habit is the only chip and the catalog's
        // opener is gone.
        expect(find.byType(ActionChip), findsOneWidget);
        expect(find.widgetWithText(ActionChip, 'roll a dice'), findsOneWidget);
        expect(find.widgetWithText(ActionChip, 'what can you do'), findsNothing);

        // Tapping the predicted chip asks it — a real dice roll reply.
        await tester.tap(find.widgetWithText(ActionChip, 'roll a dice').first);
        await tester.pumpAndSettle();
        expect(find.textContaining('olled a'), findsWidgets);
      } finally {
        QueryLog.readAllOverride = null;
        QueryLog.i.resetForTest();
        await mesh.stop();
      }

      // No history yet — the generic discovery chips stay. A fresh State
      // (as after a restart) reads the empty log and falls back to the
      // catalog.
      final (freshStore, freshMesh) = await boot();
      QueryLog.readAllOverride = () async => const [];
      try {
        await tester.pumpWidget(harness(freshMesh, key: UniqueKey()));
        await tester.pump();
        await tester.pump();
        // The generic discovery row is back — it opens with the catalog's
        // first chip, not the user's routine.
        expect(find.widgetWithText(ActionChip, 'what can you do'), findsOneWidget);
        expect(find.widgetWithText(ActionChip, 'roll a dice'), findsNothing);
      } finally {
        QueryLog.readAllOverride = null;
        QueryLog.i.resetForTest();
        await freshMesh.stop();
      }
    },
  );

  testWidgets('the nudge is once per session and honors a clean log', (
    tester,
  ) async {
    final (store, mesh) = await boot();
    QueryLog.readAllOverride = () async => [
      '{"ts":"t","kind":"ask","input":"bring me home","status":"needsInfo","route":"teach:bring me home","detail":""}',
    ];
    try {
      await tester.pumpWidget(harness(mesh));
      await tester.pump();
      await tester.pump();
      final nudge = find.byKey(const ValueKey('dream-nudge'));
      expect(nudge, findsOneWidget);

      // Dismissing it silences the session. Opening the dream review from
      // the header and closing it re-checks the log — the gaps are still
      // there, yet the nudge must not come back.
      await tester.tap(find.byTooltip('Not now'));
      await tester.pump();
      expect(nudge, findsNothing);
      await tester.tap(find.byIcon(Icons.psychology_alt_outlined));
      await tester.pumpAndSettle();
      expect(find.text('What I still misunderstand'), findsOneWidget);
      await tester.tapAt(const Offset(10, 10)); // barrier above the sheet
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('dream-nudge')), findsNothing);
    } finally {
      QueryLog.readAllOverride = null;
      QueryLog.i.resetForTest();
      await mesh.stop();
    }

    // A clean log never nudges.
    final (cleanStore, cleanMesh) = await boot();
    QueryLog.readAllOverride = () async => const [];
    try {
      await tester.pumpWidget(harness(cleanMesh));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('dream-nudge')), findsNothing);
    } finally {
      QueryLog.readAllOverride = null;
      QueryLog.i.resetForTest();
      await cleanMesh.stop();
    }
  });

  testWidgets('voice: the mic turns spoken words into the same command flow', (tester) async {
    final (store, mesh) = await boot();
    // A recognizer that "hears" one utterance, exactly like Android's.
    SpeechInput.override = () => _FakeSpeechInput('what time is it');
    try {
      await tester.pumpWidget(harness(mesh));
      await tester.pump();

      await tester.tap(find.byTooltip('Speak your question'));
      await tester.pump(); // listening
      await tester.pump(); // recognized text resolves

      // The recognized words ran through the real pipeline — a real answer.
      expect(find.textContaining("It's "), findsWidgets);
    } finally {
      SpeechInput.override = null;
      QueryLog.i.resetForTest();
      await mesh.stop();
    }
  });

  testWidgets('voice: nothing heard answers honestly, never a silent mic', (tester) async {
    final (store, mesh) = await boot();
    SpeechInput.override = () => _FakeSpeechInput(null);
    try {
      await tester.pumpWidget(harness(mesh));
      await tester.pump();

      await tester.tap(find.byTooltip('Speak your question'));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('didn\'t catch that'), findsWidgets);
    } finally {
      SpeechInput.override = null;
      QueryLog.i.resetForTest();
      await mesh.stop();
    }
  });

  testWidgets('voice: a device without a speech service says so', (tester) async {
    final (store, mesh) = await boot();
    // No override — the real SpeechInput, on a desktop host: available is
    // false, so the mic must answer honestly instead of pretending.
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      await tester.pumpWidget(harness(mesh));
      await tester.pump();

      await tester.tap(find.byTooltip('Speak your question'));
      await tester.pump();
      expect(find.textContaining('Voice input isn\'t set up'), findsWidgets);
      // And nothing was submitted — the thread stays on the honest answer.
      expect(find.textContaining("It's "), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      QueryLog.i.resetForTest();
      await mesh.stop();
    }
  });

  testWidgets('a reminder fires by itself, is acknowledged, and survives a restart', (tester) async {
    final (store, mesh) = await boot();
    // A fixed clock: 7:59pm when asked, 8:01pm when the reminder is due.
    var now = DateTime(2026, 9, 5, 19, 59);
    Reminders.nowOverride = () => now;
    try {
      await tester.pumpWidget(harness(mesh));
      await tester.pump();

      // Setting it promises to say it back — nothing fires yet.
      await ask(tester, 'remind me to take out the trash at 8pm');
      expect(find.textContaining('Reminder set for 8:00pm'), findsOneWidget);
      expect(find.byKey(const ValueKey('reminder-banner')), findsNothing);
      expect(store.agentReminders, hasLength(1));

      // Time passes; the assistant keeps its promise by itself.
      now = now.add(const Duration(minutes: 2));
      await tester.pump(const Duration(seconds: 16)); // the periodic check
      expect(find.text('Reminder: take out the trash.'), findsWidgets);
      expect(find.byKey(const ValueKey('reminder-banner')), findsOneWidget);

      // Done acknowledges it; the reminder is spent — one shot, like real.
      await tester.tap(find.byTooltip('Done'));
      await tester.pump();
      expect(find.byKey(const ValueKey('reminder-banner')), findsNothing);
      expect(store.agentReminders, isEmpty);

      // A pending reminder made before a restart still fires afterwards.
      store.agentReminders = [
        '{"id":"r-seeded","text":"stretch","dueAt":"2026-09-05T19:58:00.000"}',
      ];
      now = now.add(const Duration(minutes: 1));
      await tester.pumpWidget(harness(mesh, key: UniqueKey()));
      await tester.pump();
      expect(find.text('Reminder: stretch.'), findsWidgets);
      expect(find.byKey(const ValueKey('reminder-banner')), findsOneWidget);
      expect(store.agentReminders, isEmpty); // fired once, never again
    } finally {
      Reminders.nowOverride = null;
      QueryLog.i.resetForTest();
      await mesh.stop();
    }
  });
}
