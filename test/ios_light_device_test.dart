// The iPhone as a light device: the screens say what this phone can do.
//
// Two failures are possible here and both are copy failures, not crashes:
//
//   1. Offering a control that cannot work. The vision rows used to be drawn on
//      every platform, so an iPhone was invited to download 545 MB and 1.6 GB
//      of GGUF weights that only the on-device engine can load — and iOS has no
//      on-device engine in this build. Rules §1: never show a control that
//      does nothing.
//
//   2. Saying nothing at all. A phone that silently cannot do half of what the
//      other one can looks broken rather than limited. Rules §7: name what does
//      work in the same breath as what does not.
//
// So this file drives the real Settings screen on both platforms and checks the
// words, because the words are the feature.
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/chat_log.dart';
import 'package:nexus/core/local_ai_service.dart';
import 'package:nexus/core/local_library.dart';
import 'package:nexus/core/log_service.dart';
import 'package:nexus/core/onboarding.dart';
import 'package:nexus/core/system_prompt.dart';
import 'package:nexus/core/vision_ai.dart';
import 'package:nexus/core/vision_ai_service.dart';
import 'package:nexus/core/vision_engine.dart';
import 'package:nexus/main_ui.dart';

class _EmptyLibrary implements LocalLibrary {
  const _EmptyLibrary();

  @override
  Future<List<LocalFolder>> read() async => const <LocalFolder>[];
}

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
    ChatLog.override = () => ChatLog(store: MemoryChatLogStore());
    Onboarding.debugOverride = true;
    LocalLibrary.override = () => const _EmptyLibrary();
    SystemPrompt.override = null;
    SystemPrompt.debugReset();
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    LocalAiService.override = null;
    ChatLog.override = null;
    ChatLog.debugReset();
    Onboarding.debugOverride = null;
    LocalLibrary.override = null;
    SystemPrompt.override = null;
    SystemPrompt.debugReset();
    LogService.debugReset();
    VisionAiService.defaultFactory = null;
    VisionEngine.override = null;
  });

  /// Opens the app and lands on Settings.
  Future<void> openSettings(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const NexusUiApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Settings').last);
    await tester.pumpAndSettle();
  }

  testWidgets('an iPhone is told it is the light device, and what that means',
      (WidgetTester tester) async {
    await asPlatform(TargetPlatform.iOS, () async {
      await openSettings(tester);

      final Finder light = find.text('Light device');
      await tester.scrollUntilVisible(
        light,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      expect(light, findsOneWidget);
      // What works, named first — pairing, files, clipboard — and where the
      // heavy work went.
      expect(
        find.textContaining('Pairing, files, and clipboard work here'),
        findsOneWidget,
      );
      expect(find.textContaining('Your PC runs the heavy AI'), findsOneWidget);

      // And what does not, in one sentence.
      expect(find.text('Not on this phone'), findsOneWidget);
      expect(
        find.textContaining(
          'Wake word, background sync, and remote control are not available',
        ),
        findsOneWidget,
      );
    });
  });

  testWidgets('and is not offered a vision model it cannot load',
      (WidgetTester tester) async {
    await asPlatform(TargetPlatform.iOS, () async {
      await openSettings(tester);

      final Finder vision = find.text('Vision model');
      await tester.scrollUntilVisible(
        vision,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      // The row is there, and it is a statement, not a download.
      expect(vision, findsOneWidget);
      expect(find.text(kVisionModelOnSystemText), findsOneWidget);

      // Nothing that offers to fetch weights the phone cannot run.
      expect(find.text('Download model'), findsNothing);
      expect(find.byKey(kNexusVisionProgress), findsNothing);
    });
  });

  testWidgets('Android still gets its downloads and no light-device notice',
      (WidgetTester tester) async {
    await asPlatform(TargetPlatform.android, () async {
      await openSettings(tester);

      // The notice is an iOS fact, so it is absent where the work happens here.
      expect(find.text('Light device'), findsNothing);
      expect(find.text('Not on this phone'), findsNothing);

      // And the vision rows are the real ones. Android can run the model, so
      // the sentence for a phone that cannot is not on screen.
      final Finder scrollable = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.textContaining('SmolVLM'),
        200,
        scrollable: scrollable,
      );
      await tester.pumpAndSettle();

      expect(find.text(kVisionModelOnSystemText), findsNothing);
      expect(find.text(kVisionModelMissingText), findsNothing);
    });
  });

  test('the two sentences say different things, and both are honest', () {
    // iOS reads the photo itself with Vision; a desktop reads nothing. One
    // sentence cannot be true on both, which is why there are two.
    expect(kVisionModelOnSystemText, isNot(kVisionModelMissingText));
    expect(kVisionModelOnSystemText, contains('this phone'));
    expect(kVisionModelMissingText, contains('Connect to a PC'));
  });
}
