// The multi-modal composer: a picture waits above the field until the user
// sends it with their words. Nothing is committed on the pick, and the X throws
// the draft away instead of leaving a cache copy behind.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:nexus/core/attachment_pickers.dart';
import 'package:nexus/core/attachments.dart';
import 'package:nexus/core/chat_log.dart';
import 'package:nexus/core/local_ai_service.dart';
import 'package:nexus/core/onboarding.dart';
import 'package:nexus/core/system_actions.dart';
import 'package:nexus/core/vision_ai.dart';
import 'package:nexus/main_ui.dart';

class _NoBrain implements LocalAiService {
  final List<String> prompts = <String>[];

  @override
  Future<String> generateResponse(String prompt) async {
    prompts.add(prompt);
    return 'Okay.';
  }

  @override
  Stream<String> generateResponseStream(
    String prompt, {
    List<AiTurn> history = const <AiTurn>[],
  }) {
    prompts.add(prompt);
    return Stream<String>.value('Okay.');
  }
}

/// The phone, recording what the shell asked it to do.
class _Phone implements SystemActions {
  final List<SystemActionCall> calls = <SystemActionCall>[];

  @override
  Future<SystemActionOutcome> execute(SystemActionCall call) async {
    calls.add(call);
    return SystemActionOutcome(
      ok: true,
      message: 'Dialer opened for ${call.args['number']} — press call.',
      call: call,
    );
  }
}

class _Pickers implements AttachmentPickers {
  _Pickers(this.picture);

  final PickedAttachment? picture;

  @override
  Future<PickedAttachment?> captureImage() async => picture;

  @override
  Future<PickedAttachment?> pickImage() async => picture;

  @override
  Future<PickedAttachment?> pickFile() async => null;
}

/// Keeps the file where it is, so the test can still read it.
class _Store extends AttachmentStore {
  _Store() : super(directory: () async => null);

  @override
  Future<String?> keep(
    String sourcePath, {
    required AttachmentKind kind,
  }) async => sourcePath;
}

const List<int> _png = <int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x02,
  0x00,
  0x00,
  0x00,
  0x90,
  0x77,
  0x53,
  0xDE,
  0x00,
  0x00,
  0x00,
  0x0C,
  0x49,
  0x44,
  0x41,
  0x54,
  0x08,
  0xD7,
  0x63,
  0x60,
  0x60,
  0x60,
  0x00,
  0x00,
  0x00,
  0x04,
  0x00,
  0x01,
  0x27,
  0x34,
  0x27,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
];

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  late Directory folder;
  late File picture;
  late ChatLog chat;
  late _NoBrain brain;
  late _Phone phone;

  setUp(() async {
    folder = await Directory.systemTemp.createTemp('nexus-composer-');
    picture = File('${folder.path}/shot.png');
    await picture.writeAsBytes(_png);
    chat = ChatLog(store: MemoryChatLogStore());
    ChatLog.override = () => chat;
    brain = _NoBrain();
    phone = _Phone();
    LocalAiService.override = () => brain;
    SystemActions.override = () => phone;
    AttachmentStore.override = _Store.new;
    VisionAiService.override = null;
    VisionAiService.defaultFactory = null;
    Onboarding.debugOverride = true;
  });

  tearDown(() async {
    LocalAiService.override = null;
    SystemActions.override = null;
    ChatLog.override = null;
    ChatLog.debugReset();
    Onboarding.debugOverride = null;
    AttachmentStore.override = null;
    AttachmentPickers.override = null;
    VisionAiService.override = null;
    if (await folder.exists()) await folder.delete(recursive: true);
  });

  Future<void> pumpShell(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const NexusUiApp());
    await tester.pumpAndSettle();
  }

  Future<void> pickPhoto(WidgetTester tester) async {
    AttachmentPickers.override = () =>
        _Pickers(PickedAttachment(path: picture.path, name: 'shot.png'));
    await tester.tap(find.byKey(kComposerAdd));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(kSheetPhotos));
    await tester.pumpAndSettle();
  }

  testWidgets('a strict call runs on the phone, never through the model', (
    tester,
  ) async {
    await pumpShell(tester);

    await tester.enterText(find.byType(TextField), 'Call mom');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();

    expect(phone.calls, hasLength(1));
    expect(phone.calls.single.action, 'call_number');
    expect(phone.calls.single.args['number'], 'mom');
    expect(brain.prompts, isEmpty, reason: 'a strict command is not a prompt');
    expect(find.text('Dialer opened for mom — press call.'), findsOneWidget);
    expect(chat.entries.last.system, isTrue);
  });

  testWidgets('a picked photo waits in the composer, not in the thread', (
    tester,
  ) async {
    await pumpShell(tester);
    await pickPhoto(tester);

    expect(find.byKey(kNexusPendingAttachment), findsOneWidget);
    expect(find.byKey(kNexusRemoveAttachment), findsOneWidget);
    expect(find.byType(NexusAttachmentBubble), findsNothing);
    expect(chat.entries, isEmpty);
    // The attachment alone is enough to send: the picture is half the message.
    expect(find.byKey(const ValueKey<String>('send')), findsOneWidget);
  });

  testWidgets('the typed caption and the photo are sent in one turn', (
    tester,
  ) async {
    await pumpShell(tester);
    await pickPhoto(tester);

    await tester.enterText(find.byType(TextField), 'What is on this sign?');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('send')));
    await tester.pumpAndSettle();

    // One bubble carries both: the user's words are the caption, and the
    // picture sits above them in the same turn.
    expect(find.byKey(kNexusPendingAttachment), findsNothing);
    final NexusAttachmentBubble bubble = tester.widget<NexusAttachmentBubble>(
      find.byType(NexusAttachmentBubble),
    );
    expect(bubble.caption, 'What is on this sign?');
    expect(bubble.path, picture.path);
    expect(chat.entries.first.text, 'What is on this sign?');
    expect(chat.entries.first.imagePath, picture.path);
    // The vision layer answers in the next line, because the eyes are missing
    // in this test and the shell says so rather than inventing a description.
    expect(chat.entries.last.text, kNexusVisionMissingText);
  });

  testWidgets('the X discards the draft and deletes the kept copy', (
    tester,
  ) async {
    await pumpShell(tester);
    await pickPhoto(tester);

    await tester.tap(find.byKey(kNexusRemoveAttachment));
    await tester.pumpAndSettle();

    expect(find.byKey(kNexusPendingAttachment), findsNothing);
    expect(find.byType(NexusAttachmentBubble), findsNothing);
    expect(chat.entries, isEmpty);
  });

  testWidgets('a new pick replaces the previous draft', (tester) async {
    await pumpShell(tester);
    await pickPhoto(tester);

    final File second = File('${folder.path}/second.png');
    second.writeAsBytesSync(_png);
    AttachmentPickers.override = () =>
        _Pickers(PickedAttachment(path: second.path, name: 'second.png'));
    await tester.tap(find.byKey(kComposerAdd));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(kSheetPhotos));
    await tester.pumpAndSettle();

    expect(find.text('second.png'), findsOneWidget);
    expect(find.text('shot.png'), findsNothing);
    expect(chat.entries, isEmpty);
  });
}
