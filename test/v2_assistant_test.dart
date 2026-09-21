// The rebuilt Nexus v2 assistant: a conversation, not a dashboard.
//
// Every test here drives the real screen with fakes only at the platform
// edges (the device executor, the microphone, the speaker) — the interpreter,
// the conversation engine, the status vocabulary and the layout are the
// shipped ones. No sockets, no files, no clock dependence.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent_contract.dart';
import 'package:nexus/core/command_service.dart';
import 'package:nexus/core/device_actions.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/query_log.dart';
import 'package:nexus/core/speech.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/mesh/mesh_service.dart';
import 'package:nexus/ui/device_executor.dart';
import 'package:nexus/ui/nexus_v2/assistant_view.dart';
import 'package:nexus/ui/nexus_v2/design_system.dart';
import 'package:nexus/ui/nexus_v2/nexus_orb.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A device executor whose every answer the test writes, recording what it was
/// asked to do so the request itself is assertable.
class _FakeExecutor implements DeviceExecutor {
  _FakeExecutor(this.respond);

  final Future<ActionResult> Function(AgentRequest request) respond;
  final List<AgentRequest> seen = [];

  @override
  Future<ActionResult> run(AgentRequest request) {
    seen.add(request);
    return respond(request);
  }
}

class _FakeSpeechInput extends SpeechInput {
  _FakeSpeechInput(this.pending);

  /// Completed by the test when the user stops talking; null means they gave
  /// up, which is how the microphone's cancel path is exercised.
  final Completer<String?> pending;

  @override
  bool get available => true;

  @override
  Future<String?> listen() => pending.future;
}

class _RecordingSpeechOutput extends SpeechOutput {
  final List<String> spoken = [];

  @override
  bool get available => true;

  @override
  Future<bool> speak(String text) async {
    spoken.add(text);
    return true;
  }
}

class _FakePlayback extends SpeechPlayback {
  final notifier = ValueNotifier<bool>(false);

  @override
  bool get available => true;

  @override
  ValueListenable<bool> get speaking => notifier;

  @override
  void listen() {} // there is no channel behind this in a test
}

class _AssistantHarness {
  _AssistantHarness(this.mesh);

  final MeshService mesh;

  static _AssistantHarness create() {
    SharedPreferences.setMockInitialValues({});
    final store = NexusStore(
      explicitPath:
          '${Directory.systemTemp.createTempSync('v2_assistant').path}/s.json',
    )..autoUpdate = false;
    return _AssistantHarness(
      MeshService(
        identity: DeviceInfo(
          id: 'test-phone',
          name: 'Test Phone',
          platform: 'android',
        ),
        store: store,
      ),
    );
  }
}

Future<void> _pumpAssistant(
  WidgetTester tester, {
  required MeshService mesh,
  DeviceExecutor? executor,
  double topInset = 0,
  double width = 411,
  double height = 891,
}) async {
  tester.view.physicalSize = Size(width * 3, height * 3);
  tester.view.devicePixelRatio = 3;
  tester.view.padding = FakeViewPadding(top: topInset * 3);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.view.resetPadding();
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: buildNexusV2Theme(),
      home: Scaffold(
        body: NexusV2AssistantView(
          mesh: mesh,
          executor: executor,
        ),
      ),
    ),
  );
  await tester.pump(); // profile load
  await tester.pump();
}

/// Pumps a few frames without `pumpAndSettle`: a working globe is animating on
/// purpose, so settling would be waiting for the wrong thing.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<void> _ask(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.testTextInput.receiveAction(TextInputAction.send);
  await _settle(tester);
}

void main() {
  setUp(() {
    // Each test owns the log and the speech seams it needs.
    QueryLog.readAllOverride = () async => const [];
    SpeechInput.override = null;
    SpeechOutput.override = null;
    SpeechPlayback.override = null;
  });

  tearDown(() {
    QueryLog.readAllOverride = null;
    SpeechInput.override = null;
    SpeechOutput.override = null;
    SpeechPlayback.override = null;
  });

  testWidgets('the screen is a conversation, not a wall of example buttons',
      (tester) async {
    final harness = _AssistantHarness.create();
    await _pumpAssistant(tester, mesh: harness.mesh);

    // The four prompts the brief removed are gone in every casing, from the
    // screen and from the chips that replaced the buttons.
    String flat(String text) =>
        text.toLowerCase().replaceAll('’', "'").trim();
    final shown = tester
        .widgetList<Text>(find.byType(Text))
        .map((c) => flat(c.data ?? c.textSpan?.toPlainText() ?? ''))
        .toList();
    for (final removed in const [
      'what can you do',
      "what's on my calendar",
      'find my other devices',
      'remember this for me',
    ]) {
      expect(
        shown.where((text) => text.contains(removed)),
        isEmpty,
        reason: 'the brief removed this prompt: "$removed"',
      );
    }
    expect(find.text('Ready when you are.'), findsNothing);
    expect(
      find.textContaining('Tell me what you need'),
      findsOneWidget,
    );

    // At most two, never a wall of them.
    final chips = tester
        .widgetList<ActionChip>(find.byType(ActionChip))
        .map((chip) => (chip.label as Text).data!)
        .toList();
    expect(chips, isNotEmpty);
    expect(chips.length, lessThanOrEqualTo(2));

    await harness.mesh.stop();
  });

  testWidgets('every suggestion offered is carried out, not just understood',
      (tester) async {
    // Enumerated from a fresh screen, then each one tapped on its own fresh
    // screen: a chip is only offered if the shipped path really does something
    // with it, so no tap may end at an approval nothing can grant or at a
    // "not available yet".
    final probe = _AssistantHarness.create();
    await _pumpAssistant(tester, mesh: probe.mesh);
    final chips = tester
        .widgetList<ActionChip>(find.byType(ActionChip))
        .map((chip) => (chip.label as Text).data!)
        .toList();
    await probe.mesh.stop();
    expect(chips, isNotEmpty);

    for (final chip in chips) {
      // A blank tree first: pumping the same widget shape twice would update
      // the existing State instead of starting a new screen, and the previous
      // chip's thread would still be there.
      await tester.pumpWidget(const SizedBox.shrink());
      final harness = _AssistantHarness.create();
      await _pumpAssistant(tester, mesh: harness.mesh);
      await tester.tap(find.widgetWithText(ActionChip, chip));
      await _settle(tester);

      final shown = tester
          .widgetList<Text>(find.byType(Text))
          .map((c) => (c.data ?? c.textSpan?.toPlainText() ?? '').toLowerCase())
          .toList();
      for (final leak in const [
        'approval',
        'not available yet',
        "i don't understand",
      ]) {
        expect(shown.where((t) => t.contains(leak)), isEmpty,
            reason: 'the chip "$chip" did not really run');
      }
      // The ask and its reply are both in the thread now.
      expect(find.text(chip), findsOneWidget);
      await harness.mesh.stop();
    }
  });

  testWidgets('a routine that cannot really run is never offered',
      (tester) async {
    // "copy hello to my phone" is a real command that parses — and still ends
    // at a local gate nothing can open, so it must not become a chip.
    QueryLog.readAllOverride = () async => [
          '{"kind":"ask","input":"copy hello to my phone",'
              '"route":"clipboard.write","status":"succeeded"}',
          '{"kind":"ask","input":"copy hello to my phone",'
              '"route":"clipboard.write","status":"succeeded"}',
        ];
    final harness = _AssistantHarness.create();
    await _pumpAssistant(tester, mesh: harness.mesh);
    await _settle(tester); // the post-frame habit read

    // Parsing is not the reason it is held back: it really is a command.
    final interpreter = CommandService(devices: () => const []);
    expect(interpreter.parsesAsCommand('copy hello to my phone'), isTrue);

    expect(
      find.widgetWithText(ActionChip, 'copy hello to my phone'),
      findsNothing,
    );
    // The usable starters are still offered, so the list is not just empty.
    expect(find.widgetWithText(ActionChip, 'what time is it'), findsOneWidget);
    await harness.mesh.stop();
  });

  testWidgets('the user\'s own routine is what gets offered next',
      (tester) async {
    QueryLog.readAllOverride = () async => [
          '{"kind":"ask","input":"take a screenshot","route":"screenshot",'
              '"status":"succeeded"}',
          '{"kind":"ask","input":"take a screenshot","route":"screenshot",'
              '"status":"succeeded"}',
        ];
    final executor = _FakeExecutor(
      (request) async => const ActionResult(true, 'Screenshot saved.'),
    );
    final harness = _AssistantHarness.create();
    await _pumpAssistant(tester, mesh: harness.mesh, executor: executor);
    await _settle(tester); // the post-frame habit read

    expect(find.widgetWithText(ActionChip, 'take a screenshot'), findsOneWidget);

    // Offered because it really runs: the tap goes through the platform.
    await tester.tap(find.widgetWithText(ActionChip, 'take a screenshot'));
    await _settle(tester);
    expect(executor.seen.single.action, AgentActions.screenshot);
    expect(find.text('Screenshot saved.'), findsOneWidget);
    await harness.mesh.stop();
  });

  testWidgets('an answer becomes the conversation', (tester) async {
    final harness = _AssistantHarness.create();
    await _pumpAssistant(tester, mesh: harness.mesh);

    await _ask(tester, 'what time is it');

    // The ask is a bubble in a thread now; the greeting card it replaced is
    // gone, and the presence line never left.
    expect(find.text('what time is it'), findsOneWidget);
    expect(find.textContaining('Tell me what you need'), findsNothing);
    expect(find.byType(ListView), findsOneWidget);
    await harness.mesh.stop();
  });

  testWidgets('a failure says what happened and can be tried again',
      (tester) async {
    var calls = 0;
    final executor = _FakeExecutor((request) async {
      calls++;
      return calls == 1
          ? const ActionResult(false, 'Could not take the screenshot.')
          : const ActionResult(true, 'Screenshot saved.');
    });
    final harness = _AssistantHarness.create();
    await _pumpAssistant(tester, mesh: harness.mesh, executor: executor);

    await _ask(tester, 'take a screenshot');

    expect(executor.seen.single.action, AgentActions.screenshot);
    expect(find.text('Could not take the screenshot.'), findsOneWidget);
    expect(find.text('That did not work'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);

    await tester.tap(find.text('Try again'));
    await _settle(tester);

    expect(calls, 2);
    expect(find.text('Screenshot saved.'), findsOneWidget);
    expect(find.text('Try again'), findsNothing);
    await harness.mesh.stop();
  });

  testWidgets('a missing detail is a question, never a failure',
      (tester) async {
    final executor = _FakeExecutor(
      (request) async =>
          const ActionResult(false, 'What should I play?', needsDetail: true),
    );
    final harness = _AssistantHarness.create();
    await _pumpAssistant(tester, mesh: harness.mesh, executor: executor);

    await _ask(tester, 'play music');

    expect(find.text('What should I play?'), findsOneWidget);
    expect(find.text('That did not work'), findsNothing);
    expect(find.text('I need one more thing'), findsNothing);
    // Answering is the recovery here, so there is nothing to retry.
    expect(find.text('Try again'), findsNothing);
    await harness.mesh.stop();
  });

  testWidgets('near matches become real choices, and the answer is learned',
      (tester) async {
    final executor = _FakeExecutor((request) async {
      final contact = request.arguments['contact']?.toString() ?? '';
      if (contact != 'Alex') {
        return const ActionResult(
          false,
          'No contact named "alx" on this device.',
          candidates: ['Alex', 'Alicia'],
        );
      }
      return const ActionResult(true, 'Calling Alex.');
    });
    final harness = _AssistantHarness.create();
    await _pumpAssistant(tester, mesh: harness.mesh, executor: executor);

    await _ask(tester, 'call alx');

    expect(find.text('Which one did you mean?'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Call Alex'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Call Alicia'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Call Alex'));
    await _settle(tester);

    expect(executor.seen.last.arguments['contact'], 'Alex');
    expect(find.text('Calling Alex.'), findsOneWidget);
    expect(find.text('Which one did you mean?'), findsNothing);
    // The correction is a fact now, not just a one-off choice.
    expect(
      harness.mesh.store.agentFacts.any(
        (fact) => fact.contains('alx') && fact.contains('Alex'),
      ),
      isTrue,
    );
    await harness.mesh.stop();
  });

  testWidgets('declining the question leaves nothing hanging', (tester) async {
    final executor = _FakeExecutor(
      (request) async => const ActionResult(
        false,
        'No contact named "alx" on this device.',
        candidates: ['Alex'],
      ),
    );
    final harness = _AssistantHarness.create();
    await _pumpAssistant(tester, mesh: harness.mesh, executor: executor);

    await _ask(tester, 'call alx');
    await tester.tap(find.text('Not now'));
    await _settle(tester);

    expect(find.text('Which one did you mean?'), findsNothing);
    expect(find.text('Okay — nothing was sent or called.'), findsOneWidget);
    await harness.mesh.stop();
  });

  testWidgets('voice in, reply out, and the globe says which',
      (tester) async {
    final input = _FakeSpeechInput(Completer<String?>());
    final output = _RecordingSpeechOutput();
    final playback = _FakePlayback();
    SpeechInput.override = () => input;
    SpeechOutput.override = () => output;
    SpeechPlayback.override = () => playback;

    final harness = _AssistantHarness.create();
    await _pumpAssistant(tester, mesh: harness.mesh);
    final handle = tester.ensureSemantics();

    await tester.tap(find.byTooltip('Use voice'));
    await tester.pump();

    // The microphone really is open, so the globe may say so.
    expect(find.bySemanticsLabel('Nexus — Listening'), findsOneWidget);
    expect(find.textContaining('Listening — say it'), findsOneWidget);

    input.pending.complete('what time is it');
    await _settle(tester);

    // The utterance ran through the same pipeline as typing, and the reply to
    // a spoken ask was read out loud exactly once.
    expect(find.text('what time is it'), findsOneWidget);
    expect(output.spoken.length, 1);

    // And the speaking state comes only from the engine's own report.
    expect(find.bySemanticsLabel('Nexus — Speaking'), findsNothing);
    playback.notifier.value = true;
    await tester.pump();
    expect(find.bySemanticsLabel('Nexus — Speaking'), findsOneWidget);
    expect(find.textContaining('Speaking'), findsOneWidget);
    playback.notifier.value = false;
    await tester.pump();
    expect(find.bySemanticsLabel('Nexus — Speaking'), findsNothing);

    handle.dispose();
    await harness.mesh.stop();
  });

  testWidgets('the globe clears the status bar, and nothing overflows',
      (tester) async {
    final harness = _AssistantHarness.create();
    await _pumpAssistant(tester, mesh: harness.mesh, topInset: 77);

    final orb = tester.getRect(find.byType(NexusOrb));
    expect(orb.top, greaterThanOrEqualTo(77));
    expect(tester.takeException(), isNull);
    await harness.mesh.stop();
  });

  testWidgets('a wide window centers the conversation instead of stretching it',
      (tester) async {
    final harness = _AssistantHarness.create();
    await _pumpAssistant(tester, mesh: harness.mesh, width: 1280, height: 800);

    // The lead is already in the centered band, so the first turn does not
    // make the screen jump sideways.
    expect(
      tester.getRect(find.textContaining('Tell me what you need')).center.dx,
      closeTo(1280 / 2, 1),
    );

    await _ask(tester, 'what time is it');

    // The thread keeps to that same readable band rather than running edge to
    // edge across a wide window.
    final thread = tester.getRect(find.byType(ListView));
    expect(thread.width, NexusV2Layout.readableColumn);
    expect(thread.center.dx, closeTo(1280 / 2, 1));
    // A bubble stays a bubble.
    expect(
      tester.getRect(find.text('what time is it')).width,
      lessThan(NexusV2Layout.bubble),
    );
    expect(tester.takeException(), isNull);
    await harness.mesh.stop();
  });

  testWidgets('a new conversation clears the thread and comes back to the lead',
      (tester) async {
    final executor = _FakeExecutor(
      (request) async => const ActionResult(true, 'Screenshot saved.'),
    );
    final harness = _AssistantHarness.create();
    await _pumpAssistant(tester, mesh: harness.mesh, executor: executor);

    await _ask(tester, 'take a screenshot');
    expect(find.text('Screenshot saved.'), findsOneWidget);
    expect(find.byTooltip('New conversation'), findsOneWidget);

    await tester.tap(find.byTooltip('New conversation'));
    await _settle(tester);

    expect(find.text('Screenshot saved.'), findsNothing);
    expect(find.textContaining('Tell me what you need'), findsOneWidget);
    expect(find.byTooltip('New conversation'), findsNothing);
    await harness.mesh.stop();
  });

  testWidgets('no implementation vocabulary reaches the screen',
      (tester) async {
    final executor = _FakeExecutor(
      (request) async => const ActionResult(false, 'Could not take the screenshot.'),
    );
    final harness = _AssistantHarness.create();
    await _pumpAssistant(tester, mesh: harness.mesh, executor: executor);

    await _ask(tester, 'take a screenshot');

    for (final leak in const [
      'unavailable',
      'needsInfo',
      'succeeded',
      'AgentResultStatus',
      'teach:',
    ]) {
      expect(find.textContaining(leak), findsNothing, reason: leak);
    }
    await harness.mesh.stop();
  });
}
