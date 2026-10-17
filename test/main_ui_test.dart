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
import 'package:nexus/core/llm.dart';
import 'package:nexus/core/local_ai_service.dart';
import 'package:nexus/core/mic_access.dart';
import 'package:nexus/core/ollama_service.dart';
import 'package:nexus/core/on_device_ai_service.dart';
import 'package:nexus/core/on_device_model.dart';
import 'package:nexus/core/services/icon_service.dart';
import 'package:nexus/core/speech.dart';
import 'package:nexus/main_ui.dart';
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

  /// True to answer like a PC that is switched off, or on another network.
  bool unreachable = false;

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
  Future<String> generateResponse(String prompt) {
    prompts.add(prompt);
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

  @override
  Stream<String> generateResponseStream(String prompt) {
    prompts.add(prompt);
    return _pieces.stream;
  }

  /// Nobody in the shell calls this any more; it is here because the interface
  /// still has it, and it is defined in terms of the stream so the two can never
  /// disagree.
  @override
  Future<String> generateResponse(String prompt) =>
      generateResponseStream(prompt).join();

  /// One token, arriving.
  void write(String piece) => _pieces.add(piece);

  /// The model stopping after it has already said [said]: the error the real
  /// on-device engine throws mid-answer.
  void fail(String message) =>
      _pieces.addError(OnDeviceAiException(message));

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
    File('${dir.path}/$kOnDeviceModelFileName').writeAsBytesSync(<int>[1, 2, 3]);
    return true;
  }

  @override
  Future<void> dispose() async {}
}

/// The phone's speaker, as the shell sees it: it keeps the sentences it was
/// asked to say, in order, so a test can prove both that a reply is read out
/// and that a failure notice is not.
class _FakeSpeechOutput extends SpeechOutput {
  _FakeSpeechOutput();

  final List<String> said = <String>[];

  @override
  bool get available => true;

  @override
  Future<bool> speak(String text) async {
    said.add(text);
    return true;
  }
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
  setUp(() {
    ollama = _FakeOllama();
    LocalAiService.override = () => ollama;
  });
  tearDown(() => LocalAiService.override = null);

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

  testWidgets('opens on Home with the greeting and a bubble per side', (
    tester,
  ) async {
    await pumpShell(tester);

    expect(find.text('Hey, what do you need?'), findsOneWidget);
    expect(
      find.textContaining('Everything stays on your devices'),
      findsWidgets,
    );
    expect(find.text('What’s in my Downloads?'), findsOneWidget);
    expect(find.text('Message Nexus'), findsOneWidget);

    final home = tester.widget<IndexedStack>(find.byType(IndexedStack));
    expect(home.index, 0);

    // The composer starts as a mic, because there is nothing to send.
    expect(micButton(), findsOneWidget);
    expect(sendButton(), findsNothing);
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
    File(
      '${dir.path}/$kOnDeviceModelFileName',
    ).writeAsBytesSync(List<int>.filled(4096, 7));
    final OnDeviceAiService onDevice = OnDeviceAiService(
      model: OnDeviceModel(directory: () async => dir),
    );

    await pumpBrainSettings(tester, onDevice);

    // The phone has the model: the status says so, and the row that frees the
    // space is there instead of a download button.
    expect(find.text('On-Device (Loaded)'), findsOneWidget);
    expect(find.text('Delete model'), findsOneWidget);
    expect(find.text('Download model'), findsNothing);

    await tester.tap(find.text('Delete model'));
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
    expect(find.text('Download model'), findsOneWidget,
        reason: 'the row stays, so the user can try again');
  });

  testWidgets('a bubble can be copied, on either side of the thread', (
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

    // The user's own line: a long press puts the whole sentence on the
    // clipboard and says so, because a clipboard write is otherwise invisible.
    await tester.longPress(find.text('remember this'));
    await tester.pump();
    expect(copied, <String>['remember this']);
    expect(find.text(kNexusCopied), findsOneWidget);

    // And the reply, which is usually the half worth keeping.
    await tester.longPress(find.text(ollama.reply));
    await tester.pump();
    expect(copied, <String>['remember this', ollama.reply]);

    // The greeting bubble is copyable too: it is a Nexus message like any other.
    await tester.longPress(
      find.textContaining('Everything stays on your devices'),
    );
    await tester.pump();
    expect(copied.last, contains('Everything stays on your devices'));

    // And so is the copy control under the reply, which is the visible half of
    // the same promise — the gesture is a shortcut, not the only way in.
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
    expect(copied.last, ollama.reply);
  });

  testWidgets('a reply is spoken as it lands, and can be heard again', (
    tester,
  ) async {
    final speech = _FakeSpeechOutput();
    SpeechOutput.override = () => speech;
    addTearDown(() => SpeechOutput.override = null);
    await pumpShell(tester);

    await tester.enterText(find.byType(TextField), 'what is the weather?');
    await tester.pump();
    await tapTheButton(tester, sendButton());
    await tester.pumpAndSettle();

    // The answer is read out as it arrives — once, and the same sentence that
    // is on the bubble.
    expect(speech.said, <String>[ollama.reply]);

    // Both controls sit under every Nexus message — the opening line *and* the
    // answer that was just generated. A phone run had them on the greeting only,
    // which is why this check names both bubbles rather than counting icons.
    final Finder greeting = find.ancestor(
      of: find.textContaining('Everything stays on your devices'),
      matching: find.byType(NexusChatBubble),
    );
    final Finder reply = find.ancestor(
      of: find.text(ollama.reply),
      matching: find.byType(NexusChatBubble),
    );
    for (final Finder bubble in <Finder>[greeting, reply]) {
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

    await tester.tap(
      find.descendant(of: reply, matching: find.byTooltip(kNexusSpeakTooltip)),
    );
    await tester.pump();
    expect(speech.said, <String>[ollama.reply, ollama.reply]);
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
      find.descendant(
        of: half,
        matching: find.byTooltip(kNexusSpeakTooltip),
      ),
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
    expect(speech.said, <String>['One, two, three.']);
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

  testWidgets('the composer clears the tab bar and the bubbles take sides', (
    tester,
  ) async {
    await pumpShell(tester);

    // The pill must never sit under the navigation bar.
    final field = tester.getRect(find.byType(TextField));
    final bar = tester.getRect(find.byType(NexusTabBar));
    expect(field.bottom, lessThan(bar.top));

    // Measure the text, not the bubble: each bubble is an Align, so the
    // bubble's own rect is the full column and says nothing about its side.
    final mine = tester.getRect(find.text('What’s in my Downloads?'));
    final theirs = tester.getRect(
      find.textContaining('Everything stays on your devices'),
    );
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

  testWidgets('the dark-mode switch darkens the frame', (tester) async {
    await pumpShell(tester);
    await openTab(tester, 'Settings', 3);

    expect(find.text('Dark mode'), findsOneWidget);
    expect(find.text('Voice & speech'), findsOneWidget);
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold).first).backgroundColor,
      NexusUiColors.light.background,
    );

    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();

    expect(
      tester.widget<Scaffold>(find.byType(Scaffold).first).backgroundColor,
      NexusUiColors.dark.background,
    );
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
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
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

  testWidgets('a device that cannot listen gets an inert mic, not a mock', (
    tester,
  ) async {
    SpeechInput.override = () => const _UnavailableSpeechInput();
    addTearDown(() => SpeechInput.override = null);
    await pumpShell(tester);

    // The button is still there and still says what it is — but it explains
    // itself instead of opening a microphone this device does not have.
    final reason = find.byTooltip('Voice input isn’t set up on this device');
    expect(reason, findsOneWidget);
    expect(find.byIcon(Icons.mic_rounded), findsOneWidget);
    expect(
      tester
          .widget<InkWell>(
            find.descendant(of: reason, matching: find.byType(InkWell)),
          )
          .onTap,
      isNull,
    );

    await tester.tap(reason);
    await tester.pump();
    expect(stopButton(), findsNothing);
    expect(recordingIndicator, findsNothing);
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
      // answered before any recognizer is started.
      expect(ask.asks, 1);
      expect(mic.listens, 0);
      expect(log, isEmpty);
      expect(stopButton(), findsNothing);
      expect(recordingIndicator, findsNothing);

      await finger.up();
      await tester.pumpAndSettle();
      expect(log, isEmpty);
      expect(micButton(), findsNothing);

      // The reason is on the button and in the composer, not hidden behind a
      // gesture — a disabled control that explains itself is not a broken one.
      final String message =
          'Microphone permission needed — try again from '
          'system settings.';
      final reason = find.byTooltip(message);
      expect(reason, findsOneWidget);
      expect(find.text(message), findsOneWidget);
      expect(
        tester
            .widget<InkWell>(
              find.descendant(of: reason, matching: find.byType(InkWell)),
            )
            .onTap,
        isNull,
      );

      // And a second hold cannot re-ask or start anything.
      await tester.tap(reason);
      await tester.pumpAndSettle();
      expect(ask.asks, 1);
      expect(mic.listens, 0);
      expect(log, isEmpty);
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

  testWidgets('live conversation listens at once, then waits to be asked', (
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
    expect(
      tester.widget<Text>(find.byKey(kNexusLiveStatus)).data,
      'Mic off — tap to continue.',
    );

    // And that is where it stays. This is the bug the phone reported: the page
    // used to restart itself after a pause, so a room nobody had asked about was
    // being listened to again and again on a timer. No amount of time opens the
    // microphone now — there is no timer left in live conversation at all — and
    // the page keeps saying so while it waits.
    await tester.pump(const Duration(seconds: 30));
    expect(mic.listens, 1);
    expect(find.byKey(kNexusLiveRecordingIndicator), findsNothing);
    expect(find.byKey(kNexusLivePausedIndicator), findsOneWidget);
    expect(find.byKey(kNexusLiveResume), findsOneWidget);

    // The tap is the only way on, and it is a fresh turn: microphone open,
    // badges swapped, orb purple again.
    await tester.tap(find.byKey(kNexusLiveResume));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));
    expect(mic.listens, 2);
    expect(find.byKey(kNexusLiveRecordingIndicator), findsOneWidget);
    expect(find.byKey(kNexusLivePausedIndicator), findsNothing);
    expect(find.byKey(kNexusLiveOrbIdle), findsNothing);
    expect(
      tester.widget<Text>(find.byKey(kNexusLiveStatus)).data,
      'Listening — just speak.',
    );

    // The orb is the other half of that control — the obvious thing to press on
    // a page whose most prominent feature is a grey circle. It answers the
    // second turn the same way: words to the PC, answer on the page, wait.
    ollama.reply = 'Second answer.';
    mic.say('a second turn');
    await tester.pump();
    mic.hear('a second turn');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));
    expect(mic.listens, 2);
    expect(liveText(tester), 'Second answer.');
    await tester.tap(find.byKey(kNexusLiveOrb));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));
    expect(mic.listens, 3);
    expect(find.byKey(kNexusLiveRecordingIndicator), findsOneWidget);

    // Nothing any of that heard reached the composer underneath: live mode has
    // no draft in the field to overwrite. The composer is under an opaque route,
    // so it is offstage rather than gone — its state, and therefore its text, is
    // exactly what the route covered.
    expect(
      tester
          .widget<TextField>(find.byType(TextField, skipOffstage: false))
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
    expect(
      tester.widget<Text>(find.byKey(kNexusLiveStatus)).data,
      'Mic off — tap to continue.',
    );

    // No amount of time reopens the microphone...
    await tester.pump(const Duration(seconds: 30));
    expect(mic.listens, 1);
    expect(liveText(tester), 'Twenty degrees and clear.');

    // ...and the tap clears the page and starts listening again, as asked.
    await tester.tap(find.byKey(kNexusLiveResume));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));
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
    expect(
      tester.widget<Text>(find.byKey(kNexusLiveStatus)).data,
      'Mic off — tap to continue.',
    );

    // One ask per turn: a quiet room while the page waits cannot ask the
    // recognizer for anything a second time.
    mic.loudness(-2);
    await tester.pump();
    await tester.pump(kSpeechTurnGap + const Duration(milliseconds: 100));
    expect(mic.finishes, 1);
    expect(mic.listens, 1);
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

    // Flip the one switch that owns the frame, then open the room: the live page
    // is the theme's, so dark mode gets the immersive ground it was designed
    // around while light mode gets the light one above.
    await openTab(tester, 'Settings', 3);
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
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

  testWidgets('live conversation is inert where the microphone is', (
    tester,
  ) async {
    SpeechInput.override = () => const _UnavailableSpeechInput();
    addTearDown(() => SpeechInput.override = null);
    await pumpShell(tester);

    final live = find.byTooltip('Live conversation isn’t available here');
    expect(live, findsOneWidget);
    expect(
      tester
          .widget<InkWell>(
            find.descendant(of: live, matching: find.byType(InkWell)),
          )
          .onTap,
      isNull,
    );
    await tester.tap(live);
    await tester.pump();
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
}
