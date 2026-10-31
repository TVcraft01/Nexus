// Clipboard sync, in the shipped shell.
//
// Three pieces, and each one is a promise the app makes:
//
//  1. the switch — copying is private until the user turns sync on;
//  2. the bar — a peer's plain text lands in front of the user with Accept and
//     Dismiss, and it says which device it came from, because "a clipboard
//     arrived" is not a question anybody can answer;
//  3. the send row — the deliberate version, one clip now, with the count the
//     mesh actually delivered.
//
// The clipboard is a seam ([ClipboardBackend]), so every assertion here is
// about what the local clipboard actually holds: nothing pastes itself, and
// Dismiss leaves it exactly as it was.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/main_ui.dart'
    show
        NexusClipboardBanner,
        NexusShell,
        NexusTheme,
        SettingsTab,
        kNexusClipboardAccept,
        kNexusClipboardBanner,
        kNexusClipboardDismiss,
        kNexusClipboardSyncToggle,
        kNexusSendClipboard;
import 'package:nexus/mesh/mesh_service.dart';

/// A clipboard that lives in memory — this is the fake the two-instance run
/// gives each app, because two windows share one OS clipboard.
class _MemoryClipboard implements ClipboardBackend {
  String? value;

  @override
  Future<String?> readText() async => value;

  @override
  Future<void> writeText(String text) async => value = text;
}

/// A mesh that never opens a socket, and records what it was asked to send.
class _ClipMesh extends MeshService {
  _ClipMesh({required super.store, required ClipboardBackend clip})
    : super(
        identity: DeviceInfo(
          id: 'this-pc',
          name: 'Rehearsal PC',
          platform: 'linux',
        ),
        clipboard: clip,
      );

  /// Every text handed to [broadcastClipboard], in order.
  final List<String> sent = <String>[];

  /// What the next broadcast reports as delivered. Zero is the honest answer
  /// when no peer took the copy.
  int deliverTo = 1;

  @override
  Future<int> broadcastClipboard(String text) async {
    sent.add(text);
    return deliverTo;
  }
}

void main() {
  late Directory tmp;
  late NexusStore store;
  late _MemoryClipboard clip;
  late _ClipMesh mesh;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('nexus-clip-shell-');
    store = NexusStore(explicitPath: '${tmp.path}/store.json');
    await store.save();
    clip = _MemoryClipboard();
    mesh = _ClipMesh(store: store, clip: clip);
    addTearDown(() {
      mesh.stop();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
  });

  Future<void> pumpBanner(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: NexusTheme.light(),
        home: Scaffold(body: NexusClipboardBanner(mesh: mesh)),
      ),
    );
    await tester.pump();
  }

  /// Stages a push the way the mesh does on arrival: one entry, the mesh's own
  /// notification, and nothing on the clipboard.
  void stageClip({
    String text = 'bring milk',
    String? fromName = 'Kit',
    bool autoAccepted = false,
  }) {
    mesh.lastIncomingClip = ClipEntry(
      text: text,
      fromName: fromName,
      fromId: 'peer-kit',
      autoAccepted: autoAccepted,
    );
    mesh.notifyListeners();
  }

  group('the bar that asks', () {
    testWidgets('says which device sent it, and Accept pastes the text', (
      tester,
    ) async {
      await pumpBanner(tester);
      expect(find.byKey(kNexusClipboardBanner), findsNothing);

      stageClip();
      await tester.pump();

      // Naming the sender is the difference between a prompt and a mystery:
      // the user knows which of their devices just copied something.
      expect(find.text('Clipboard from Kit'), findsOneWidget);
      expect(find.text('bring milk'), findsOneWidget);
      expect(clip.value, isNull, reason: 'nothing pastes itself');

      await tester.tap(find.byKey(kNexusClipboardAccept));
      await tester.pump();
      await tester.pump();

      expect(clip.value, 'bring milk');
      expect(find.byKey(kNexusClipboardBanner), findsNothing);
      expect(mesh.hasPendingClipboard, isFalse);
    });

    testWidgets('Dismiss forgets the clip and writes nothing', (tester) async {
      clip.value = 'what was here before';
      await pumpBanner(tester);
      stageClip(text: 'a long secret');
      await tester.pump();

      expect(find.text('a long secret'), findsOneWidget);

      await tester.tap(find.byKey(kNexusClipboardDismiss));
      await tester.pump();
      await tester.pump();

      // The local clipboard is exactly what it was, and the text is gone from
      // the app — a dismissal that kept the payload would be a wait, not a no.
      expect(clip.value, 'what was here before');
      expect(mesh.lastIncomingClip, isNull);
      expect(find.byKey(kNexusClipboardBanner), findsNothing);
    });

    testWidgets('a clip that applied itself shows no bar', (tester) async {
      await pumpBanner(tester);
      stageClip(text: '482916', autoAccepted: true);
      await tester.pump();

      // An OTP is already on the clipboard; asking about it after the fact
      // would be a question with nothing left to answer.
      expect(find.byKey(kNexusClipboardBanner), findsNothing);
    });

    testWidgets('a multiline payload is one line of preview', (tester) async {
      await pumpBanner(tester);
      stageClip(text: 'first line\nsecond line');
      await tester.pump();

      expect(find.text('first line second line'), findsOneWidget);
      expect(find.byKey(kNexusClipboardBanner), findsOneWidget);
    });

    testWidgets('an unnamed sender is called what it is', (tester) async {
      await pumpBanner(tester);
      stageClip(fromName: null);
      await tester.pump();

      expect(find.text('Clipboard from a paired device'), findsOneWidget);
    });
  });

  testWidgets('the shell draws the bar above whatever tab is open', (
    tester,
  ) async {
    // The widget above is only useful if the shipped shell mounts it. This is
    // the shell itself, with a mesh that has nothing to do with a socket.
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: NexusTheme.light(),
        home: NexusShell(
          darkMode: false,
          onDarkModeChanged: (bool _) {},
          mesh: mesh,
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(kNexusClipboardBanner), findsNothing);

    stageClip();
    await tester.pump();

    expect(find.byKey(kNexusClipboardBanner), findsOneWidget);
    expect(find.text('Clipboard from Kit'), findsOneWidget);

    await tester.tap(find.byKey(kNexusClipboardAccept));
    await tester.pump();
    await tester.pump();

    expect(clip.value, 'bring milk');
    expect(find.byKey(kNexusClipboardBanner), findsNothing);
  });

  group('the switch, in Settings', () {
    Future<void> pumpSettings(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: NexusTheme.light(),
          home: Scaffold(
            body: SettingsTab(
              darkMode: false,
              onDarkModeChanged: (bool _) {},
              mesh: mesh,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.scrollUntilVisible(
        find.byKey(kNexusClipboardSyncToggle),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump();
    }

    testWidgets('is off on a fresh install, and tapping it turns sync on', (
      tester,
    ) async {
      expect(store.clipboardSync, isFalse, reason: 'off until chosen');
      await pumpSettings(tester);

      final Finder toggle = find.descendant(
        of: find.byKey(kNexusClipboardSyncToggle),
        matching: find.byType(Switch),
      );
      expect(toggle, findsOneWidget);
      expect(
        find.textContaining('off until you turn it on'),
        findsOneWidget,
        reason: 'the row says what off means',
      );
      expect(tester.widget<Switch>(toggle).value, isFalse);

      await tester.tap(toggle);
      await tester.pump();

      expect(
        mesh.store.clipboardSync,
        isTrue,
        reason: 'the flag the mesh reads',
      );
      expect(tester.widget<Switch>(toggle).value, isTrue);
    });
  });

  group('the send row', () {
    Future<void> pumpSettings(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: NexusTheme.light(),
          home: Scaffold(
            body: SettingsTab(
              darkMode: false,
              onDarkModeChanged: (bool _) {},
              mesh: mesh,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.scrollUntilVisible(
        find.byKey(kNexusSendClipboard),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump();
    }

    testWidgets('sends what is on the clipboard and counts the device', (
      tester,
    ) async {
      clip.value = 'bring milk';
      await pumpSettings(tester);

      await tester.tap(find.byKey(kNexusSendClipboard));
      await tester.pump();
      await tester.pump();

      expect(mesh.sent, <String>['bring milk']);
      expect(find.text('Sent to 1 device.'), findsOneWidget);
    });

    testWidgets('an empty clipboard is said out loud, not sent as empty', (
      tester,
    ) async {
      await pumpSettings(tester);

      await tester.tap(find.byKey(kNexusSendClipboard));
      await tester.pump();
      await tester.pump();

      expect(mesh.sent, isEmpty);
      expect(
        find.text('Nothing to send — copy some text first.'),
        findsOneWidget,
      );
    });

    testWidgets('a send nobody took says so instead of claiming success', (
      tester,
    ) async {
      clip.value = 'bring milk';
      mesh.deliverTo = 0;
      await pumpSettings(tester);

      await tester.tap(find.byKey(kNexusSendClipboard));
      await tester.pump();
      await tester.pump();

      expect(
        find.text('No paired device took it. Check that one is online.'),
        findsOneWidget,
      );
    });
  });
}
