// The composer's two attachment doors, end to end at the level a widget test
// can reach: the store that keeps the bytes, the caption and prompt one
// decision makes, the bubble that draws a picture in the thread, and the
// full-screen viewer behind a tap.
//
// The phone camera itself is not opened here — a widget test has no lens — so
// the camera door is driven through [AttachmentPickers.override], the same seam
// the composer uses, and the screenshot is driven through the same seam the
// phone uses ([ScreenCapture.override]) with a real PNG on disk. That is the
// whole capture path minus the system apps.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show DebugPrintCallback, debugPrint;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:nexus/core/attachment_pickers.dart';
import 'package:nexus/core/attachments.dart';
import 'package:nexus/core/chat_log.dart';
import 'package:nexus/core/local_ai_service.dart';
import 'package:nexus/core/local_library.dart';
import 'package:nexus/core/ml_vision_service.dart';
import 'package:nexus/core/onboarding.dart';
import 'package:nexus/core/system_actions.dart';
import 'package:nexus/core/vision_ai.dart';
import 'package:nexus/main_ui.dart';
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
  Future<String?> keep(
    String sourcePath, {
    required AttachmentKind kind,
  }) async => sourcePath;
}

/// The gallery and the file browser, answered by the test instead of a
/// platform dialog. Records which door was opened, and hands back whatever the
/// test put in it.
class _FakePickers implements AttachmentPickers {
  PickedAttachment? camera;
  PickedAttachment? image;
  PickedAttachment? file;
  int cameraPicks = 0;
  int imagePicks = 0;
  int filePicks = 0;

  @override
  Future<PickedAttachment?> captureImage() async {
    cameraPicks++;
    return camera;
  }

  @override
  Future<PickedAttachment?> pickImage() async {
    imagePicks++;
    return image;
  }

  @override
  Future<PickedAttachment?> pickFile() async {
    filePicks++;
    return file;
  }
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
  late _FakePickers pickers;

  setUp(() {
    brain = _EchoBrain();
    LocalAiService.override = () => brain;
    AttachmentStore.override = _MemoryStore.new;
    pickers = _FakePickers();
    AttachmentPickers.override = () => pickers;
    VisionAiService.override = null;
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
    AttachmentStore.override = null;
    AttachmentPickers.override = null;
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

    test('a gallery pick is a photo, and a file is not', () {
      expect(AttachmentKind.gallery.caption, 'Photo attached');
      expect(AttachmentKind.gallery.isImage, isTrue);
      expect(AttachmentKind.document.caption, 'File attached');
      expect(AttachmentKind.document.isImage, isFalse);
      expect(AttachmentKind.document.noun, 'file');
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
      final AttachmentStore store = AttachmentStore(
        directory: () async => null,
      );

      expect(
        await store.keep(source.path, kind: AttachmentKind.screenshot),
        source.path,
      );
    });

    test('keeps a document under its own extension', () async {
      final Directory folder = await Directory.systemTemp.createTemp(
        'nexus-doc-',
      );
      addTearDown(() => folder.delete(recursive: true));
      final File source = File('${folder.path}/notes.pdf');
      await source.writeAsString('hello');
      final AttachmentStore store = AttachmentStore(
        directory: () async => folder,
      );

      final String? kept = await store.keep(
        source.path,
        kind: AttachmentKind.document,
      );

      expect(kept, endsWith('.pdf'));
      expect(File(kept!).existsSync(), isTrue);
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
        await store.keep(
          '${folder.path}/never-existed.png',
          kind: AttachmentKind.photo,
        ),
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

      final ChatEntry? read = ChatEntry.fromJson(Map<String, Object?>.of(json));
      expect(read!.imagePath, '/tmp/shot.png');
      expect(read.text, 'Photo attached');
      expect(read.mine, isTrue);
    });

    test('a line with no picture stores no image key', () {
      expect(const ChatEntry('hello').toJson().containsKey('image'), isFalse);
    });

    test('carries a document path beside its caption', () {
      const ChatEntry entry = ChatEntry(
        'File attached: notes.pdf',
        mine: true,
        filePath: '/tmp/notes.pdf',
      );
      final Map<String, Object?> json = entry.toJson();
      expect(json['file'], '/tmp/notes.pdf');
      final ChatEntry? read = ChatEntry.fromJson(Map<String, Object?>.of(json));
      expect(read!.filePath, '/tmp/notes.pdf');
      expect(read.imagePath, isNull);
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
    testWidgets('is a plus, and the plus opens three large doors', (
      tester,
    ) async {
      await pumpShell(tester);

      // Claude's composer: one add control on the left, nothing else. The
      // camera and screen buttons that used to sit here are gone.
      expect(find.byKey(kComposerAdd), findsOneWidget);
      expect(find.byKey(kSheetCamera), findsNothing);
      expect(find.byTooltip('Add'), findsOneWidget);
      expect(find.byKey(kNexusLiveScreenShare), findsNothing);

      await tester.tap(find.byKey(kComposerAdd));
      await tester.pumpAndSettle();

      expect(find.byKey(kSheetCamera), findsOneWidget);
      expect(find.byKey(kSheetPhotos), findsOneWidget);
      expect(find.byKey(kSheetFiles), findsOneWidget);
      expect(find.text('Camera'), findsOneWidget);
      expect(find.text('Photos'), findsOneWidget);
      // `Files` is also the tab behind the sheet; the key above is the door.
      expect(find.text('Files'), findsWidgets);
      // Large targets: the sheet is three words and a thumb, not a menu row.
      final Size row = tester.getSize(find.byKey(kSheetCamera));
      expect(row.height, greaterThanOrEqualTo(72));
    });

    testWidgets('the camera door takes the system camera\'s photo', (
      tester,
    ) async {
      final File file = (await tester.runAsync(shot))!;
      pickers.camera = PickedAttachment(path: file.path, name: 'shot.png');
      await pumpShell(tester);

      await tester.tap(find.byKey(kComposerAdd));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kSheetCamera));
      await tester.pumpAndSettle();

      // No preview page of our own: the phone's camera app is the camera.
      // The pick lands in the composer, not the thread, with an X to undo it.
      expect(pickers.cameraPicks, 1);
      expect(find.byKey(kNexusPendingAttachment), findsOneWidget);
      expect(find.byKey(kNexusRemoveAttachment), findsOneWidget);
      expect(find.byType(NexusAttachmentBubble), findsNothing);
      expect(find.text('Message Nexus'), findsOneWidget);

      // Send is what puts the picture and the words in the thread together.
      await tester.tap(find.byKey(const ValueKey<String>('send')));
      await tester.pumpAndSettle();
      expect(find.text('Photo attached'), findsOneWidget);
      expect(find.byType(NexusAttachmentBubble), findsOneWidget);
      expect(find.byKey(kNexusPendingAttachment), findsNothing);

      // The image itself carries the 18-point radius, and the caption is a
      // separate capsule underneath rather than a strip inside a bubble.
      final Finder picture = find.descendant(
        of: find.byType(NexusAttachmentBubble),
        matching: find.byType(ClipRRect),
      );
      expect(
        tester.widget<ClipRRect>(picture).borderRadius,
        const BorderRadius.all(Radius.circular(18)),
      );
      expect(
        tester.getTopLeft(find.text('Photo attached')).dy,
        greaterThan(tester.getBottomLeft(picture).dy),
      );
    });

    testWidgets('backing out of the camera leaves the thread untouched', (
      tester,
    ) async {
      pickers.camera = null;
      await pumpShell(tester);

      await tester.tap(find.byKey(kComposerAdd));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kSheetCamera));
      await tester.pumpAndSettle();

      expect(pickers.cameraPicks, 1);
      expect(find.text('Photo attached'), findsNothing);
      expect(find.byType(NexusAttachmentBubble), findsNothing);
      expect(chat.entries, isEmpty);
    });

    testWidgets('the gallery door attaches a photo and asks the vision layer', (
      tester,
    ) async {
      final File file = (await tester.runAsync(shot))!;
      pickers.image = PickedAttachment(path: file.path, name: 'shot.png');
      await pumpShell(tester);

      await tester.tap(find.byKey(kComposerAdd));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kSheetPhotos));
      await tester.pumpAndSettle();

      expect(pickers.imagePicks, 1);
      expect(find.byKey(kNexusPendingAttachment), findsOneWidget);
      expect(find.byType(NexusAttachmentBubble), findsNothing);
      // A text brain is never asked to describe a picture it cannot see.
      expect(brain.prompts, isEmpty);

      await tester.tap(find.byKey(const ValueKey<String>('send')));
      await tester.pumpAndSettle();
      expect(find.text('Photo attached'), findsOneWidget);
      expect(find.byType(NexusAttachmentBubble), findsOneWidget);
      expect(find.text(kNexusVisionMissingText), findsOneWidget);
    });

    testWidgets('the vision layer sends OCR and labels to the local brain', (
      tester,
    ) async {
      final List<String> prompts = <String>[];
      VisionAiService.override = () => MlVisionService(
        readText: (_) async => 'STOP\nMain Street',
        readLabels: (_) async => const <String>[
          'Dog',
          'Outdoor',
          'Car',
          'Grass',
          'Sky',
          'Tree',
        ],
        answer: (String prompt) async {
          prompts.add(prompt);
          return 'A dog beside a road.';
        },
      );
      final File file = (await tester.runAsync(shot))!;
      pickers.image = PickedAttachment(path: file.path, name: 'shot.png');
      await pumpShell(tester);

      await tester.tap(find.byKey(kComposerAdd));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kSheetPhotos));
      await tester.pumpAndSettle();

      // Nothing is scanned until the picture is actually sent.
      expect(prompts, isEmpty);
      expect(find.byKey(kNexusPendingAttachment), findsOneWidget);

      await tester.enterText(
        find.byType(TextField),
        'What is happening in this photo?',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey<String>('send')));
      await tester.pumpAndSettle();

      expect(prompts, hasLength(1));
      expect(
        prompts.single,
        '[Image Context: Text="STOP\nMain Street", '
        'Objects="Dog, Outdoor, Car, Grass, Sky"]\n'
        '[User Question]: What is happening in this photo?',
      );
      expect(find.text('A dog beside a road.'), findsOneWidget);
      expect(find.text(kNexusVisionMissingText), findsNothing);
      // The scan is kept, but behind the ⓘ: the bubble leads with the picture
      // and the caption, and machine labels are one deliberate tap away.
      expect(find.byKey(kNexusVisionCaption), findsNothing);
      await tester.tap(find.byKey(kNexusVisionInfo));
      await tester.pumpAndSettle();
      expect(find.byKey(kNexusVisionCaption), findsOneWidget);
      expect(find.text('Detected text: "STOP\nMain Street"'), findsOneWidget);
      expect(
        find.text('Objects: Dog, Outdoor, Car, Grass, Sky'),
        findsOneWidget,
      );
    });

    testWidgets('the files door attaches a document as a file chip', (
      tester,
    ) async {
      final File file = (await tester.runAsync(shot))!;
      pickers.file = PickedAttachment(path: file.path, name: 'notes.pdf');
      await pumpShell(tester);

      await tester.tap(find.byKey(kComposerAdd));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kSheetFiles));
      await tester.pumpAndSettle();

      expect(pickers.filePicks, 1);
      expect(find.byKey(kNexusPendingAttachment), findsOneWidget);
      expect(find.byType(NexusFileBubble), findsNothing);
      // A document is not a picture: nothing is asked about it, and nothing
      // pretends to have read it.
      expect(brain.prompts, isEmpty);
      expect(find.text(kNexusVisionMissingText), findsNothing);

      await tester.tap(find.byKey(const ValueKey<String>('send')));
      await tester.pumpAndSettle();
      expect(find.byType(NexusFileBubble), findsOneWidget);
      // The chip names the document and says how big it is; the automatic
      // "File attached: …" line is not repeated under it.
      expect(find.text('notes.pdf'), findsOneWidget);
      expect(find.text(localFileSize(file.lengthSync())), findsOneWidget);
      final ChatEntry stored = chat.entries.single;
      expect(stored.filePath, isNotNull);
      expect(stored.attachmentName, 'notes.pdf');
      expect(stored.text, 'File attached: notes.pdf');
    });

    testWidgets('the attachment doors log that they fired', (tester) async {
      // The lines `adb logcat | grep -E 'attach:|camera:'` shows when a thumb
      // lands on a door. Kept because the buttons were in the tree and still
      // "not reachable" in an earlier report.
      final List<String> lines = <String>[];
      final DebugPrintCallback original = debugPrint;
      debugPrint = (String? line, {int? wrapWidth}) {
        if (line != null &&
            (line.startsWith('camera:') || line.startsWith('attach:'))) {
          lines.add(line);
        }
      };
      try {
        final File file = (await tester.runAsync(shot))!;
        pickers.image = PickedAttachment(path: file.path, name: 'shot.png');
        pickers.file = PickedAttachment(path: file.path, name: 'notes.pdf');
        await pumpShell(tester);

        await tester.tap(find.byKey(kComposerAdd));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(kSheetPhotos));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(kComposerAdd));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(kSheetFiles));
        await tester.pumpAndSettle();

        expect(
          lines.any((String line) => line.startsWith('attach: photos tapped')),
          isTrue,
          reason: 'the gallery door has to prove it fired',
        );
        expect(
          lines.any((String line) => line.startsWith('attach: files tapped')),
          isTrue,
          reason: 'the files door has to prove it fired',
        );
      } finally {
        debugPrint = original;
      }
    });

    testWidgets('the camera door logs that it fired', (tester) async {
      final List<String> lines = <String>[];
      final DebugPrintCallback original = debugPrint;
      debugPrint = (String? line, {int? wrapWidth}) {
        if (line != null && line.startsWith('camera:')) lines.add(line);
      };
      try {
        final File file = (await tester.runAsync(shot))!;
        pickers.camera = PickedAttachment(path: file.path, name: 'shot.png');
        await pumpShell(tester);

        await tester.tap(find.byKey(kComposerAdd));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(kSheetCamera));
        await tester.pumpAndSettle();

        expect(
          lines.any(
            (String line) => line.startsWith('camera: attach button tapped'),
          ),
          isTrue,
          reason: 'the camera door has to prove it fired',
        );
        expect(
          lines.any((String line) => line.startsWith('camera: captured')),
          isTrue,
          reason: 'the system camera has to prove it came back',
        );
      } finally {
        debugPrint = original;
      }
    });
  });

  group('the image bubble', () {
    testWidgets('tapping it opens the full-screen viewer, and closes again', (
      tester,
    ) async {
      // Real file IO has to run outside the fake clock a widget test uses,
      // or it never completes.
      final File file = (await tester.runAsync(shot))!;
      chat = ChatLog(
        store: MemoryChatLogStore(<ChatEntry>[
          ChatEntry('Photo attached', mine: true, imagePath: file.path),
        ]),
      );
      ChatLog.override = () => chat;
      await pumpShell(tester);

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
          ChatEntry(
            'Photo attached',
            mine: true,
            imagePath: file.path,
            visionText: 'NEXUS VISION TEST',
            visionLabels: const <String>['Monochrome'],
          ),
          const ChatEntry('Looks like a cat.'),
        ]),
      );
      ChatLog.override = () => chat;

      await pumpShell(tester);

      expect(find.byType(NexusAttachmentBubble), findsOneWidget);
      expect(find.text('Photo attached'), findsOneWidget);
      expect(find.text('Looks like a cat.'), findsOneWidget);
      // The evidence is part of the stored line: reopening the app can show the
      // same scan under the same picture, not just the caption. It stays hidden
      // until the ⓘ is tapped.
      expect(find.byKey(kNexusVisionCaption), findsNothing);
      await tester.tap(find.byKey(kNexusVisionInfo));
      await tester.pumpAndSettle();
      expect(find.text('Detected text: "NEXUS VISION TEST"'), findsOneWidget);
      expect(find.text('Objects: Monochrome'), findsOneWidget);
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
