// "Send to…", driven the way a thumb drives it: tap the control under a photo,
// pick a device, watch the bar, read the result.
//
// The transport is faked at [FileLink] — the same move these tests make for the
// brain and the microphone — so what is pinned here is the *flow*: the picker
// lists paired devices and nobody else, the bar moves while the send is in
// flight, the sentence the send ends with is the one on screen, and a phone
// with nothing paired says how to add one instead of showing an empty sheet.
// The staged copy itself (real bytes, real progress) is pinned in
// test/file_link_test.dart.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/file_link.dart';
import 'package:nexus/core/paired_devices.dart';
import 'package:nexus/main_ui.dart'
    show
        NexusAttachmentBubble,
        NexusTheme,
        kNexusSendProgress,
        kNexusSendResult,
        kNexusSendTo;
import 'package:nexus/mesh/nearby.dart' show NearbyDevices;
import 'package:nexus/ui/image_viewer_page.dart' show kImageViewerSend;

/// The transport, scripted: it reports progress in two steps and answers with
/// whatever the test wants the user to read.
class _FakeLink extends FileLink {
  _FakeLink({required this.result, this.gate});

  final FileSendResult result;

  /// Held open when a test wants to look at the bar mid-flight.
  final Completer<void>? gate;

  final List<String> sentTo = <String>[];

  @override
  Future<FileSendResult> send({
    required String path,
    required PairedDevice device,
    void Function(double progress)? onProgress,
  }) async {
    sentTo.add(device.id);
    onProgress?.call(0.4);
    if (gate != null) await gate!.future;
    onProgress?.call(1);
    return result;
  }
}

/// A paired peer, and one that is not this phone.
const PairedDevice _laptop = PairedDevice(
  id: 'laptop000000000000000000000000001',
  name: 'Study laptop',
  publicKey: 'laptop-key',
  addresses: <String>['192.168.1.30'],
  port: 51820,
  online: true,
);

const PairedDevice _onlyThisDevice = PairedDevice(
  id: 'this-device',
  name: 'This Phone',
  publicKey: '',
  isThisDevice: true,
);

void main() {
  late File shot;
  late _FakeLink link;

  setUp(() async {
    // A real file, because the bubble checks for one before drawing.
    final Directory dir = await Directory.systemTemp.createTemp('nexus-send-');
    shot = File('${dir.path}/shot.png')..writeAsBytesSync(_onePixelPng);
    NearbyDevices.debugOverride = NearbyDevices.new;
    link = _FakeLink(
      result: const FileSendResult(
        ok: true,
        message: 'Prepared for Study laptop (1 KB).',
      ),
    );
    FileLink.override = () => link;
  });

  tearDown(() {
    shot.parent.deleteSync(recursive: true);
    FileLink.override = null;
    FileLink.debugReset();
    PairedDevices.override = null;
    NearbyDevices.debugOverride = null;
    NearbyDevices.debugReset();
  });

  /// The bubble on its own, in the app's own theme.
  Future<void> pumpBubble(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: NexusTheme.dark(),
        home: Scaffold(
          body: Center(
            child: NexusAttachmentBubble(
              path: shot.path,
              caption: 'Photo attached',
              mine: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> openSheet(WidgetTester tester) async {
    await tester.tap(find.byKey(kNexusSendTo));
    await tester.pumpAndSettle();
  }

  testWidgets('the picker lists the paired peers, and sends to the one tapped', (
    tester,
  ) async {
    PairedDevices.override = () =>
        PairedDevices(store: MemoryPairedDevicesStore(), seed: <PairedDevice>[
          _onlyThisDevice,
          _laptop,
        ]);
    final Completer<void> gate = Completer<void>();
    link = _FakeLink(
      gate: gate,
      result: const FileSendResult(
        ok: true,
        message: 'Prepared for Study laptop (1 KB).',
      ),
    );
    FileLink.override = () => link;
    await pumpBubble(tester);

    await openSheet(tester);

    // The list is paired devices, and this phone is not one of them: a device
    // cannot send a file to itself.
    expect(find.text('Study laptop'), findsOneWidget);
    expect(find.text('This Phone'), findsNothing);

    await tester.tap(find.byKey(const ValueKey<String>(
      'send-to-laptop000000000000000000000000001',
    )));
    await tester.pump();

    // In flight: the bar is a real progress reading, and the sentence names the
    // device rather than the file.
    expect(find.byKey(kNexusSendProgress), findsOneWidget);
    expect(find.text('Sending to Study laptop…'), findsOneWidget);
    final LinearProgressIndicator bar = tester.widget<LinearProgressIndicator>(
      find.byKey(kNexusSendProgress),
    );
    expect(bar.value, closeTo(0.4, 0.001));

    gate.complete();
    await tester.pumpAndSettle();

    expect(link.sentTo, <String>[_laptop.id]);
    expect(find.byKey(kNexusSendResult), findsOneWidget);
    expect(find.text('Prepared for Study laptop (1 KB).'), findsOneWidget);
    expect(find.byKey(kNexusSendProgress), findsNothing);
  });

  testWidgets('a failure is shown in the send\'s own words', (tester) async {
    PairedDevices.override = () =>
        PairedDevices(store: MemoryPairedDevicesStore(), seed: <PairedDevice>[
          _onlyThisDevice,
          _laptop,
        ]);
    link = _FakeLink(
      result: const FileSendResult(
        ok: false,
        message: 'That file is no longer on this device.',
      ),
    );
    FileLink.override = () => link;
    await pumpBubble(tester);
    await openSheet(tester);

    await tester.tap(
      find.byKey(
        const ValueKey<String>('send-to-laptop000000000000000000000000001'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('That file is no longer on this device.'), findsOneWidget);
  });

  testWidgets('with nothing paired it says how to add a device', (
    tester,
  ) async {
    PairedDevices.override = () => PairedDevices(
      store: MemoryPairedDevicesStore(),
      seed: <PairedDevice>[_onlyThisDevice],
    );
    await pumpBubble(tester);

    await openSheet(tester);

    // The sheet's title, and the bubble's own control behind it: the two carry
    // the same words on purpose — one names the action, the other is it.
    expect(find.text('Send to…'), findsWidgets);
    expect(find.textContaining('No other device is paired yet'), findsOneWidget);
    expect(find.byKey(kNexusSendProgress), findsNothing);
  });

  testWidgets('the full-screen viewer carries the same door', (tester) async {
    PairedDevices.override = () =>
        PairedDevices(store: MemoryPairedDevicesStore(), seed: <PairedDevice>[
          _onlyThisDevice,
          _laptop,
        ]);
    await pumpBubble(tester);

    // Tapping the picture opens the viewer; the send control is on the page as
    // well as on the bubble, because that is where a user looks closely.
    await tester.tap(find.text('Photo attached'));
    await tester.pumpAndSettle();
    expect(find.byKey(kImageViewerSend), findsOneWidget);

    await tester.tap(find.byKey(kImageViewerSend));
    await tester.pumpAndSettle();

    expect(find.text('Study laptop'), findsOneWidget);
  });
}

/// One opaque black pixel, so a real decoder accepts the file.
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
