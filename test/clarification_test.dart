// A half-command is understood and incomplete, and the interpreter already
// says exactly what it is missing ("How long should the timer run?"). That
// question belongs to Nexus, not to the model: handed over, it becomes a
// paragraph that asks nothing, and the user's other half is never collected.
//
// What this file holds: the question is shown, the model is not asked, the
// answer is merged into the sentence it belongs to and runs, and a sentence
// that is not an answer is still read as itself.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:nexus/core/chat_log.dart';
import 'package:nexus/core/device_actions.dart';
import 'package:nexus/core/device_capabilities.dart';
import 'package:nexus/core/local_ai_service.dart';
import 'package:nexus/core/ollama_service.dart';
import 'package:nexus/core/on_device_model.dart';
import 'package:nexus/core/onboarding.dart';
import 'package:nexus/core/system_actions.dart';
import 'package:nexus/main_ui.dart';

/// The model, counting how often it was asked and answering prose when it is.
class _CountingBrain extends OllamaService {
  int asked = 0;

  @override
  Future<String> generateResponse(
    String prompt, {
    List<AiTurn> history = const <AiTurn>[],
  }) async {
    asked++;
    return 'The model answered this one.';
  }
}

/// The phone: records what it was asked to do, does none of it.
class _Phone extends DeviceActionBackend {
  final List<String> calls = <String>[];
  final List<Map<String, dynamic>> arguments = <Map<String, dynamic>>[];

  @override
  Future<ActionResult> run(String action, Map<String, dynamic> args) async {
    calls.add(action);
    arguments.add(args);
    return const ActionResult(true, 'Done.');
  }
}

void main() {
  late _CountingBrain brain;
  late _Phone phone;

  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  setUp(() {
    brain = _CountingBrain();
    phone = _Phone();
    Onboarding.debugOverride = true;
    ChatLog.override = () => ChatLog(store: MemoryChatLogStore());
    ModelChoice.override = () => ModelChoice(store: MemoryModelChoiceStore());
    LocalAiService.override = () => brain;
    DeviceCapabilities.override = null;
    SystemActions.override = () => DeviceSystemActions(backend: phone);
  });

  tearDown(() {
    SystemActions.override = null;
    LocalAiService.override = null;
    ChatLog.override = null;
    ModelChoice.override = null;
  });

  Future<void> pumpShell(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const NexusUiApp());
    await tester.pumpAndSettle();
  }

  /// Types [phrase] and presses the send control.
  ///
  /// Settled before the press, and pressed at the control's own centre: the
  /// send slot slides in with the first character, so a tap computed while it
  /// is still moving lands where the button was. The assertion after it is what
  /// proves the press arrived — the field is empty again.
  Future<void> send(WidgetTester tester, String phrase) async {
    await tester.enterText(find.byType(TextField), phrase);
    await tester.pumpAndSettle();
    await tester.tapAt(
      tester.getCenter(find.byIcon(Icons.arrow_upward_rounded)),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      isEmpty,
      reason: 'the send did not happen — "$phrase" is still in the field',
    );
  }

  testWidgets('a timer with no length asks for the length, not the model', (
    WidgetTester tester,
  ) async {
    await pumpShell(tester);
    await send(tester, 'set a timer');

    expect(find.text('How long should the timer run?'), findsOneWidget);
    expect(brain.asked, 0, reason: 'the question is the shell\'s to ask');
    expect(phone.calls, isEmpty, reason: 'nothing has run yet');
  });

  testWidgets('the answer arrives and the timer it belongs to runs', (
    WidgetTester tester,
  ) async {
    await pumpShell(tester);
    await send(tester, 'set a timer');
    await send(tester, '5 minutes');

    // The merge is what makes this a command: neither half is one alone.
    expect(phone.calls, contains('timer.set'));
    expect(
      phone.arguments.last['seconds'],
      300,
      reason: 'five minutes, read as the timer the sentence asked for',
    );
    expect(brain.asked, 0);
  });

  testWidgets('a file with no device asks which device', (
    WidgetTester tester,
  ) async {
    await pumpShell(tester);
    await send(tester, 'get report.pdf');

    expect(
      find.text('Which device should I get report.pdf from?'),
      findsOneWidget,
    );
    expect(brain.asked, 0);
  });

  testWidgets('a sentence that is not a command still reaches the model', (
    WidgetTester tester,
  ) async {
    await pumpShell(tester);
    await send(tester, 'tell me about the roman empire');

    expect(brain.asked, 1);
    expect(find.text('The model answered this one.'), findsOneWidget);
  });

  testWidgets('an abandoned question does not swallow the next command', (
    WidgetTester tester,
  ) async {
    await pumpShell(tester);
    await send(tester, 'set a timer');
    // Not an answer — a new command. It must be read as itself, not joined to
    // "set a timer" into a sentence nobody typed.
    await send(tester, 'flashlight on');

    expect(phone.calls, contains('device.flashlight'));
    expect(brain.asked, 0);
  });
}
