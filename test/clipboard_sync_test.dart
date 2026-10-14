// Clipboard sync that never silently overwrites.
//
// The design rule, driven end to end: a copy pushes to all paired peers,
// but a push never touches the receiving device's clipboard on its own.
// Plain text waits in the one pending slot until the user taps the paste
// pill (swipe forgets it); only an OTP (6-8 digits) or a URL (http/https)
// applies itself, with a short "Copied from <peer>" toast.
//
// Mesh tests pair two real meshes over loopback (like mesh_test.dart) with
// in-memory clipboards, so every assertion is about what actually arrived
// and what the local clipboard actually holds. Widget tests drive the real
// AssistantView pill: tap pastes and dismisses, swipe dismisses clean.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/query_log.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/mesh/mesh_service.dart';
import 'package:nexus/ui/assistant_view.dart';
import 'package:nexus/ui/theme.dart';

/// A clipboard that lives in memory — no platform channels needed in tests.
class _MemoryClipboard implements ClipboardBackend {
  String? value;
  @override
  Future<String?> readText() async => value;
  @override
  Future<void> writeText(String text) async => value = text;
}

/// A mesh that never opens a socket — enough for the assistant to build
/// around it while the test stages a pending push by hand.
class _WidgetMesh extends MeshService {
  _WidgetMesh({required super.store, required ClipboardBackend clip})
    : super(
        identity: DeviceInfo(
          id: 'this-phone',
          name: 'Test Phone',
          platform: 'android',
        ),
        clipboard: clip,
      );
}

Future<void> _waitFor(bool Function() cond) async {
  for (var i = 0; i < 40 && !cond(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

void main() {
  test('the auto-accept gate passes OTPs and URLs, nothing else', () {
    // OTPs: exactly 6–8 digits, surrounding whitespace ignored.
    expect(isClipboardAutoAccept('482916'), isTrue);
    expect(isClipboardAutoAccept('12345678'), isTrue);
    expect(isClipboardAutoAccept('  482916  '), isTrue);
    expect(isClipboardAutoAccept('12345'), isFalse);
    expect(isClipboardAutoAccept('123456789'), isFalse);
    expect(isClipboardAutoAccept('12a456'), isFalse);
    expect(isClipboardAutoAccept(''), isFalse);
    // URLs: http/https only.
    expect(isClipboardAutoAccept('https://example.com/s'), isTrue);
    expect(isClipboardAutoAccept('http://example.com/s'), isTrue);
    expect(isClipboardAutoAccept('HTTPS://EXAMPLE.COM'), isTrue);
    expect(isClipboardAutoAccept('ftp://example.com'), isFalse);
    expect(isClipboardAutoAccept('example.com'), isFalse);
    // Everything else waits for the tap.
    expect(isClipboardAutoAccept('bring milk'), isFalse);
    expect(isClipboardAutoAccept('call mom at 5'), isFalse);
  });

  group('over the mesh', () {
    late Directory tmp;
    late NexusStore storeA;
    late NexusStore storeB;
    late MeshService meshA;
    late MeshService meshB;
    late _MemoryClipboard clipA;
    late _MemoryClipboard clipB;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('nexus_clip_sync');
      storeA = NexusStore(explicitPath: '${tmp.path}/a.json')
        ..port = 53220
        ..clipboardSync = true
        ..pairingEnabled = true;
      storeB = NexusStore(explicitPath: '${tmp.path}/b.json')
        ..port = 53221
        ..clipboardSync = true
        ..pairingEnabled = true;
      await storeA.save();
      await storeB.save();
      clipA = _MemoryClipboard();
      clipB = _MemoryClipboard();
      meshA = MeshService(
        identity: DeviceInfo(
          id: 'device-a',
          name: 'Rehearsal PC',
          platform: 'linux',
        ),
        store: storeA,
        clipboard: clipA,
        heartbeatInterval: const Duration(seconds: 2),
        connectTimeout: const Duration(milliseconds: 300),
      );
      meshB = MeshService(
        identity: DeviceInfo(
          id: 'device-b',
          name: 'Test Phone',
          platform: 'android',
        ),
        store: storeB,
        clipboard: clipB,
        heartbeatInterval: const Duration(seconds: 2),
        connectTimeout: const Duration(milliseconds: 300),
      );
      await meshA.start();
      await meshB.start();
      final session = meshA.beginPairing();
      final result = await meshB.pairWith(
        address: '127.0.0.1',
        port: meshA.port,
        code: session.code,
      );
      expect(result.ok, isTrue, reason: result.error);
    });

    tearDown(() async {
      await meshA.stop();
      await meshB.stop();
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    test(
      'a copy on peer A arrives on peer B as pending — the local '
      'clipboard is untouched',
      () async {
        await meshB.broadcastClipboard('bring milk');

        await _waitFor(() => meshA.lastIncomingClip?.text == 'bring milk');
        expect(
          meshA.lastIncomingClip?.text,
          'bring milk',
          reason: 'B\'s copy never arrived on A',
        );
        expect(meshA.lastIncomingClip?.fromName, 'Test Phone');
        expect(meshA.lastIncomingClip?.autoAccepted, isFalse);
        expect(meshA.hasPendingClipboard, isTrue);
        // The whole point: nothing was written behind the user's back.
        expect(clipA.value, isNull);
      },
    );

    test('an OTP push applies itself on arrival', () async {
      await meshB.broadcastClipboard('482916');

      await _waitFor(() => clipA.value == '482916');
      expect(clipA.value, '482916');
      expect(meshA.lastIncomingClip?.autoAccepted, isTrue);
      expect(meshA.hasPendingClipboard, isFalse);
    });

    test('a URL push applies itself on arrival', () async {
      await meshB.broadcastClipboard('https://example.com/notes');

      await _waitFor(() => clipA.value == 'https://example.com/notes');
      expect(clipA.value, 'https://example.com/notes');
      expect(meshA.lastIncomingClip?.autoAccepted, isTrue);
      expect(meshA.hasPendingClipboard, isFalse);
    });

    test(
      'plain text keeps waiting: still pending and still unapplied after '
      'the poll runs again',
      () async {
        await meshB.broadcastClipboard('bring milk');
        await _waitFor(() => meshA.hasPendingClipboard);

        // Let the 1.5 s clipboard poll run twice more. Nothing may sneak
        // the push into the clipboard while the user hasn't tapped.
        await Future<void>.delayed(const Duration(milliseconds: 3600));
        expect(meshA.hasPendingClipboard, isTrue);
        expect(meshA.lastIncomingClip?.text, 'bring milk');
        expect(clipA.value, isNull);
      },
    );

    test('accepting the pending push pastes it and dismisses', () async {
      await meshB.broadcastClipboard('bring milk');
      await _waitFor(() => meshA.hasPendingClipboard);

        await meshA.acceptPendingClipboard();
      expect(clipA.value, 'bring milk');
      expect(meshA.lastIncomingClip, isNull);
      expect(meshA.hasPendingClipboard, isFalse);
    });

    test('dismissing the pending push forgets it without pasting', () async {
      await meshB.broadcastClipboard('bring milk');
      await _waitFor(() => meshA.hasPendingClipboard);

      meshA.dismissPendingClipboard();
      expect(meshA.lastIncomingClip, isNull);
      expect(clipA.value, isNull);
    });
  });

  group('the paste pill', () {
    testWidgets('tap pastes the push and dismisses the pill', (tester) async {
      final root = Directory.systemTemp.createTempSync('clip_pill_tap');
      addTearDown(() async {
        if (root.existsSync()) await root.delete(recursive: true);
      });
      final clip = _MemoryClipboard();
      final mesh = _WidgetMesh(
        store: NexusStore(explicitPath: '${root.path}/s.json'),
        clip: clip,
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildNexusTheme(),
            home: Scaffold(body: AssistantView(mesh: mesh)),
          ),
        );
        await tester.pump();

        mesh.lastIncomingClip = const ClipEntry(
          text: 'bring milk',
          fromName: 'Rehearsal PC',
        );
        mesh.notifyListeners();
        await tester.pump();

        const pillText = 'Clipboard from Rehearsal PC — tap to paste.';
        expect(find.text(pillText), findsOneWidget);

        await tester.tap(find.text(pillText));
        await tester.pump();
        await tester.pump();

        expect(clip.value, 'bring milk');
        expect(find.text(pillText), findsNothing);
      } finally {
        QueryLog.i.resetForTest();
      }
    });

    testWidgets('swipe dismisses the pill without pasting', (tester) async {
      final root = Directory.systemTemp.createTempSync('clip_pill_swipe');
      addTearDown(() async {
        if (root.existsSync()) await root.delete(recursive: true);
      });
      final clip = _MemoryClipboard();
      final mesh = _WidgetMesh(
        store: NexusStore(explicitPath: '${root.path}/s.json'),
        clip: clip,
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildNexusTheme(),
            home: Scaffold(body: AssistantView(mesh: mesh)),
          ),
        );
        await tester.pump();

        mesh.lastIncomingClip = const ClipEntry(
          text: 'bring milk',
          fromName: 'Rehearsal PC',
        );
        mesh.notifyListeners();
        await tester.pump();

        const pillText = 'Clipboard from Rehearsal PC — tap to paste.';
        expect(find.text(pillText), findsOneWidget);

        await tester.drag(
          find.byKey(const ValueKey('clipboard-pill')),
          const Offset(500, 0),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump(const Duration(milliseconds: 500));

        expect(find.text(pillText), findsNothing);
        expect(clip.value, isNull);
        expect(mesh.lastIncomingClip, isNull);
      } finally {
        QueryLog.i.resetForTest();
      }
    });

    testWidgets('an auto-accepted push never shows the pill', (tester) async {
      final root = Directory.systemTemp.createTempSync('clip_pill_auto');
      addTearDown(() async {
        if (root.existsSync()) await root.delete(recursive: true);
      });
      final mesh = _WidgetMesh(
        store: NexusStore(explicitPath: '${root.path}/s.json'),
        clip: _MemoryClipboard(),
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildNexusTheme(),
            home: Scaffold(body: AssistantView(mesh: mesh)),
          ),
        );
        await tester.pump();

        mesh.lastIncomingClip = const ClipEntry(
          text: '482916',
          fromName: 'Rehearsal PC',
          autoAccepted: true,
        );
        mesh.notifyListeners();
        await tester.pump();

        expect(find.byKey(const ValueKey('clipboard-pill')), findsNothing);
      } finally {
        QueryLog.i.resetForTest();
      }
    });
  });
}
