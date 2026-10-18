// The first run: which model the app recommends, what the welcome screen does
// with that answer, and — the part that has to hold — that the app never shows
// it twice.
//
// The device is a parameter here, not the machine running the suite: the RAM is
// injected, so an 8 GB phone and a 4 GB phone are two lines apart. The download
// is a fake fetcher pointed at a temp directory, in the shape `main_ui_test`
// already uses for the Settings download row, because what is being tested is
// which file the decision produces, not whether a socket works.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/device_memory.dart';
import 'package:nexus/core/llm.dart';
import 'package:nexus/core/on_device_ai_service.dart';
import 'package:nexus/core/on_device_model.dart';
import 'package:nexus/core/onboarding.dart';
import 'package:nexus/main_ui.dart'
    show
        kNexusWelcomeDownload,
        kNexusWelcomeProgress,
        kNexusWelcomeSkip,
        NexusTheme,
        NexusUiApp,
        WelcomeView;
import 'package:shared_preferences/shared_preferences.dart';

/// A fetcher that reports progress and writes the file the *model* names — the
/// one thing about a download this screen is responsible for.
class _FakeDownload extends Llm {
  _FakeDownload({required super.model, required this.dir})
    : super(modelsDir: () async => dir);

  final Directory dir;
  final List<double> progress = <double>[];

  @override
  Future<bool> download({void Function(double progress)? onProgress}) async {
    for (final double step in <double>[0.25, 0.5, 1]) {
      progress.add(step);
      onProgress?.call(step);
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    File('${dir.path}/${model.name}.gguf').writeAsBytesSync(<int>[1, 2, 3]);
    return true;
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  late Directory dir;
  late ModelChoice choice;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nexus_welcome');
    choice = ModelChoice(store: MemoryModelChoiceStore());
    ModelChoice.override = () => choice;
    // A store that answers, and starts empty: this device has never run Nexus.
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() {
    ModelChoice.override = null;
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// Pumps the welcome screen on a stated device, with a fetcher that writes
  /// into [dir] instead of over the wire.
  Future<void> pumpWelcome(
    WidgetTester tester, {
    required int? ramBytes,    String? presentFile,
  }) async {
    if (presentFile != null) {
      File('${dir.path}/$presentFile').writeAsBytesSync(<int>[1]);
    }
    await tester.pumpWidget(
      MaterialApp(
        theme: NexusTheme.light(),
        home: WelcomeView(
          ramProbe: () async => ramBytes,
          onDevice: OnDeviceAiService(
            model: OnDeviceModel(
              directory: () async => dir,
              engine: () => _FakeDownload(
                model: OnDeviceModelChoice.qwen.weights,
                dir: dir,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('which model a device is offered', () {
    test('is the bigger one above six gigabytes, and the small one below', () {
      // 8 GB — the phone this screen was written for.
      expect(
        recommendedModel(8 * 1024 * 1024 * 1024),
        OnDeviceModelChoice.llama,
      );
      // Exactly 6 GB is not *above* six gigabytes, and the smaller model is the
      // safe side of that line: the A25 this app runs on has 6.
      expect(
        recommendedModel(6 * 1024 * 1024 * 1024),
        OnDeviceModelChoice.qwen,
      );
      expect(
        recommendedModel(4 * 1024 * 1024 * 1024),
        OnDeviceModelChoice.qwen,
      );
      // A device that will not say gets the model that cannot hurt it: a guess
      // *down* costs a slower answer, a guess *up* costs most of a minute of
      // download on a phone that may not be able to run it.
      expect(recommendedModel(null), OnDeviceModelChoice.qwen);
    });

    test('the memory is reported in the words the screen uses', () {
      expect(DeviceMemory.label(8 * 1024 * 1024 * 1024), '8 GB');
      expect(DeviceMemory.label(6 * 1024 * 1024 * 1024), '6 GB');
      expect(DeviceMemory.label(512 * 1024 * 1024), '512 MB');
      expect(DeviceMemory.label(null), 'Could not tell');
      expect(DeviceMemory.label(0), 'Could not tell');
    });

    test('the reason names the memory either way, so it can be checked', () {
      expect(
        recommendationReason(8 * 1024 * 1024 * 1024, OnDeviceModelChoice.llama),
        contains('8 GB'),
      );
      expect(
        recommendationReason(4 * 1024 * 1024 * 1024, OnDeviceModelChoice.qwen),
        contains('4 GB'),
      );
      expect(
        recommendationReason(null, OnDeviceModelChoice.qwen),
        contains('could not read'),
      );
    });

    test('reads this machine without a platform channel', () async {
      // Whatever the suite runs on: Linux answers from /proc/meminfo, and a
      // platform with neither that file nor the plugin answers null — both are
      // answers, and neither throws.
      final int? ram = await DeviceMemory.totalBytes();
      if (ram != null) expect(ram, greaterThan(0));
    });
  });

  group('the welcome screen', () {
    testWidgets('says what it is for, and which model this device gets', (
      tester,
    ) async {
      await pumpWelcome(tester, ramBytes: 8 * 1024 * 1024 * 1024);

      expect(find.text('Welcome to Nexus.'), findsOneWidget);
      expect(find.text("Let's get your private AI set up."), findsOneWidget);
      expect(find.text('This device has 8 GB of RAM'), findsOneWidget);
      expect(find.text('Recommended: Llama 3.2 1B'), findsOneWidget);
      expect(find.textContaining('771 MB'), findsOneWidget);
      expect(find.text('Download Recommended AI'), findsOneWidget);
      expect(find.text('Skip for now'), findsOneWidget);
    });

    testWidgets('a smaller phone is offered the smaller model', (tester) async {
      await pumpWelcome(tester, ramBytes: 4 * 1024 * 1024 * 1024);

      expect(find.text('This device has 4 GB of RAM'), findsOneWidget);
      expect(find.text('Recommended: Qwen 2.5 0.5B'), findsOneWidget);
      // The size that goes with it, and not the other model's.
      expect(find.textContaining('469 MB'), findsOneWidget);
      expect(find.textContaining('771 MB'), findsNothing);
    });

    testWidgets('downloading fetches the recommended model, and lets the user '
        'in', (tester) async {
      int done = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: NexusTheme.light(),
          home: WelcomeView(
            ramProbe: () async => 8 * 1024 * 1024 * 1024,
            onDone: () => done++,
            onDevice: OnDeviceAiService(
              model: OnDeviceModel(
                directory: () async => dir,
                engine: () => _FakeDownload(
                  // The 1B names its own file; the fake writes what it is told.
                  model: OnDeviceModelChoice.llama.weights,
                  dir: dir,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(kNexusWelcomeDownload));
      await tester.pump();
      expect(find.byKey(kNexusWelcomeProgress), findsOneWidget);
      await tester.pumpAndSettle();

      // The file the brain will look for is on disk, and the selection points at
      // it — one decision, made where the user made it.
      expect(
        File('${dir.path}/${OnDeviceModelChoice.llama.fileName}').existsSync(),
        isTrue,
      );
      expect(choice.choice, OnDeviceModelChoice.llama);
      expect(await Onboarding.isDone(), isTrue);
      expect(done, 1);
    });

    testWidgets('skipping leaves without a download and is not asked again', (
      tester,
    ) async {
      await pumpWelcome(tester, ramBytes: 4 * 1024 * 1024 * 1024);

      await tester.tap(find.byKey(kNexusWelcomeSkip));
      await tester.pumpAndSettle();

      expect(await Onboarding.isDone(), isTrue);
      expect(dir.listSync(), isEmpty);
      // The recommendation is still what Settings will offer to download.
      expect(choice.choice, OnDeviceModelChoice.qwen);
    });

    testWidgets('a model already on disk is not downloaded twice', (
      tester,
    ) async {
      await pumpWelcome(
        tester,
        ramBytes: 4 * 1024 * 1024 * 1024,
        presentFile: OnDeviceModelChoice.qwen.fileName,
      );

      expect(find.text('Qwen 2.5 0.5B — already downloaded'), findsOneWidget);
      expect(find.text('Start chatting'), findsOneWidget);
      expect(find.text('Download Recommended AI'), findsNothing);
    });
  });

  group('the flag', () {
    testWidgets('starts unanswered, and is written once it has been answered', (
      tester,
    ) async {
      expect(await Onboarding.isDone(), isFalse);
      await Onboarding.complete();
      expect(await Onboarding.isDone(), isTrue);
    });

    testWidgets('decides which screen a fresh install opens on, once', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        Onboarding.key: false,
      });
      await tester.pumpWidget(const NexusUiApp(key: ValueKey<String>('fresh')));
      await tester.pumpAndSettle();
      expect(find.text('Welcome to Nexus.'), findsOneWidget);
      expect(find.text('Hey, what do you need?'), findsNothing);

      // The same app, one launch later — a new state, so the preference is read
      // again rather than remembered from the first screen.
      SharedPreferences.setMockInitialValues(<String, Object>{
        Onboarding.key: true,
      });
      await tester.pumpWidget(const NexusUiApp(key: ValueKey<String>('next')));
      await tester.pumpAndSettle();
      expect(find.text('Welcome to Nexus.'), findsNothing);
      expect(find.text('Hey, what do you need?'), findsOneWidget);
    });
  });
}
