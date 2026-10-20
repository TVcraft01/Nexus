import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show
        DebugPrintCallback,
        TargetPlatform,
        debugDefaultTargetPlatformOverride,
        debugPrint;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show MethodCall, MethodChannel, SystemChannels;
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:nexus/core/agent_contract.dart' show AgentActions;
import 'package:nexus/core/ai_status.dart';
import 'package:nexus/core/attachments.dart';
import 'package:nexus/core/chat_log.dart';
import 'package:nexus/core/device_actions.dart';
import 'package:nexus/core/device_capabilities.dart';
import 'package:nexus/core/llm.dart';
import 'package:nexus/core/local_ai_service.dart';
import 'package:nexus/core/log_service.dart';
import 'package:nexus/core/memory_service.dart';
import 'package:nexus/core/mic_access.dart';
import 'package:nexus/core/ollama_service.dart';
import 'package:nexus/core/on_device_ai_service.dart';
import 'package:nexus/core/on_device_model.dart';
import 'package:nexus/core/onboarding.dart';
import 'package:nexus/core/screen_capture.dart';
import 'package:nexus/core/services/icon_service.dart';
import 'package:nexus/core/speech.dart';
import 'package:nexus/core/system_actions.dart';
import 'package:nexus/core/system_prompt.dart';
import 'package:nexus/core/version.dart';
import 'package:nexus/core/vision_ai.dart';
import 'package:nexus/core/voice_settings.dart';
import 'package:nexus/main_ui.dart';
import 'package:nexus/mesh/updater.dart' show UpdateCheck, UpdateInfo;
import 'package:shared_preferences/shared_preferences.dart';

/// A recognizer that holds the utterance open until it is told what to do with
/// it — the shape of Android's, where the finger decides when the sentence is
/// over and the words arrive separately: [say] is the live guess while the
/// microphone is open, [hear] is the transcript it hands over at the end, and
/// [finish]/[stop] are the two ways of asking for the end of it.
class _FakeSpeechInput extends SpeechInput {
  _FakeSpeechInput();

  final StreamController<String> _partials =
      StreamController<String>.broadcast();
  final StreamController<double> _rms = StreamController<double>.broadcast();
  Completer<String?>? _open;
  int listens = 0;
  int finishes = 0;
  int stops = 0;

  @override
  bool get available => true;

  @override
  Stream<String> get partials => _partials.stream;

  @override
  Stream<double> get rms => _rms.stream;

  /// One loudness reading from the recognizer, in the dB the platform reports:
  /// the meter's input, arriving the way the real one does — many times a second
  /// while the user is speaking.
  void loudness(double db) => _rms.add(db);

  @override
  Future<String?> listen() {
    listens++;
    return (_open = Completer<String?>()).future;
  }

  /// The recognizer's current guess at the sentence, revised as it hears more
  /// — cumulative, like the platform's, so each one replaces the last.
  void say(String text) => _partials.add(text);

  /// The recognizer hands [text] over as the final transcript: what it answers
  /// the pending [listen] with once it has been asked to finish.
  void hear(String text) => _open?.complete(text);

  /// Asked for the transcript instead of being cancelled — what a released
  /// finger means. The answer arrives a moment later, through [hear].
  @override
  Future<void> finish() async => finishes++;

  @override
  Future<void> stop() async {
    stops++;
    _open?.complete(null);
    _open = null;
  }
}

/// The PC's Ollama, as the shell sees it: a canned answer, a log of the prompts
/// it was asked, and two ways to behave like a real PC — stall, or fail.
///
/// It replaces the *service* rather than the socket, because these tests are
/// about what the screen does with an answer; the wire itself is covered by
/// `test/ollama_service_test.dart`, where the fake is the socket.
class _FakeOllama extends OllamaService {
  /// What a settled request answers with. Set it before the send when a test
  /// wants to assert on the answer itself.
  String reply = 'Hello from the PC.';

  /// Every prompt the shell has sent, in order.
  final List<String> prompts = <String>[];

  /// The history each prompt was asked with — what the screen remembered when it
  /// asked, which for a one-question chat is nothing at all.
  final List<List<AiTurn>> histories = <List<AiTurn>>[];

  /// True to answer like a PC that is switched off, or on another network.
  bool unreachable = false;

  /// An error the *next* request fails with, taken once — the seam's way of
  /// saying "the model did not fit in memory" before the retry.
  Object? failureOnce;

  /// Set by [stall], taken by the next request that arrives — so a test can arm
  /// the stall *before* the screen asks.
  Completer<String>? _stalled;

  /// The request that is actually waiting, so [answer] completes the right one.
  Completer<String>? _inflight;

  /// Holds the next request open until [answer] is called, which is how a test
  /// gets to look at the page *while* an answer is being written.
  void stall() => _stalled = Completer<String>();

  /// Completes the request that is in flight with [text].
  ///
  /// Loud on purpose when nothing is waiting: a test that calls this after the
  /// answer has already landed is a test asserting nothing, and it should fail
  /// here rather than pass for the wrong reason.
  void answer(String text) {
    final Completer<String>? open = _inflight;
    if (open == null) {
      throw StateError('no request is in flight to answer');
    }
    _inflight = null;
    open.complete(text);
  }

  @override
  Future<String> generateResponse(
    String prompt, {
    List<AiTurn> history = const <AiTurn>[],
  }) {
    prompts.add(prompt);
    histories.add(history);
    final Object? once = failureOnce;
    if (once != null) {
      failureOnce = null;
      return Future<String>.error(once);
    }
    if (unreachable) {
      return Future<String>.error(
        const OllamaException(kNexusOllamaUnreachableText),
      );
    }
    final Completer<String>? stalled = _stalled;
    if (stalled != null) {
      _stalled = null;
      _inflight = stalled;
      return stalled.future;
    }
    return Future<String>.value(reply);
  }
}

/// A brain that writes its answer a piece at a time, on command.
///
/// The whole point of the streaming seam is that the screen sees the answer
/// *while* it is being written, which a fake that returns one finished string
/// cannot show. So the test holds the model's pen: [write] is one token
/// arriving, [end] is the model reaching the end of its answer, and [fail] is
/// it stopping badly — half a sentence already on screen.
class _StreamingBrain implements LocalAiService {
  final StreamController<String> _pieces = StreamController<String>();

  /// Every prompt the shell has sent, in order — the same record [_FakeOllama]
  /// keeps, because the page should ask once either way.
  final List<String> prompts = <String>[];

  /// What each question was asked with. Live mode is the one caller that
  /// remembers, so this is where a conversation shows up.
  final List<List<AiTurn>> histories = <List<AiTurn>>[];

  @override
  Stream<String> generateResponseStream(
    String prompt, {
    List<AiTurn> history = const <AiTurn>[],
  }) {
    prompts.add(prompt);
    histories.add(history);
    return _pieces.stream;
  }

  /// Nobody in the shell calls this any more; it is here because the interface
  /// still has it, and it is defined in terms of the stream so the two can never
  /// disagree.
  @override
  Future<String> generateResponse(
    String prompt, {
    List<AiTurn> history = const <AiTurn>[],
  }) => generateResponseStream(prompt, history: history).join();

  /// One token, arriving.
  void write(String piece) => _pieces.add(piece);

  /// The model stopping after it has already said [said]: the error the real
  /// on-device engine throws mid-answer.
  void fail(String message) => _pieces.addError(OnDeviceAiException(message));

  /// The end of the answer.
  ///
  /// Deliberately not awaited by the caller, and not returned: a controller's
  /// `close()` future only completes once a listener has received the done
  /// event, so a test that awaited it before the screen had subscribed would
  /// wait forever — the very hang a fake like this must not introduce.
  void end() {
    if (_pieces.isClosed) return;
    unawaited(_pieces.close());
  }
}

/// The on-device model's fetcher, scripted: progress without a socket, and a
/// file on disk at the end. The real download-and-verify is proven against a
/// loopback server in test/on_device_ai_service_test.dart; this exists so the
/// download row and its bar can be walked in a widget test.
class _FakeDownloadLlm extends Llm {
  _FakeDownloadLlm({required super.model, required this.dir})
    : super(modelsDir: () async => dir);

  final Directory dir;

  @override
  Future<bool> download({void Function(double progress)? onProgress}) async {
    onProgress?.call(0.25);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    onProgress?.call(1);
    // The file the *model* names: the shell's first model is `model.gguf`, and
    // the 1B is named after itself — one fake has to serve both.
    File('${dir.path}/${model.name}.gguf').writeAsBytesSync(<int>[1, 2, 3]);
    return true;
  }

  @override
  Future<void> dispose() async {}
}

/// A speaker that starts talking and does not stop until the test says so.
///
/// The Stop speaking control lives in the gap between these two events: a fake
/// that finished on the next microtask would never show it.
class _GatedSpeechOutput extends SpeechOutput {
  final StreamController<void> _done = StreamController<void>.broadcast();
  final List<String> said = <String>[];
  int stops = 0;
  bool stopped = false;

  @override
  bool get available => true;

  @override
  Stream<void> get spoken => _done.stream;

  @override
  Future<bool> speak(String text) async {
    said.add(text);
    return true;
  }

  @override
  Future<void> stop() async {
    stops++;
    stopped = true;
  }

  /// The engine reaching the end of the utterance.
  void finish() => _done.add(null);
}

/// The phone's speaker, as the shell sees it: it keeps the sentences it was
/// asked to say, in order, so a test can prove both that a reply is read out
/// and that a failure notice is not.
class _FakeSpeechOutput extends SpeechOutput {
  _FakeSpeechOutput();

  final List<String> said = <String>[];

  /// The platform's completion event. The real one arrives on the speech-out
  /// channel when the engine finishes; this answers on the next microtask, the
  /// same moment a very short utterance would.
  final StreamController<void> _spoken = StreamController<void>.broadcast();

  @override
  bool get available => true;

  @override
  Stream<void> get spoken => _spoken.stream;

  @override
  Future<bool> speak(String text) async {
    said.add(text);
    _spoken.add(null);
    return true;
  }

  @override
  Future<void> stop() async {
    _spoken.add(null);
  }
}

/// The phone's own hands, as the thread sees them: the real
/// [DeviceSystemActions] over a recorder instead of the method channel.
///
/// The wording and the plan are the shipped ones — a fake of the *service* would
/// let the bubble say one thing while the app promised another — and only the
/// native call is replaced, which is the same move these tests already make for
/// the brain and the microphone.
class _FakePhoneBackend extends DeviceActionBackend {
  final List<(String, Map<String, dynamic>)> calls =
      <(String, Map<String, dynamic>)>[];

  /// What the phone answers. The default is success with the sentence the
  /// native side uses; a test that wants a refusal sets it.
  ActionResult reply = const ActionResult(true, 'Done.');

  @override
  Future<ActionResult> run(String action, Map<String, dynamic> args) async {
    calls.add((action, args));
    return reply;
  }
}

/// The attachment store without a disk: a widget test runs in fake time, where
/// a real file read never completes.
class _MemoryAttachments extends AttachmentStore {
  _MemoryAttachments() : super(directory: () async => null);

  @override
  Future<String?> keep(
    String sourcePath, {
    required AttachmentKind kind,
  }) async => sourcePath;
}

/// A recognizer for a device that cannot listen: on the phone it would be a
/// ROM with no speech service at all.
class _UnavailableSpeechInput extends SpeechInput {
  const _UnavailableSpeechInput();

  @override
  bool get available => false;
}

/// The phone's answer to the one microphone ask, counting the asks so a test
/// can prove there is only ever one.
class _FakeMicAsk {
  _FakeMicAsk.granted() : _granted = true, _message = null;

  _FakeMicAsk.refused([String? message])
    : _granted = false,
      _message =
          message ??
          'Microphone permission needed — voice input stays '
              'off until you allow it.';

  final bool _granted;
  final String? _message;
  int asks = 0;

  Future<MicrophonePermissionResult> call() async {
    asks++;
    return MicrophonePermissionResult(granted: _granted, message: _message);
  }
}

/// A recognizer that keeps its sentence to itself — the shape of the platform
/// seam after a stop.
///
/// `MainActivity.releaseRecognizerIf` answers the pending listen only when the
/// session it holds is still the live one, and `stopSpeech` clears that before
/// it cancels, so a stopped or replaced recognizer answers *nobody*: the Dart
/// future stays pending for ever. [answer] is the other half of the same
/// problem — a recognizer that reports the sentence late, to a session the user
/// has already ended. Nothing here answers anything by itself, which is what
/// makes it the fake that proves the shell does not wait on the platform to
/// know that a session is over.
class _LateAnswerSpeechInput extends SpeechInput {
  final StreamController<String> _partials =
      StreamController<String>.broadcast();
  final StreamController<double> _rms = StreamController<double>.broadcast();
  Completer<String?>? _open;
  int listens = 0;
  int finishes = 0;
  int stops = 0;

  @override
  bool get available => true;

  @override
  Stream<String> get partials => _partials.stream;

  @override
  Stream<double> get rms => _rms.stream;

  /// One loudness reading, for the tests that measure the meter rather than the
  /// words.
  void loudness(double db) => _rms.add(db);

  @override
  Future<String?> listen() {
    listens++;
    return (_open = Completer<String?>()).future;
  }

  /// The recognizer's live guess, revised as it hears more — it streams like
  /// Android's does, and it is only the *end* of the utterance it never reports.
  void say(String text) => _partials.add(text);

  /// The recognizer's answer, whenever it decides to give one.
  void answer(String text) => _open?.complete(text);

  @override
  Future<void> finish() async => finishes++;

  @override
  Future<void> stop() async => stops++;
}

/// The UI shell is standalone, so it is tested standalone: pump [NexusUiApp],
/// drive it like a thumb would, and check what is actually on screen.
void main() {
  setUpAll(() {
    // The shell asks google_fonts for Inter; in a test there is no network, so
    // tell the package not to try and let text fall back to the test font.
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  /// Every test in this file gets the same canned PC. The answer path is walked
  /// by most of them — sending a message, finishing a live turn — and none of
  /// them should be able to reach a socket, an address on the developer's LAN,
  /// or a real model that takes four seconds to think.
  late _FakeOllama ollama;

  /// The conversation this test's app remembers. One per test, in memory: a
  /// real preference store would let one test's chat turn up in the next one's
  /// welcome screen.
  late ChatLog chat;

  /// Which model this test's app is set to run. One per test, in memory: the
  /// real store is a preference, and a preference is a platform channel that a
  /// widget test has no answer for.
  late ModelChoice modelChoice;

  /// The phone's speaker for every test that does not bring its own.
  ///
  /// Since live conversation waits for the platform to report that the answer
  /// has been read out, a test that let the real channel through would wait for
  /// a `done` that a widget test has no engine to send. This fake answers on
  /// the next microtask — the same moment a short utterance would — so the page
  /// gets back to "tap to continue" and its 1.5 s auto-listen without any test
  /// having to fake a whole speech engine.
  late _FakeSpeechOutput defaultSpeech;
  setUp(() {
    ollama = _FakeOllama();
    LocalAiService.override = () => ollama;
    defaultSpeech = _FakeSpeechOutput();
    SpeechOutput.override = () => defaultSpeech;
    chat = ChatLog(store: MemoryChatLogStore());
    ChatLog.override = () => chat;
    modelChoice = ModelChoice(store: MemoryModelChoiceStore());
    ModelChoice.override = () => modelChoice;
    // The refusal memory is process-wide (it is the same fact the capability
    // checks), so every test starts from "never asked", and no test can leave
    // the next one with a microphone it believes is permanently refused.
    MicrophoneAccess.debugReset();
    DeviceCapabilities.override = null;
    // Every test starts with a phone that has no hands. Only the tests about
    // actions give it a recorder, so an old test can never be the reason a new
    // one's torch came on.
    SystemActions.override = null;
    // And every test starts with a phone that has been set up: the app root
    // opens on the welcome screen for a fresh install now, and this file is
    // about the shell. The first run has its own file
    // (test/onboarding_test.dart), where the flag is the subject rather than a
    // precondition — and the seam rather than a preference, so nothing here
    // touches the preferences store for it.
    Onboarding.debugOverride = true;
    HomeTab.updateCheckOverride = null;
    SystemPrompt.override = null;
    SystemPrompt.debugReset();
  });
  tearDown(() {
    LocalAiService.override = null;
    DeviceCapabilities.override = null;
    ChatLog.override = null;
    ChatLog.debugReset();
    SystemActions.override = null;
    ModelChoice.override = null;
    ModelChoice.debugReset();
    Onboarding.debugOverride = null;
    SpeechOutput.override = null;
    HomeTab.updateCheckOverride = null;
    SystemPrompt.override = null;
    SystemPrompt.debugReset();
    LogService.debugReset();
  });

  /// A phone-shaped surface — the layout the shell is designed against.
  Future<void> pumpShell(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const NexusUiApp());
    await tester.pumpAndSettle();
  }

  /// Runs [body] with the shell's own mic log lines captured — the same stream
  /// the phone's logcat shows (`adb logcat | grep mic:`), so the format these
  /// tests pin is the format the evidence is read in.
  ///
  /// `debugPrint` is restored in the body, not in a tearDown: the framework
  /// checks foundation's debug variables *before* tearDowns run, so restoring
  /// there would be too late and would fail the next test instead.
  Future<void> withMicLog(Future<void> Function(List<String> log) body) async {
    final List<String> lines = <String>[];
    final DebugPrintCallback original = debugPrint;
    debugPrint = (String? line, {int? wrapWidth}) {
      if (line != null && line.startsWith('mic:')) lines.add(line);
    };
    try {
      await body(lines);
    } finally {
      debugPrint = original;
    }
  }

  final RegExp startLine = RegExp(
    r'^mic:start \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}',
  );

  /// Every way a session can end, as the log spells them: `final` is a
  /// transcript in hand, `cancelled` a held finger that slid off the button,
  /// `stopped` the tap that closed a session it had opened, `closed` the X that
  /// ended live conversation, `background` the app leaving the foreground,
  /// `timeout` the guard, `empty` a recognizer that closed the session itself,
  /// and `error` a seam that failed outright.
  final RegExp stopLine = RegExp(
    r'^mic:stop \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+ '
    r'reason=(final|cancelled|stopped|closed|background|timeout|empty|error)$',
  );

  /// The words in the composer's field — which is where a hold writes the
  /// sentence while it is still being spoken.
  String fieldText(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).controller!.text;

  /// The one button, named in each of the three states it can be in: the mic
  /// (nothing in the field), the stop (a session is live), and the send arrow
  /// (there are words to send). A test says which state it expects to be looking
  /// at, so a button that fails to change fails the test that asked.
  Finder micButton() => find.byTooltip('Tap to dictate, hold to talk');
  Finder stopButton() => find.byTooltip('Stop listening');
  Finder sendButton() => find.byTooltip('Send');

  /// The recording indicator: the ring that pulses inside the button for as long
  /// as the microphone is open. It is a compliance requirement rather than
  /// decoration, so the tests below hold it to being on screen for the whole of
  /// every session — in both modes — and gone the moment one ends.
  final Finder recordingIndicator = find.byKey(kNexusRecordingIndicator);

  /// The button's own cross-fade, run to its end: for 180ms the button on its
  /// way out is still in the tree behind the one arriving, and a test that looks
  /// at "the button" mid-swap is looking at two of them.
  Future<void> settleButton(WidgetTester tester) =>
      tester.pump(const Duration(milliseconds: 250));

  /// The tap: down and up inside [kNexusMicHold], which is what makes it a tap
  /// rather than a hold. What it *does* is the button's business — open the
  /// microphone, or close the session the previous tap opened.
  ///
  /// It settles the button first, because the press under test is a press on the
  /// button the user can see: a thumb reaching for the stop a moment after the
  /// mic became one is the normal case, and it is the one worth testing.
  /// [WidgetTester.tap] then advances no time at all, so the press is the
  /// shortest there is — slower than this is a hold, by definition.
  Future<void> tapTheButton(WidgetTester tester, Finder button) async {
    await settleButton(tester);
    await tester.tap(button);
    await tester.pump();
  }

  /// Presses the mic button and holds it past [kNexusMicHold]: a real finger,
  /// held over the deadline and past the 180ms swap that retires the mic, because
  /// the hold is the gesture under test — [WidgetTester.longPress] is one call
  /// with no moment in the middle of it to speak into.
  ///
  /// Pumped, not settled: the recording indicator repeats for as long as the
  /// microphone is open, so there is nothing to settle to.
  Future<TestGesture> holdMic(WidgetTester tester) async {
    final TestGesture finger = await tester.startGesture(
      tester.getCenter(micButton()),
    );
    await tester.pump(kNexusMicHold + const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 200));
    return finger;
  }

  /// The finger coming up on the button, which is its own line in the log: it
  /// is the release, not a second tap, that asks for the transcript.
  final RegExp releaseLine = RegExp(
    r'^mic:release \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}',
  );

  /// Stands in for the system dialog, granting the microphone: without this a
  /// test that taps the mic would reach the real channel and be refused.
  _FakeMicAsk grantMic() {
    final ask = _FakeMicAsk.granted();
    MicrophoneAccess.debugRequestOverride = ask.call;
    addTearDown(() => MicrophoneAccess.debugRequestOverride = null);
    return ask;
  }

  Finder tab(String label) =>
      find.descendant(of: find.byType(NexusTabBar), matching: find.text(label));

  Future<void> openTab(WidgetTester tester, String label, int index) async {
    await tester.tap(tab(label));
    await tester.pumpAndSettle();
    expect(tester.widget<IndexedStack>(find.byType(IndexedStack)).index, index);
  }

  /// The tab bar's icon colour — scoped, because the same glyphs show up in
  /// the file and device lists too.
  Color tabIconColor(WidgetTester tester, IconData icon) => tester
      .widget<Icon>(
        find.descendant(
          of: find.byType(NexusTabBar),
          matching: find.byIcon(icon),
        ),
      )
      .color!;

  testWidgets('opens on Home with a welcome and nothing said yet', (
    tester,
  ) async {
    await pumpShell(tester);

    // The welcome is a heading, not a message: the screen used to open with an
    // assistant sentence and a question nobody had asked, drawn by the same code
    // as a real answer — so the first thing the app "said" was its own.
    expect(find.text('Hey, what do you need?'), findsOneWidget);
    expect(find.text('What’s in my Downloads?'), findsNothing);
    expect(
      find.textContaining('Everything stays on your devices'),
      findsNothing,
    );
    expect(find.byType(NexusChatBubble), findsNothing);
    expect(find.byTooltip(kNexusCopyTooltip), findsNothing);
    expect(find.text('Message Nexus'), findsOneWidget);

    final home = tester.widget<IndexedStack>(find.byType(IndexedStack));
    expect(home.index, 0);

    // The composer starts as a mic, because there is nothing to send.
    expect(micButton(), findsOneWidget);
    expect(sendButton(), findsNothing);
  });

  testWidgets('the empty home offers three suggestions that fill the field', (
    tester,
  ) async {
    await pumpShell(tester);

    // Three, not a wall: three of the five commands this build can actually
    // run, chosen fresh on each launch. A blank screen asks the user to invent
    // a request; a chip shows them the vocabulary.
    expect(kNexusSuggestionPool.length, 5);
    int shown = 0;
    for (final (String label, String prompt) in kNexusSuggestionPool) {
      if (find.text(label).evaluate().isEmpty) continue;
      shown++;
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      // Filled, not sent: the suggestion is a draft the user can finish.
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        prompt,
      );
      expect(ollama.prompts, isEmpty, reason: 'a chip is a draft, not a send');
    }
    expect(shown, 3);
  });

  testWidgets('the composer turns the mic into send, and posts the message', (
    tester,
  ) async {
    await pumpShell(tester);

    await tester.enterText(find.byType(TextField), 'summarise my notes');
    await tester.pumpAndSettle();
    expect(sendButton(), findsOneWidget);
    expect(micButton(), findsNothing);

    await tapTheButton(tester, sendButton());
    await tester.pumpAndSettle();

    expect(find.text('summarise my notes'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '',
    );
    expect(micButton(), findsOneWidget);
    // The message went to the PC's model, and the thread shows what it said.
    expect(ollama.prompts, <String>['summarise my notes']);
    expect(find.text(ollama.reply), findsOneWidget);
  });

  testWidgets('a message is answered where it was asked', (tester) async {
    await pumpShell(tester);
    // The PC takes its time: this is the state a slow model on a laptop is in
    // for seconds at a time, and the thread has to say so rather than look like
    // it swallowed the message.
    ollama.stall();

    await tester.enterText(find.byType(TextField), 'what is in my Downloads?');
    await tester.pump();
    await tapTheButton(tester, sendButton());
    await tester.pump();

    expect(find.text('what is in my Downloads?'), findsOneWidget);
    expect(find.text(kNexusThinking), findsOneWidget);
    expect(ollama.prompts, <String>['what is in my Downloads?']);
    // The wait is not a modal and not a blocked composer: the field is empty and
    // usable, and the send button is a mic again.
    expect(micButton(), findsOneWidget);

    // The answer replaces the placeholder rather than arriving beside it.
    ollama.answer('Your Downloads folder has six items.');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(kNexusThinking), findsNothing);
    expect(find.text('Your Downloads folder has six items.'), findsOneWidget);
  });

  testWidgets(
    'a PC that cannot be reached shows a red notice, and never says it',
    (tester) async {
      final speech = _FakeSpeechOutput();
      SpeechOutput.override = () => speech;
      addTearDown(() => SpeechOutput.override = null);
      ollama.unreachable = true;
      await pumpShell(tester);

      await tester.enterText(find.byType(TextField), 'hello?');
      await tester.pump();
      await tapTheButton(tester, sendButton());
      await tester.pumpAndSettle();

      // No dialog, no spinner left running, no silence — and not a reply bubble
      // either. The failure is its own widget, because a red, bordered notice
      // cannot be mistaken for something the assistant said.
      final Finder notice = find.byKey(kNexusErrorBubble);
      expect(notice, findsOneWidget);
      expect(find.text(kNexusOllamaUnreachableText), findsOneWidget);
      expect(find.text(kNexusThinking), findsNothing);
      expect(
        find.descendant(
          of: find.byType(NexusChatBubble),
          matching: find.text(kNexusOllamaUnreachableText),
        ),
        findsNothing,
      );

      // Red rim, light red wash, red ink, and a warning sign: the four things that
      // make it read as a warning at a glance.
      final BoxDecoration decoration =
          tester.widget<Container>(notice).decoration! as BoxDecoration;
      expect(decoration.color, kNexusErrorWash);
      expect((decoration.border! as Border).top.color, kNexusErrorRim);
      expect(
        tester
            .widget<Text>(
              find.descendant(
                of: notice,
                matching: find.text(kNexusOllamaUnreachableText),
              ),
            )
            .style!
            .color,
        kNexusErrorInk,
      );
      expect(
        find.descendant(
          of: notice,
          matching: find.byIcon(Icons.warning_amber_rounded),
        ),
        findsOneWidget,
      );

      // It can be copied — that is how a user reports it — and it cannot be
      // replayed, because a failure is not something the assistant said.
      expect(
        find.descendant(
          of: find.byType(NexusErrorBubble),
          matching: find.byTooltip(kNexusCopyTooltip),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(NexusErrorBubble),
          matching: find.byTooltip(kNexusSpeakTooltip),
        ),
        findsNothing,
      );

      // And it was never read out: the speaker was never asked to say it.
      expect(speech.said, isEmpty);
      expect(micButton(), findsOneWidget);
    },
  );

  /// The real chain, with a phone that has no model file: the first brain on
  /// the device throws [ModelNotFoundException] and the PC answers instead.
  /// The fake brain above proves the shell shows an answer; this proves the
  /// *chain* produces one, which is the whole point of the fallback.
  testWidgets('a phone with no model falls back to the PC and answers', (
    tester,
  ) async {
    final Directory dir = Directory.systemTemp.createTempSync('nexus_no_model');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final _FakeOllama pc = _FakeOllama()..reply = 'From the PC, over Wi-Fi.';
    LocalAiService.override = () => FallbackAiService(
      onDevice: OnDeviceAiService(
        model: OnDeviceModel(directory: () async => dir),
      ),
      pc: pc,
    );
    await pumpShell(tester);

    await tester.enterText(find.byType(TextField), 'hello?');
    await tester.pump();
    await tapTheButton(tester, sendButton());
    await tester.pumpAndSettle();

    expect(find.text('From the PC, over Wi-Fi.'), findsOneWidget);
    expect(pc.prompts, <String>[
      'hello?',
    ], reason: 'the device had no model, so the PC was asked');
    expect(find.byKey(kNexusErrorBubble), findsNothing);
  });

  /// Both brains gone: the device has no model and the PC is not reachable.
  /// What the user gets is the red notice — not a reply bubble — and the
  /// sentence names the download that would fix it.
  testWidgets('no model and no PC: the notice names the way out', (
    tester,
  ) async {
    final speech = _FakeSpeechOutput();
    SpeechOutput.override = () => speech;
    addTearDown(() => SpeechOutput.override = null);
    final Directory dir = Directory.systemTemp.createTempSync('nexus_no_brain');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final _FakeOllama pc = _FakeOllama()..unreachable = true;
    LocalAiService.override = () => FallbackAiService(
      onDevice: OnDeviceAiService(
        model: OnDeviceModel(directory: () async => dir),
      ),
      pc: pc,
    );
    await pumpShell(tester);

    await tester.enterText(find.byType(TextField), 'hello?');
    await tester.pump();
    await tapTheButton(tester, sendButton());
    await tester.pumpAndSettle();

    expect(find.byKey(kNexusErrorBubble), findsOneWidget);
    expect(find.text(kNexusOllamaUnreachableText), findsOneWidget);
    expect(pc.prompts, <String>[
      'hello?',
    ], reason: 'the PC is asked before the user is told there is no brain');
    expect(speech.said, isEmpty);
  });

  /// The Settings screen, on its own, with a brain pointed at a temp
  /// directory — the only way to walk the Brain rows without 470 MB and a
  /// platform channel. The download itself is proven against a real loopback
  /// server in test/on_device_ai_service_test.dart; what is proven here is what
  /// the user sees and what the delete button does to the file.
  Future<void> pumpBrainSettings(
    WidgetTester tester,
    OnDeviceAiService onDevice,
  ) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: NexusTheme.light(),
        home: Scaffold(
          body: SettingsTab(
            darkMode: false,
            onDarkModeChanged: (_) {},
            onDevice: onDevice,
          ),
        ),
      ),
    );
    // The status is read asynchronously: two frames is the file check and the
    // row that reports it.
    await tester.pump();
    await tester.pump();
    await tester.scrollUntilVisible(
      find.text('AI status'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
  }

  testWidgets('the Brain section reports the model on this device', (
    tester,
  ) async {
    final Directory dir = Directory.systemTemp.createTempSync('nexus_brain');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    File('${dir.path}/$kOnDeviceModelFileName')
        .writeAsBytesSync(List<int>.filled(4096, 7));
    final OnDeviceAiService onDevice = OnDeviceAiService(
      model: OnDeviceModel(directory: () async => dir),
    );

    await pumpBrainSettings(tester, onDevice);

    // The phone has the model: the status says so, and the row that frees the
    // space is there instead of a download button.
    expect(find.text('On-Device (Loaded)'), findsOneWidget);
    expect(find.text('Delete model'), findsOneWidget);
    expect(find.text('Download model'), findsNothing);

    // The title is the danger colour, so the row is recognisable as destructive
    // before it is read.
    final Text title = tester.widget<Text>(find.text('Delete model'));
    expect(title.style?.color, NexusUiColors.light.danger);
    expect(
      NexusUiColors.light.danger,
      isNot(NexusUiColors.light.textStrong),
      reason: 'a destructive row must not look like every other row',
    );

    // It asks first, and it says what the megabytes cost: a model that goes away
    // takes offline answers with it.
    await tester.tap(find.text('Delete model'));
    await tester.pumpAndSettle();
    expect(find.text(kNexusDeleteModelTitle), findsOneWidget);
    expect(find.textContaining('free up 1 MB'), findsOneWidget);
    expect(find.textContaining('not be able to chat offline'), findsOneWidget);

    // Backing out leaves the file alone — the default answer to "are you sure"
    // has to be no.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(File('${dir.path}/$kOnDeviceModelFileName').existsSync(), isTrue);
    expect(find.text('On-Device (Loaded)'), findsOneWidget);

    // Confirming does it.
    await tester.tap(find.text('Delete model'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(kNexusConfirmAction));
    await tester.pump();
    await tester.pump();

    // The file is gone, and the row that asked for it is gone with it: the
    // next question falls back to the PC, which with no PC on this network is
    // exactly what the status reports.
    expect(File('${dir.path}/$kOnDeviceModelFileName').existsSync(), isFalse);
    expect(find.text('On-Device (Loaded)'), findsNothing);
    expect(find.text('No AI available'), findsOneWidget);
    expect(find.text('Download model'), findsOneWidget);
  });

  testWidgets('the download row shows real progress, then the model arrives', (
    tester,
  ) async {
    final Directory dir = Directory.systemTemp.createTempSync('nexus_download');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final OnDeviceAiService onDevice = OnDeviceAiService(
      model: OnDeviceModel(
        directory: () async => dir,
        engine: () => _FakeDownloadLlm(model: kOnDeviceLlmModel, dir: dir),
      ),
    );

    await pumpBrainSettings(tester, onDevice);
    await tester.tap(find.text('Download model'));
    await tester.pump();

    // Mid-download: the bar is on screen and a quarter full, which is the one
    // thing a 470 MB wait has to show the user.
    expect(find.byKey(kNexusBrainProgress), findsOneWidget);
    expect(
      tester
          .widget<FractionallySizedBox>(find.byKey(kNexusBrainProgress))
          .widthFactor,
      closeTo(0.25, 0.001),
    );
    expect(
      find.text('25% of ${kPhoneModel.megabytes} MB — keep Nexus open'),
      findsOneWidget,
    );

    await tester.pumpAndSettle();

    // Done: the file is there, the bar is gone, and the rows are the ones a
    // device that owns its model shows.
    expect(File('${dir.path}/$kOnDeviceModelFileName').existsSync(), isTrue);
    expect(find.byKey(kNexusBrainProgress), findsNothing);
    expect(find.text('On-Device (Loaded)'), findsOneWidget);
    expect(find.text('Delete model'), findsOneWidget);
    expect(find.text('Download model'), findsNothing);
  });

  testWidgets(
    'the picker offers both models, and switching one moves the rows',
    (tester) async {
      final Directory dir = Directory.systemTemp.createTempSync('nexus_picker');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      File('${dir.path}/$kOnDeviceModelFileName').writeAsBytesSync(<int>[7]);
      final OnDeviceAiService onDevice = OnDeviceAiService(
        model: OnDeviceModel(directory: () async => dir),
      );

      await pumpBrainSettings(tester, onDevice);

      // Both choices are listed, by the names the task names them.
      expect(find.text('Qwen 2.5 0.5B'), findsOneWidget);
      expect(find.text('Llama 3.2 1B'), findsOneWidget);
      expect(modelChoice.choice, OnDeviceModelChoice.qwen);

      // The 1B is not downloaded, but it can still be chosen: selecting it is a
      // decision, and the Download row below is how it is honoured.
      await tester.tap(find.text('Llama 3.2 1B'));
      await tester.pumpAndSettle();

      expect(modelChoice.choice, OnDeviceModelChoice.llama);
      await tester.scrollUntilVisible(
        find.text('Download model'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.textContaining('Llama 3.2 1B — ${kLlamaModel.megabytes} MB'),
        findsOneWidget,
        reason: 'the download row is about the model that is selected',
      );
      expect(
        find.text('Delete model'),
        findsNothing,
        reason: 'the selected model is not on this device',
      );
    },
  );

  testWidgets('the download fetches the selected model under its own name', (
    tester,
  ) async {
    final Directory dir = Directory.systemTemp.createTempSync('nexus_llama_dl');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final OnDeviceAiService onDevice = OnDeviceAiService(
      model: OnDeviceModel(
        directory: () async => dir,
        engine: () => _FakeDownloadLlm(model: kLlamaModel, dir: dir),
      ),
    );
    await modelChoice.select(OnDeviceModelChoice.llama);

    await pumpBrainSettings(tester, onDevice);
    await tester.scrollUntilVisible(
      find.text('Download model'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Download model'));
    await tester.pumpAndSettle();

    expect(
      File('${dir.path}/${OnDeviceModelChoice.llama.fileName}').existsSync(),
      isTrue,
    );
    expect(
      File('${dir.path}/$kOnDeviceModelFileName').existsSync(),
      isFalse,
      reason: 'the small model was never downloaded',
    );
    expect(find.text('Delete model'), findsOneWidget);
  });

  testWidgets('Delete removes the selected model and leaves the other one', (
    tester,
  ) async {
    final Directory dir = Directory.systemTemp.createTempSync(
      'nexus_two_models',
    );
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    File('${dir.path}/$kOnDeviceModelFileName').writeAsBytesSync(<int>[1, 2]);
    File('${dir.path}/${OnDeviceModelChoice.llama.fileName}')
        .writeAsBytesSync(<int>[3, 4, 5]);
    final OnDeviceAiService onDevice = OnDeviceAiService(
      model: OnDeviceModel(directory: () async => dir),
    );
    await modelChoice.select(OnDeviceModelChoice.llama);

    await pumpBrainSettings(tester, onDevice);
    await tester.scrollUntilVisible(
      find.text('Delete model'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Delete model'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(kNexusConfirmAction));
    await tester.pump();
    await tester.pump();

    expect(
      File('${dir.path}/${OnDeviceModelChoice.llama.fileName}').existsSync(),
      isFalse,
      reason: 'the selected model is the one Delete is about',
    );
    expect(
      File('${dir.path}/$kOnDeviceModelFileName').existsSync(),
      isTrue,
      reason: 'the other model is not the user\'s answer to this question',
    );
    expect(modelChoice.choice, OnDeviceModelChoice.llama);
  });

  testWidgets('a download that cannot start says so, and keeps no file', (
    tester,
  ) async {
    final Directory dir = Directory.systemTemp.createTempSync('nexus_no_wifi');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final OnDeviceAiService onDevice = OnDeviceAiService(
      model: OnDeviceModel(directory: () async => dir),
    );

    await pumpBrainSettings(tester, onDevice);
    expect(find.text('Download model'), findsOneWidget);

    // The test binding refuses every HTTP request, which is the honest shape of
    // a phone with no connection — the same failure a user gets on a plane.
    await tester.tap(find.text('Download model'));
    await tester.pumpAndSettle();

    expect(find.text('Download failed'), findsOneWidget);
    expect(find.textContaining('nothing was kept'), findsOneWidget);
    expect(File('${dir.path}/$kOnDeviceModelFileName').existsSync(), isFalse);
    expect(
      find.text('Download model'),
      findsOneWidget,
      reason: 'the row stays, so the user can try again',
    );
  });

  testWidgets('a long press on a user bubble opens its action sheet', (
    tester,
  ) async {
    // The clipboard as Android sees it: every write is a `Clipboard.setData`
    // call on the platform channel, so the test reads back exactly the text
    // that would have reached the phone's clipboard.
    final List<String> copied = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (
          MethodCall call,
        ) async {
          if (call.method == 'Clipboard.setData') {
            final Object? args = call.arguments;
            if (args is Map) copied.add(args['text'] as String);
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await pumpShell(tester);
    await tester.enterText(find.byType(TextField), 'remember this');
    await tester.pump();
    await tapTheButton(tester, sendButton());
    await tester.pumpAndSettle();

    // Both sides of the thread are inside the selectable region, which is what
    // makes the hold below a selection rather than a copy of the whole line.
    expect(
      find.ancestor(
        of: find.text('remember this'),
        matching: find.byType(SelectionArea),
      ),
      findsOneWidget,
    );

    // The user's own line, held: a sheet offers the three things a sent line
    // can still do. Nothing reaches the clipboard until one of them is chosen,
    // so the hold never lands as an invisible copy.
    await tester.longPress(find.text('remember this'));
    await tester.pumpAndSettle();
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Select Text'), findsOneWidget);
    expect(find.text('Edit'), findsOneWidget);
    expect(copied, isEmpty);
    expect(find.text(kNexusCopied), findsNothing);

    // Copy writes the whole line and says so.
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(copied, <String>['remember this']);
    expect(find.text(kNexusCopied), findsOneWidget);

    // Edit puts the sent words back in the composer, where they can be said
    // differently. The bubble is not removed: nothing is unsent until the user
    // sends the edited version.
    await tester.longPress(find.text('remember this'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      'remember this',
    );
    expect(find.text('remember this'), findsWidgets);

    // The reply, which is usually the half worth keeping, keeps its copy
    // control: the fine case is a selection, and the whole sentence is still
    // one tap for the case that is not fine.
    final Finder replyCopy = find.descendant(
      of: find.ancestor(
        of: find.text(ollama.reply),
        matching: find.byType(NexusChatBubble),
      ),
      matching: find.byTooltip(kNexusCopyTooltip),
    );
    expect(replyCopy, findsOneWidget);
    await tester.tap(replyCopy);
    await tester.pump();
    expect(copied, <String>['remember this', ollama.reply]);
    expect(find.text(kNexusCopied), findsOneWidget);
  });

  testWidgets('a typed question is answered in silence', (tester) async {
    final speech = _FakeSpeechOutput();
    SpeechOutput.override = () => speech;
    addTearDown(() => SpeechOutput.override = null);
    await pumpShell(tester);

    await tester.enterText(find.byType(TextField), 'what is the weather?');
    await tester.pump();
    await tapTheButton(tester, sendButton());
    await tester.pumpAndSettle();

    // Typed, so not spoken. A phone that starts talking after a silent tap is
    // the behaviour this rule exists to stop — the answer is on screen, and the
    // speaker under it is there for whoever wants it.
    expect(speech.said, isEmpty);

    // The bubble's own controls are the manual half, and they are on the answer
    // that was just generated.
    final Finder reply = find.ancestor(
      of: find.text(ollama.reply),
      matching: find.byType(NexusChatBubble),
    );
    for (final Finder bubble in <Finder>[reply]) {
      expect(bubble, findsOneWidget);
      expect(
        find.descendant(
          of: bubble,
          matching: find.byTooltip(kNexusCopyTooltip),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: bubble,
          matching: find.byTooltip(kNexusSpeakTooltip),
        ),
        findsOneWidget,
      );
    }

    // The user's own words get neither: they are already theirs to copy, and the
    // thread is not a player for their own voice.
    final Finder mine = find.ancestor(
      of: find.text('what is the weather?'),
      matching: find.byType(NexusChatBubble),
    );
    expect(
      find.descendant(of: mine, matching: find.byTooltip(kNexusSpeakTooltip)),
      findsNothing,
    );

    // And the control works: one tap reads the answer out loud. This is the
    // manual half of the rule above — the app is silent unless it was spoken to,
    // and it is never silent when it is asked.
    await tester.tap(
      find.descendant(of: reply, matching: find.byTooltip(kNexusSpeakTooltip)),
    );
    await tester.pump();
    expect(speech.said, <String>[ollama.reply]);
  });

  testWidgets('a question asked out loud is answered out loud', (tester) async {
    grantMic();
    final mic = _FakeSpeechInput();
    SpeechInput.override = () => mic;
    addTearDown(() => SpeechInput.override = null);
    final speech = _FakeSpeechOutput();
    SpeechOutput.override = () => speech;
    addTearDown(() => SpeechOutput.override = null);
    await pumpShell(tester);

    // Dictated: the finger is on the button, the recognizer hands over the
    // sentence, and the words land in the field as a draft.
    final TestGesture finger = await holdMic(tester);
    mic.say('what is the weather');
    await tester.pump();
    mic.hear('what is the weather');
    await finger.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(fieldText(tester), 'what is the weather');
    expect(speech.said, isEmpty, reason: 'nothing is spoken before the answer');

    await tapTheButton(tester, sendButton());
    await tester.pumpAndSettle();

    // Spoken in, spoken out: the reply is read once, as it lands.
    expect(speech.said, <String>[ollama.reply]);

    // And the flag is spent with the turn: the next question, typed, is answered
    // in silence even though the one before it was spoken.
    await tester.enterText(find.byType(TextField), 'and tomorrow?');
    await tester.pump();
    await tapTheButton(tester, sendButton());
    await tester.pumpAndSettle();
    expect(speech.said, <String>[ollama.reply]);
  });

  testWidgets('the answer grows in the bubble as the model writes it', (
    tester,
  ) async {
    final brain = _StreamingBrain();
    LocalAiService.override = () => brain;
    addTearDown(brain.end);
    final speech = _FakeSpeechOutput();
    SpeechOutput.override = () => speech;
    addTearDown(() => SpeechOutput.override = null);
    await pumpShell(tester);

    await tester.enterText(find.byType(TextField), 'count to three');
    await tester.pump();
    await tapTheButton(tester, sendButton());
    await tester.pump();
    expect(brain.prompts, <String>['count to three']);

    // Nothing has arrived yet, so the bubble is still the placeholder — the
    // state the user used to be stuck in for the whole answer.
    expect(find.text(kNexusThinking), findsOneWidget);

    // The first token lands while the model is still working: the placeholder is
    // gone, and the half-sentence is in its place.
    brain.write('One, ');
    await tester.pump();
    expect(find.text(kNexusThinking), findsNothing);
    expect(find.text('One, '), findsOneWidget);

    // Each piece is appended to what is already there rather than replacing it.
    brain.write('two, ');
    await tester.pump();
    expect(find.text('One, two, '), findsOneWidget);

    // A half-written answer is a placeholder, not a reply: the copy and speaker
    // controls wait for the sentence to be whole, and nothing is spoken yet.
    final Finder half = find.ancestor(
      of: find.text('One, two, '),
      matching: find.byType(NexusChatBubble),
    );
    expect(
      find.descendant(of: half, matching: find.byTooltip(kNexusSpeakTooltip)),
      findsNothing,
    );
    expect(speech.said, isEmpty);

    // The last token ends the answer: the bubble becomes a real message, with
    // its controls back, and it is read out once — whole.
    brain.write('three.');
    brain.end();
    await tester.pumpAndSettle();
    expect(find.text('One, two, three.'), findsOneWidget);
    expect(
      find.descendant(
        of: find.ancestor(
          of: find.text('One, two, three.'),
          matching: find.byType(NexusChatBubble),
        ),
        matching: find.byTooltip(kNexusSpeakTooltip),
      ),
      findsOneWidget,
    );
    // Nothing is said: this turn was typed. The whole answer is what the speaker
    // button would read, and the button is offered the moment it is whole.
    expect(speech.said, isEmpty);
  });

  testWidgets('a model that stops mid-answer keeps its words and says so', (
    tester,
  ) async {
    final brain = _StreamingBrain();
    LocalAiService.override = () => brain;
    addTearDown(brain.end);
    final speech = _FakeSpeechOutput();
    SpeechOutput.override = () => speech;
    addTearDown(() => SpeechOutput.override = null);
    await pumpShell(tester);

    await tester.enterText(find.byType(TextField), 'tell me a story');
    await tester.pump();
    await tapTheButton(tester, sendButton());
    await tester.pump();

    brain.write('Once upon a time');
    await tester.pump();
    expect(find.text('Once upon a time'), findsOneWidget);

    // The model dies with half a sentence on screen. The words are kept — they
    // are the model's, and erasing them would leave the user with nothing — and
    // the sentence that says what happened is appended, separated by a break so
    // it reads as an ending rather than as more of the story.
    brain.fail(kOnDeviceStreamFailureText);
    brain.end();
    await tester.pumpAndSettle();
    expect(
      find.text('Once upon a time\n\n$kOnDeviceStreamFailureText'),
      findsOneWidget,
    );

    // A broken answer is never read out loud: half a story in the user's ear is
    // worse than a half-story they can read.
    expect(speech.said, isEmpty);
  });

  testWidgets('the thread follows the newest message to the bottom', (
    tester,
  ) async {
    await pumpShell(tester);

    // The thread is the one scroll view on Home; the composer sits under it.
    final Finder thread = find.byType(SingleChildScrollView);
    expect(thread, findsOneWidget);
    ScrollController scroll() =>
        tester.widget<SingleChildScrollView>(thread).controller!;

    // A short thread has nothing to scroll: the greeting and two bubbles fit.
    expect(scroll().position.maxScrollExtent, 0);

    // Enough messages to overflow the phone-shaped screen — each one a bubble
    // of the user's and the placeholder that its answer replaces.
    for (int i = 0; i < 8; i++) {
      await tester.enterText(find.byType(TextField), 'message number $i');
      await tester.pump();
      await tapTheButton(tester, sendButton());
      await tester.pumpAndSettle();
    }

    final ScrollPosition position = scroll().position;
    expect(position.maxScrollExtent, greaterThan(0));
    // The view is at the end of the thread, not where the first message left it.
    expect(position.pixels, closeTo(position.maxScrollExtent, 1));

    // Which is the same claim in pixels: the newest answer is fully inside the
    // viewport, rather than sitting below the composer where nobody can read it.
    final Rect viewport = tester.getRect(thread);
    final Rect newest = tester.getRect(find.text(ollama.reply).last);
    expect(newest.top, greaterThanOrEqualTo(viewport.top));
    expect(newest.bottom, lessThanOrEqualTo(viewport.bottom));
  });

  testWidgets('only the active tab is purple; the rest are grey', (
    tester,
  ) async {
    await pumpShell(tester);

    expect(tabIconColor(tester, Icons.home_rounded), kNexusAccent);
    expect(tabIconColor(tester, Icons.folder_outlined), isNot(kNexusAccent));

    await openTab(tester, 'Files', 1);
    expect(tabIconColor(tester, Icons.folder_rounded), kNexusAccent);
    expect(tabIconColor(tester, Icons.home_outlined), isNot(kNexusAccent));
  });

  testWidgets('Files lists files for the chosen device', (tester) async {
    await pumpShell(tester);
    await openTab(tester, 'Files', 1);

    expect(find.text('This Phone'), findsWidgets);
    expect(find.text('report.pdf'), findsOneWidget);
    expect(find.text('3.4 MB · Oct 9'), findsOneWidget);

    // A folder is a door: the chevron says a tap goes into something, where a
    // file keeps the "more" dots because it opens itself.
    final Finder folder = find.ancestor(
      of: find.text('Downloads'),
      matching: find.byType(NexusFileRow),
    );
    expect(
      find.descendant(
        of: folder,
        matching: find.byIcon(Icons.chevron_right_rounded),
      ),
      findsOneWidget,
    );
    final Finder file = find.ancestor(
      of: find.text('report.pdf'),
      matching: find.byType(NexusFileRow),
    );
    expect(
      find.descendant(
        of: file,
        matching: find.byIcon(Icons.chevron_right_rounded),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: file,
        matching: find.byIcon(Icons.more_horiz_rounded),
      ),
      findsOneWidget,
    );

    // Switch device through the dropdown.
    await tester.tap(find.text('This Phone').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('My PC').last);
    await tester.pumpAndSettle();
    expect(find.text('On My PC'), findsOneWidget);
  });

  testWidgets('long-pressing a file opens its action sheet', (tester) async {
    await pumpShell(tester);
    await openTab(tester, 'Files', 1);

    await tester.longPress(find.text('report.pdf'));
    await tester.pumpAndSettle();

    final sheet = find.byType(BottomSheet);
    expect(sheet, findsOneWidget);
    expect(
      find.descendant(of: sheet, matching: find.text('4.0 KB · Oct 11')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: sheet, matching: find.text('Send to a device')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: sheet, matching: find.text('Rename')),
      findsOneWidget,
    );
  });

  testWidgets('each bubble is its own selection, not the whole thread', (
    tester,
  ) async {
    await pumpShell(tester);
    await tester.enterText(find.byType(TextField), 'remember this');
    await tester.pump();
    await tapTheButton(tester, sendButton());
    await tester.pumpAndSettle();

    // One region per message. A single region around the thread meant "Select
    // all" swept the question and the answer into one clipboard, so copying a
    // reply also copied what was asked.
    expect(find.byType(SelectionArea), findsNWidgets(2));
    for (final String line in <String>['remember this', ollama.reply]) {
      expect(
        find.ancestor(
          of: find.text(line),
          matching: find.byType(SelectionArea),
        ),
        findsOneWidget,
      );
    }
  });

  testWidgets('the composer clears the tab bar and the bubbles take sides', (
    tester,
  ) async {
    await pumpShell(tester);

    // The pill must never sit under the navigation bar.
    final field = tester.getRect(find.byType(TextField));
    final bar = tester.getRect(find.byType(NexusTabBar));
    expect(field.bottom, lessThan(bar.top));

    // A real exchange, because there is no invented one to measure any more.
    await tester.enterText(find.byType(TextField), 'What’s in my Downloads?');
    await tester.pump();
    await tapTheButton(tester, sendButton());
    await tester.pumpAndSettle();

    // Measure the text, not the bubble: each bubble is an Align, so the
    // bubble's own rect is the full column and says nothing about its side.
    final mine = tester.getRect(find.text('What’s in my Downloads?'));
    final theirs = tester.getRect(find.text(ollama.reply));
    expect(theirs.left, lessThan(60));
    expect(mine.left, greaterThan(theirs.left));
    expect(mine.right, greaterThan(theirs.right));
  });

  testWidgets('Devices shows a dot and a word per peer', (tester) async {
    await pumpShell(tester);
    await openTab(tester, 'Devices', 2);

    expect(find.text('PAIRED'), findsOneWidget);
    expect(find.text('Online'), findsNWidgets(2));
    expect(find.text('Offline'), findsOneWidget);
    expect(find.byType(NexusStatusDot), findsNWidgets(3));
    expect(find.text('Pair a device'), findsOneWidget);

    final dots = tester.widgetList<NexusStatusDot>(find.byType(NexusStatusDot));
    expect(dots.where((dot) => dot.online).length, 2);
  });

  /// The switch on a named Settings row.
  Switch switchOn(WidgetTester tester, String row) => tester.widget<Switch>(
    find.descendant(
      of: find.ancestor(of: find.text(row), matching: find.byType(NexusRow)),
      matching: find.byType(Switch),
    ),
  );

  Future<void> tapSwitchOn(WidgetTester tester, String row) async {
    await tester.tap(
      find.descendant(
        of: find.ancestor(of: find.text(row), matching: find.byType(NexusRow)),
        matching: find.byType(Switch),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('appearance follows the phone until the user says otherwise', (
    tester,
  ) async {
    await pumpShell(tester);
    await openTab(tester, 'Settings', 3);

    // The default is the phone's own answer — and a widget test's platform is
    // (by default) a light one, so the light frame is what "follow" means here.
    expect(find.text('Follow system'), findsOneWidget);
    expect(switchOn(tester, 'Follow system').value, isTrue);
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold).first).backgroundColor,
      NexusUiColors.light.background,
    );
    // The manual switch reports the state and refuses to pretend otherwise: an
    // enabled switch that bounced straight back would look broken.
    expect(switchOn(tester, 'Dark mode').value, isFalse);
    expect(switchOn(tester, 'Dark mode').onChanged, isNull);
    expect(
      find.text('From your phone — turn off Follow system to choose'),
      findsOneWidget,
    );
    // Disabled and visibly greyed, not merely inert: a Material switch with
    // `onChanged: null` still looks almost enabled, and a control that looks
    // live but ignores taps is the thing users report as broken.
    expect(
      tester.widget<Opacity>(find.byKey(kNexusDarkModeLocked)).opacity,
      lessThan(0.5),
    );

    // Taking appearance back in hand, then darkening it.
    await tapSwitchOn(tester, 'Follow system');
    expect(switchOn(tester, 'Follow system').value, isFalse);
    expect(switchOn(tester, 'Dark mode').onChanged, isNotNull);
    expect(
      tester.widget<Opacity>(find.byKey(kNexusDarkModeLocked)).opacity,
      1.0,
      reason: 'once the user is in charge the switch is fully live again',
    );

    await tapSwitchOn(tester, 'Dark mode');
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold).first).backgroundColor,
      NexusUiColors.dark.background,
    );
    expect(switchOn(tester, 'Dark mode').value, isTrue);
  });

  testWidgets(
    'the theme switch shows it is working, then gets out of the way',
    (tester) async {
      await pumpShell(tester);
      await openTab(tester, 'Settings', 3);
      await tapSwitchOn(tester, 'Follow system');

      await tester.tap(
        find.descendant(
          of: find.ancestor(
            of: find.text('Dark mode'),
            matching: find.byType(NexusRow),
          ),
          matching: find.byType(Switch),
        ),
      );
      // The frame that is applying the new theme: the switch is a spinner while
      // the screen catches up, and the row is still there to be looked at.
      await tester.pump();
      expect(find.byKey(kNexusThemeBusy), findsOneWidget);

      await tester.pumpAndSettle();
      expect(find.byKey(kNexusThemeBusy), findsNothing);
      expect(switchOn(tester, 'Dark mode').value, isTrue);
    },
  );

  testWidgets('opening a tab asks its screen to look again', (tester) async {
    await pumpShell(tester);
    // Offstage while another tab is showing, which is where the first readings
    // are taken: the shell keeps every tab alive, and so do these finders.
    final Finder settings = find.byType(SettingsTab, skipOffstage: false);
    final Finder home = find.byType(HomeTab, skipOffstage: false);
    final int settingsBefore = tester
        .widget<SettingsTab>(settings)
        .refreshEpoch;
    final int homeBefore = tester.widget<HomeTab>(home).refreshEpoch;

    // The shell is the one that knows a tab was selected, and every visit is a
    // new number: both screens read where answers come from when they mount, and
    // a reading that never happened again would keep saying "No AI" — or keep
    // promising this device — after the model or the PC arrived.
    await openTab(tester, 'Settings', 3);
    await tester.pumpAndSettle();
    expect(
      tester.widget<SettingsTab>(settings).refreshEpoch,
      greaterThan(settingsBefore),
    );

    await openTab(tester, 'Home', 0);
    await tester.pumpAndSettle();
    expect(tester.widget<HomeTab>(home).refreshEpoch, greaterThan(homeBefore));
  });

  testWidgets('the composer line is re-read when Home is opened again', (
    tester,
  ) async {
    AiStatus.debugProbeOverride = () async => const AiStatus(AiSource.none);
    addTearDown(() => AiStatus.debugProbeOverride = null);

    Future<void> pumpAt(int epoch) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: NexusTheme.light(),
          home: Scaffold(body: HomeTab(refreshEpoch: epoch)),
        ),
      );
      await tester.pump();
      await tester.pump();
      // The line is swapped with an animation, so the old one is on its way out
      // for a few frames: settle before reading which line is on screen.
      await tester.pumpAndSettle();
    }

    await pumpAt(0);
    expect(find.textContaining('Your own devices answer'), findsOneWidget);

    // The model is downloaded — or the PC's Ollama comes up — while the screen
    // stays alive: coming back to Home is the moment to read it again, because
    // the line under the composer is a promise about the next answer.
    AiStatus.debugProbeOverride = () async => const AiStatus(AiSource.onDevice);
    await pumpAt(1);
    expect(find.textContaining('This device answers'), findsOneWidget);
    expect(find.textContaining('Your own devices answer'), findsNothing);
  });

  testWidgets('the Brain rows follow a model that arrives while open', (
    tester,
  ) async {
    final Directory dir = Directory.systemTemp.createTempSync('nexus_reread');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final OnDeviceAiService onDevice = OnDeviceAiService(
      model: OnDeviceModel(directory: () async => dir),
    );
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    Future<void> pumpAt(int epoch) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: NexusTheme.light(),
          home: Scaffold(
            body: SettingsTab(
              darkMode: false,
              onDarkModeChanged: (_) {},
              onDevice: onDevice,
              refreshEpoch: epoch,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.scrollUntilVisible(
        find.text('AI status'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump();
    }

    await pumpAt(0);
    expect(find.text('Download model'), findsOneWidget);
    expect(find.text('Delete model'), findsNothing);

    // The model lands while the screen is still open — a download finishing in
    // the background is exactly that — and the next visit to the tab is the
    // signal to read it again.
    File('${dir.path}/$kOnDeviceModelFileName')
        .writeAsBytesSync(List<int>.filled(4096, 7));
    await pumpAt(1);

    expect(find.text('Delete model'), findsOneWidget);
    expect(find.text('Download model'), findsNothing);
  });

  testWidgets('the About row names the build, not an empty shell', (
    tester,
  ) async {
    final Directory dir = Directory.systemTemp.createTempSync('nexus_about');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    await pumpBrainSettings(
      tester,
      OnDeviceAiService(model: OnDeviceModel(directory: () async => dir)),
    );
    await tester.scrollUntilVisible(
      find.text('Version'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();

    // The version the build actually is, and no line claiming the model is not
    // attached while it is answering questions.
    expect(find.text(appVersion), findsOneWidget);
    expect(find.text('UI shell preview'), findsNothing);
    expect(find.textContaining('no model attached'), findsNothing);
  });

  testWidgets('the colour wheel applies the pick on Done, not while dragging', (
    tester,
  ) async {
    await pumpShell(tester);
    await openTab(tester, 'Settings', 3);

    expect(find.text('Accent colour'), findsOneWidget);
    expect(find.textContaining('choose accent color'), findsOneWidget);
    expect(
      tabIconColor(tester, Icons.settings_rounded),
      NexusAccent.purple.light,
      reason: 'the shell starts on the shipped purple',
    );

    await tester.tap(find.byKey(kNexusPickColor));
    await tester.pumpAndSettle();

    // The wheel is the control: a real one, in a dialog, with the hex bar that
    // makes a picked colour repeatable.
    expect(find.byKey(kNexusColorWheel), findsOneWidget);

    // Pick a colour by touching the wheel, which is what a user does — a tap in
    // the ring, away from the centre where saturation is zero.
    final Rect wheel = tester.getRect(find.byKey(kNexusColorWheel));
    await tester.tapAt(
      Offset(wheel.left + wheel.width * 0.78, wheel.top + wheel.height * 0.28),
    );
    await tester.pumpAndSettle();

    // Nothing is repainted yet: the wheel used to apply on every drag event,
    // which made the whole app stutter while the user was still choosing. The
    // dialog previews the colour; the app keeps the one it had until Done.
    expect(
      tabIconColor(tester, Icons.settings_rounded),
      NexusAccent.purple.light,
      reason: 'a preview must not repaint the app before it is confirmed',
    );

    // Done is the one moment the pick becomes the accent — and it is not a
    // private repaint of one widget: the whole scheme follows, which is what
    // Material's own controls read.
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.byKey(kNexusColorWheel), findsNothing);
    final Color painted = tabIconColor(tester, Icons.settings_rounded);
    expect(
      painted,
      isNot(NexusAccent.purple.light),
      reason: 'the confirmed colour has to be the accent',
    );
    expect(
      Theme.of(tester.element(find.byType(NexusTabBar))).colorScheme.primary,
      painted,
    );

    // Reset is a pending choice too: it paints nothing until Done, and then it
    // is the way back to the shipped purple.
    await tester.tap(find.byKey(kNexusPickColor));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(kNexusResetAccent));
    await tester.pumpAndSettle();
    expect(
      tabIconColor(tester, Icons.settings_rounded),
      painted,
      reason: 'Reset previews the shipped purple without applying it',
    );
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(
      tabIconColor(tester, Icons.settings_rounded),
      NexusAccent.purple.light,
    );
  });

  test('a pale hex swatch shows the colour that was picked', () {
    // #FBF5FF is a near-white lavender. The row used to draw the *derived ink*
    // for a light page, which is a deepened purple — so typing this hex showed a
    // purple dot. The swatch is the pick itself; only the palette is derived.
    const Color pale = Color(0xFFFBF5FF);
    final NexusAccent accent = NexusAccent.custom(pale);
    expect(accent.swatch, pale);
    expect(accent.label, 'Custom #FBF5FF');
    expect(accent.light, isNot(pale));
    expect(accent.light.computeLuminance(), lessThanOrEqualTo(0.45));
  });

  test('a picked accent is made readable, and a legible one is left alone', () {
    // Almost white: unusable as ink on a light page, so it is deepened until it
    // can be read. The hue survives; only lightness moves.
    final NexusAccent pale = NexusAccent.custom(const Color(0xFFFFF9C4));
    expect(pale.light, isNot(const Color(0xFFFFF9C4)));
    expect(pale.light.computeLuminance(), lessThanOrEqualTo(0.45));
    expect(
      HSLColor.fromColor(pale.light).hue,
      closeTo(HSLColor.fromColor(const Color(0xFFFFF9C4)).hue, 1),
    );
    // Near black: already ink, so it is painted exactly as it was picked — an
    // accent the user chose is not silently turned into a different colour.
    const Color deep = Color(0xFF0B3D91);
    expect(NexusAccent.custom(deep).light, deep);
    // And on a dark page the same rule runs the other way: a colour that would
    // disappear into the near-black surface is lifted, and one that already
    // stands out is left exactly as it was picked.
    const Color navy = Color(0xFF14143C);
    expect(navy.computeLuminance(), lessThan(0.1));
    expect(NexusAccent.custom(navy).dark, isNot(navy));
    expect(NexusAccent.custom(navy).dark.computeLuminance(), greaterThan(0.2));
    expect(
      NexusAccent.custom(const Color(0xFF9D6BF5)).dark,
      const Color(0xFF9D6BF5),
    );
    // And the ink that sits *on* the accent flips when the accent is too bright
    // for white to be seen on it — which is the one place a pale pick is safe.
    const Color paleYellow = Color(0xFFFFF176);
    expect(
      NexusAccent.custom(paleYellow).onAccentFor(Brightness.dark),
      isNot(Colors.white),
    );
    expect(NexusAccent.purple.onAccentFor(Brightness.dark), Colors.white);
  });

  testWidgets('Settings opens at the top however it was left', (tester) async {
    await pumpShell(tester);
    await openTab(tester, 'Settings', 3);

    final Finder settingsList = find.descendant(
      of: find.byType(SettingsTab),
      matching: find.byType(ListView),
    );

    // Scrolled down to the About rows, then away to another tab.
    await tester.drag(settingsList, const Offset(0, -600));
    await tester.pumpAndSettle();
    final ScrollController controller = tester
        .widget<ListView>(settingsList)
        .controller!;
    expect(controller.offset, greaterThan(0));

    await openTab(tester, 'Home', 0);
    await openTab(tester, 'Settings', 3);

    expect(controller.offset, 0);
    expect(find.text('Follow system'), findsOneWidget);
  });

  testWidgets('the composer pill is the theme\'s surface in both themes', (
    tester,
  ) async {
    await pumpShell(tester);

    // The pill, found by what it is rather than where it is: the composer's own
    // container, painted in the theme's surface colour. It used to be a dark
    // tone under a light frame, which is the bug this pins shut.
    Finder pillIn(Color color) => find.byWidgetPredicate(
      (Widget widget) =>
          widget is AnimatedContainer &&
          widget.decoration is BoxDecoration &&
          (widget.decoration! as BoxDecoration).color == color,
    );

    expect(pillIn(NexusUiColors.light.surface), findsWidgets);
    expect(
      pillIn(const Color(0xFF111113)),
      findsNothing,
      reason: 'nothing in the light composer may be painted the live room',
    );

    await openTab(tester, 'Settings', 3);
    await tapSwitchOn(tester, 'Follow system');
    await tapSwitchOn(tester, 'Dark mode');
    await openTab(tester, 'Home', 0);

    expect(pillIn(NexusUiColors.dark.surface), findsWidgets);
    expect(pillIn(NexusUiColors.light.surface), findsNothing);
  });

  testWidgets('voice settings is a real page you can open and leave', (
    tester,
  ) async {
    await pumpShell(tester);
    await openTab(tester, 'Settings', 3);

    await tester.tap(find.text('Voice & speech'));
    await tester.pumpAndSettle();

    expect(find.text('Wake word'), findsOneWidget);
    expect(find.text('Speak replies'), findsOneWidget);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Wake word'), findsNothing);
    expect(tester.widget<IndexedStack>(find.byType(IndexedStack)).index, 3);
  });

  testWidgets('a new language is shown as soon as it is chosen', (
    tester,
  ) async {
    // The row reads the value from VoiceSettings, a notifier. Picking a
    // language must update the closed dropdown on the same frame — showing the
    // old one until the page is reopened made a working setting look ignored.
    final VoiceSettings voice = VoiceSettings(initial: 'en-US');
    VoiceSettings.override = () => voice;
    addTearDown(() => VoiceSettings.override = null);
    await pumpShell(tester);
    await openTab(tester, 'Settings', 3);
    await tester.tap(find.text('Voice & speech'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('nexus-voice-language')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('English (UK)').last);
    await tester.pumpAndSettle();

    expect(voice.language, 'en-GB');
    expect(find.text('English (UK)'), findsOneWidget);
    expect(find.text('English (US)'), findsNothing);
  });

  testWidgets('Speak replies is live and persisted', (tester) async {
    final VoiceSettings voice = VoiceSettings(initial: 'en-US');
    VoiceSettings.override = () => voice;
    addTearDown(() => VoiceSettings.override = null);
    await pumpShell(tester);
    await openTab(tester, 'Settings', 3);
    await tester.tap(find.text('Voice & speech'));
    await tester.pumpAndSettle();

    expect(voice.speakReplies, isTrue);
    await tester.tap(find.byKey(const Key('nexus-speak-replies')));
    await tester.pumpAndSettle();
    expect(voice.speakReplies, isFalse);

    // And the dead wake-word switch says why it is dead.
    expect(
      find.text('Requires background service (disabled for privacy).'),
      findsOneWidget,
    );
  });

  testWidgets('a custom system prompt is saved from Settings', (tester) async {
    final SystemPrompt prompt = SystemPrompt();
    SystemPrompt.override = () => prompt;
    await pumpShell(tester);
    await openTab(tester, 'Settings', 3);
    await tester.scrollUntilVisible(
      find.byKey(const Key('nexus-system-prompt')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();

    // Honest expectations under the field: the on-device model may ignore a
    // complex instruction, so the note says to keep it brief.
    expect(
      find.text(
        'Note: Small on-device models may ignore complex instructions. '
        'For best results, keep it brief (e.g., \'My name is TVCraft\').',
      ),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const Key('nexus-system-prompt')),
      'The user is TVCraft. Always answer in French.',
    );
    await tester.pumpAndSettle();

    expect(prompt.text, 'The user is TVCraft. Always answer in French.');
  });

  testWidgets('Settings pushes to Customization, and back returns to the tab', (
    tester,
  ) async {
    await pumpShell(tester);
    await openTab(tester, 'Settings', 3);

    await tester.tap(find.text('Customization'));
    await tester.pumpAndSettle();

    // The page the row promises: its own title, the App icon group, and the
    // honest note about the options that are not here yet.
    expect(find.text('LAUNCHER ICON'), findsOneWidget);
    expect(find.text('App icon'), findsOneWidget);
    expect(
      find.textContaining('Accent colour, type and motion join this page'),
      findsOneWidget,
    );

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('LAUNCHER ICON'), findsNothing);
    expect(tester.widget<IndexedStack>(find.byType(IndexedStack)).index, 3);
  });

  testWidgets('a hold streams the utterance in and leaves it in the field', (
    tester,
  ) async {
    grantMic();
    final mic = _FakeSpeechInput();
    SpeechInput.override = () => mic;
    addTearDown(() => SpeechInput.override = null);
    await pumpShell(tester);
    await withMicLog((List<String> log) async {
      final int bubblesBefore = find.byType(NexusChatBubble).evaluate().length;

      final TestGesture finger = await holdMic(tester);

      // The button is a stop while the microphone is open, and the ring inside
      // it says so for as long as that lasts.
      expect(stopButton(), findsOneWidget);
      expect(micButton(), findsNothing);
      expect(recordingIndicator, findsOneWidget);

      // The recognizer revises as it hears, and every revision is on screen: the
      // sentence is written while it is still being spoken, not after it.
      mic.say('hello');
      await tester.pump();
      expect(fieldText(tester), 'hello');
      mic.say('hello world');
      await tester.pump();
      expect(fieldText(tester), 'hello world');

      // Releasing on the button asks for the transcript instead of throwing the
      // utterance away...
      await finger.up();
      await tester.pump();
      expect(mic.finishes, 1);
      expect(mic.stops, 0);

      mic.hear('hello world');
      await tester.pumpAndSettle();

      // ...and the transcript stays in the field. A release sends nothing: the
      // arrow is the only thing in this composer that posts a message, which is
      // what makes a mis-heard sentence editable instead of gone.
      expect(fieldText(tester), 'hello world');
      expect(find.byType(NexusChatBubble).evaluate().length, bubblesBefore);
      expect(sendButton(), findsOneWidget);
      expect(recordingIndicator, findsNothing);
      expect(log.first, contains('mode=oneShot'));
      expect(log.last, contains('reason=final'));

      // The tap that follows is the send, and it is what posts the message.
      await tapTheButton(tester, sendButton());
      expect(fieldText(tester), '');
      expect(find.text('hello world'), findsOneWidget);
      // Two bubbles, not one: the message, and the PC's answer to it. The count
      // is checked after the answer has landed, so the placeholder and the reply
      // are the same bubble as far as this test is concerned.
      await tester.pumpAndSettle();
      expect(find.byType(NexusChatBubble).evaluate().length, bubblesBefore + 2);
      expect(find.text(ollama.reply), findsOneWidget);
      expect(micButton(), findsOneWidget);
    });
  });

  testWidgets('a finger that comes up away from the button cancels the hold', (
    tester,
  ) async {
    grantMic();
    final mic = _FakeSpeechInput();
    SpeechInput.override = () => mic;
    addTearDown(() => SpeechInput.override = null);
    await pumpShell(tester);
    final int bubblesBefore = find.byType(NexusChatBubble).evaluate().length;
    await withMicLog((List<String> log) async {
      final TestGesture finger = await holdMic(tester);
      mic.say('never mind');
      await tester.pump();
      expect(fieldText(tester), 'never mind');

      // The finger slides clear of the disc — and of the generous margin around
      // it — before it comes up. That is how a hold is abandoned, and the words
      // said into an abandoned gesture are not a transcript the user asked for:
      // the field goes back to empty rather than keeping a guess nobody wanted.
      await finger.moveTo(
        tester.getCenter(stopButton()) + const Offset(0, -140),
      );
      await tester.pump();
      await finger.up();
      await tester.pumpAndSettle();

      // A cancel, not a stop: nothing was asked for, so nothing is handed over —
      // and the microphone is released the moment the finger leaves, rather than
      // waiting on a recognizer that has nothing to answer with.
      expect(mic.stops, 1);
      expect(mic.finishes, 0);
      expect(micButton(), findsOneWidget);
      expect(recordingIndicator, findsNothing);
      expect(fieldText(tester), '');
      expect(find.text('never mind'), findsNothing);
      expect(find.byType(NexusChatBubble).evaluate().length, bubblesBefore);
      expect(log.last, contains('reason=cancelled'));
    });
  });

  testWidgets('a tap dictates until the next tap, and the words stay', (
    tester,
  ) async {
    grantMic();
    final mic = _FakeSpeechInput();
    SpeechInput.override = () => mic;
    addTearDown(() => SpeechInput.override = null);
    await pumpShell(tester);
    await withMicLog((List<String> log) async {
      final int bubblesBefore = find.byType(NexusChatBubble).evaluate().length;

      // Nothing in the field means the button is the mic and nothing else: the
      // arrow is for words, and there are none yet.
      expect(mic.listens, 0);
      expect(sendButton(), findsNothing);

      // The first tap opens the microphone and leaves it open: a tap is not one
      // utterance, it is "listen until I say otherwise".
      await tapTheButton(tester, micButton());
      expect(mic.listens, 1);
      await settleButton(tester);
      expect(stopButton(), findsOneWidget);
      expect(micButton(), findsNothing);
      expect(recordingIndicator, findsOneWidget);

      // The words collect as they are spoken, across whatever pauses the user
      // takes: nothing is ended by a silence.
      mic.say('hello');
      await tester.pump();
      expect(fieldText(tester), 'hello');
      mic.say('hello world');
      await tester.pump();
      expect(fieldText(tester), 'hello world');
      await tester.pump(const Duration(seconds: 5));
      expect(fieldText(tester), 'hello world');
      expect(stopButton(), findsOneWidget);

      // The second tap closes the session and keeps what it collected. Stopped,
      // not finished: nothing is handed over after the fact, because the words
      // the user watched arrive are the words the user is entitled to keep.
      await tapTheButton(tester, stopButton());
      expect(mic.stops, 1);
      expect(mic.finishes, 0);
      expect(fieldText(tester), 'hello world');
      expect(find.byType(NexusChatBubble).evaluate().length, bubblesBefore);
      // The ring leaves with the session; what the swap still has on screen for
      // a moment is the stop fading out, which is not a live microphone.
      await settleButton(tester);
      expect(recordingIndicator, findsNothing);
      expect(sendButton(), findsOneWidget);
      expect(log.first, contains('mode=continuous'));
      expect(log.last, contains('reason=stopped'));
    });
  });

  testWidgets('a dictation is a draft: it can be edited before it is sent', (
    tester,
  ) async {
    grantMic();
    final mic = _FakeSpeechInput();
    SpeechInput.override = () => mic;
    addTearDown(() => SpeechInput.override = null);
    await pumpShell(tester);

    await tapTheButton(tester, micButton());
    mic.say('one');
    await tester.pump();
    await tapTheButton(tester, stopButton());
    expect(fieldText(tester), 'one');
    final int bubblesBefore = find.byType(NexusChatBubble).evaluate().length;

    // The field is an ordinary field, and what the recognizer heard is a
    // starting point: the user can fix a mis-hearing before anything leaves the
    // composer, which is only possible because the release no longer sends.
    await tester.enterText(find.byType(TextField), 'one two');
    await tester.pump();
    expect(sendButton(), findsOneWidget);
    await tapTheButton(tester, sendButton());

    expect(find.text('one two'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byType(NexusChatBubble).evaluate().length, bubblesBefore + 2);
    expect(find.text(ollama.reply), findsOneWidget);
    expect(fieldText(tester), '');
    expect(micButton(), findsOneWidget);
  });

  testWidgets('a hold nobody ends is closed by the guard', (tester) async {
    grantMic();
    final mic = _LateAnswerSpeechInput();
    SpeechInput.override = () => mic;
    addTearDown(() => SpeechInput.override = null);
    await pumpShell(tester);
    await withMicLog((List<String> log) async {
      final TestGesture finger = await holdMic(tester);
      expect(stopButton(), findsOneWidget);
      expect(recordingIndicator, findsOneWidget);
      mic.say('still here');
      await tester.pump();
      expect(fieldText(tester), 'still here');

      // Well inside the guard a live microphone is still the finger's to end.
      await tester.pump(const Duration(seconds: 20));
      expect(stopButton(), findsOneWidget);
      expect(recordingIndicator, findsOneWidget);

      // Past it the session ends by itself, the microphone is released on the
      // platform side too, and the log says which of the ways it was.
      await tester.pump(const Duration(seconds: 11));
      await tester.pump(const Duration(milliseconds: 250));
      expect(micButton(), findsOneWidget);
      expect(recordingIndicator, findsNothing);
      expect(mic.stops, 1);
      expect(log.last, matches(stopLine));
      expect(log.last, contains('reason=timeout'));

      // A hold nobody released is an abandoned utterance, so the guesses that
      // were streaming into the field go with it: there is no release to have
      // meant them, and the button is back to the mic.
      expect(fieldText(tester), '');

      // And the release that comes after it has nothing left to end: one
      // session, one stop, and no transcript asked for out of a closed one.
      await finger.up();
      await tester.pumpAndSettle();
      expect(mic.stops, 1);
      expect(mic.finishes, 0);
      expect(micButton(), findsOneWidget);
    });
  });

  testWidgets('a session the platform never answers ends on the finger leaving', (
    tester,
  ) async {
    grantMic();
    final mic = _LateAnswerSpeechInput();
    SpeechInput.override = () => mic;
    addTearDown(() => SpeechInput.override = null);
    await pumpShell(tester);

    final TestGesture finger = await holdMic(tester);
    await finger.moveTo(tester.getCenter(stopButton()) + const Offset(0, -140));
    await finger.up();
    await tester.pump();

    // Idle at once. The state is cleared before the platform is told, so a
    // channel that never answers cannot hold the button — this is the bug these
    // tests exist for — and the button is the mic on that same frame.
    expect(micButton(), findsOneWidget);
    expect(mic.stops, 1);
    // The ring belongs to the session, and it leaves with it: what is still on
    // screen for the next 180ms is the stop fading out, which is why the
    // indicator is checked once that has run its course.
    await settleButton(tester);
    expect(recordingIndicator, findsNothing);
    // The button's own swap is a 180ms fade, so the stop it is trading places
    // with is still on its way out; once that has run its course, nothing is
    // left saying "listening".
    await tester.pump(const Duration(milliseconds: 250));
    expect(stopButton(), findsNothing);

    // The guard is left to run out, since nothing else will end a session whose
    // recognizer never answers — exactly like the platform one it stands in
    // for. It must sweep an already-closed session without reopening anything.
    await tester.pump(const Duration(seconds: 31));
    expect(micButton(), findsOneWidget);
    expect(mic.stops, 1);
  });

  testWidgets('words from a session the user abandoned are dropped', (
    tester,
  ) async {
    grantMic();
    final mic = _LateAnswerSpeechInput();
    SpeechInput.override = () => mic;
    addTearDown(() => SpeechInput.override = null);
    await pumpShell(tester);
    final int before = find.byType(NexusChatBubble).evaluate().length;
    await withMicLog((List<String> log) async {
      final TestGesture finger = await holdMic(tester);
      await finger.moveTo(
        tester.getCenter(stopButton()) + const Offset(0, -140),
      );
      await finger.up();
      await tester.pumpAndSettle();

      // The recognizer finally reports the sentence it was still holding. It
      // belongs to a session the user ended, so it is dropped, not sent.
      mic.answer('this was cancelled');
      await tester.pumpAndSettle();
      expect(find.text('this was cancelled'), findsNothing);
      expect(find.byType(NexusChatBubble).evaluate().length, before);
      expect(log, hasLength(2));
      expect(log.last, contains('reason=cancelled'));
    });
  });

  testWidgets(
    'a guess in flight when the session ends never lands in the field',
    (tester) async {
      grantMic();
      final mic = _FakeSpeechInput();
      SpeechInput.override = () => mic;
      addTearDown(() => SpeechInput.override = null);
      await pumpShell(tester);

      final TestGesture finger = await holdMic(tester);
      mic.say('half a sentence');
      await tester.pump();
      expect(fieldText(tester), 'half a sentence');

      // Cancelled: the field is cleared, and the interim words go with the
      // session that produced them. A revision the recognizer was still sending
      // belongs to nobody now, so the next user's field cannot inherit it.
      await finger.moveTo(
        tester.getCenter(stopButton()) + const Offset(0, -140),
      );
      await finger.up();
      await tester.pumpAndSettle();
      expect(fieldText(tester), '');

      mic.say('half a sentence and more');
      await tester.pump();
      expect(fieldText(tester), '');
    },
  );

  testWidgets('every session logs a start, a release and a matching stop', (
    tester,
  ) async {
    grantMic();
    final mic = _FakeSpeechInput();
    SpeechInput.override = () => mic;
    addTearDown(() => SpeechInput.override = null);
    await pumpShell(tester);
    await withMicLog((List<String> log) async {
      final TestGesture finger = await holdMic(tester);
      await finger.up();
      await tester.pump();
      mic.hear('what time is it');
      await tester.pumpAndSettle();

      // Three lines: the hold opening the session, the finger coming up on the
      // button, and the session closing on the transcript it produced.
      expect(log, hasLength(3));
      expect(log.first, matches(startLine));
      expect(log.first, contains('mode=oneShot'));
      expect(log[1], matches(releaseLine));
      expect(log.last, matches(stopLine));
      expect(log.last, contains('reason=final'));
    });
  });

  testWidgets('the microphone is asked for once, before any recognizer starts', (
    tester,
  ) async {
    final ask = _FakeMicAsk.granted();
    MicrophoneAccess.debugRequestOverride = ask.call;
    addTearDown(() => MicrophoneAccess.debugRequestOverride = null);
    final mic = _FakeSpeechInput();
    SpeechInput.override = () => mic;
    addTearDown(() => SpeechInput.override = null);
    await pumpShell(tester);

    // The first hold asks first and listens second: the recognizer is never
    // started for a user who has not answered the permission dialog.
    final TestGesture finger = await holdMic(tester);
    expect(ask.asks, 1);
    expect(mic.listens, 1);
    expect(stopButton(), findsOneWidget);
    await finger.up();
    await tester.pump();
    mic.hear('what time is it');
    await tester.pumpAndSettle();
    expect(fieldText(tester), 'what time is it');

    // A tap goes through the same door, and does not ask a second time either:
    // Android would not show the dialog anyway, so asking twice would be a
    // gesture that quietly does nothing.
    await tapTheButton(tester, sendButton());
    await tester.pumpAndSettle();
    await tapTheButton(tester, micButton());
    expect(ask.asks, 1);
    expect(mic.listens, 2);
    expect(stopButton(), findsOneWidget);
    await tapTheButton(tester, stopButton());
    expect(mic.stops, 1);
  });

  testWidgets('a device with no microphone is not offered one at all', (
    tester,
  ) async {
    // The iPhone this build has no recognizer for, in the shape the shell sees
    // it: the capability says the device cannot listen, so nothing about voice
    // is drawn. (The refusal below is the other half of the rule: a *refused*
    // microphone is still a real button, and it explains itself.)
    SpeechInput.override = () => const _UnavailableSpeechInput();
    addTearDown(() => SpeechInput.override = null);
    DeviceCapabilities.override = () => const DeviceCapabilities(
      platformOverride: TargetPlatform.iOS,
      ramBytes: 8 * 1024 * 1024 * 1024,
    );
    addTearDown(() => DeviceCapabilities.override = null);
    await pumpShell(tester);

    // Neither button is on screen: the composer is the field and the send
    // arrow, and the pill is shorter for it.
    expect(find.byTooltip('Tap to dictate, hold to talk'), findsNothing);
    expect(
      find.byTooltip('Voice input isn’t set up on this device'),
      findsNothing,
    );
    expect(find.byTooltip('Live conversation'), findsNothing);
    expect(
      find.byTooltip('Live conversation isn’t available here'),
      findsNothing,
    );
    expect(find.byIcon(Icons.mic_rounded), findsNothing);
    expect(find.byKey(kNexusLevelBars), findsNothing);

    // Nothing is explained either, because there is nothing to explain: the
    // note line is the brain's, not a refusal about a button nobody drew.
    expect(find.textContaining('Microphone'), findsNothing);

    // And the screen still works: a typed message is sent and answered, which
    // is what a device with no voice has left.
    await tester.enterText(find.byType(TextField), 'type it instead');
    await tester.pump();
    await tapTheButton(tester, sendButton());
    await tester.pumpAndSettle();
    expect(ollama.prompts, <String>['type it instead']);
    expect(find.text(ollama.reply), findsOneWidget);
  });

  testWidgets('a refused microphone offers the settings page that fixes it', (
    tester,
  ) async {
    final ask = _FakeMicAsk.refused(
      'Microphone permission needed — turn it on in system settings.',
    );
    MicrophoneAccess.debugRequestOverride = ask.call;
    addTearDown(() => MicrophoneAccess.debugRequestOverride = null);
    SpeechInput.override = _FakeSpeechInput.new;
    addTearDown(() => SpeechInput.override = null);

    // The platform's settings page, watched rather than opened: what the dialog
    // promises is a call to the activity that owns it (MainActivity's
    // `openAppSettings`).
    final List<MethodCall> deviceCalls = <MethodCall>[];
    const MethodChannel device = MethodChannel('dev.nexus.nexus/device');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(device, (MethodCall call) async {
          deviceCalls.add(call);
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(device, null),
    );
    await pumpShell(tester);

    await tapTheButton(tester, micButton());
    await tester.pumpAndSettle();

    // Asked once, refused, and the answer to the refusal is a door: the dialog
    // names the permission and offers the one place it can be granted.
    expect(ask.asks, 1);
    expect(find.text('Microphone permission needed'), findsOneWidget);
    expect(
      find.text(
        'Microphone permission needed — turn it on in system settings.',
      ),
      findsWidgets,
    );
    expect(find.text(kNexusOpenSettingsLabel), findsOneWidget);

    // Not now: nothing is opened, and the dialog is gone.
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(deviceCalls, isEmpty);
    expect(find.text(kNexusOpenSettingsLabel), findsNothing);

    // And the *way out* works when it is taken: one call to the platform, which
    // is the whole of what this shell can do about a permission. The button to
    // press is the muted one — its tooltip is the refusal now, not the gesture —
    // which is the same button the user is looking at.
    await tester.tap(
      find.byTooltip(
        'Microphone permission needed — turn it on in system settings.',
      ),
    );
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();
    await tester.tap(find.text(kNexusOpenSettingsLabel));
    await tester.pumpAndSettle();
    expect(deviceCalls.map((MethodCall call) => call.method), <String>[
      'openAppSettings',
    ]);
    expect(find.text(kNexusOpenSettingsLabel), findsNothing);
  });

  testWidgets('a device that cannot run the model is told so, and not sold one', (
    tester,
  ) async {
    DeviceCapabilities.override = () => const DeviceCapabilities(
      platformOverride: TargetPlatform.iOS,
      ramBytes: 8 * 1024 * 1024 * 1024,
    );
    addTearDown(() => DeviceCapabilities.override = null);
    final Directory dir = Directory.systemTemp.createTempSync(
      'nexus_unsupported',
    );
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final OnDeviceAiService onDevice = OnDeviceAiService(
      model: OnDeviceModel(directory: () async => dir),
    );

    await pumpBrainSettings(tester, onDevice);

    // The status row stays — "where do the answers come from" still has an
    // answer on this device — and the download half of the section is replaced
    // by one sentence naming the other way to get one.
    expect(find.text('AI status'), findsOneWidget);
    expect(find.text(kNoOnDeviceAiText), findsOneWidget);
    expect(find.text('Download model'), findsNothing);
    expect(find.text('Delete model'), findsNothing);
    expect(find.byKey(kNexusBrainProgress), findsNothing);

    // The sentence about needing a download is gone with the button: the status
    // detail may not point at what is not on screen.
    expect(find.textContaining('Download the model below'), findsNothing);
  });

  testWidgets('an iPhone gets no Voice section, and no dead switches', (
    tester,
  ) async {
    DeviceCapabilities.override = () => const DeviceCapabilities(
      platformOverride: TargetPlatform.iOS,
      ramBytes: 8 * 1024 * 1024 * 1024,
    );
    addTearDown(() => DeviceCapabilities.override = null);
    final Directory dir = Directory.systemTemp.createTempSync('nexus_ios');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    await pumpBrainSettings(
      tester,
      OnDeviceAiService(model: OnDeviceModel(directory: () async => dir)),
    );

    // Wake word and spoken replies are both Android engines in this build, so
    // the section that holds them is not drawn: a screen of switches that
    // cannot switch is worse than a shorter screen.
    expect(find.text('Voice & speech'), findsNothing);
    expect(find.text('Wake word'), findsNothing);
    expect(find.text('Speak replies'), findsNothing);

    // Nothing else was taken with it: the page is still Settings, with the
    // Brain section it came for.
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('AI status'), findsOneWidget);
  });

  testWidgets('a refused microphone leaves the button inert and says why', (
    tester,
  ) async {
    final ask = _FakeMicAsk.refused(
      'Microphone permission needed — try '
      'again from system settings.',
    );
    MicrophoneAccess.debugRequestOverride = ask.call;
    addTearDown(() => MicrophoneAccess.debugRequestOverride = null);
    final mic = _FakeSpeechInput();
    SpeechInput.override = () => mic;
    addTearDown(() => SpeechInput.override = null);
    await pumpShell(tester);
    await withMicLog((List<String> log) async {
      final TestGesture finger = await holdMic(tester);

      // Asked exactly once, no session, and nothing to end: the refusal is
      // answered before any recognizer is started. The answer to the refusal is
      // a dialog with the way out in it, so it is on screen while the finger is
      // still down — and the hold itself stays refused either way.
      expect(ask.asks, 1);
      expect(mic.listens, 0);
      expect(log, isEmpty);
      expect(stopButton(), findsNothing);
      expect(recordingIndicator, findsNothing);
      expect(find.text('Microphone permission needed'), findsOneWidget);
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();

      await finger.up();
      await tester.pumpAndSettle();
      expect(log, isEmpty);
      expect(micButton(), findsNothing);

      // The reason is on the button and in the composer, not hidden behind a
      // gesture — a muted control that explains itself is not a broken one.
      final String message =
          'Microphone permission needed — try again from '
          'system settings.';
      final reason = find.byTooltip(message);
      expect(reason, findsOneWidget);
      expect(find.text(message), findsOneWidget);

      // And a second tap cannot re-ask — Android shows the dialog once — but it
      // is not a dead end either: the tap now offers the page where the
      // permission is turned back on (see the settings-dialog test). No
      // session starts either way.
      await tester.tap(reason);
      await tester.pumpAndSettle();
      expect(ask.asks, 1);
      expect(mic.listens, 0);
      expect(log, isEmpty);
      expect(find.text(kNexusOpenSettingsLabel), findsOneWidget);
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
    });
  });

  testWidgets(
    'an inert mic keeps the long press the tooltip explains it with',
    (tester) async {
      final ask = _FakeMicAsk.refused('Microphone permission needed.');
      MicrophoneAccess.debugRequestOverride = ask.call;
      addTearDown(() => MicrophoneAccess.debugRequestOverride = null);
      SpeechInput.override = _FakeSpeechInput.new;
      addTearDown(() => SpeechInput.override = null);
      await pumpShell(tester);

      // The refusal puts the hold out of action, so the long press is free again —
      // and it is the only way left of reading why the button is inert on a phone,
      // where nothing hovers.
      await tester.longPress(find.byTooltip('Tap to dictate, hold to talk'));
      await tester.pumpAndSettle();
      expect(find.text('Microphone permission needed.'), findsWidgets);
    },
  );

  testWidgets('a second hand tapping elsewhere leaves one session, not two', (
    tester,
  ) async {
    grantMic();
    final mic = _FakeSpeechInput();
    SpeechInput.override = () => mic;
    addTearDown(() => SpeechInput.override = null);
    await pumpShell(tester);

    final TestGesture finger = await holdMic(tester);
    mic.say('hold on');
    await tester.pump();

    // The other hand taps the field while the first is still holding. Nothing
    // breaks: no second recognizer is opened for a gesture that is already
    // speaking, and the hold is not disturbed by the tap.
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(mic.listens, 1);
    expect(stopButton(), findsOneWidget);
    expect(fieldText(tester), 'hold on');

    // The held finger still owns the release: one session, one end, one answer.
    await finger.up();
    await tester.pump();
    expect(mic.finishes, 1);
    mic.hear('hold on a moment');
    await tester.pumpAndSettle();
    expect(fieldText(tester), 'hold on a moment');
    expect(mic.stops, 0);
  });

  testWidgets('a recognizer that closes the session itself keeps the words', (
    tester,
  ) async {
    grantMic();
    final mic = _FakeSpeechInput();
    SpeechInput.override = () => mic;
    addTearDown(() => SpeechInput.override = null);
    await pumpShell(tester);
    await withMicLog((List<String> log) async {
      // A session opened by a tap, and the recognizer gives up on its own —
      // Android does that after a stretch of silence, and it is nobody's doing.
      await tapTheButton(tester, micButton());
      mic.say('half a sentence');
      await tester.pump();
      expect(fieldText(tester), 'half a sentence');

      // The platform closes the session without a word for it.
      mic.hear('');
      await tester.pumpAndSettle();

      // The button is back to the mic and the words are still on screen: a
      // session closing is not a sentence cancelled, and the user is the only
      // one who gets to decide that.
      expect(recordingIndicator, findsNothing);
      expect(stopButton(), findsNothing);
      expect(fieldText(tester), 'half a sentence');
      expect(sendButton(), findsOneWidget);
      expect(log.last, contains('reason=empty'));
    });
  });

  testWidgets('the guard closes a session a tap opened, and keeps its words', (
    tester,
  ) async {
    grantMic();
    final mic = _LateAnswerSpeechInput();
    SpeechInput.override = () => mic;
    addTearDown(() => SpeechInput.override = null);
    await pumpShell(tester);
    await withMicLog((List<String> log) async {
      // The guard is not the hold's: a tap session nobody closes is exactly as
      // much of an open microphone as a hold nobody releases, and it ends the
      // same way.
      await tapTheButton(tester, micButton());
      expect(mic.listens, 1);
      expect(recordingIndicator, findsOneWidget);
      await tester.pump(const Duration(seconds: 31));
      await tester.pump(const Duration(milliseconds: 250));

      expect(mic.stops, 1);
      expect(log.last, contains('reason=timeout'));
      expect(recordingIndicator, findsNothing);
      expect(micButton(), findsOneWidget);
    });
  });

  testWidgets(
    'the app leaving the foreground ends the session, and none starts there',
    (tester) async {
      grantMic();
      final mic = _FakeSpeechInput();
      SpeechInput.override = () => mic;
      addTearDown(() => SpeechInput.override = null);
      await pumpShell(tester);

      await withMicLog((List<String> log) async {
        await tapTheButton(tester, micButton());
        mic.say('half a sentence');
        await tester.pump();
        expect(fieldText(tester), 'half a sentence');
        expect(recordingIndicator, findsOneWidget);

        // The app loses the foreground — the shade, a dialog, another window. The
        // microphone closes with it: consent to listen to a room was given to a
        // screen the user was looking at, and it does not survive that screen
        // going away.
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.pump();

        expect(mic.stops, 1);
        await settleButton(tester);
        expect(recordingIndicator, findsNothing);
        expect(stopButton(), findsNothing);
        expect(log.last, contains('reason=background'));
        // What was heard is still the user's draft: leaving the app is not
        // cancelling a sentence.
        expect(fieldText(tester), 'half a sentence');
        expect(sendButton(), findsOneWidget);

        // And no microphone may be opened from there, however the button is
        // reached: the tap asks, is already allowed, and still listens to nothing.
        await tester.enterText(find.byType(TextField), '');
        await tester.pump();
        await tapTheButton(tester, micButton());
        expect(mic.listens, 1);
        expect(recordingIndicator, findsNothing);

        // Back on screen, the same tap works again — the refusal to listen was
        // about the background, not about the microphone.
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        await tapTheButton(tester, micButton());
        expect(mic.listens, 2);
        expect(recordingIndicator, findsOneWidget);

        // The rest of the way out — the app going away altogether — ends a session
        // the same way, and the platform walks it in the order it happens in:
        // `inactive`, then `hidden`, then `paused`. Nothing is pumped after these:
        // `hidden` turns frames off, and the session is over by the time the
        // observer returns.
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        expect(mic.stops, 2);
        expect(log.last, contains('reason=background'));
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        // One session, one stop, and no second `background` line: the three states
        // are one departure, not three endings.
        expect(mic.stops, 2);
      });
    },
  );
  // -------------------------------------------------------------------------
  // The two ways in: dictation (the composer's listening layout) and live
  // conversation (the page). They share one session machine, one permission ask
  // and one 30-second guard, so what is tested here is the surface each adds.
  // -------------------------------------------------------------------------

  /// The live conversation button: the outlined circle beside the dictation
  /// slot, named for what it opens.
  Finder liveButton() => find.byTooltip('Live conversation');

  /// The live page itself.
  final Finder liveOverlay = find.byKey(kNexusLiveOverlay);

  /// The one line of large type in the middle of the live page.
  String liveText(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(kNexusLiveText)).data!;

  /// Opens live conversation the way a thumb would: the permission ask is
  /// answered in the same frame the tap lands on, and the page's entrance is
  /// 260ms, so it is pumped rather than settled — the page listens from the
  /// moment it is up, and a repeating orb never settles.
  Future<void> openLive(WidgetTester tester) async {
    await tester.tap(liveButton());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 320));
  }

  /// The X that discards a dictation, and the level meter that stands beside the
  /// words. Named once here so every assertion below is about the same widgets
  /// the user is looking at.
  final Finder cancelButton = find.byTooltip('Cancel dictation');
  final Finder levelBars = find.byKey(kNexusLevelBars);

  /// The height of the tallest bar in the meter, in logical pixels — what a
  /// viewer would call "how high the bars are". There is one bar per entry in
  /// the meter's row, and they animate independently, so the tallest is the
  /// honest single number for "is it standing up".
  double tallestBar(WidgetTester tester) => tester
      .widgetList<Container>(
        find.descendant(of: levelBars, matching: find.byType(Container)),
      )
      .map((Container bar) => tester.getSize(find.byWidget(bar)).height)
      .reduce(math.max);

  /// The loudness the platform reports, from the meter's own scale: the dB
  /// Android's `onRmsChanged` hands over. [db] of -2 is a silent room and +10 a
  /// raised voice ([rmsToLevel] owns that mapping), so a test can say "the user
  /// is speaking" without inventing numbers.

  testWidgets('dictation turns the composer into the listening layout', (
    tester,
  ) async {
    grantMic();
    final mic = _FakeSpeechInput();
    SpeechInput.override = () => mic;
    addTearDown(() => SpeechInput.override = null);
    await pumpShell(tester);

    // At rest: one filled mic, one live door, no meter, no X.
    expect(micButton(), findsOneWidget);
    expect(liveButton(), findsOneWidget);
    expect(levelBars, findsNothing);
    expect(cancelButton, findsNothing);

    await tapTheButton(tester, micButton());
    await tester.pump(const Duration(milliseconds: 260));

    // Listening: the mic is gone, the live door has stood down, and the two
    // controls that end the session are where a thumb already is — X on the
    // left, stop on the right.
    expect(micButton(), findsNothing);
    expect(find.byIcon(Icons.mic_rounded), findsNothing);
    expect(liveButton(), findsNothing);
    expect(stopButton(), findsOneWidget);
    expect(cancelButton, findsOneWidget);
    expect(levelBars, findsOneWidget);

    // The meter stands between the X and the words, and the words are beside it
    // rather than behind it: bars under a sentence make both unreadable, and the
    // sentence is the part the user is reading.
    final Rect bars = tester.getRect(levelBars);
    final Rect field = tester.getRect(find.byType(TextField));
    expect(bars.left, greaterThanOrEqualTo(tester.getRect(cancelButton).right));
    expect(bars.right, lessThanOrEqualTo(field.left));

    // With the room quiet the bars are dots, not nothing: a meter that vanished
    // between words would read as a meter that had stopped working.
    expect(tallestBar(tester), kNexusBarMinHeight);

    // The words arrive beside them, and neither one sends anything.
    mic.say('hello');
    await tester.pump();
    expect(fieldText(tester), 'hello');
    expect(levelBars, findsOneWidget);

    // The stop square keeps the words and puts the composer back.
    await tapTheButton(tester, stopButton());
    await tester.pump(const Duration(milliseconds: 260));
    expect(levelBars, findsNothing);
    expect(cancelButton, findsNothing);
    expect(fieldText(tester), 'hello');
    expect(sendButton(), findsOneWidget);
    expect(micButton(), findsNothing);

    // A hold is the same layout: the mic leaves on the deadline, and both
    // endings arrive with it.
    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    final TestGesture finger = await holdMic(tester);
    expect(micButton(), findsNothing);
    expect(stopButton(), findsOneWidget);
    expect(cancelButton, findsOneWidget);
    expect(levelBars, findsOneWidget);
    await finger.up();
    await tester.pump();
    mic.hear('');
    await tester.pumpAndSettle();
    expect(levelBars, findsNothing);
  });

  testWidgets('the bars stand up with the voice and fall back to dots', (
    tester,
  ) async {
    grantMic();
    final mic = _FakeSpeechInput();
    SpeechInput.override = () => mic;
    addTearDown(() => SpeechInput.override = null);
    await pumpShell(tester);

    await tapTheButton(tester, micButton());
    await tester.pump(const Duration(milliseconds: 260));
    expect(tallestBar(tester), kNexusBarMinHeight);

    // The meter is built from [TweenAnimationBuilder]s, not `AnimatedContainer`s:
    // a reading is never delayed by the animation, it is the target the
    // animation is already heading for.
    expect(
      find.descendant(
        of: find.byKey(kNexusLevelBars),
        matching: find.byType(AnimatedContainer),
      ),
      findsNothing,
    );

    // The platform's own reading of the room, arriving the way it really does —
    // a stream of numbers a few times a second, which is exactly why the bars
    // glide: jumping between forty readings and holding still is what looked
    // like stuttering on the phone.
    final double loud =
        kNexusBarMinHeight +
        (kNexusBarMaxHeight - kNexusBarMinHeight) * rmsToLevel(9);
    mic.loudness(9);
    await tester.pump();
    // The frame the reading lands on is the frame the bar leaves the dot...
    expect(tallestBar(tester), lessThan(loud));
    // ...and 50ms later — half of the 100ms glide, on an ease-out — it is
    // already most of the way up. That is the "snap to loud sounds" the phone
    // asked for: a reading never waits for the animation to finish.
    await tester.pump(const Duration(milliseconds: 50));
    expect(tallestBar(tester), greaterThan(kNexusBarMaxHeight * 0.6));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tallestBar(tester), closeTo(loud, 0.01));

    // ...a quieter reading leaves them shorter, and a silent room eases them
    // back to dots rather than switching them off — the other half of the
    // smoothing.
    mic.loudness(3);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final double mid = tallestBar(tester);
    expect(mid, closeTo(kNexusBarMinHeight + 21 * rmsToLevel(3), 0.01));
    expect(mid, lessThan(kNexusBarMaxHeight * 0.8));
    expect(mid, greaterThan(kNexusBarMinHeight));

    mic.loudness(-2);
    await tester.pump();
    // On the way down the bar is still tall on the frame the reading lands, and
    // visibly between the two heights a moment later: it glides, it does not
    // drop.
    expect(tallestBar(tester), closeTo(mid, 0.01));
    await tester.pump(const Duration(milliseconds: 50));
    expect(tallestBar(tester), lessThan(mid));
    expect(tallestBar(tester), greaterThan(kNexusBarMinHeight));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tallestBar(tester), kNexusBarMinHeight);
  });

  /// The live page's waveform, as the painter sees it: one number per bar, 0..1.
  List<double> waveBars(WidgetTester tester) {
    final CustomPaint paint = tester.widget<CustomPaint>(
      find.byKey(kNexusLiveWave),
    );
    return (paint.painter! as NexusLiveWavePainter).heights;
  }

  testWidgets('the live waveform rolls and eases, rather than stepping', (
    tester,
  ) async {
    grantMic();
    final mic = _FakeSpeechInput();
    SpeechInput.override = () => mic;
    addTearDown(() => SpeechInput.override = null);
    await pumpShell(tester);
    await openLive(tester);

    // A silent room: the meter is a resting line of dots, and it is *drawn* —
    // an open microphone with nothing to hear must look different from a page
    // that stopped drawing.
    for (final double bar in waveBars(tester)) {
      expect(bar, 0);
    }

    // One reading from the recognizer, then frames: the heights move a little
    // per frame instead of jumping to the new value in one — that is the whole
    // difference from the two-image version this replaced.
    mic.loudness(9);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    final List<double> first = waveBars(tester);
    await tester.pump(const Duration(milliseconds: 120));
    final List<double> second = waveBars(tester);

    double peak(List<double> bars) => bars.reduce(math.max);
    double total(List<double> bars) =>
        bars.fold(0, (double sum, double bar) => sum + bar);

    expect(total(first), greaterThan(0), reason: 'the reading leaves the dots');
    expect(
      total(second),
      greaterThan(total(first)),
      reason: 'the waveform is still rising a few frames later',
    );
    expect(
      peak(second),
      greaterThan(peak(first)),
      reason: 'it is on its way up',
    );
    expect(
      peak(second),
      lessThan(1),
      reason: 'eased, not snapped: the tallest bar is still short of the top',
    );

    // The roll: after a moment the tall part of the waveform has travelled, so
    // the shape is not the same row of bars with new heights.
    await tester.pump(const Duration(milliseconds: 400));
    final List<double> later = waveBars(tester);
    expect(later, isNot(equals(second)));
    expect(later.where((double bar) => bar > 0.05).length, greaterThan(3));

    // And it settles. The room goes quiet — the recognizer's own reading of a
    // silent room — and the waveform rolls the tall bars off the end and fills
    // in behind them with dots, rather than cutting out or freezing mid-shout.
    mic.loudness(-2);
    await tester.pump();
    // Frames, not one long jump: the waveform advances on the frame clock, and a
    // single 1.5s pump is one frame of it (the tick clamps a stalled frame to
    // 50ms on purpose, so a hitch cannot fire the whole array across at once).
    for (int i = 0; i < 32; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(total(waveBars(tester)), lessThan(total(later)));
    expect(total(waveBars(tester)), lessThan(0.2));
  });

  testWidgets('live conversation remembers the turns before it', (
    tester,
  ) async {
    grantMic();
    final mic = _FakeSpeechInput();
    SpeechInput.override = () => mic;
    addTearDown(() => SpeechInput.override = null);
    await pumpShell(tester);
    await openLive(tester);

    // The first question, asked with nothing behind it.
    mic.hear('what is the weather');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));
    expect(ollama.prompts, <String>['what is the weather']);
    expect(ollama.histories.single, isEmpty);

    // The second one, a moment later: "it" has a referent now, and the model is
    // handed the exchange that gives it one — the question and the answer, in
    // that order, without the new question twice.
    ollama.reply = 'Warm and clear.';
    // A normal reply hands the microphone back by itself; there is no resume
    // button to press, which is the point of the hand-back.
    await tester.pump(kLiveAutoListenDelay);
    expect(mic.listens, 2);
    mic.hear('and tomorrow?');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));

    expect(ollama.prompts, <String>['what is the weather', 'and tomorrow?']);
    final List<AiTurn> history = ollama.histories.last;
    expect(history, hasLength(2));
    expect(history.first.fromUser, isTrue);
    expect(history.first.text, 'what is the weather');
    expect(history.last.fromUser, isFalse);
    expect(history.last.text, 'Hello from the PC.');
    expect(
      history.any((AiTurn turn) => turn.text == 'and tomorrow?'),
      isFalse,
      reason: 'the current question travels as the prompt, not as history',
    );
  });

  testWidgets('an action asked for out loud runs from the live page too', (
    tester,
  ) async {
    grantMic();
    final mic = _FakeSpeechInput();
    SpeechInput.override = () => mic;
    addTearDown(() => SpeechInput.override = null);
    final _FakePhoneBackend phone = _FakePhoneBackend();
    SystemActions.override = () => DeviceSystemActions(backend: phone);
    await pumpShell(tester);
    await openLive(tester);

    // The live page is the same brain behind a different surface: a request for
    // the torch has to be run there too, or "it's dark in here" said out loud
    // would answer with a JSON object in 30-point type.
    ollama.reply = '{"action":"set_flashlight","state":"on"}';
    mic.hear("it's dark in here");
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));

    expect(liveText(tester), 'Flashlight on.');
    expect(phone.calls.single.$1, AgentActions.flashlightToggle);

    // And the line joins the conversation the page closes into — as a system
    // pill, because the shell is what did it.
    await tester.tap(find.byKey(kNexusLiveClose));
    await tester.pumpAndSettle();
    expect(find.byKey(kNexusSystemBubble), findsOneWidget);
    expect(find.text('Flashlight on.'), findsOneWidget);
  });

  testWidgets('a sum said out loud is answered by the shell too', (
    tester,
  ) async {
    grantMic();
    final mic = _FakeSpeechInput();
    SpeechInput.override = () => mic;
    addTearDown(() => SpeechInput.override = null);
    await pumpShell(tester);
    await openLive(tester);

    // The same question said out loud is the same question: the model must not
    // be the one that answers it, on this surface either.
    ollama.reply = '{"action":"set_timer","seconds":420}';
    mic.say('what is 6 times 7');
    mic.hear('what is 6 times 7');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));

    expect(liveText(tester), '6 * 7 = 42');
    expect(ollama.prompts, isEmpty);

    // And it joins the conversation when the page closes, like any answer.
    await tester.tap(find.byKey(kNexusLiveClose));
    await tester.pumpAndSettle();
    expect(find.text('6 * 7 = 42'), findsOneWidget);
  });

  testWidgets('closing live conversation keeps what was said in the thread', (
    tester,
  ) async {
    grantMic();
    final mic = _FakeSpeechInput();
    SpeechInput.override = () => mic;
    addTearDown(() => SpeechInput.override = null);
    await pumpShell(tester);

    expect(find.byType(NexusChatBubble), findsNothing);
    await openLive(tester);

    // A question for the model, not for the phone's clock: "what day is it" is
    // answered by the shell now (the model cannot know it), and this test is
    // about the words surviving the page closing.
    ollama.reply = 'You are Sam.';
    mic.hear('who am i');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));
    expect(liveText(tester), 'You are Sam.');

    await tester.tap(find.byKey(kNexusLiveClose));
    await tester.pumpAndSettle();

    // The room is empty again, and the conversation is in the chat thread — the
    // words the user spoke and the answer they heard, in the order they
    // happened, where they can be re-read and copied.
    expect(liveOverlay, findsNothing);
    expect(find.text('who am i'), findsOneWidget);
    expect(find.text('You are Sam.'), findsOneWidget);
    expect(find.byType(NexusChatBubble), findsNWidgets(2));
    final Finder spoken = find.ancestor(
      of: find.text('who am i'),
      matching: find.byType(NexusChatBubble),
    );
    expect(tester.widget<NexusChatBubble>(spoken).mine, isTrue);
  });

  testWidgets('a reading from a closed session never moves the bars again', (
    tester,
  ) async {
    grantMic();
    final mic = _FakeSpeechInput();
    SpeechInput.override = () => mic;
    addTearDown(() => SpeechInput.override = null);
    await pumpShell(tester);

    await tapTheButton(tester, micButton());
    mic.loudness(10);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(tallestBar(tester), greaterThan(kNexusBarMaxHeight * 0.6));

    // The session ends while a reading is still in flight — and the meter is
    // part of the session, not a thing that keeps its own last value: a bar left
    // standing would say the phone was still hearing somebody.
    await tapTheButton(tester, stopButton());
    mic.loudness(10);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tapTheButton(tester, micButton());
    await tester.pump(const Duration(milliseconds: 260));
    expect(tallestBar(tester), kNexusBarMinHeight);

    await tapTheButton(tester, stopButton());
    await tester.pump(const Duration(milliseconds: 260));
  });

  testWidgets('the X discards the dictation and clears the field', (
    tester,
  ) async {
    grantMic();
    final mic = _FakeSpeechInput();
    SpeechInput.override = () => mic;
    addTearDown(() => SpeechInput.override = null);
    await pumpShell(tester);
    final int bubbles = find.byType(NexusChatBubble).evaluate().length;

    await tapTheButton(tester, micButton());
    mic.say('never mind');
    await tester.pump();
    expect(fieldText(tester), 'never mind');
    expect(levelBars, findsOneWidget);

    await withMicLog((List<String> log) async {
      await tapTheButton(tester, cancelButton);
      expect(mic.stops, 1);
      expect(log.last, matches(stopLine));
      expect(log.last, contains('reason=cancelled'));
    });

    // Nothing was kept and nothing was sent, which is the difference between the
    // X and the stop square beside it.
    await tester.pump(const Duration(milliseconds: 260));
    expect(fieldText(tester), '');
    expect(levelBars, findsNothing);
    expect(cancelButton, findsNothing);
    expect(micButton(), findsOneWidget);
    expect(find.byType(NexusChatBubble).evaluate().length, bubbles);
  });

  testWidgets('the composer offers dictation and live as two buttons', (
    tester,
  ) async {
    await pumpShell(tester);

    expect(micButton(), findsOneWidget);
    expect(liveButton(), findsOneWidget);

    // Side by side in one row, not stacked and not in place of each other.
    final Rect dictation = tester.getRect(micButton());
    final Rect live = tester.getRect(liveButton());
    expect(live.left, greaterThan(dictation.right));
    expect((live.center.dy - dictation.center.dy).abs(), lessThan(1));

    // The live door stays when the field has words, which is the difference
    // between it and the dictation slot the send arrow takes over.
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pumpAndSettle();
    expect(sendButton(), findsOneWidget);
    expect(micButton(), findsNothing);
    expect(liveButton(), findsOneWidget);
  });

  testWidgets('the field cannot be typed into while the mic is open', (
    tester,
  ) async {
    grantMic();
    final mic = _FakeSpeechInput();
    SpeechInput.override = () => mic;
    addTearDown(() => SpeechInput.override = null);
    await pumpShell(tester);

    // At rest the composer is a field like any other — and the user is typing in
    // it, which is the state this bug was reported from: keyboard up, field
    // focused, thumb on the mic.
    TextField field() => tester.widget<TextField>(find.byType(TextField));
    expect(field().readOnly, isFalse);
    expect(field().enableInteractiveSelection, isTrue);
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(field().focusNode!.hasFocus, isTrue);

    // The moment the mic opens, the field stops being editable: keystrokes and
    // the recognizer cannot both own the same text, and a caret the user drags
    // mid-sentence is a selection the next transcript overwrites anyway. The
    // keyboard goes with it — the field is unfocused for the length of the
    // session — so there is no live input connection left to type down either.
    await tapTheButton(tester, micButton());
    await tester.pump(const Duration(milliseconds: 260));
    expect(field().readOnly, isTrue);
    expect(field().enableInteractiveSelection, isFalse);
    expect(field().focusNode!.hasFocus, isFalse);

    // The words the recognizer hears still arrive — it is the *user's* input
    // that is off, not the session's.
    mic.say('hello');
    await tester.pump();
    expect(fieldText(tester), 'hello');

    // And a keystroke really does nothing, through a live input connection:
    // this is the acceptance criterion, not the property list above it. Typing
    // here must not be able to fight the recognizer for the field, not merely be
    // discouraged from it.
    await tester.enterText(find.byType(TextField), 'typed over the mic');
    await tester.pump();
    expect(fieldText(tester), 'hello');

    // Stop hands the draft back, editable, exactly where the mic left it: the
    // same keystrokes that were refused a moment ago now land.
    await tapTheButton(tester, stopButton());
    await tester.pump(const Duration(milliseconds: 260));
    expect(field().readOnly, isFalse);
    expect(field().enableInteractiveSelection, isTrue);
    expect(fieldText(tester), 'hello');
    await tester.enterText(find.byType(TextField), 'hello again');
    await tester.pump();
    expect(fieldText(tester), 'hello again');

    // And a hold is the same field: the finger is the mic's, not the caret's.
    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    final TestGesture finger = await holdMic(tester);
    expect(field().readOnly, isTrue);
    await finger.up();
    await tester.pump();
    mic.hear('');
    await tester.pumpAndSettle();
    expect(field().readOnly, isFalse);
  });

  testWidgets('live conversation listens at once, then hands the turn back', (
    tester,
  ) async {
    grantMic();
    final mic = _FakeSpeechInput();
    SpeechInput.override = () => mic;
    addTearDown(() => SpeechInput.override = null);
    await pumpShell(tester);

    await tester.enterText(find.byType(TextField), 'draft');
    await tester.pump();
    final FocusNode focus = tester
        .widget<TextField>(find.byType(TextField))
        .focusNode!;
    expect(focus.hasFocus, isTrue);

    await openLive(tester);

    // The page, the microphone, and the keyboard gone: live conversation is a
    // screen to look at, not a field to type into.
    expect(liveOverlay, findsOneWidget);
    expect(mic.listens, 1);
    expect(focus.hasFocus, isFalse);
    // The page follows the app's own brightness: this shell is in light mode,
    // so the live room is the light surface and not the immersive black it used
    // to be in every theme — that black page under a light frame was the bug.
    expect(
      tester.widget<Scaffold>(liveOverlay).backgroundColor,
      NexusUiColors.light.surface,
    );
    expect(kNexusLiveGround, isNot(NexusUiColors.light.surface));
    expect(liveText(tester), 'Listening…');
    expect(
      tester.widget<Text>(find.byKey(kNexusLiveStatus)).data,
      'Listening — just speak.',
    );
    // The indicator is the page's own: the composer's ring is behind this route,
    // and a widget nobody can see does not tell the user the mic is open.
    expect(find.byKey(kNexusLiveRecordingIndicator), findsOneWidget);

    // The way out is at the bottom of the screen, centred, and large: the one
    // control this page has must not be a hunt.
    final Rect page = tester.getRect(liveOverlay);
    final Rect close = tester.getRect(find.byKey(kNexusLiveClose));
    expect(close.center.dy, greaterThan(page.center.dy));
    expect(close.center.dx, closeTo(page.center.dx, 1));
    expect(close.width, greaterThanOrEqualTo(70));

    // The guess is shown while it is still being spoken, in the same large type
    // the captured sentence will use.
    mic.say('hello');
    await tester.pump();
    expect(liveText(tester), 'hello');
    mic.say('hello there');
    await tester.pump();
    expect(liveText(tester), 'hello there');

    // The recognizer ends the turn when the speaker stops: the sentence goes to
    // the model on the PC, and the microphone closes for the whole of the wait.
    ollama.reply = 'I am well — what can I do for you?';
    mic.hear('hello there, how are you');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));
    expect(ollama.prompts, <String>['hello there, how are you']);
    expect(liveText(tester), 'I am well — what can I do for you?');
    expect(find.byKey(kNexusLiveRecordingIndicator), findsNothing);
    expect(mic.listens, 1);

    // The end of the turn is announced, not hidden: a grey "Mic off" badge takes
    // the recording badge's place, the orb drops its purple for a grey core, and
    // the page says in words that the microphone is closed. A dark screen that
    // had merely stopped animating would be indistinguishable from one recording.
    expect(find.byKey(kNexusLivePausedIndicator), findsOneWidget);
    expect(find.byKey(kNexusLiveOrbIdle), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(kNexusLiveStatus)).data, 'Mic off.');
    // A normal reply does not ask for a tap: the 1.5 s hand-back is already on
    // its way. "Tap to continue" belongs to the guard alone.
    expect(find.byKey(kNexusLiveResume), findsNothing);

    // And then the page hands the turn back on its own: the answer has been
    // read out, and 1.5 s after the voice stops the microphone is open again.
    // That is what makes live mode a conversation rather than a page that needs
    // a tap after every answer — and it is after *speech*, not after sending,
    // so the phone never listens to its own voice.
    await tester.pump(kLiveAutoListenDelay);
    expect(mic.listens, 2);
    expect(find.byKey(kNexusLiveRecordingIndicator), findsOneWidget);
    expect(find.byKey(kNexusLivePausedIndicator), findsNothing);
    expect(find.byKey(kNexusLiveOrbIdle), findsNothing);
    expect(
      tester.widget<Text>(find.byKey(kNexusLiveStatus)).data,
      'Listening — just speak.',
    );

    // The next turn is a fresh one: words to the PC, answer on the page, and
    // then the same 1.5 s beat before the microphone comes back.
    ollama.reply = 'Second answer.';
    mic.say('a second turn');
    await tester.pump();
    mic.hear('a second turn');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));
    expect(mic.listens, 2);
    expect(liveText(tester), 'Second answer.');
    await tester.pump(kLiveAutoListenDelay);
    expect(mic.listens, 3);
    expect(find.byKey(kNexusLiveRecordingIndicator), findsOneWidget);

    // Nothing any of that heard reached the composer underneath: live mode has
    // no draft in the field to overwrite. The composer is under an opaque route,
    // so it is offstage rather than gone — its state, and therefore its text, is
    // exactly what the route covered.
    expect(
      tester
          .widget<TextField>(
            find.byKey(kNexusComposerField, skipOffstage: false),
          )
          .controller!
          .text,
      'draft',
    );

    await tester.tap(find.byKey(kNexusLiveClose));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(liveOverlay, findsNothing);
    expect(mic.stops, 1);
  });

  testWidgets('the wait for an answer is a state, not a spinner', (
    tester,
  ) async {
    grantMic();
    final mic = _FakeSpeechInput();
    SpeechInput.override = () => mic;
    addTearDown(() => SpeechInput.override = null);
    await pumpShell(tester);
    ollama.stall();
    await openLive(tester);

    mic.say('what is the weather');
    await tester.pump();
    mic.hear('what is the weather');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));

    // Thinking: the microphone is closed, the orb is blue and moving, and the
    // large type says what is happening. This is not a spinner laid over a live
    // page — the page itself changed state.
    expect(ollama.prompts, <String>['what is the weather']);
    expect(find.byKey(kNexusLiveOrbThinking), findsOneWidget);
    expect(find.byKey(kNexusLiveOrbIdle), findsNothing);
    expect(find.byKey(kNexusLiveRecordingIndicator), findsNothing);
    expect(liveText(tester), kNexusThinking);
    expect(mic.listens, 1);
    expect(
      tester.widget<Text>(find.byKey(kNexusLiveStatus)).data,
      'Mic off — asking the AI…',
    );

    // The blue is the point, not just the key: this is the one state that says
    // "working", and it must not be mistakable for the purple of an open mic.
    final AnimatedContainer core = tester.widget<AnimatedContainer>(
      find.byKey(kNexusLiveOrbThinking),
    );
    expect(
      ((core.decoration! as BoxDecoration).gradient! as RadialGradient).colors,
      contains(kNexusLiveThinking),
    );
    expect(kNexusLiveThinking, isNot(kNexusAccent));

    // The orb is inert while the answer is being written: tapping it is asking
    // to interrupt a request that is already out.
    await tester.tap(find.byKey(kNexusLiveOrb));
    await tester.pump(const Duration(milliseconds: 260));
    expect(mic.listens, 1);
    expect(find.byKey(kNexusLiveOrbThinking), findsOneWidget);

    // The answer arrives in the same large type the guess used, and the page
    // drops into the waiting state that needs a tap.
    ollama.answer('Twenty degrees and clear.');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));
    expect(liveText(tester), 'Twenty degrees and clear.');
    expect(find.byKey(kNexusLiveOrbIdle), findsOneWidget);
    expect(find.byKey(kNexusLivePausedIndicator), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(kNexusLiveStatus)).data, 'Mic off.');

    // The answer is read out, and 1.5 s after the voice stops the page hands
    // the turn back on its own: a conversation, not a page that needs a tap
    // after every answer.
    await tester.pump(kLiveAutoListenDelay);
    expect(mic.listens, 2);
    expect(liveText(tester), 'Listening…');
    expect(find.byKey(kNexusLiveOrbThinking), findsNothing);
  });

  testWidgets('a live turn with no PC on the network says so', (tester) async {
    grantMic();
    final mic = _FakeSpeechInput();
    SpeechInput.override = () => mic;
    final speech = _FakeSpeechOutput();
    SpeechOutput.override = () => speech;
    addTearDown(() {
      SpeechInput.override = null;
      SpeechOutput.override = null;
    });
    await pumpShell(tester);
    ollama.unreachable = true;
    await openLive(tester);

    mic.hear('are you there');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));

    // The failure is the answer: same large type, same waiting state, and the
    // microphone closed the whole way through.
    expect(liveText(tester), kNexusOllamaUnreachableText);
    expect(find.byKey(kNexusLiveOrbIdle), findsOneWidget);
    expect(find.byKey(kNexusLiveRecordingIndicator), findsNothing);
    expect(mic.listens, 1);
    // And it is not read out: the apology is the shell talking, and hearing a
    // machine apologise for its PC is worse than reading it.
    expect(speech.said, isEmpty);
    await tester.pump(const Duration(seconds: 30));
    expect(mic.listens, 1);

    await tester.tap(find.byKey(kNexusLiveClose));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(liveOverlay, findsNothing);
  });

  testWidgets('a live turn ends on the quiet after speech, and answers aloud', (
    tester,
  ) async {
    grantMic();
    final mic = _FakeSpeechInput();
    SpeechInput.override = () => mic;
    final speech = _FakeSpeechOutput();
    SpeechOutput.override = () => speech;
    addTearDown(() {
      SpeechInput.override = null;
      SpeechOutput.override = null;
    });
    await pumpShell(tester);
    ollama.reply = 'It is twenty degrees and clear.';
    await openLive(tester);

    // The phone hears a voice: the meter moves, and the recognizer offers the
    // words it is forming.
    mic.loudness(8);
    await tester.pump();
    mic.say('what is the weather');
    await tester.pump();

    // A speaker who is still talking is never cut off, however long they take:
    // every loud reading and every interim word restarts the pause.
    mic.loudness(6);
    await tester.pump(const Duration(milliseconds: 700));
    mic.loudness(5);
    await tester.pump(const Duration(milliseconds: 700));
    mic.loudness(4);
    await tester.pump(const Duration(milliseconds: 700));
    expect(mic.finishes, 0);
    expect(find.byKey(kNexusLiveRecordingIndicator), findsOneWidget);

    // The room goes quiet. This is live conversation's missing end-of-turn: the
    // recognizer is asked for the transcript it has been holding, rather than
    // the page waiting for a final result a phone may never send on its own.
    mic.loudness(-2);
    await tester.pump();
    await tester.pump(kSpeechTurnGap + const Duration(milliseconds: 100));
    expect(mic.finishes, 1);
    // Still listening while the transcript is on its way: the microphone is only
    // closed by the answer, not by the ask for one.
    expect(find.byKey(kNexusLiveRecordingIndicator), findsOneWidget);

    // The transcript arrives, and goes to the model on the PC.
    mic.hear('what is the weather');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));
    expect(ollama.prompts, <String>['what is the weather']);
    expect(liveText(tester), 'It is twenty degrees and clear.');

    // Read out loud as it lands, in the same words — and the page is already in
    // the grey, waiting state by the time the voice starts: what the user hears
    // is a reply they can also read, not a microphone that could still be open.
    expect(speech.said, <String>['It is twenty degrees and clear.']);
    expect(find.byKey(kNexusLiveOrbIdle), findsOneWidget);
    expect(find.byKey(kNexusLiveRecordingIndicator), findsNothing);
    expect(tester.widget<Text>(find.byKey(kNexusLiveStatus)).data, 'Mic off.');

    // One ask per turn: the quiet that follows the answer does not ask the
    // recognizer for a transcript a second time. The microphone itself *is*
    // open again — that is the 1.5 s hand-back — but it is a fresh turn with
    // nothing yet said, so there is nothing to finish.
    mic.loudness(-2);
    await tester.pump();
    await tester.pump(kSpeechTurnGap + const Duration(milliseconds: 100));
    expect(mic.finishes, 1);
    expect(mic.listens, 2);
  });

  testWidgets('a live answer is written onto the page as the model writes it', (
    tester,
  ) async {
    grantMic();
    final mic = _FakeSpeechInput();
    SpeechInput.override = () => mic;
    addTearDown(() => SpeechInput.override = null);
    final speech = _FakeSpeechOutput();
    SpeechOutput.override = () => speech;
    addTearDown(() => SpeechOutput.override = null);
    final brain = _StreamingBrain();
    LocalAiService.override = () => brain;
    addTearDown(brain.end);
    await pumpShell(tester);
    await openLive(tester);

    // A spoken turn, ended the way the quiet ends one.
    mic.loudness(8);
    await tester.pump();
    mic.say('what is the weather');
    await tester.pump();
    mic.loudness(-2);
    await tester.pump();
    await tester.pump(kSpeechTurnGap + const Duration(milliseconds: 100));
    mic.hear('what is the weather');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));
    expect(brain.prompts, <String>['what is the weather']);

    // While the model is thinking the large type says so — and the first token
    // replaces it, instead of the page sitting on "Thinking…" until the answer
    // is already over.
    expect(liveText(tester), kNexusThinking);
    brain.write('Twenty degrees');
    await tester.pump();
    expect(liveText(tester), 'Twenty degrees');

    brain.write(' and clear.');
    await tester.pump();
    expect(liveText(tester), 'Twenty degrees and clear.');

    // The end of the stream settles the page into the grey "tap to continue"
    // state, and only then is the answer spoken — once, whole.
    brain.end();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));
    expect(liveText(tester), 'Twenty degrees and clear.');
    expect(speech.said, <String>['Twenty degrees and clear.']);
  });

  testWidgets('a live page opened onto a quiet room ends no turn by itself', (
    tester,
  ) async {
    grantMic();
    final mic = _FakeSpeechInput();
    SpeechInput.override = () => mic;
    addTearDown(() => SpeechInput.override = null);
    await pumpShell(tester);
    await openLive(tester);

    // Silence before anyone has spoken is not the end of a sentence: the page
    // waits for the user rather than handing an empty turn to the recognizer.
    mic.loudness(-2);
    await tester.pump();
    await tester.pump(kSpeechTurnGap + const Duration(milliseconds: 300));
    expect(mic.finishes, 0);
    expect(find.byKey(kNexusLiveRecordingIndicator), findsOneWidget);
    expect(liveText(tester), 'Listening…');
  });

  testWidgets('screen share belongs to live mode, and its frame is a turn', (
    tester,
  ) async {
    grantMic();
    final mic = _FakeSpeechInput();
    SpeechInput.override = () => mic;
    addTearDown(() => SpeechInput.override = null);
    final Directory dir = Directory.systemTemp.createTempSync(
      'nexus-live-shot',
    );
    addTearDown(() => dir.deleteSync(recursive: true));
    final File shot = File('${dir.path}/shot.png')..writeAsBytesSync(<int>[1]);
    ScreenCapture.override = () async => ScreenCaptureResult(shot.path);
    addTearDown(() => ScreenCapture.override = null);
    AttachmentStore.override = _MemoryAttachments.new;
    addTearDown(() => AttachmentStore.override = null);
    await pumpShell(tester);

    // Nowhere in the composer. One screen, one place for it: the conversation.
    expect(find.byKey(kNexusLiveScreenShare), findsNothing);
    await openLive(tester);
    expect(find.byKey(kNexusLiveScreenShare), findsOneWidget);

    await tester.tap(find.byKey(kNexusLiveScreenShare));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    // The microphone closes before the projection dialog opens: the room is
    // not recorded while the user decides what to share.
    expect(mic.stops, 1);
    expect(find.text(kScreenshotCaption), findsOneWidget);
    expect(liveText(tester), kNexusVisionMissingText);

    // And the frame is part of the conversation, not a side effect left behind
    // in the composer.
    await tester.tap(find.byKey(kNexusLiveClose));
    await tester.pumpAndSettle();
    expect(find.byType(NexusAttachmentBubble), findsOneWidget);
    expect(find.text(kScreenshotCaption), findsOneWidget);
  });

  testWidgets('a system action does not end live conversation', (tester) async {
    grantMic();
    final mic = _FakeSpeechInput();
    SpeechInput.override = () => mic;
    addTearDown(() => SpeechInput.override = null);
    final _FakePhoneBackend phone = _FakePhoneBackend();
    SystemActions.override = () => DeviceSystemActions(backend: phone);
    await pumpShell(tester);
    await openLive(tester);

    ollama.reply = '{"action":"set_timer","seconds":60}';
    mic.say('set a timer for one minute');
    mic.hear('set a timer for one minute');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));

    expect(phone.calls.single.$1, AgentActions.timerSet);
    expect(liveText(tester), 'Timer set for 1 minute.');
    expect(mic.listens, 1);

    // The clock app is now in front: the microphone closes, but this is not the
    // user leaving the room. The page stays, with the timer's line on it.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(liveOverlay, findsOneWidget);
    // The microphone was already closed while the timer was being set; the
    // background must not close the page on top of that.
    expect(mic.listens, 1);
    expect(find.byKey(kNexusLiveRecordingIndicator), findsNothing);
    expect(liveText(tester), 'Timer set for 1 minute.');

    // Back from the timer, and the conversation is exactly where it was: same
    // page, microphone open, no drop into the text thread.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));
    expect(liveOverlay, findsOneWidget);
    expect(mic.listens, 2);
    expect(find.byKey(kNexusLiveRecordingIndicator), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(kNexusLiveStatus)).data,
      'Listening — just speak.',
    );
  });

  testWidgets('a refused play_music is a failure, not a check mark', (
    tester,
  ) async {
    final _FakePhoneBackend phone = _FakePhoneBackend();
    phone.reply = const ActionResult(false, 'The phone said no.');
    SystemActions.override = () => DeviceSystemActions(backend: phone);
    await pumpShell(tester);

    ollama.reply = '{"action":"play_music"}';
    await tester.enterText(find.byType(TextField), 'play some music');
    await tester.pump();
    await tapTheButton(tester, sendButton());
    await tester.pumpAndSettle();

    expect(phone.calls.single.$1, AgentActions.musicPlay);
    expect(find.text(kMusicUnavailableText), findsOneWidget);
    final NexusSystemBubble pill = tester.widget<NexusSystemBubble>(
      find.byType(NexusSystemBubble),
    );
    expect(pill.ok, isFalse);
    expect(find.textContaining('song:'), findsNothing);
  });

  testWidgets(
    'a music phrase is run by the shell, never claimed by the model',
    (tester) async {
      // The measured failure: asked "play some music", the model answered "The
      // phone's music player has opened" and nothing opened. The phrase is one
      // the shell already understands, so the model is not asked at all.
      final _FakePhoneBackend phone = _FakePhoneBackend();
      phone.reply = const ActionResult(true, 'Opened Spotify.');
      SystemActions.override = () => DeviceSystemActions(backend: phone);
      await pumpShell(tester);

      await tester.enterText(find.byType(TextField), 'play some music');
      await tester.pump();
      await tapTheButton(tester, sendButton());
      await tester.pumpAndSettle();

      expect(ollama.prompts, isEmpty, reason: 'no model had to guess');
      expect(phone.calls.single.$1, AgentActions.musicPlay);
      expect(find.text('Opened Spotify.'), findsOneWidget);
      final NexusSystemBubble pill = tester.widget<NexusSystemBubble>(
        find.byType(NexusSystemBubble),
      );
      expect(pill.ok, isTrue);
    },
  );

  testWidgets('a music phrase spoken into live mode is run there too', (
    tester,
  ) async {
    grantMic();
    final mic = _FakeSpeechInput();
    SpeechInput.override = () => mic;
    addTearDown(() => SpeechInput.override = null);
    final _FakePhoneBackend phone = _FakePhoneBackend();
    phone.reply = const ActionResult(true, 'Opened Spotify.');
    SystemActions.override = () => DeviceSystemActions(backend: phone);
    await pumpShell(tester);
    await openLive(tester);

    mic.hear('play some music');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));

    expect(ollama.prompts, isEmpty, reason: 'no model had to guess');
    expect(phone.calls.single.$1, AgentActions.musicPlay);
    expect(liveText(tester), 'Opened Spotify.');
  });

  testWidgets('the X ends live conversation and the microphone with it', (
    tester,
  ) async {
    grantMic();
    final mic = _FakeSpeechInput();
    SpeechInput.override = () => mic;
    addTearDown(() => SpeechInput.override = null);
    await pumpShell(tester);
    await openLive(tester);
    expect(mic.listens, 1);

    await withMicLog((List<String> log) async {
      await tester.tap(find.byKey(kNexusLiveClose));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));

      // One session, one ending, and the log says which door it was.
      expect(mic.stops, 1);
      expect(log.last, matches(stopLine));
      expect(log.last, contains('reason=closed'));
    });
    expect(liveOverlay, findsNothing);

    // Nothing reopens the page or the microphone by itself.
    await tester.pump(const Duration(seconds: 5));
    expect(mic.listens, 1);
    expect(find.byKey(kNexusLiveRecordingIndicator), findsNothing);
    expect(micButton(), findsOneWidget);
  });

  testWidgets('the system back gesture closes live conversation too', (
    tester,
  ) async {
    grantMic();
    final mic = _FakeSpeechInput();
    SpeechInput.override = () => mic;
    addTearDown(() => SpeechInput.override = null);
    await pumpShell(tester);
    await openLive(tester);
    expect(mic.listens, 1);

    // Not the X: the route is taken away by the platform, and the microphone has
    // to go with a page somebody else closed. This is the one path where the
    // overlay leaves without asking this screen first.
    await withMicLog((List<String> log) async {
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));

      expect(liveOverlay, findsNothing);
      expect(mic.stops, 1);
      expect(log.last, contains('reason=closed'));
    });

    expect(micButton(), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(mic.listens, 1);
  });

  testWidgets('leaving the app ends live conversation, page and all', (
    tester,
  ) async {
    grantMic();
    final mic = _FakeSpeechInput();
    SpeechInput.override = () => mic;
    addTearDown(() => SpeechInput.override = null);
    await pumpShell(tester);
    await openLive(tester);
    expect(mic.listens, 1);

    await withMicLog((List<String> log) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(mic.stops, 1);
      expect(log.last, matches(stopLine));
      expect(log.last, contains('reason=background'));
    });

    // The page goes with the session: coming back to a dark screen that has
    // silently stopped listening would be worse than the composer.
    expect(liveOverlay, findsNothing);
    await tester.pump(const Duration(seconds: 5));
    expect(mic.listens, 1);

    // Put the lifecycle back for the tests after this one.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
  });

  testWidgets('the guard ends a live turn nobody finishes', (tester) async {
    grantMic();
    final mic = _LateAnswerSpeechInput();
    SpeechInput.override = () => mic;
    addTearDown(() => SpeechInput.override = null);
    await pumpShell(tester);
    await openLive(tester);
    expect(mic.listens, 1);

    await withMicLog((List<String> log) async {
      await tester.pump(const Duration(seconds: 31));
      await tester.pump();
      expect(mic.stops, 1);
      expect(log.last, matches(stopLine));
      expect(log.last, contains('reason=timeout'));
    });

    // The page stays, because vanishing after thirty silent seconds would read
    // like a crash. What changed is the page itself: no recording badge, a grey
    // orb, and the one thing that is true — the microphone is off. The words are
    // the guard's, not a pause's: this is a turn the phone stopped on its own,
    // and the user is owed the difference.
    expect(liveOverlay, findsOneWidget);
    expect(find.byKey(kNexusLiveRecordingIndicator), findsNothing);
    expect(find.byKey(kNexusLivePausedIndicator), findsNothing);
    expect(find.byKey(kNexusLiveOrbIdle), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(kNexusLiveStatus)).data,
      'Mic off. Nothing is recording.',
    );

    // And it stays off. The guard tripped once; there is no timer, no hidden
    // countdown and no loop that could reopen the microphone without a tap.
    await tester.pump(const Duration(seconds: 30));
    expect(mic.listens, 1);
    expect(find.byKey(kNexusLiveRecordingIndicator), findsNothing);

    // The tap is the only way back, and it is a fresh turn: mic open, badges
    // swapped, orb purple again.
    await tester.tap(find.byKey(kNexusLiveResume));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));
    expect(mic.listens, 2);
    expect(find.byKey(kNexusLiveRecordingIndicator), findsOneWidget);
    expect(find.byKey(kNexusLiveOrbIdle), findsNothing);
    expect(
      tester.widget<Text>(find.byKey(kNexusLiveStatus)).data,
      'Listening — just speak.',
    );

    // And the turn the user restarted answers to the same guard as every other:
    // a recognizer that goes quiet for another thirty seconds is stopped again,
    // with the page left saying the microphone is off rather than looping.
    await tester.pump(const Duration(seconds: 31));
    await tester.pump();
    expect(mic.listens, 2);
    expect(mic.stops, 2);
    expect(find.byKey(kNexusLiveRecordingIndicator), findsNothing);
    expect(find.byKey(kNexusLiveOrbIdle), findsOneWidget);
    await tester.pump(const Duration(seconds: 30));
    expect(mic.listens, 2);
  });

  testWidgets('live conversation takes the dark ground in dark mode', (
    tester,
  ) async {
    grantMic();
    final mic = _FakeSpeechInput();
    SpeechInput.override = () => mic;
    addTearDown(() => SpeechInput.override = null);
    await pumpShell(tester);

    // Hand appearance back to nobody (the phone is light in a test), then take
    // it in hand and darken it: the live page is the theme's, so dark mode gets
    // the immersive ground it was designed around while light mode gets the
    // light one above.
    await openTab(tester, 'Settings', 3);
    await tapSwitchOn(tester, 'Follow system');
    await tapSwitchOn(tester, 'Dark mode');
    await openTab(tester, 'Home', 0);

    await openLive(tester);
    expect(
      tester.widget<Scaffold>(liveOverlay).backgroundColor,
      kNexusLiveGround,
    );
    // The design's hex, not merely some dark tone the constant happens to hold.
    expect(kNexusLiveGround, const Color(0xFF111113));

    await tester.tap(find.byKey(kNexusLiveClose));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
  });

  testWidgets('live conversation is not offered where the microphone is not', (
    tester,
  ) async {
    SpeechInput.override = () => const _UnavailableSpeechInput();
    addTearDown(() => SpeechInput.override = null);
    await pumpShell(tester);

    // The live page is the same recognizer as dictation, so a device that cannot
    // dictate has nothing for it to be: the button is not drawn, in either of
    // its two states, and there is no page to open.
    expect(find.byTooltip('Live conversation'), findsNothing);
    expect(
      find.byTooltip('Live conversation isn’t available here'),
      findsNothing,
    );
    expect(liveOverlay, findsNothing);
  });

  testWidgets('one microphone, one session: live stands down while dictating', (
    tester,
  ) async {
    grantMic();
    final mic = _FakeSpeechInput();
    SpeechInput.override = () => mic;
    addTearDown(() => SpeechInput.override = null);
    await pumpShell(tester);

    await tapTheButton(tester, micButton());
    await settleButton(tester);
    expect(stopButton(), findsOneWidget);

    // While the dictation is open the live door is withdrawn from the row: two
    // sessions cannot share one microphone, and a door that is on screen but
    // refuses is worse than a door that is not there.
    expect(liveButton(), findsNothing);
    expect(mic.listens, 1);
    expect(liveOverlay, findsNothing);

    // It comes back the moment the dictation ends.
    await tapTheButton(tester, stopButton());
    await tester.pump(const Duration(milliseconds: 260));
    expect(liveButton(), findsOneWidget);
  });

  testWidgets('Settings opens a Privacy screen that says what the mic does', (
    tester,
  ) async {
    await pumpShell(tester);
    await openTab(tester, 'Settings', 3);

    // The row sits in the Privacy group, with the sync row it belongs beside —
    // not buried at the bottom of the page. (The on-device model moved down to
    // its own Brain section, where its row is a real status rather than a fixed
    // word: see the Brain tests above.)
    expect(find.text('Cloud sync'), findsOneWidget);
    await tester.tap(find.text('Privacy'));
    await tester.pumpAndSettle();

    // The screen is a stub with nothing to configure, and that is the point: the
    // one thing this build can promise about voice is a sentence long, and the
    // policy it will point at is a placeholder until somebody writes one.
    expect(
      find.text(
        'Voice input is processed on this device. Audio is never sent '
        'anywhere.',
      ),
      findsOneWidget,
    );
    expect(find.text('Full privacy policy: <link>'), findsOneWidget);

    // A real page, reached and left like the other one: back returns to the tab.
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Full privacy policy: <link>'), findsNothing);
    expect(tester.widget<IndexedStack>(find.byType(IndexedStack)).index, 3);
  });

  testWidgets('Privacy deletes every remembered fact and every chat', (
    tester,
  ) async {
    final MemoryService memory = MemoryService(store: MemoryMemoryStore());
    await memory.remember('My name is TVCraft');
    await memory.remember('I live in Lyon');
    MemoryService.override = () => memory;
    AttachmentStore.override = () =>
        AttachmentStore(directory: () async => null);
    addTearDown(() {
      MemoryService.override = null;
      MemoryService.debugReset();
      AttachmentStore.override = null;
    });
    chat.save(<ChatEntry>[
      const ChatEntry('what is the weather?', mine: true),
      const ChatEntry('Warm and clear.'),
    ]);

    await pumpShell(tester);
    await openTab(tester, 'Settings', 3);
    await tester.tap(find.text('Privacy'));
    await tester.pumpAndSettle();

    expect(find.text(kNexusDeleteAllDataRow), findsOneWidget);
    await tester.tap(find.byKey(kNexusDeleteAllData));
    await tester.pumpAndSettle();

    // The dialog names what is lost, then the one red button loses it.
    expect(find.text(kNexusDeleteAllDataTitle), findsOneWidget);
    expect(find.textContaining('1 chat, 2 remembered facts'), findsOneWidget);
    await tester.tap(find.byKey(kNexusConfirmAction));
    await tester.pumpAndSettle();

    expect(memory.notes, isEmpty);
    expect(chat.sessionCount, 0);
    expect(chat.entries, isEmpty);
    expect(find.text('Memory, chats and attachments deleted.'), findsOneWidget);
  });

  testWidgets('the shell\'s App icon row switches the launcher alias', (
    tester,
  ) async {
    // The icon is the one setting in the shell that is not a mock: the row
    // stores the choice and tells Android which launcher alias to enable, so
    // this drives the same channel MainActivity answers.
    SharedPreferences.setMockInitialValues(<String, Object>{});
    const MethodChannel iconChannel = MethodChannel('dev.nexus.nexus/app_icon');
    final List<MethodCall> calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(iconChannel, (MethodCall call) async {
          calls.add(call);
          return switch (call.method) {
            'currentIcon' => 'light',
            'setIcon' => true,
            _ => null,
          };
        });
    // The platform override is cleared in the body, not in a tearDown: the
    // framework checks its debug variables before tearDowns run.
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      // The service is a singleton that outlives a test, so this one states
      // where it starts instead of inheriting whatever ran before it.
      await IconService.instance.setMode(IconMode.light);
      calls.clear();

      await pumpShell(tester);
      await openTab(tester, 'Settings', 3);
      await tester.tap(find.text('Customization'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('App icon'));
      await tester.pumpAndSettle();

      // Three marks, the one in force ticked. Only the sheet carries a tick, so
      // the check is scoped to it.
      final sheet = find.byType(BottomSheet);
      expect(sheet, findsOneWidget);
      for (final mode in IconMode.values) {
        expect(
          find.descendant(of: sheet, matching: find.text(mode.label)),
          findsOneWidget,
        );
      }
      expect(
        find.descendant(of: sheet, matching: find.byIcon(Icons.check_rounded)),
        findsOneWidget,
      );

      await tester.tap(find.descendant(of: sheet, matching: find.text('Dark')));
      await tester.pumpAndSettle();

      // Android was told exactly once, and the choice was stored before it was
      // asked — so a refused switch is retried on the next start, not forgotten.
      expect(
        calls
            .where((call) => call.method == 'setIcon')
            .map((call) => (call.arguments as Map<Object?, Object?>)['mode'])
            .toList(),
        <Object?>['dark'],
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(SharedPrefsIconModeStore.key), 'dark');

      // And the row says what it did, without a second tap.
      expect(find.text('Always the dark mark.'), findsOneWidget);
      expect(find.text('Dark'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(iconChannel, null);
    }
  });

  testWidgets('a platform that cannot switch icons is told so, not mocked', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      await pumpShell(tester);
      await openTab(tester, 'Settings', 3);
      await tester.tap(find.text('Customization'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Light, Dark or Auto — the launcher mark switches on Android.',
        ),
        findsOneWidget,
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('a conversation survives being closed and opened again', (
    tester,
  ) async {
    await pumpShell(tester);
    await tester.enterText(find.byType(TextField), 'what is the weather?');
    await tester.pump();
    await tapTheButton(tester, sendButton());
    await tester.pumpAndSettle();
    expect(find.text(ollama.reply), findsOneWidget);

    // The app going away and coming back with the same log: a fresh tree over
    // the same store is what a relaunch is, without the process.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(const NexusUiApp());
    await tester.pumpAndSettle();

    expect(find.text('what is the weather?'), findsOneWidget);
    expect(find.text(ollama.reply), findsOneWidget);
    expect(
      find.text('Hey, what do you need?'),
      findsNothing,
      reason: 'the welcome heading is for a thread with nothing in it',
    );
  });

  testWidgets('the answer is asked with the conversation behind it', (
    tester,
  ) async {
    await pumpShell(tester);

    Future<void> ask(String text) async {
      await tester.enterText(find.byType(TextField), text);
      await tester.pump();
      await tapTheButton(tester, sendButton());
      await tester.pumpAndSettle();
    }

    // The first question, asked with nothing behind it.
    await ask('what is the weather?');
    expect(ollama.histories.single, isEmpty);

    // The second: "and tomorrow?" has no referent unless the model is handed
    // the exchange — the question and the answer, in that order, and not the
    // question being asked, which travels as the prompt.
    ollama.reply = 'Warm and clear.';
    await ask('and tomorrow?');

    expect(ollama.prompts, <String>['what is the weather?', 'and tomorrow?']);
    final List<AiTurn> history = ollama.histories.last;
    expect(history, hasLength(2));
    expect(history.first.fromUser, isTrue);
    expect(history.first.text, 'what is the weather?');
    expect(history.last.fromUser, isFalse);
    expect(history.last.text, 'Hello from the PC.');
    expect(
      history.any((AiTurn turn) => turn.text == 'and tomorrow?'),
      isFalse,
      reason: 'the current question travels as the prompt, not as history',
    );
  });

  testWidgets('the model is given the last ten messages, not the whole day', (
    tester,
  ) async {
    // A conversation that has been going on for a while: twelve lines, which is
    // more than a phone's context should be asked to hold.
    chat = ChatLog(
      store: MemoryChatLogStore(<ChatEntry>[
        for (int i = 0; i < 12; i++)
          ChatEntry(i.isEven ? 'question $i' : 'answer $i', mine: i.isEven),
      ]),
    );
    await pumpShell(tester);
    await tester.pumpAndSettle();
    expect(find.text('answer 11'), findsOneWidget, reason: 'restored first');

    await tester.enterText(find.byType(TextField), 'and now?');
    await tester.pump();
    await tapTheButton(tester, sendButton());
    await tester.pumpAndSettle();

    final List<AiTurn> history = ollama.histories.single;
    expect(history, hasLength(kAiHistoryLimit));
    expect(
      history.first.fromUser,
      isTrue,
      reason:
          'a chat template expects a conversation that starts with the '
          'user, so the trim drops a leading answer',
    );
    expect(history.first.text, 'question 2');
    expect(history.last.text, 'answer 11');
    expect(history.any((AiTurn turn) => turn.text == 'and now?'), isFalse);
  });

  testWidgets('Clear chat is gone from Settings, and the thread survives it', (
    tester,
  ) async {
    await pumpShell(tester);
    await tester.enterText(find.byType(TextField), 'what is the weather?');
    await tester.pump();
    await tapTheButton(tester, sendButton());
    await tester.pumpAndSettle();
    expect(chat.hasChat, isTrue);

    await openTab(tester, 'Settings', 3);
    // The row used to sit under the Privacy section. Scroll the whole list to
    // its end so "not found" means absent, not merely below the fold: deleting
    // chats now lives in the drawer's multi-select, where the chats are.
    await tester.scrollUntilVisible(
      find.text('Version'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text(kNexusClearChatRow), findsNothing);
    expect(find.text(kNexusClearChatTitle), findsNothing);

    // Nothing was deleted on the way through Settings.
    expect(chat.hasChat, isTrue);
    await openTab(tester, 'Home', 0);
    expect(find.text('what is the weather?'), findsOneWidget);
  });

  testWidgets('the Devices header offers a + that opens the pairing sheet', (
    tester,
  ) async {
    await pumpShell(tester);
    await openTab(tester, 'Devices', 2);

    await tester.tap(find.byKey(kNexusAddDevice));
    await tester.pumpAndSettle();

    // The sheet, and both ways through it. The two row labels are the sheet's
    // own — the pair row at the foot of the list spells them differently enough
    // that they cannot be mistaken for each other.
    expect(find.text(kNexusScanQrLabel), findsOneWidget);
    expect(find.text(kNexusShowQrLabel), findsOneWidget);
  });

  testWidgets('an action reply becomes a pill, and the JSON never shows', (
    tester,
  ) async {
    final _FakePhoneBackend phone = _FakePhoneBackend();
    SystemActions.override = () => DeviceSystemActions(backend: phone);
    await pumpShell(tester);

    // What a model does when the room is dark: it asks for the torch rather
    // than talking about it.
    ollama.reply = '{"action":"set_flashlight","state":"on"}';
    await tester.enterText(find.byType(TextField), "it's dark in here");
    await tester.pump();
    await tapTheButton(tester, sendButton());
    await tester.pumpAndSettle();

    expect(find.byKey(kNexusSystemBubble), findsOneWidget);
    expect(find.text('Flashlight on.'), findsOneWidget);
    expect(
      find.textContaining('"action"'),
      findsNothing,
      reason: 'the request is the app\'s business, not a sentence for the user',
    );
    expect(phone.calls.single.$1, AgentActions.flashlightToggle);
    expect(phone.calls.single.$2, <String, dynamic>{'mode': 'on'});

    // The line is remembered as a system line, and comes back as one.
    expect(chat.entries.last.system, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(const NexusUiApp());
    await tester.pumpAndSettle();
    expect(find.byKey(kNexusSystemBubble), findsOneWidget);
    expect(find.text('Flashlight on.'), findsOneWidget);
  });

  testWidgets('a reply that is nearly an action is shown as the answer it is', (
    tester,
  ) async {
    final _FakePhoneBackend phone = _FakePhoneBackend();
    SystemActions.override = () => DeviceSystemActions(backend: phone);
    await pumpShell(tester);

    // An action the app does not have is still an action request, and a
    // request is never prose: the block is taken out of the reply and answered
    // with the shell's refusal (see the pill tests below). What this test pins
    // is that the guess is never *run* — the parser stays the one gate.
    ollama.reply = '{"action":"launch_missiles"}';
    await tester.enterText(find.byType(TextField), 'do something silly');
    await tester.pump();
    await tapTheButton(tester, sendButton());
    await tester.pumpAndSettle();

    expect(phone.calls, isEmpty, reason: 'nothing was run for a guess');
    expect(
      find.text(nexusUnknownActionLine('launch_missiles')),
      findsOneWidget,
    );
    expect(find.textContaining('"action"'), findsNothing);
  });

  group('a model that answers in JSON', () {
    // Measured on the A25: asked "what is 2+2", the 1B model answered with an
    // object instead of a sentence. The thread is a conversation, so the object
    // is read and its words are what the user sees — never the wire format.
    test('an answer field is read as its value, whatever it is called', () {
      expect(nexusReadableText('{"result": 4}'), '4');
      expect(nexusReadableText('{"answer": "Four."}'), 'Four.');
      expect(nexusReadableText('{"text": "Four"}'), 'Four');
      expect(nexusReadableText('{"response": "Four"}'), 'Four');
      // The field name is a convention, not a case: `Result` is the same field.
      expect(nexusReadableText('{"Result": true}'), 'true');
    });

    test('a value that is itself JSON is read too', () {
      // A model that wraps its wrapper: one pass is not enough.
      expect(nexusReadableText('{"result": "{\\"answer\\": 4}"}'), '4');
    });

    test('an object with no answer field keeps its words, not its quotes', () {
      expect(nexusReadableText('{"colour": "red"}'), 'colour: red');
      expect(nexusReadableText('{"colour": "red"}'), isNot(contains('{')));
      expect(nexusReadableText('{"a": 1, "b": 2}'), 'a: 1, b: 2');
    });

    test('a key-value line with no braces is left as the plain text it is', () {
      // The hallucination from the phone: asked to play a song, the model
      // answered with data-shaped prose. There is no object to read and no
      // action to run, so the honest thing is to show what it said — the prompt
      // rule is what stops the next one from claiming it played the song.
      const String invented = 'song: Yesterday, artist: The Beatles';
      expect(nexusReadableText(invented), invented);
    });

    test('python-flavoured JSON is read the same way', () {
      expect(nexusReadableText("{'result': 4,}"), '4');
      expect(nexusReadableText('{result: 4}'), '4');
    });

    test('a truncated object loses its brace and keeps its words', () {
      expect(nexusReadableText('{"result": 4'), 'result: 4');
      expect(nexusReadableText('{"result": 4'), isNot(contains('{')));
    });

    test('a fragment that never opened a brace loses its quotes too', () {
      // Measured on the A25: "what is a mesh network" was answered
      // `"mesh_network": type:object,value:name:802.15.4 …` — the model's
      // wire format with the object's braces left off, so there was no region
      // for the object reader to read and the quotes went to the bubble.
      expect(
        nexusReadableText(
          '"mesh_network": type:object,value:name:802.15.4 wireless mesh '
          'network,description:A type of wireless communication standard.',
        ),
        'mesh_network: type:object,value:name:802.15.4 wireless mesh '
        'network,description:A type of wireless communication standard.',
      );
    });

    test('a sentence that begins with a quotation keeps it', () {
      expect(
        nexusReadableText('"Less is more" is the rule.'),
        '"Less is more" is the rule.',
      );
    });

    test('prose around the object survives it', () {
      expect(nexusReadableText('Sure. {"answer": "Four"}'), 'Sure. Four');
    });

    test('braces that are not JSON are left as the user wrote them', () {
      // The rule is against the model's wire format, not against punctuation:
      // editing a sentence that happens to have braces in it would be worse
      // than the thing this fixes.
      expect(
        nexusReadableText('Use {curly braces} in code.'),
        'Use {curly braces} in code.',
      );
    });

    test('a plain answer is untouched', () {
      expect(
        nexusReadableText('A mesh shares one connection between devices.'),
        'A mesh shares one connection between devices.',
      );
    });
  });

  testWidgets('a JSON answer is a bubble with the words in it', (tester) async {
    SystemActions.override = () =>
        DeviceSystemActions(backend: _FakePhoneBackend());
    await pumpShell(tester);

    ollama.reply = '{"result": 4}';
    await tester.enterText(find.byType(TextField), 'tell me about the sun');
    await tester.pump();
    await tapTheButton(tester, sendButton());
    await tester.pumpAndSettle();

    expect(find.text('4'), findsOneWidget);
    expect(find.textContaining('{'), findsNothing);
    expect(find.textContaining('result'), findsNothing);
    expect(
      find.byKey(kNexusSystemBubble),
      findsNothing,
      reason: 'an answer is not an action',
    );
  });

  testWidgets('a JSON answer is saved to the thread as the words', (
    tester,
  ) async {
    // The sanitised sentence is what the thread keeps — otherwise the next
    // question is read against a wire format, and a relaunch brings the JSON
    // back to the screen.
    SystemActions.override = () =>
        DeviceSystemActions(backend: _FakePhoneBackend());
    await pumpShell(tester);

    ollama.reply = '{"answer": "Four."}';
    await tester.enterText(find.byType(TextField), 'tell me about the sun');
    await tester.pump();
    await tapTheButton(tester, sendButton());
    await tester.pumpAndSettle();
    expect(find.text('Four.'), findsOneWidget);

    ollama.reply = 'Anything else?';
    await tester.enterText(find.byType(TextField), 'thanks');
    await tester.pump();
    await tapTheButton(tester, sendButton());
    await tester.pumpAndSettle();

    final List<AiTurn> history = ollama.histories.last;
    expect(history.map((AiTurn turn) => turn.text), <String>[
      'tell me about the sun',
      'Four.',
    ]);

    // And what is on disk is the same sentence: the bubble is written exactly
    // as it is drawn.
    expect(
      ChatLog.instance.entries.map((ChatEntry entry) => entry.text),
      isNot(contains('{"answer": "Four."}')),
    );
    expect(
      ChatLog.instance.entries.map((ChatEntry entry) => entry.text),
      contains('Four.'),
    );
  });

  testWidgets(
    'a JSON answer saved by an older build is cleaned on the way in',
    (tester) async {
      // The A25's own thread before this fix: a bubble holds the object. It is
      // read into words when the conversation is restored — the screen never
      // shows JSON, including yesterday's — and written back clean.
      chat.save(<ChatEntry>[const ChatEntry('{"result": 4}')]);
      await pumpShell(tester);

      expect(find.text('4'), findsOneWidget);
      expect(find.textContaining('{'), findsNothing);
      expect(chat.entries.single.text, '4');
    },
  );

  testWidgets('a reply that is nothing but braces is an honest sentence', (
    tester,
  ) async {
    SystemActions.override = () =>
        DeviceSystemActions(backend: _FakePhoneBackend());
    await pumpShell(tester);

    // There is no answer field to read and no words between the braces. An
    // empty bubble would look like a rendering fault; the object is not
    // something a person can read. The shell says the only true thing left.
    ollama.reply = '{}';
    await tester.enterText(find.byType(TextField), 'tell me about the sun');
    await tester.pump();
    await tapTheButton(tester, sendButton());
    await tester.pumpAndSettle();

    expect(find.text(kNexusNoAnswerText), findsOneWidget);
    expect(find.textContaining('{'), findsNothing);
  });

  testWidgets('an answer wrapped in JSON and a sentence reads as both', (
    tester,
  ) async {
    SystemActions.override = () =>
        DeviceSystemActions(backend: _FakePhoneBackend());
    await pumpShell(tester);

    ollama.reply = 'Sure thing. {"result": "Four"}';
    await tester.enterText(find.byType(TextField), 'tell me about the sun');
    await tester.pump();
    await tapTheButton(tester, sendButton());
    await tester.pumpAndSettle();

    expect(find.text('Sure thing. Four'), findsOneWidget);
    expect(find.textContaining('{'), findsNothing);
  });

  testWidgets('the live page reads a JSON answer out as words too', (
    tester,
  ) async {
    grantMic();
    final mic = _FakeSpeechInput();
    SpeechInput.override = () => mic;
    addTearDown(() => SpeechInput.override = null);
    SystemActions.override = () =>
        DeviceSystemActions(backend: _FakePhoneBackend());
    await pumpShell(tester);
    await openLive(tester);

    // The large type is the same reply behind another surface: a JSON object
    // in 30-point type is the worst version of this bug, not a different one.
    ollama.reply = '{"result": "Four"}';
    mic.say('tell me about the sun');
    mic.hear('tell me about the sun');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));

    expect(liveText(tester), 'Four');

    await tester.tap(find.byKey(kNexusLiveClose));
    await tester.pumpAndSettle();
    expect(find.text('Four'), findsOneWidget);
  });

  testWidgets('a settings request runs without asking the model at all', (
    tester,
  ) async {
    final _FakePhoneBackend phone = _FakePhoneBackend()
      ..reply = const ActionResult(true, 'Brightness set to 60%.');
    SystemActions.override = () => DeviceSystemActions(backend: phone);
    await pumpShell(tester);

    // The exact request that failed on the A25: it reached the model, which
    // answered "Brightness set to 60%." and changed nothing. The vocabulary is
    // closed and the shell has it, so the model must not be asked at all.
    await tester.enterText(find.byType(TextField), 'set brightness to 60');
    await tester.pump();
    await tapTheButton(tester, sendButton());
    await tester.pumpAndSettle();

    expect(phone.calls.single.$1, AgentActions.brightnessSet);
    expect(phone.calls.single.$2, <String, dynamic>{
      'mode': 'set',
      'level': 60,
    });
    expect(find.byKey(kNexusSystemBubble), findsOneWidget);
    expect(find.text('Brightness set to 60%.'), findsOneWidget);
    expect(
      ollama.prompts,
      isEmpty,
      reason: 'the shell could read the request itself',
    );
  });

  testWidgets('a refused action says why, in the phone\'s own words', (
    tester,
  ) async {
    final _FakePhoneBackend phone = _FakePhoneBackend()
      ..reply = const ActionResult(false, 'What app should I open?');
    SystemActions.override = () => DeviceSystemActions(backend: phone);
    await pumpShell(tester);

    ollama.reply = '{"action":"open_app","app_name":"qqq"}';
    await tester.enterText(find.byType(TextField), 'open qqq');
    await tester.pump();
    await tapTheButton(tester, sendButton());
    await tester.pumpAndSettle();

    expect(find.text('What app should I open?'), findsOneWidget);
    expect(find.byKey(kNexusSystemBubble), findsOneWidget);
  });

  testWidgets('the action line goes back to the model as the answer it was', (
    tester,
  ) async {
    final _FakePhoneBackend phone = _FakePhoneBackend();
    SystemActions.override = () => DeviceSystemActions(backend: phone);
    await pumpShell(tester);

    Future<void> ask(String text) async {
      await tester.enterText(find.byType(TextField), text);
      await tester.pump();
      await tapTheButton(tester, sendButton());
      await tester.pumpAndSettle();
    }

    ollama.reply = '{"action":"set_timer","seconds":300}';
    await ask('set a timer for five minutes');
    expect(find.text('Timer set for 5 minutes.'), findsOneWidget);
    expect(phone.calls.single.$1, AgentActions.timerSet);

    ollama.reply = 'Anything else?';
    await ask('thanks');

    // The next question is asked with the exchange behind it, action line
    // included: "Timer set for 5 minutes." was the reply to the question, and a
    // model handed the question with no reply reads the next turn as a second
    // half of the same request — measured on llama3.2, which answered "turn on
    // the flashlight" by setting the timer again.
    final List<AiTurn> history = ollama.histories.last;
    expect(history.map((AiTurn turn) => turn.text), <String>[
      'set a timer for five minutes',
      'Timer set for 5 minutes.',
    ]);
    expect(
      history.last.fromUser,
      isFalse,
      reason: 'the shell\'s line is the answer, not another question',
    );
  });

  testWidgets('a loose action buried in prose is stripped and run', (
    tester,
  ) async {
    final _FakePhoneBackend phone = _FakePhoneBackend();
    SystemActions.override = () => DeviceSystemActions(backend: phone);
    await pumpShell(tester);

    // What a 1B model actually writes: unquoted keys and a friendly sentence
    // around them. Strict JSON parsing refused this, so the thread used to show
    // the request instead of running it.
    ollama.reply =
        'Sure — turning it on. {action: "set_flashlight", state: "on"} Enjoy.';
    await tester.enterText(find.byType(TextField), "it's dark in here");
    await tester.pump();
    await tapTheButton(tester, sendButton());
    await tester.pumpAndSettle();

    expect(find.byKey(kNexusSystemBubble), findsOneWidget);
    expect(find.text('Flashlight on.'), findsOneWidget);
    expect(phone.calls.single.$1, AgentActions.flashlightToggle);
    // The prose survives; the JSON never reaches the thread.
    expect(find.textContaining('Sure — turning it on.'), findsOneWidget);
    expect(find.textContaining('action'), findsNothing);
    expect(find.textContaining('{'), findsNothing);
  });

  testWidgets('a fenced action block is a pill, not a code sample', (
    tester,
  ) async {
    final _FakePhoneBackend phone = _FakePhoneBackend();
    SystemActions.override = () => DeviceSystemActions(backend: phone);
    await pumpShell(tester);

    ollama.reply = '```json\n{action: set_timer, seconds: 300}\n```';
    await tester.enterText(find.byType(TextField), 'set a timer for five');
    await tester.pump();
    await tapTheButton(tester, sendButton());
    await tester.pumpAndSettle();

    expect(find.byKey(kNexusSystemBubble), findsOneWidget);
    expect(find.text('Timer set for 5 minutes.'), findsOneWidget);
    expect(phone.calls.single.$1, AgentActions.timerSet);
    expect(find.textContaining('```'), findsNothing);
    expect(find.textContaining('seconds'), findsNothing);
  });

  testWidgets('single quotes and a trailing comma are still an action', (
    tester,
  ) async {
    final _FakePhoneBackend phone = _FakePhoneBackend();
    SystemActions.override = () => DeviceSystemActions(backend: phone);
    await pumpShell(tester);

    // Python-flavoured JSON, which a small model writes as readily as JSON:
    // the punctuation is normalised and only then offered to the parser, so the
    // user gets a timer rather than a lesson in quoting.
    ollama.reply = "On it. {'action': 'set_timer', 'seconds': 300,}";
    await tester.enterText(find.byType(TextField), 'set a timer for five');
    await tester.pump();
    await tapTheButton(tester, sendButton());
    await tester.pumpAndSettle();

    expect(phone.calls.single.$1, AgentActions.timerSet);
    expect(find.text('Timer set for 5 minutes.'), findsOneWidget);
    expect(find.textContaining("'action'"), findsNothing);
    expect(find.textContaining('seconds'), findsNothing);
  });

  testWidgets('an action the phone does not have is a refusal, not JSON', (
    tester,
  ) async {
    final _FakePhoneBackend phone = _FakePhoneBackend();
    SystemActions.override = () => DeviceSystemActions(backend: phone);
    await pumpShell(tester);

    // The guard, not the interceptor's enthusiasm: an action nobody implements
    // is never *run*. It is not printed either — the report caught exactly this
    // reply on the A25, and a wall of JSON in the bubble is worse than a
    // refusal, because it looks like output.
    ollama.reply = '{"action":"launch_missiles","target":"the moon"}';
    await tester.enterText(find.byType(TextField), 'do something silly');
    await tester.pump();
    await tapTheButton(tester, sendButton());
    await tester.pumpAndSettle();

    expect(phone.calls, isEmpty);
    expect(find.byKey(kNexusSystemBubble), findsOneWidget);
    expect(
      find.text(nexusUnknownActionLine('launch_missiles')),
      findsOneWidget,
    );
    // The name is said the way a person would: "launch missiles".
    expect(find.textContaining('launch missiles'), findsOneWidget);
    expect(find.textContaining('"action"'), findsNothing);
    expect(find.textContaining('{'), findsNothing);
  });

  testWidgets('the A25\'s hallucinated brightness action gets the same pill', (
    tester,
  ) async {
    final _FakePhoneBackend phone = _FakePhoneBackend();
    SystemActions.override = () => DeviceSystemActions(backend: phone);
    await pumpShell(tester);

    // Verbatim from the phone: llama3.2 answered "it's dark in here" with a
    // brightness action this build does not have (`set_brightness` is the real
    // one). The reply reached the thread as JSON before this was fixed.
    ollama.reply = '{"action":"turn_down_brightness","state":90}';
    await tester.enterText(find.byType(TextField), "it's dark in here");
    await tester.pump();
    await tapTheButton(tester, sendButton());
    await tester.pumpAndSettle();

    expect(phone.calls, isEmpty, reason: 'nothing was invented to run');
    expect(
      find.text(nexusUnknownActionLine('turn_down_brightness')),
      findsOneWidget,
    );
    expect(find.textContaining('state'), findsNothing);
    expect(find.textContaining('{'), findsNothing);
  });

  testWidgets('a refusal does not come back to the model, a result does', (
    tester,
  ) async {
    // On the A25 a thread with three refusal pills in it turned the 1B model
    // into an action machine: "explain what a mesh network is" was answered
    // with a Wi-Fi request. A refusal is a line about a word the phone does not
    // know, so it teaches nothing and is kept out; a successful result stays,
    // because it is the reply to the question (see the timer test below).
    final _FakePhoneBackend phone = _FakePhoneBackend();
    SystemActions.override = () => DeviceSystemActions(backend: phone);
    await pumpShell(tester);

    ollama.reply = '{"action":"launch_missiles"}';
    await tester.enterText(find.byType(TextField), 'do something silly');
    await tester.pump();
    await tapTheButton(tester, sendButton());
    await tester.pumpAndSettle();
    expect(
      find.text(nexusUnknownActionLine('launch_missiles')),
      findsOneWidget,
    );

    ollama.reply = '{"action":"set_flashlight","state":"on"}';
    await tester.enterText(find.byType(TextField), 'turn on the flashlight');
    await tester.pump();
    await tapTheButton(tester, sendButton());
    await tester.pumpAndSettle();
    expect(find.text('Flashlight on.'), findsOneWidget);

    ollama.reply = 'A mesh shares one connection between devices.';
    await tester.enterText(find.byType(TextField), 'what is a mesh?');
    await tester.pump();
    await tapTheButton(tester, sendButton());
    await tester.pumpAndSettle();

    final List<AiTurn> history = ollama.histories.last;
    expect(
      history.any(
        (AiTurn turn) => turn.text == nexusUnknownActionLine('launch_missiles'),
      ),
      isFalse,
      reason: 'a refusal is the shell declining, not an answer to learn from',
    );
    expect(
      history.map((AiTurn turn) => turn.text),
      contains('Flashlight on.'),
      reason: 'the result is the reply to the question that asked for it',
    );
  });

  testWidgets('a sum is answered by the shell, not the model', (tester) async {
    final _FakePhoneBackend phone = _FakePhoneBackend();
    SystemActions.override = () => DeviceSystemActions(backend: phone);
    await pumpShell(tester);

    // Measured on the A25: this question was answered with
    // {"action":"set_timer","seconds":420} — a seven-minute timer where an
    // answer belonged. A sum has one answer, so the shell works it out and the
    // model is never asked.
    ollama.reply = '{"action":"set_timer","seconds":420}';
    await tester.enterText(find.byType(TextField), 'what is 6 times 7');
    await tester.pump();
    await tapTheButton(tester, sendButton());
    await tester.pumpAndSettle();

    expect(find.text('6 * 7 = 42'), findsOneWidget);
    expect(ollama.prompts, isEmpty, reason: 'arithmetic needs no model');
    expect(phone.calls, isEmpty, reason: 'and no timer');
    expect(find.byKey(kNexusSystemBubble), findsNothing);
    expect(
      chat.entries.last.text,
      '6 * 7 = 42',
      reason: 'the shell\'s answer is stored like any other',
    );
  });

  testWidgets('a question about an attached photo is answered honestly', (
    tester,
  ) async {
    // A picture attached before this question, as the thread stores it: the
    // caption plus the path. No file is needed — the answer comes before any
    // image is read.
    chat.save(<ChatEntry>[
      const ChatEntry(
        'Photo attached',
        mine: true,
        imagePath: '/tmp/nexus-photo.png',
      ),
    ]);
    await pumpShell(tester);

    await tester.enterText(find.byType(TextField), 'what is this?');
    await tester.pump();
    await tapTheButton(tester, sendButton());
    await tester.pumpAndSettle();

    expect(find.text(kNexusVisionMissingText), findsOneWidget);
    expect(
      ollama.prompts,
      isEmpty,
      reason: 'a text model cannot see, so it is not asked',
    );
  });

  testWidgets('the vision notice does not swallow ordinary questions', (
    tester,
  ) async {
    chat.save(<ChatEntry>[
      const ChatEntry(
        'Photo attached',
        mine: true,
        imagePath: '/tmp/nexus-photo.png',
      ),
    ]);
    await pumpShell(tester);

    // A photo in the thread is not a licence to answer every later question
    // with a notice about a camera.
    ollama.reply = 'A mesh shares one connection between devices.';
    await tester.enterText(find.byType(TextField), 'what is a mesh network');
    await tester.pump();
    await tapTheButton(tester, sendButton());
    await tester.pumpAndSettle();

    expect(ollama.prompts.single, 'what is a mesh network');
    expect(
      find.text('A mesh shares one connection between devices.'),
      findsOneWidget,
    );
  });

  testWidgets('"what is this?" with no picture is the model\'s', (
    tester,
  ) async {
    await pumpShell(tester);

    ollama.reply = 'This is Nexus, a private assistant.';
    await tester.enterText(find.byType(TextField), 'what is this?');
    await tester.pump();
    await tapTheButton(tester, sendButton());
    await tester.pumpAndSettle();

    expect(ollama.prompts.single, 'what is this?');
    expect(find.text(kNexusVisionMissingText), findsNothing);
  });

  testWidgets('a clock question never reaches the model', (tester) async {
    final _FakePhoneBackend phone = _FakePhoneBackend();
    SystemActions.override = () => DeviceSystemActions(
      backend: phone,
      clock: () => DateTime(2026, 10, 19, 15, 5),
    );
    await pumpShell(tester);

    // Measured on the A25: with the clock in its system turn and `get_time` in
    // its vocabulary, the model still answered "07:30" at 14:24. So the shell
    // recognises the question itself — and the model is not asked at all.
    ollama.reply = '{"time": "07:30"}';
    await tester.enterText(find.byType(TextField), 'what time is it');
    await tester.pump();
    await tapTheButton(tester, sendButton());
    await tester.pumpAndSettle();

    expect(
      ollama.prompts,
      isEmpty,
      reason: 'the model has no clock to consult',
    );
    expect(phone.calls, isEmpty, reason: 'the clock needs no native call');
    expect(find.byKey(kNexusSystemBubble), findsOneWidget);
    expect(find.text("It's 15:05 on Monday 19 October 2026."), findsOneWidget);
    expect(find.textContaining('07:30'), findsNothing);
  });

  testWidgets('a get_time request is answered from the phone\'s clock', (
    tester,
  ) async {
    final _FakePhoneBackend phone = _FakePhoneBackend();
    SystemActions.override = () => DeviceSystemActions(backend: phone);
    await pumpShell(tester);

    // The model asked for this on the A25 before the action existed. Now it is
    // one of the ten, and the answer is the shell's own clock — never the
    // model's guess, and never the request itself.
    ollama.reply = '{"action":"get_time"}';
    await tester.enterText(find.byType(TextField), 'what time is it');
    await tester.pump();
    await tapTheButton(tester, sendButton());
    await tester.pumpAndSettle();

    expect(phone.calls, isEmpty, reason: 'the clock needs no native call');
    expect(find.byKey(kNexusSystemBubble), findsOneWidget);
    expect(find.textContaining("It's "), findsOneWidget);
    expect(find.textContaining('get_time'), findsNothing);
    expect(find.textContaining('{'), findsNothing);
  });

  testWidgets('an invented time object becomes the real clock', (tester) async {
    final _FakePhoneBackend phone = _FakePhoneBackend();
    SystemActions.override = () => DeviceSystemActions(backend: phone);
    await pumpShell(tester);

    // Verbatim from the phone at 14:24: the model has no clock, so it wrote a
    // plausible-looking one. The thread answers with the phone's time.
    ollama.reply = '{"time": "07:30"}';
    await tester.enterText(find.byType(TextField), 'what time is it');
    await tester.pump();
    await tapTheButton(tester, sendButton());
    await tester.pumpAndSettle();

    expect(find.textContaining("It's "), findsOneWidget);
    expect(find.textContaining('07:30'), findsNothing);
    expect(find.textContaining('"time"'), findsNothing);
    expect(find.textContaining('{'), findsNothing);
  });

  testWidgets('the live page strips a loose action too, not just strict JSON', (
    tester,
  ) async {
    grantMic();
    final mic = _FakeSpeechInput();
    SpeechInput.override = () => mic;
    addTearDown(() => SpeechInput.override = null);
    final _FakePhoneBackend phone = _FakePhoneBackend();
    SystemActions.override = () => DeviceSystemActions(backend: phone);
    await pumpShell(tester);
    await openLive(tester);

    ollama.reply = 'On it. {action: "set_flashlight", state: "on"}';
    mic.say("it's dark");
    mic.hear("it's dark");
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));

    expect(phone.calls.single.$1, AgentActions.flashlightToggle);
    expect(liveText(tester), 'Flashlight on.');
    expect(liveText(tester), isNot(contains('action')));

    // Closing keeps the exchange in the thread, prose and pill both.
    await tester.tap(find.byKey(kNexusLiveClose));
    await tester.pumpAndSettle();
    expect(find.text('On it.'), findsOneWidget);
    expect(find.text('Flashlight on.'), findsOneWidget);
  });

  testWidgets('a speaking answer can be stopped, and stopping it listens again', (
    tester,
  ) async {
    grantMic();
    final mic = _FakeSpeechInput();
    SpeechInput.override = () => mic;
    addTearDown(() => SpeechInput.override = null);
    final _GatedSpeechOutput speech = _GatedSpeechOutput();
    SpeechOutput.override = () => speech;
    addTearDown(() => SpeechOutput.override = null);
    await pumpShell(tester);
    ollama.reply = 'A long answer that is still being read out.';
    await openLive(tester);

    mic.say('tell me something');
    mic.hear('tell me something');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));

    expect(speech.said, <String>[
      'A long answer that is still being read out.',
    ]);
    // While the voice is going the page offers the way to interrupt it, and
    // says so in words rather than making the user guess.
    expect(find.byKey(kNexusLiveStopSpeaking), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(kNexusLiveStatus)).data,
      'Speaking — tap to stop.',
    );

    await tester.tap(find.byKey(kNexusLiveStopSpeaking));
    await tester.pump();
    expect(speech.stops, 1);

    // Stop is an interruption, not a pause: the voice is gone and the next turn
    // is already open, which is what the user asked for by tapping it.
    expect(mic.listens, 2);
    expect(find.byKey(kNexusLiveResume), findsNothing);
    expect(find.byKey(kNexusLiveRecordingIndicator), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(kNexusLiveStatus)).data,
      'Listening — just speak.',
    );

    // Nothing stale reopens it a second time: the auto-listen timer belonged to
    // the answer that was interrupted and went with it.
    await tester.pump(const Duration(seconds: 2));
    expect(mic.listens, 2);
  });

  testWidgets('the live page\'s buttons stay readable on a pale accent', (
    tester,
  ) async {
    // Found on the A25: a near-white accent (#FBF5FF) filled the Resume pill
    // and the label was painted hard white, so the one control that reopens the
    // microphone was invisible. The accent class already computes the ink that
    // sits on a colour; the live page has to ask it rather than assume white.
    grantMic();
    final mic = _FakeSpeechInput();
    SpeechInput.override = () => mic;
    addTearDown(() => SpeechInput.override = null);
    final _GatedSpeechOutput speech = _GatedSpeechOutput();
    SpeechOutput.override = () => speech;
    addTearDown(() => SpeechOutput.override = null);
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    const Color pale = Color(0xFFFBF5FF);
    await tester.pumpWidget(
      NexusUiApp(initialAccent: NexusAccent.custom(pale)),
    );
    await tester.pumpAndSettle();
    // The reported screen was the dark live page, and that is where the accent
    // is the raw pick (on a light page a pale seed is deepened into readable
    // ink first, so white is still correct there).
    await openTab(tester, 'Settings', 3);
    await tapSwitchOn(tester, 'Follow system');
    await tapSwitchOn(tester, 'Dark mode');
    await openTab(tester, 'Home', 0);
    await openLive(tester);

    ollama.reply = 'A long answer that is still being read out.';
    mic.say('tell me something');
    mic.hear('tell me something');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));

    // While the voice is going.
    final FilledButton stop = tester.widget<FilledButton>(
      find.byKey(kNexusLiveStopSpeaking),
    );
    expect(
      stop.style?.foregroundColor?.resolve(<WidgetState>{}),
      isNot(Colors.white),
    );

    // Stop hands the microphone straight back, so the resume pill belongs to
    // the guard — the one ending that really waits for the user. Trip it and
    // check the same ink rule on the control the user then sees.
    await tester.tap(find.byKey(kNexusLiveStopSpeaking));
    await tester.pump();
    await tester.pump(const Duration(seconds: 31));
    await tester.pump();
    final FilledButton resume = tester.widget<FilledButton>(
      find.byKey(kNexusLiveResume),
    );
    expect(
      resume.style?.foregroundColor?.resolve(<WidgetState>{}),
      const Color(0xFF141414),
      reason: 'dark ink on a near-white accent',
    );
  });

  testWidgets('tapping the page interrupts the voice as well as the button', (
    tester,
  ) async {
    grantMic();
    final mic = _FakeSpeechInput();
    SpeechInput.override = () => mic;
    addTearDown(() => SpeechInput.override = null);
    final _GatedSpeechOutput speech = _GatedSpeechOutput();
    SpeechOutput.override = () => speech;
    addTearDown(() => SpeechOutput.override = null);
    await pumpShell(tester);
    ollama.reply = 'Read this out loud for a while.';
    await openLive(tester);

    mic.say('read to me');
    mic.hear('read to me');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));
    expect(find.byKey(kNexusLiveStopSpeaking), findsOneWidget);

    // The large type is not a control of its own; the tap falls through to the
    // page's own "tap anywhere to stop".
    await tester.tap(find.byKey(kNexusLiveText));
    await tester.pump();
    expect(speech.stops, 1);
    expect(find.byKey(kNexusLiveStopSpeaking), findsNothing);
    // Interrupted, and listening again: a tap on the page is the same gesture as
    // the Stop control, not a request for a quiet room.
    expect(find.byKey(kNexusLiveRecordingIndicator), findsOneWidget);
    expect(mic.listens, 2);
  });

  testWidgets('a model that does not fit names the download that would', (
    tester,
  ) async {
    // The A25 case: the 1B model did not fit, and the app was killed mid-answer.
    // With no smaller model on the phone there is nothing to switch to, so the
    // thread says which download would fit — red, and actionable.
    final Directory dir = Directory.systemTemp.createTempSync('nexus_no_room');
    addTearDown(() {
      OnDeviceModel.debugDirectoryOverride = null;
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    OnDeviceModel.debugDirectoryOverride = () async => dir;
    await pumpShell(tester);

    ollama.failureOnce = const InsufficientMemoryException(
      label: 'Llama 3.2 1B',
      neededBytes: 1200000000,
      freeBytes: 300000000,
    );
    await tester.enterText(find.byType(TextField), 'what is a mesh?');
    await tester.pump();
    await tapTheButton(tester, sendButton());
    await tester.pumpAndSettle();

    expect(find.text(kNexusNotEnoughMemoryText), findsOneWidget);
    expect(find.textContaining('Qwen 0.5B'), findsOneWidget);
    // Asked once: there was no smaller file to try.
    expect(ollama.prompts, hasLength(1));
  });

  testWidgets('a model that does not fit falls back to the smaller one', (
    tester,
  ) async {
    // The download the user may already have is the answer to a model that is
    // too big: switch the selection, ask again, and say nothing about memory —
    // the question still gets an answer.
    final Directory dir = Directory.systemTemp.createTempSync('nexus_room');
    File('${dir.path}/model.gguf').writeAsBytesSync(<int>[1, 2, 3]);
    addTearDown(() {
      OnDeviceModel.debugDirectoryOverride = null;
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    OnDeviceModel.debugDirectoryOverride = () async => dir;
    await pumpShell(tester);
    await modelChoice.select(OnDeviceModelChoice.llama);

    ollama.failureOnce = const InsufficientMemoryException(
      label: 'Llama 3.2 1B',
      neededBytes: 1200000000,
      freeBytes: 300000000,
    );
    ollama.reply = 'Answered by Qwen.';
    await tester.enterText(find.byType(TextField), 'what is a mesh?');
    await tester.pump();
    await tapTheButton(tester, sendButton());
    await tester.pumpAndSettle();

    expect(find.text('Answered by Qwen.'), findsOneWidget);
    expect(find.text(kNexusNotEnoughMemoryText), findsNothing);
    expect(ollama.prompts, hasLength(2));
    expect(modelChoice.choice, OnDeviceModelChoice.qwen);
  });

  testWidgets('a drag from the left edge opens the chat drawer', (
    tester,
  ) async {
    await pumpShell(tester);
    expect(find.text('Chats'), findsNothing);

    // From the edge itself, which is the gesture a phone user makes. The
    // scaffold gives the first 32 points to the drawer.
    await tester.dragFrom(const Offset(2, 300), const Offset(260, 0));
    await tester.pumpAndSettle();

    expect(find.text('Chats'), findsOneWidget);
    expect(find.byKey(kNexusNewChat), findsOneWidget);
  });

  testWidgets('long-press offers the menu, and multi-select comes second', (
    tester,
  ) async {
    chat.save(const <ChatEntry>[
      ChatEntry('A chat to manage', mine: true),
      ChatEntry('Here to help.'),
    ]);
    await pumpShell(tester);
    // `attach` migrates the single-thread store into a session of its own, so
    // the id is read after the screen has restored, not before.
    final String id = chat.activeSessionId!;
    await tester.tap(find.byKey(kNexusChatMenu));
    await tester.pumpAndSettle();

    await tester.longPress(find.byKey(ValueKey<String>('chat-session-$id')));
    await tester.pumpAndSettle();
    expect(find.text('Rename'), findsOneWidget);
    expect(find.text('Pin'), findsOneWidget);
    expect(find.text('Multi-select'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
    expect(find.text('1 selected'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey<String>('chat-menu-multiselect')),
    );
    await tester.pumpAndSettle();

    expect(find.text('1 selected'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('delete-all-chats')),
      findsOneWidget,
    );
  });

  testWidgets('rename and pin persist on the drawer row', (tester) async {
    chat.save(const <ChatEntry>[
      ChatEntry('An old name', mine: true),
      ChatEntry('An answer.'),
    ]);
    await pumpShell(tester);
    final String id = chat.activeSessionId!;
    await tester.tap(find.byKey(kNexusChatMenu));
    await tester.pumpAndSettle();

    await tester.longPress(find.byKey(ValueKey<String>('chat-session-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('chat-menu-rename')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('rename-chat-field')),
      'Project notes',
    );
    await tester.tap(find.byKey(const ValueKey<String>('rename-chat-save')));
    await tester.pumpAndSettle();
    expect(find.text('Project notes'), findsOneWidget);

    await tester.longPress(find.byKey(ValueKey<String>('chat-session-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('chat-menu-pin')));
    await tester.pumpAndSettle();
    expect(find.text('PINNED'), findsOneWidget);
    expect(chat.sessions.single.pinned, isTrue);
    expect(chat.sessions.single.title, 'Project notes');
  });

  testWidgets('seven taps on the version row unlock Developer Logs', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    LogService.debugReset();
    LogService.instance.log('TEST: developer logs are visible');
    await pumpShell(tester);
    await openTab(tester, 'Settings', 3);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey<String>('app-version-row')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();

    final Finder version = find.byKey(
      const ValueKey<String>('app-version-row'),
    );
    for (int i = 0; i < 7; i++) {
      await tester.tap(version);
      await tester.pump(const Duration(milliseconds: 80));
    }
    await tester.pumpAndSettle();

    expect(find.text('Developer Mode Unlocked!'), findsOneWidget);
    expect(tab('Logs'), findsOneWidget);
    await tester.tap(tab('Logs'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('developer-logs-list')),
      findsOneWidget,
    );
    expect(find.textContaining('TEST: developer logs'), findsOneWidget);
    // The count is a number, not the list's own `toString()`: the header once
    // printed `[Instance of 'LogLine', …].length` over the page.
    expect(find.text('1 of 500 lines — newest last'), findsOneWidget);
    expect(find.textContaining('Instance of'), findsNothing);
    expect(find.text('Copy to Clipboard'), findsOneWidget);
    expect(find.text('Clear Logs'), findsOneWidget);
  });

  testWidgets('the accent preview is a small swatch that opens the wheel', (
    tester,
  ) async {
    await pumpShell(tester);
    await openTab(tester, 'Settings', 3);

    // A 40dp disc, not a full-width sheet of colour: the hex block read as a
    // white panel in dark mode. The row around it is still the whole target.
    final Size swatch = tester.getSize(find.byKey(kNexusAccentSwatch));
    expect(swatch.width, 40);
    expect(swatch.height, 40);
    expect(tester.getSize(find.byKey(kNexusPickColor)).height, lessThan(90));

    await tester.tap(find.byKey(kNexusPickColor));
    await tester.pumpAndSettle();
    expect(find.byKey(kNexusColorWheel), findsOneWidget);
  });

  testWidgets('a newer release becomes a dismissible Home banner', (
    tester,
  ) async {
    HomeTab.updateCheckOverride = () async => const UpdateCheck(
      UpdateInfo(
        version: '9.9.9',
        downloadUrl: 'https://example.com/nexus-9.9.9.apk',
      ),
    );
    await pumpShell(tester);
    // The launch check is an async read of the package version followed by the
    // (injected) release lookup; give those two turns a frame to land.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();

    expect(find.text('Nexus v9.9.9 is available'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('update-banner-dismiss')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('update-banner')), findsNothing);
  });

  testWidgets('a waiting answer counts the seconds until the first token', (
    tester,
  ) async {
    final _StreamingBrain brain = _StreamingBrain();
    LocalAiService.override = () => brain;
    await pumpShell(tester);

    await tester.enterText(find.byKey(kNexusComposerField), 'what is a mesh?');
    await tester.pump();
    await tapTheButton(tester, sendButton());
    await tester.pump();

    expect(find.byKey(const ValueKey<String>('thinking-timer')), findsNothing);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('(1s)'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('(3s)'), findsOneWidget);

    brain.write('A mesh shares one connection.');
    // The stream delivers after the pump's microtask drain, so the first token
    // lands in the next frame; the timer is gone once that frame is built.
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey<String>('thinking-timer')), findsNothing);
    expect(find.text('A mesh shares one connection.'), findsOneWidget);
  });

  test('a thought block splits into reasoning and answer, even mid-stream', () {
    final NexusThoughtSplit finished = splitNexusThought(
      '<thought>check the map</thought>It is on the table.',
    );
    expect(finished.thinking, isFalse);
    expect(finished.reasoning, 'check the map');
    expect(finished.answer, 'It is on the table.');

    final NexusThoughtSplit streaming = splitNexusThought(
      '<thought>check the map',
    );
    expect(streaming.thinking, isTrue);
    expect(streaming.reasoning, 'check the map');
    expect(streaming.answer, isEmpty);

    // A half-written opening tag is hidden rather than flashed for one frame.
    expect(splitNexusThought('Hello <thou').answer, 'Hello');
  });

  test('labelled reasoning splits into a bubble and an answer', () {
    for (final String label in <String>[
      'Thought:',
      'Thinking:',
      'Reasoning:',
    ]) {
      final NexusThoughtSplit split = splitNexusThought(
        '$label check the map\n\nThe map is on the table.',
      );
      expect(split.thinking, isFalse);
      expect(split.reasoning, 'check the map');
      expect(split.answer, 'The map is on the table.');
    }

    // The labels repeat on every line; the divider is still the answer.
    final NexusThoughtSplit many = splitNexusThought(
      'Thought: first\nThought: second\n\nfinal answer',
    );
    expect(many.reasoning, 'first\nsecond');
    expect(many.answer, 'final answer');

    // No divider: the last labelled block is the best final answer there is.
    final NexusThoughtSplit noBoundary = splitNexusThought(
      'Thought: first\nThought: second',
    );
    expect(noBoundary.reasoning, 'first');
    expect(noBoundary.answer, 'second');

    // While the stream is still arriving, the label is working-out, not an
    // answer that happens to begin with the word "Thought".
    final NexusThoughtSplit streaming = splitNexusThought(
      'Thought: check the map',
      finished: false,
    );
    expect(streaming.thinking, isTrue);
    expect(streaming.reasoning, 'check the map');
    expect(streaming.answer, isEmpty);

    // Two paragraphs with no reasoning label stay one answer. The divider is
    // only a reasoning boundary once the model has named a reasoning block.
    final NexusThoughtSplit plain = splitNexusThought(
      'Once upon a time\n\nThe end.',
    );
    expect(plain.reasoning, isEmpty);
    expect(plain.answer, 'Once upon a time\n\nThe end.');
  });

  testWidgets('the thinking bubble streams above the answer and collapses', (
    tester,
  ) async {
    ollama.reply = '<thought>Check the map.</thought>The map is on the table.';
    await pumpShell(tester);
    await tester.enterText(find.byType(TextField), 'where is the map?');
    await tester.pump();
    await tapTheButton(tester, sendButton());
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('reasoning-bubble')),
      findsOneWidget,
    );
    expect(find.text('Thinking...'), findsOneWidget);
    expect(find.text('The map is on the table.'), findsOneWidget);
    expect(
      find.text('Check the map.'),
      findsNothing,
      reason: 'finished reasoning starts collapsed',
    );

    await tester.tap(find.byKey(const ValueKey<String>('reasoning-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('Check the map.'), findsOneWidget);
  });

  testWidgets('a Thought: label gets the same thinking bubble', (tester) async {
    ollama.reply = 'Thought: Check the map.\n\nThe map is on the table.';
    await pumpShell(tester);
    await tester.enterText(find.byType(TextField), 'where is the map?');
    await tester.pump();
    await tapTheButton(tester, sendButton());
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('reasoning-bubble')),
      findsOneWidget,
    );
    expect(find.text('Thinking...'), findsOneWidget);
    expect(find.text('The map is on the table.'), findsOneWidget);
    expect(
      find.text('Check the map.'),
      findsNothing,
      reason: 'finished reasoning starts collapsed',
    );

    await tester.tap(find.byKey(const ValueKey<String>('reasoning-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('Check the map.'), findsOneWidget);
  });

  test('the destructive red is solid, not a faded pink', () {
    // The dark theme shipped #FFB4AB, which reads as a secondary label rather
    // than as "this deletes something". Delete controls use `danger`, and it is
    // now the hardcoded red the report asked for.
    expect(NexusUiColors.dark.danger, const Color(0xFFFF5252));
    expect(NexusUiColors.light.danger, const Color(0xFFD32F2F));
    expect(NexusUiColors.dark.danger, isNot(NexusUiColors.dark.textMuted));
  });
}
