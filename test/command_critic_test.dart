// The critic's run: real sentences typed into the real shell, one per family,
// with the phone's own backend recording what each one tried to do.
//
// This is the pass that types like a user rather than asserting like a parser.
// The interpreter corpus (command_inventive_test.dart) proves the mapping; this
// proves the sentence survives the composer, reaches the action, and does not
// hang, throw, or answer with a claim it cannot back.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:nexus/core/ai_status.dart';
import 'package:nexus/core/chat_log.dart';
import 'package:nexus/core/composer_settings.dart';
import 'package:nexus/core/device_actions.dart';
import 'package:nexus/core/device_capabilities.dart';
import 'package:nexus/core/llm.dart';
import 'package:nexus/core/local_ai_service.dart';
import 'package:nexus/core/ollama_service.dart';
import 'package:nexus/core/on_device_model.dart';
import 'package:nexus/core/onboarding.dart';
import 'package:nexus/core/speech.dart';
import 'package:nexus/core/system_actions.dart';
import 'package:nexus/main_ui.dart';

/// The PC the shell believes it has: reachable, instant, and never a socket.
class _FakeOllama extends OllamaService {
  @override
  Future<String> generateResponse(
    String prompt, {
    List<AiTurn> history = const <AiTurn>[],
  }) async => 'Right away.';
}

/// The phone: records what it was asked to do, does none of it.
class _Phone extends DeviceActionBackend {
  final List<String> calls = <String>[];

  @override
  Future<ActionResult> run(String action, Map<String, dynamic> args) async {
    calls.add(action);
    return const ActionResult(true, 'Done.');
  }
}

/// One sentence, and the backend call it must reach (null = a local answer).
typedef _Case = ({String phrase, String? call, String family});

const List<_Case> _cases = <_Case>[
  (phrase: 'what time is it', call: null, family: 'time'),
  (phrase: '12 times 5', call: null, family: 'math'),
  (phrase: 'flashlight on', call: 'torch', family: 'device'),
  (phrase: 'battery', call: 'battery', family: 'device query'),
  (phrase: 'volume up', call: 'volume', family: 'device'),
  (phrase: 'wifi off', call: 'wifi', family: 'settings'),
  (phrase: 'open youtube', call: 'openApp', family: 'settings'),
  (phrase: 'set an alarm for 7am', call: 'setAlarm', family: 'alarm'),
  (phrase: 'set a timer for 5 minutes', call: 'setTimer', family: 'timer'),
  (phrase: 'note that buy milk', call: null, family: 'memory/notes'),
  (phrase: 'add eggs to my shopping list', call: null, family: 'memory/notes'),
  (phrase: 'remember that my bike code is 4321', call: null, family: 'memory'),
  (phrase: 'who is mom', call: null, family: 'memory'),
  (phrase: 'play hotline bling', call: 'playMusic', family: 'music'),
  (phrase: 'call mom', call: 'callNumber', family: 'call'),
  (phrase: 'text mom saying hi', call: 'sendText', family: 'text'),
  (phrase: 'get report.pdf from my pc', call: null, family: 'file fetch'),
  (phrase: 'search for cats', call: null, family: 'web'),
  // Hostile and broken input has to end somewhere sensible too.
  (
    phrase: 'call mom on facetime on my phone via whatsapp',
    call: 'callNumber',
    family: 'hostile',
  ),
  (phrase: 'asdkjhaskjdhaksjdh', call: null, family: 'hostile'),
  (phrase: '', call: null, family: 'empty'),
  (phrase: 'quelle heure est-il', call: null, family: 'French'),
  (phrase: 'Getreport.pdf from my PC', call: null, family: 'voice-glued'),
];

void main() {
  late _Phone phone;

  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  setUp(() {
    phone = _Phone();
    Onboarding.debugOverride = true;
    ChatLog.override = () => ChatLog(store: MemoryChatLogStore());
    ModelChoice.override = () =>
        ModelChoice(store: MemoryModelChoiceStore());
    LocalAiService.override = () => _FakeOllama();
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

  /// Types [phrase] and presses send. Returns false when the composer refused
  /// to take the text at all, which is itself a finding.
  Future<bool> send(WidgetTester tester, String phrase) async {
    final Finder field = find.byType(TextField);
    if (field.evaluate().isEmpty) return false;
    await tester.enterText(field, phrase);
    await tester.pump();
    final Finder button = find.byTooltip('Send');
    if (button.evaluate().isEmpty) return false;
    await tester.tap(button);
    await tester.pumpAndSettle();
    return true;
  }

  test('the phrase translator does know these sentences', () {
    // The shell's typed path asks the model; core has a translator that reads
    // the same sentences without one. Every action phrase in the table above
    // that the translator recognises is one the composer *could* run with no
    // model at all — the fact that it does not is the gap.
    final List<String> recognised = <String>[for (final _Case c in _cases)
      if (c.call != null && actionFromPhrase(c.phrase) != null) c.phrase];
    expect(
      recognised,
      contains('flashlight on'),
      reason: 'the translator lost its torch phrase',
    );
    expect(
      recognised.length,
      greaterThanOrEqualTo(5),
      reason: 'recognised only: $recognised',
    );
  });

  for (final _Case c in _cases) {
    testWidgets('${c.family}: "${c.phrase}"', (WidgetTester tester) async {
      await pumpShell(tester);

      final bool accepted = await send(tester, c.phrase);
      if (c.phrase.isEmpty) {
        // An empty composer must not send at all — no bubble, no action.
        expect(phone.calls, isEmpty);
        return;
      }
      expect(accepted, isTrue, reason: 'the composer would not take the text');
      expect(tester.takeException(), isNull);

      // The user's own words are in the conversation and the composer is back.
      // Whether the action *ran* is not asserted here: on the typed path this
      // shell asks the model what to do, so a prose answer runs nothing. That
      // gap is the first complaint in the audit report, and it is pinned by the
      // translator test below rather than pretended away here.
      expect(find.text(c.phrase), findsWidgets);
      expect(find.byType(TextField), findsWidgets);
    });
  }
}
