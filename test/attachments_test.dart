// The composer's two attachment doors, end to end at the level a widget test
// can reach: the store that keeps the bytes, the caption and prompt one
// decision makes, the bubble that draws a picture in the thread, and the
// full-screen viewer behind a tap.
//
// The camera itself is not opened here — a widget test has no lens — so
// CameraPage is walked only as far as its own fallback, and the screenshot is
// driven through the same seam the phone uses ([ScreenCapture.override]) with a
// real PNG on disk. That is the whole capture path minus the platform dialog.
import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart' show CameraDescription;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:nexus/core/attachments.dart';
import 'package:nexus/core/chat_log.dart';
import 'package:nexus/core/local_ai_service.dart';
import 'package:nexus/core/onboarding.dart';
import 'package:nexus/core/screen_capture.dart';
import 'package:nexus/core/system_actions.dart';
import 'package:nexus/main_ui.dart';
import 'package:nexus/ui/camera_page.dart';
import 'package:nexus/ui/image_viewer_page.dart';

/// The store, without the disk.
///
/// A widget test runs inside fake time, where a real file read never completes
/// — the copy itself is proven in the plain tests below, where time is real.
/// Here the point is the wiring: the capture's path reaches the thread, the
/// log and the bubble unchanged.
class _MemoryStore extends AttachmentStore {
  _MemoryStore() : super(directory: () async => null);

  @override
  Future<String?> keep(String sourcePath, {required AttachmentKind kind}) async =>
      sourcePath;
}

/// A brain that answers immediately and remembers what it was asked.
class _EchoBrain implements LocalAiService {
  final List<String> prompts = <String>[];

  @override
  Stream<String> generateResponseStream(
    String prompt, {
    List<AiTurn> history = const <AiTurn>[],
  }) {
    prompts.add(prompt);
    return Stream<String>.value('Okay.');
  }

  @override
  Future<String> generateResponse(String prompt) =>
      generateResponseStream(prompt).join();
}

/// The smallest valid PNG: one opaque black pixel, so a real decoder accepts
/// the file rather than the bubble falling back to its placeholder.
const List<int> _onePixelPng = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
  0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41,
  0x54, 0x08, 0xD7, 0x63, 0x60, 0x60, 0x60, 0x00,
  0x00, 0x00, 0x04, 0x00, 0x01, 0x27, 0x34, 0x27,
  0x0A, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
  0x44, 0xAE, 0x42, 0x60, 0x82,
];

void main() {
  setUpAll(() {
    // No network for Inter in a test; the fallback font is what every other
    // shell test uses.
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  late _EchoBrain brain;
  late ChatLog chat;

  setUp(() {
    brain = _EchoBrain();
    LocalAiService.override = () => brain;
    AttachmentStore.override = _MemoryStore.new;
    chat = ChatLog(store: MemoryChatLogStore());
    ChatLog.override = () => chat;
    SystemActions.override = null;
    Onboarding.debugOverride = true;
  });

  tearDown(() {
    LocalAiService.override = null;
    ChatLog.override = null;
    ChatLog.debugReset();
    Onboarding.debugOverride = null;
    ScreenCapture.override = null;
    AttachmentStore.override = null;
  });

  /// A phone-shaped surface, the layout the composer is designed against.
  Future<void> pumpShell(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const NexusUiApp());
    await tester.pumpAndSettle();
  }

  /// A temporary PNG that looks like a capture.
  Future<File> shot() async {
    final Directory dir = await Directory.systemTemp.createTemp('nexus-shot-');
    addTearDown(() => dir.delete(recursive: true));
    final File file = File('${dir.path}/shot.png');
    await file.writeAsBytes(_onePixelPng);
    return file;
  }

  group('the caption and the prompt are one decision', () {
    test('a photo is captioned and described exactly as the model is told', () {
      expect(AttachmentKind.photo.caption, 'Photo attached');
      expect(AttachmentKind.photo.prompt, '[User attached a photo]');
    });

    test('a screenshot says what it is, in both places', () {
      expect(AttachmentKind.screenshot.caption, 'Screenshot attached');
      expect(AttachmentKind.screenshot.prompt, '[User attached a screenshot]');
    });
  });

  group('the store', () {
    test('copies a capture into its folder and answers the copy', () async {
      final Directory folder = await Directory.systemTemp.createTemp(
        'nexus-store-',
      );
      addTearDown(() => folder.delete(recursive: true));
      final File source = await shot();
      final AttachmentStore store = AttachmentStore(
        directory: () async => folder,
      );

      final String? kept = await store.keep(
        source.path,
        kind: AttachmentKind.photo,
      );

      expect(kept, isNotNull);
      expect(kept, isNot(source.path));
      expect(kept, startsWith(folder.path));
      expect(File(kept!).existsSync(), isTrue);
      expect(await File(kept).length(), _onePixelPng.length);
      // The name says what it is, so the folder is readable by a human.
      expect(kept.split('/').last, startsWith('photo-'));
    });

    test('keeps the capture where it is when there is no folder', () async {
      final File source = await shot();
      final AttachmentStore store = AttachmentStore(directory: () async => null);

      expect(
        await store.keep(source.path, kind: AttachmentKind.screenshot),
        source.path,
      );
    });

    test('answers null for a capture that has already gone', () async {
      final Directory folder = await Directory.systemTemp.createTemp(
        'nexus-gone-',
      );
      addTearDown(() => folder.delete(recursive: true));
      final AttachmentStore store = AttachmentStore(
        directory: () async => folder,
      );

      expect(
        await store.keep('${folder.path}/never-existed.png',
            kind: AttachmentKind.photo),
        isNull,
      );
    });

    test('clear removes every kept picture', () async {
      final Directory folder = await Directory.systemTemp.createTemp(
        'nexus-clear-',
      );
      // clear() deletes the folder itself, so the cleanup tolerates its absence.
      addTearDown(() async {
        if (await folder.exists()) await folder.delete(recursive: true);
      });
      final File source = await shot();
      final AttachmentStore store = AttachmentStore(
        directory: () async => folder,
      );
      final String? kept = await store.keep(
        source.path,
        kind: AttachmentKind.photo,
      );

      await store.clear();

      expect(File(kept!).existsSync(), isFalse);
      expect(folder.existsSync(), isFalse);
    });
  });

  group('the stored line', () {
    test('carries the picture beside its caption', () {
      const ChatEntry entry = ChatEntry(
        'Photo attached',
        mine: true,
        imagePath: '/tmp/shot.png',
      );

      final Map<String, Object?> json = entry.toJson();
      expect(json['image'], '/tmp/shot.png');

      final ChatEntry? read = ChatEntry.fromJson(
        Map<String, Object?>.of(json),
      );
      expect(read!.imagePath, '/tmp/shot.png');
      expect(read.text, 'Photo attached');
      expect(read.mine, isTrue);
    });

    test('a line with no picture stores no image key', () {
      expect(const ChatEntry('hello').toJson().containsKey('image'), isFalse);
    });

    test('an unreadable image value is dropped, not the line', () {
      final ChatEntry? read = ChatEntry.fromJson(<String, Object?>{
        'text': 'Photo attached',
        'image': 42,
      });
      expect(read, isNotNull);
      expect(read!.imagePath, isNull);
      expect(read.text, 'Photo attached');
    });
  });

  group('the composer', () {
    testWidgets('offers a camera and a screen beside the field', (
      tester,
    ) async {
      await pumpShell(tester);

      expect(find.byKey(kAttachCamera), findsOneWidget);
      expect(find.byKey(kAttachScreen), findsOneWidget);
      expect(find.byTooltip(AttachmentKind.photo.action), findsOneWidget);
      expect(find.byTooltip(AttachmentKind.screenshot.action), findsOneWidget);

      // Small, because the field shares the row with two voice controls.
      final Size size = tester.getSize(find.byKey(kAttachCamera));
      expect(size.width, lessThanOrEqualTo(34));
      expect(size.height, lessThanOrEqualTo(34));
    });

    testWidgets('the camera opens the capture page, and X comes back', (
      tester,
    ) async {
      await pumpShell(tester);

      await tester.tap(find.byKey(kAttachCamera));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byKey(kCameraClose), findsOneWidget);

      await tester.tap(find.byKey(kCameraClose));
      await tester.pumpAndSettle();
      expect(find.byKey(kCameraClose), findsNothing);
      expect(find.text('Message Nexus'), findsOneWidget);
    });

    testWidgets('a device with no camera says so instead of a black screen', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: CameraPage(
            cameras: () async => const <CameraDescription>[],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text(kCameraUnavailableText), findsOneWidget);
      expect(find.byKey(kCameraClose), findsOneWidget);
      expect(find.byKey(kCameraShutter), findsNothing);
    });

    testWidgets('a screenshot becomes a thumbnail and the brain is told', (
      tester,
    ) async {
      // Real file IO has to run outside the fake clock a widget test uses,
      // or it never completes.
      final File file = (await tester.runAsync(shot))!;
      ScreenCapture.override = () async => ScreenCaptureResult(file.path);
      await pumpShell(tester);

      await tester.tap(find.byKey(kAttachScreen));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      // The user's turn: the caption, and a picture in the same bubble.
      expect(find.text('Screenshot attached'), findsOneWidget);
      expect(find.byType(NexusAttachmentBubble), findsOneWidget);
      // The brain never receives the picture — it receives the sentence.
      expect(brain.prompts, <String>['[User attached a screenshot]']);
      // And the conversation remembers the file, not only the words.
      final ChatEntry stored = chat.entries.firstWhere(
        (ChatEntry e) => e.text == 'Screenshot attached',
      );
      expect(stored.imagePath, isNotNull);
      expect(File(stored.imagePath!).existsSync(), isTrue);
    });

    testWidgets('a refused screenshot explains itself and adds no bubble', (
      tester,
    ) async {
      ScreenCapture.override = () async => const ScreenCaptureResult(
        null,
        'Screen capture was not allowed.',
      );
      await pumpShell(tester);

      await tester.tap(find.byKey(kAttachScreen));
      await tester.pumpAndSettle();

      expect(find.text('Screen capture was not allowed.'), findsOneWidget);
      expect(find.byType(NexusAttachmentBubble), findsNothing);
      expect(brain.prompts, isEmpty);
    });
  });

  group('the image bubble', () {
    testWidgets('tapping it opens the full-screen viewer, and closes again', (
      tester,
    ) async {
      // Real file IO has to run outside the fake clock a widget test uses,
      // or it never completes.
      final File file = (await tester.runAsync(shot))!;
      ScreenCapture.override = () async => ScreenCaptureResult(file.path);
      await pumpShell(tester);

      await tester.tap(find.byKey(kAttachScreen));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(NexusAttachmentBubble));
      await tester.pumpAndSettle();

      expect(find.byKey(kImageViewerClose), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsOneWidget);

      await tester.tap(find.byKey(kImageViewerClose));
      await tester.pumpAndSettle();
      expect(find.byKey(kImageViewerClose), findsNothing);
      expect(find.byType(NexusAttachmentBubble), findsOneWidget);
    });

    testWidgets('a restored conversation still shows the picture', (
      tester,
    ) async {
      // Real file IO has to run outside the fake clock a widget test uses,
      // or it never completes.
      final File file = (await tester.runAsync(shot))!;
      // One instance for the whole test: the screen attaches, restores and
      // listens to the same log, or the restore lands in a different one.
      chat = ChatLog(
        store: MemoryChatLogStore(<ChatEntry>[
          ChatEntry('Photo attached', mine: true, imagePath: file.path),
          const ChatEntry('Looks like a cat.'),
        ]),
      );
      ChatLog.override = () => chat;

      await pumpShell(tester);

      expect(find.byType(NexusAttachmentBubble), findsOneWidget);
      expect(find.text('Photo attached'), findsOneWidget);
      expect(find.text('Looks like a cat.'), findsOneWidget);
    });

    testWidgets('a picture that has gone keeps its caption', (tester) async {
      chat = ChatLog(
        store: MemoryChatLogStore(<ChatEntry>[
          const ChatEntry(
            'Photo attached',
            mine: true,
            imagePath: '/tmp/nexus-not-here.png',
          ),
        ]),
      );
      ChatLog.override = () => chat;

      await pumpShell(tester);
      // The missing file is discovered asynchronously by the image loader, so
      // the placeholder arrives a frame or two after the bubble does.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(NexusAttachmentBubble), findsOneWidget);
      expect(find.text('Photo attached'), findsOneWidget);
      expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
    });
  });
}
