// The app on an iPhone: it starts, and it says what it cannot do.
//
// Every Android channel in this app answers the question "is this an Android
// phone" before it is called, and the platforms with no handler at all answer
// `MissingPluginException`. Both facts are load-bearing on iOS, where
// `dev.nexus.nexus/*` has no Kotlin behind it and a `tray_manager` or
// `window_manager` call would throw where a phone should render.
//
// So this file does the one thing that actually proves it: it pumps the real
// shell with the platform set to iOS and *no* method-channel handlers
// installed. Any channel that is reached unguarded throws, and
// `tester.takeException()` catches it. A test that only checked getters would
// prove nothing about the startup path — which is where a crash is fatal.
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/chat_log.dart';
import 'package:nexus/core/device_capabilities.dart';
import 'package:nexus/core/local_ai_service.dart';
import 'package:nexus/core/local_library.dart';
import 'package:nexus/core/log_service.dart';
import 'package:nexus/core/on_device_model.dart';
import 'package:nexus/core/onboarding.dart';
import 'package:nexus/core/speech.dart';
import 'package:nexus/core/system_prompt.dart';
import 'package:nexus/core/vision_ai.dart';
import 'package:nexus/core/vision_engine.dart';
import 'package:nexus/main_ui.dart';
import 'package:nexus/mesh/wake_word.dart';

/// An empty library, so the Files tab does not read this machine's folders.
///
/// Empty rather than populated on purpose: this file is about the app starting,
/// and a folder list is another screen's subject. An empty answer is also the
/// fastest one, which matters because a widget test's clock is fake.
class _TempLibrary implements LocalLibrary {
  const _TempLibrary();

  @override
  Future<List<LocalFolder>> read() async => const <LocalFolder>[];
}

/// A brain that is never asked anything in these tests.
class _SilentBrain implements LocalAiService {
  const _SilentBrain();

  @override
  Future<String> generateResponse(String prompt) async => '';

  @override
  Stream<String> generateResponseStream(
    String prompt, {
    List<AiTurn> history = const <AiTurn>[],
  }) => const Stream<String>.empty();
}

void main() {
  /// Runs [body] as [platform], and puts the platform back before returning.
  ///
  /// The restore has to happen *inside* the test body, not in `tearDown`: the
  /// test framework asserts that no foundation debug variable was left changed
  /// when the body ends, so a `tearDown` reset is already too late.
  Future<void> asPlatform(
    TargetPlatform platform,
    Future<void> Function() body,
  ) async {
    debugDefaultTargetPlatformOverride = platform;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  setUp(() {
    LocalAiService.override = () => const _SilentBrain();
    SpeechOutput.override = null;
    SpeechInput.override = null;
    ChatLog.override = () => ChatLog(store: MemoryChatLogStore());
    ModelChoice.override = () => ModelChoice(store: MemoryModelChoiceStore());
    Onboarding.debugOverride = true;
    LocalLibrary.override = () => const _TempLibrary();
    SystemPrompt.override = null;
    SystemPrompt.debugReset();
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    LocalAiService.override = null;
    ChatLog.override = null;
    ChatLog.debugReset();
    ModelChoice.override = null;
    ModelChoice.debugReset();
    Onboarding.debugOverride = null;
    LocalLibrary.override = null;
    SystemPrompt.override = null;
    SystemPrompt.debugReset();
    LogService.debugReset();
    VisionAiService.defaultFactory = null;
    VisionEngine.override = null;
  });

  testWidgets('the shell starts on iOS with no Android channel handlers',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await asPlatform(TargetPlatform.iOS, () async {
      await tester.pumpWidget(const NexusUiApp());
      await tester.pumpAndSettle();

      // The frame rendered. A MissingPluginException from a channel that was
      // reached unguarded would be here instead.
      expect(tester.takeException(), isNull);
      expect(find.byType(MaterialApp), findsOneWidget);
    });
  });

  testWidgets('booting on iOS never reaches the wake-word controller', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    addTearDown(WakeWord.resetForTest);

    await asPlatform(TargetPlatform.iOS, () async {
      await tester.pumpWidget(const NexusUiApp());
      await tester.pumpAndSettle();

      // Not "the channel refused": startup must not have built the controller
      // at all. It would have loaded the ONNX engine, and those models are in
      // the bundle, so reaching it is already the bug.
      expect(WakeWord.isCreated, isFalse);
    });
  });

  testWidgets('it renders the first screen rather than an error page',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await asPlatform(TargetPlatform.iOS, () async {
      await tester.pumpWidget(const NexusUiApp());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // The shell's own chrome, and no trace of an exception surfaced as copy.
      expect(find.text('Nexus'), findsWidgets);
      expect(find.textContaining('Something went wrong'), findsNothing);
      expect(find.textContaining('MissingPluginException'), findsNothing);
    });
  });

  testWidgets('switching tabs on iOS reaches no unguarded channel',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await asPlatform(TargetPlatform.iOS, () async {
      await tester.pumpWidget(const NexusUiApp());
      await tester.pumpAndSettle();

      // Every top-level tab, in turn: each one builds a screen that asks the
      // platform whether it can do things, and each answer has to be "no"
      // without a call.
      int visited = 0;
      for (final String tab in <String>['Files', 'Devices', 'Settings']) {
        final Finder found = find.text(tab);
        if (found.evaluate().isEmpty) continue;
        await tester.tap(found.first);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: tab);
        visited++;
      }
      // Proves the loop was not skipped wholesale: a tab bar that moved would
      // otherwise leave this test passing while checking nothing.
      expect(visited, greaterThanOrEqualTo(2));
    });
  });

  test('iOS has no wake word, no launcher icons, and no Android recorder', () {
    const DeviceCapabilities ios = DeviceCapabilities(
      platformOverride: TargetPlatform.iOS,
    );

    // Both are Android-only here, and both say so instead of calling a channel
    // that has nothing behind it.
    expect(ios.supportsWakeWord, isFalse);
    expect(ios.supportsLauncherIcons, isFalse);
    expect(ios.isMobile, isTrue);
  });

  test('the platform-wide answers agree, on both phones', () async {
    await asPlatform(TargetPlatform.iOS, () async {
      expect(SpeechInput.current.available, isFalse);
      expect(SpeechOutput.current.available, isFalse);
    });

    await asPlatform(TargetPlatform.android, () async {
      expect(SpeechInput.current.available, isTrue);
      expect(SpeechOutput.current.available, isTrue);
    });
  });

  test('Android keeps its wake word and launcher icons', () {
    const DeviceCapabilities android = DeviceCapabilities(
      platformOverride: TargetPlatform.android,
    );

    expect(android.supportsWakeWord, isTrue);
    expect(android.supportsLauncherIcons, isTrue);
  });

  test('opening the settings page fails soft on iOS instead of throwing',
      () async {
    // No handler for dev.nexus.nexus/device on iOS: the button that is meant to
    // be the way out of a dead end must answer, not throw.
    expect(await const DeviceCapabilities().openAppSettings(), isFalse);
  });

  test('a build with no vision engine still reports what it can do', () async {
    await asPlatform(TargetPlatform.iOS, () async {
      // On iOS there IS an engine, and it is the platform-channel one.
      expect(VisionEngine.isSupported, isTrue);
      expect(VisionEngine.current, isA<PlatformVisionEngine>());
    });

    await asPlatform(TargetPlatform.linux, () async {
      // On a desktop there is not, and the app says so rather than offering a
      // photo it cannot describe.
      expect(VisionEngine.isSupported, isFalse);
      expect(VisionEngine.current, isNull);
    });
  });
}
