// The pairing flow, driven the way a person drives it: tap "Pair a device",
// pick one of the two answers, and see what the screen does with the result.
//
// The camera is the one thing here that cannot run, so it is the one thing the
// tests replace — `debugPairScannerOverride` stands in for the whole scanner
// page where the test is about the list, and `PairScanPage.cameraBuilder`
// stands in for the sensor where the test is about the page itself. Everything
// between those two seams (the JSON payload, the parse, the store, the notice)
// is the real code.
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/pair_invite.dart';
import 'package:nexus/core/paired_devices.dart';
import 'package:nexus/main_ui.dart' show
    DevicesTab,
    kNexusLegacyPairCodeText,
    kNexusNotAPairCodeText,
    kNexusPairTitle,
    kNexusScanQrLabel,
    kNexusShowQrLabel,
    NexusTheme,
    PairQrPage,
    PairScanPage,
    debugPairScannerOverride;
import 'package:qr_flutter/qr_flutter.dart';

const PairInvite _ocean = PairInvite(
  deviceName: 'Ocean Phone',
  deviceId: 'oceanphone00000000000000000000001',
  publicKey: 'ocean-key',
);

/// A fixed identity, so the QR the page draws is the QR the test parses.
const PairIdentity _me = PairIdentity(
  name: 'This Phone',
  id: 'thisphone0000000000000000000000001',
  publicKey: 'this-key',
);

/// Puts the screen on a phone-sized frame with the app's own theme, which is
/// what the tokens and the row metrics were chosen against.
Future<void> _pumpDevices(
  WidgetTester tester, {
  required PairedDevices paired,
}) async {
  PairedDevices.override = () => paired;
  await tester.pumpWidget(
    MaterialApp(
      theme: NexusTheme.light(),
      home: const Scaffold(body: DevicesTab()),
    ),
  );
  await tester.pump();
}

void main() {
  late PairedDevices paired;
  late MemoryPairedDevicesStore store;

  setUp(() {
    // A fresh store per test: the list is persisted, so a shared one would let
    // one test's pairing show up in the next.
    store = MemoryPairedDevicesStore();
    paired = PairedDevices(store: store);
    PairIdentity.override = () => _me;
  });

  tearDown(() {
    PairedDevices.override = null;
    PairIdentity.override = null;
    PairIdentity.debugReset();
    debugPairScannerOverride = null;
  });

  group('the Devices tab', () {
    testWidgets('lists the paired devices with a word and a dot each', (
      tester,
    ) async {
      await _pumpDevices(tester, paired: paired);

      expect(find.text('This Phone'), findsOneWidget);
      expect(find.text('My PC'), findsOneWidget);
      expect(find.text('Studio Mac'), findsOneWidget);
      // The status is a word as well as a colour, so it survives being read by
      // somebody who cannot see the dot.
      expect(find.text('Online'), findsNWidgets(2));
      expect(find.text('Offline'), findsOneWidget);
      expect(find.text(kNexusPairTitle), findsOneWidget);
    });

    testWidgets('offers Forget on peers, never on this device', (tester) async {
      await _pumpDevices(tester, paired: paired);

      expect(find.byKey(const ValueKey<String>('forget-example-pc')), findsOne);
      expect(find.byKey(const ValueKey<String>('forget-example-mac')), findsOne);
      expect(find.byKey(const ValueKey<String>('forget-this-device')), findsNothing);
    });

    testWidgets('forgetting a device takes its row away and says so', (
      tester,
    ) async {
      await _pumpDevices(tester, paired: paired);

      await tester.tap(find.byKey(const ValueKey<String>('forget-example-pc')));
      await tester.pumpAndSettle();

      expect(find.text('My PC'), findsNothing);
      expect(find.text('Studio Mac'), findsOneWidget);
      expect(find.text('Forgot My PC.'), findsOneWidget);
      // The screen and the store agree: the row is gone from what the next
      // start would read back, not just from what is on screen.
      expect(store.read(), completion(isNotNull));
      final List<PairedDevice>? written = await store.read();
      expect(written!.map((PairedDevice d) => d.name), isNot(contains('My PC')));
    });
  });

  group('the pairing sheet', () {
    testWidgets('opens with both answers', (tester) async {
      await _pumpDevices(tester, paired: paired);

      await tester.tap(find.text(kNexusPairTitle));
      await tester.pumpAndSettle();

      expect(find.text(kNexusScanQrLabel), findsOneWidget);
      expect(find.text(kNexusShowQrLabel), findsOneWidget);
    });

    testWidgets('Show my QR code opens a code that parses back as this device', (
      tester,
    ) async {
      await _pumpDevices(tester, paired: paired);

      await tester.tap(find.text(kNexusPairTitle));
      await tester.pumpAndSettle();
      await tester.tap(find.text(kNexusShowQrLabel));
      await tester.pumpAndSettle();

      final QrImageView qr = tester.widget<QrImageView>(find.byType(QrImageView));
      // Drawn on white in both themes: a scanner needs the contrast.
      expect(qr.backgroundColor, Colors.white);
      expect(qr.size, greaterThanOrEqualTo(200));

      // `QrImageView` keeps its data private, so the page states what it drew
      // and the test parses that same string back into an invite.
      final String payload = tester
          .widget<PairQrPage>(find.byType(PairQrPage))
          .payload;
      final PairInvite? parsed = PairInvite.parse(payload);
      expect(parsed, isNotNull);
      expect(parsed!.deviceName, 'This Phone');
      expect(parsed.deviceId, _me.id);
      expect(parsed.publicKey, 'this-key');
      // The payload is JSON, and it says what it is.
      expect(payload, startsWith('{"type":"nexus_pair"'));
      expect(find.text('This Phone'), findsOneWidget);
    });

    testWidgets('the QR page stands on its own too', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: NexusTheme.light(),
          home: const PairQrPage(identity: _me),
        ),
      );
      await tester.pump();

      final PairInvite? parsed = PairInvite.parse(
        tester.widget<PairQrPage>(find.byType(PairQrPage)).payload,
      );
      expect(parsed?.deviceId, _me.id);
      expect(find.textContaining('this'), findsWidgets);
    });
  });

  group('scanning', () {
    testWidgets('a Nexus code pairs the device and says whose it was', (
      tester,
    ) async {
      await _pumpDevices(tester, paired: paired);
      debugPairScannerOverride = (BuildContext context) async => _ocean;

      await tester.tap(find.text(kNexusPairTitle));
      await tester.pumpAndSettle();
      await tester.tap(find.text(kNexusScanQrLabel));
      await tester.pumpAndSettle();

      expect(find.text('Paired with Ocean Phone'), findsOneWidget);
      // The row is in the list behind the notice, and it is there because the
      // store changed, not because the sheet remembered it.
      expect(find.text('Ocean Phone'), findsOneWidget);
      expect(find.text('Paired just now'), findsOneWidget);
      expect(paired.contains(_ocean.deviceId), isTrue);
    });

    testWidgets('the same device twice is one row, and says so', (tester) async {
      await _pumpDevices(tester, paired: paired);
      debugPairScannerOverride = (BuildContext context) async => _ocean;

      for (int i = 0; i < 2; i++) {
        await tester.tap(find.text(kNexusPairTitle));
        await tester.pumpAndSettle();
        await tester.tap(find.text(kNexusScanQrLabel));
        await tester.pumpAndSettle();
      }

      expect(find.text('Ocean Phone is already paired.'), findsOneWidget);
      expect(find.text('Ocean Phone'), findsOneWidget);
      expect(
        paired.devices.where((PairedDevice d) => d.id == _ocean.deviceId),
        hasLength(1),
      );
    });

    testWidgets('backing out of the camera changes nothing', (tester) async {
      await _pumpDevices(tester, paired: paired);
      debugPairScannerOverride = (BuildContext context) async => null;

      await tester.tap(find.text(kNexusPairTitle));
      await tester.pumpAndSettle();
      await tester.tap(find.text(kNexusScanQrLabel));
      await tester.pumpAndSettle();

      expect(find.byType(SnackBar), findsNothing);
      expect(paired.devices, kSeedPairedDevices);
    });
  });

  group('the scanner page', () {
    /// Opens the page through a route, so "it closed with an invite" is
    /// observable the way the list observes it — as the route's result rather
    /// than as a variable the page wrote on its way out.
    Future<_ScanHarnessState> open(WidgetTester tester) async {
      final GlobalKey<_ScanHarnessState> key = GlobalKey<_ScanHarnessState>();
      await tester.pumpWidget(
        MaterialApp(
          theme: NexusTheme.light(),
          home: _ScanHarness(key: key),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return key.currentState!;
    }

    testWidgets('a code that is not ours is refused in words', (tester) async {
      final _ScanHarnessState harness = await open(tester);
      expect(find.byType(PairScanPage), findsOneWidget);

      harness.feed('https://example.com/some-page');
      await tester.pump();

      expect(find.text(kNexusNotAPairCodeText), findsOneWidget);
      // The camera stays open: the answer to the wrong code is to try the right
      // one, not to be sent back.
      expect(find.byType(PairScanPage), findsOneWidget);
      // The notice clears itself, so the next attempt starts on a clean screen
      // rather than under a stack of them.
      await tester.pump(const Duration(seconds: 2));
      expect(find.text(kNexusNotAPairCodeText), findsNothing);
      await tester.pumpAndSettle();
    });

    testWidgets('an older Nexus code is a different sentence', (tester) async {
      final _ScanHarnessState harness = await open(tester);

      harness.feed('nexus://pair?v=1&id=abc&name=PC&port=51820&code=ABCD-2345');
      await tester.pump();

      expect(find.text(kNexusLegacyPairCodeText), findsOneWidget);
      expect(find.text(kNexusNotAPairCodeText), findsNothing);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
    });

    testWidgets('a Nexus code closes the page with the invite', (tester) async {
      final _ScanHarnessState harness = await open(tester);

      harness.feed(_ocean.encode());
      await tester.pumpAndSettle();

      expect(find.byType(PairScanPage), findsNothing);
      expect(harness.closed, isTrue);
      expect(harness.result?.deviceId, _ocean.deviceId);
      expect(harness.result?.deviceName, 'Ocean Phone');
    });

    testWidgets('a platform with no scanner says so instead of throwing', (
      tester,
    ) async {
      // A desktop build has no camera plugin behind it. The page must answer
      // with the same guidance a refused permission gets — not with a
      // MissingPluginException from inside the plugin's own async start.
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: NexusTheme.light(),
            home: const PairScanPage(),
          ),
        );
        await tester.pump();

        expect(find.text('The camera could not start.'), findsOneWidget);
        expect(find.text('Back'), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}

/// A page below the scanner, holding the two things a test has to see from the
/// outside: the way in (the code callback the fake camera was given) and the
/// way out (the route's result).
class _ScanHarness extends StatefulWidget {
  const _ScanHarness({super.key});

  @override
  State<_ScanHarness> createState() => _ScanHarnessState();
}

class _ScanHarnessState extends State<_ScanHarness> {
  /// Set while the scanner page is on top: the fake camera's feeding hand.
  ValueChanged<String>? _onCode;

  /// What the page above answered with, once it has answered.
  PairInvite? result;
  bool closed = false;

  void feed(String raw) => _onCode!(raw);

  Future<void> _open() async {
    final PairInvite? invite = await Navigator.of(context).push<PairInvite>(
      MaterialPageRoute<PairInvite>(
        builder: (BuildContext routeContext) => PairScanPage(
          cameraBuilder: (BuildContext _, ValueChanged<String> onCode) {
            _onCode = onCode;
            return const ColoredBox(color: Colors.black);
          },
        ),
      ),
    );
    if (!mounted) return;
    setState(() {
      result = invite;
      closed = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: TextButton(onPressed: _open, child: const Text('open')),
      ),
    );
  }
}
