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
import 'package:nexus/core/qr_pairing.dart' show QrPairingToken;
import 'package:nexus/main_ui.dart'
    show
        DevicesTab,
        kNexusConfirmAction,
        kNexusDiscoverNearby,
        kNexusDiscoverWindow,
        kNexusForgetTitle,
        kNexusLegacyPairCodeText,
        kNexusLivePairCodeText,
        kNexusNotAPairCodeText,
        kNexusPairTitle,
        kNexusScanQrLabel,
        kNexusShowQrLabel,
        NexusTheme,
        PairQrPage,
        PairQrPageState,
        PairScanPage,
        debugPairScannerOverride;
import 'package:nexus/mesh/discovery.dart' show DiscoveredDevice;
import 'package:nexus/mesh/nearby.dart' show NearbyDevices;
import 'package:qr_flutter/qr_flutter.dart';

/// A device answering discovery, as the real announce payload describes it.
final DiscoveredDevice _kettle = DiscoveredDevice(
  id: 'kettle000000000000000000000000001',
  name: 'Kitchen tablet',
  platform: 'android',
  address: '192.168.1.44',
  port: 51820,
  lastSeen: DateTime(2026, 10, 18, 12),
);

/// Discovery, without a socket.
///
/// A subclass rather than another interface because the point of these tests is
/// what the *screen* does with what discovery heard — the hearing itself is
/// pinned in test/nearby_test.dart, where a fake transport can announce.
class _FakeNearby extends NearbyDevices {
  _FakeNearby(this.heard);

  final List<DiscoveredDevice> heard;
  int startCalls = 0;

  @override
  bool get running => true;

  @override
  List<DiscoveredDevice> get devices => heard;

  @override
  bool hasHeard(String id) => heard.any((DiscoveredDevice d) => d.id == id);

  @override
  DiscoveredDevice? device(String id) {
    for (final DiscoveredDevice d in heard) {
      if (d.id == id) return d;
    }
    return null;
  }

  @override
  String get status => heard.isEmpty
      ? 'Discovery is listening; no other Nexus device has been heard yet.'
      : 'Heard ${heard.length} Nexus device on this network.';

  @override
  Future<void> start() async => startCalls++;

  @override
  Future<void> stop() async {}

  /// A fake's version of the real thing: the announcement stream would put this
  /// device straight back, so Forget takes it out of the heard list.
  @override
  void forget(String id) {
    heard.removeWhere((DiscoveredDevice d) => d.id == id);
  }
}

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

/// Scrolls the Devices list until [finder] is built and on screen.
///
/// The tab is a lazy list and the Nearby section sits under the RAM row, the
/// paired rows and the discover button — below the fold on the 800×600 test
/// surface, so a plain `find` never sees it.
Future<void> _revealDevices(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    140,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
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
    NearbyDevices.debugOverride = null;
    NearbyDevices.debugReset();
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

    testWidgets('offers a bin on peers, never on this device', (tester) async {
      await _pumpDevices(tester, paired: paired);

      expect(find.byKey(const ValueKey<String>('forget-example-pc')), findsOne);
      expect(
        find.byKey(const ValueKey<String>('forget-example-mac')),
        findsOne,
      );
      expect(
        find.byKey(const ValueKey<String>('forget-this-device')),
        findsNothing,
      );
    });

    testWidgets('the bin asks before it breaks a pairing', (tester) async {
      await _pumpDevices(tester, paired: paired);

      await tester.tap(find.byKey(const ValueKey<String>('forget-example-pc')));
      await tester.pumpAndSettle();

      // A question, not a switch: nothing has happened yet.
      expect(find.text(kNexusForgetTitle), findsOneWidget);
      expect(find.text('My PC'), findsWidgets);

      // And every other way out of it leaves the pairing exactly where it was.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text(kNexusForgetTitle), findsNothing);
      expect(paired.devices.map((PairedDevice d) => d.name), contains('My PC'));
    });

    testWidgets('forgetting a device takes its row away and says so', (
      tester,
    ) async {
      await _pumpDevices(tester, paired: paired);

      await tester.tap(find.byKey(const ValueKey<String>('forget-example-pc')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kNexusConfirmAction));
      await tester.pumpAndSettle();

      expect(find.text('My PC'), findsNothing);
      expect(find.text('Studio Mac'), findsOneWidget);
      expect(find.text('Forgot My PC.'), findsOneWidget);
      // The screen and the store agree: the row is gone from what the next
      // start would read back, not just from what is on screen.
      expect(store.read(), completion(isNotNull));
      final List<PairedDevice>? written = await store.read();
      expect(
        written!.map((PairedDevice d) => d.name),
        isNot(contains('My PC')),
      );
    });

    testWidgets('Discover Nearby Devices listens, and lists what answered', (
      tester,
    ) async {
      final _FakeNearby nearby = _FakeNearby(<DiscoveredDevice>[_kettle]);
      NearbyDevices.debugOverride = () => nearby;
      addTearDown(NearbyDevices.debugReset);
      await _pumpDevices(tester, paired: paired);

      // Nothing heard yet: the screen says what discovery is actually doing
      // rather than showing a cheerful spinner that never ends.
      expect(find.text(nearby.status), findsOneWidget);

      await tester.tap(find.byKey(kNexusDiscoverNearby));
      await tester.pump();

      expect(find.text('Looking for devices…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // One announce cycle plus the unicast reply is three to six seconds; the
      // button waits the window out rather than answering "nobody" instantly.
      await tester.pump(kNexusDiscoverWindow);
      await tester.pumpAndSettle();

      expect(find.text('Discover Nearby Devices'), findsOneWidget);
      expect(nearby.startCalls, greaterThan(0));
      // What answered is a row, not a notice that scrolls away: the name, what
      // kind of machine it is, and the address the announcement came from.
      await _revealDevices(tester, find.text('Kitchen tablet'));
      expect(find.text('Kitchen tablet'), findsOneWidget);
      expect(find.text('Phone · 192.168.1.44:51820'), findsOneWidget);
    });

    testWidgets('tapping a heard device pairs it, with the address it used', (
      tester,
    ) async {
      NearbyDevices.debugOverride = () =>
          _FakeNearby(<DiscoveredDevice>[_kettle]);
      addTearDown(NearbyDevices.debugReset);
      await _pumpDevices(tester, paired: paired);

      // The Nearby section sits under the paired rows, below an 800x600 frame:
      // a thumb would scroll to it, and so does this.
      final Finder row = find.byKey(ValueKey<String>('nearby-${_kettle.id}'));
      await _revealDevices(tester, row);
      await tester.tap(row);
      await tester.pumpAndSettle();

      expect(find.text('Paired with Kitchen tablet'), findsOneWidget);
      expect(paired.contains(_kettle.id), isTrue);
      final PairedDevice stored = paired.devices.firstWhere(
        (PairedDevice d) => d.id == _kettle.id,
      );
      expect(stored.addresses, <String>['192.168.1.44']);
      expect(stored.port, 51820);
    });

    testWidgets('forgetting a heard device removes it from Nearby too', (
      tester,
    ) async {
      final _FakeNearby nearby = _FakeNearby(<DiscoveredDevice>[_kettle]);
      NearbyDevices.debugOverride = () => nearby;
      addTearDown(NearbyDevices.debugReset);
      await _pumpDevices(tester, paired: paired);

      // Pair it by tapping the Nearby row, then forget it: the paired row goes
      // away, and so must the Nearby row — otherwise the next announcement puts
      // the deleted device back on screen a second later.
      final Finder heardRow = find.byKey(
        ValueKey<String>('nearby-${_kettle.id}'),
      );
      await _revealDevices(tester, heardRow);
      await tester.tap(heardRow);
      await tester.pumpAndSettle();
      // Paired rows and Nearby rows are different sections, so the same device
      // that moved up is no longer listed as heard-but-unpaired.
      expect(
        find.byKey(ValueKey<String>('nearby-${_kettle.id}')),
        findsNothing,
      );

      await tester.tap(find.byKey(ValueKey<String>('forget-${_kettle.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kNexusConfirmAction));
      await tester.pumpAndSettle();

      expect(find.text('Kitchen tablet'), findsNothing);
      expect(
        find.byKey(ValueKey<String>('forget-${_kettle.id}')),
        findsNothing,
      );
      expect(paired.contains(_kettle.id), isFalse);
      expect(nearby.devices, isEmpty);
    });

    testWidgets('a paired device that is being heard says so', (tester) async {
      paired.add(
        PairInvite(
          deviceName: _kettle.name,
          deviceId: _kettle.id,
          publicKey: 'kettle-key',
          addresses: <String>[_kettle.address],
          port: _kettle.port,
        ),
      );
      NearbyDevices.debugOverride = () =>
          _FakeNearby(<DiscoveredDevice>[_kettle]);
      addTearDown(NearbyDevices.debugReset);
      await _pumpDevices(tester, paired: paired);

      // The stored row said "Desktop · this room" when it was written. What is
      // on screen now is what the network is saying now.
      expect(find.text('Seen just now at 192.168.1.44'), findsOneWidget);
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

    testWidgets(
      'Show my QR code opens a code that parses back as this device',
      (tester) async {
        await _pumpDevices(tester, paired: paired);

        await tester.tap(find.text(kNexusPairTitle));
        await tester.pumpAndSettle();
        await tester.tap(find.text(kNexusShowQrLabel));
        await tester.pumpAndSettle();

        final QrImageView qr = tester.widget<QrImageView>(
          find.byType(QrImageView),
        );
        // Drawn on white in both themes: a scanner needs the contrast.
        expect(qr.backgroundColor, Colors.white);
        expect(qr.size, greaterThanOrEqualTo(200));

        // `QrImageView` keeps its data private, so the page states what it drew
        // and the test parses that same string back into an invite.
        final String payload = tester
            .state<PairQrPageState>(find.byType(PairQrPage))
            .currentPayload;
        final PairInvite? parsed = PairInvite.parse(payload);
        expect(parsed, isNotNull);
        expect(parsed!.deviceName, 'This Phone');
        expect(parsed.deviceId, _me.id);
        expect(parsed.publicKey, 'this-key');
        // The payload is JSON, and it says what it is.
        expect(payload, startsWith('{"type":"nexus_pair"'));
        expect(find.text('This Phone'), findsOneWidget);
      },
    );

    testWidgets('the QR page stands on its own too', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: NexusTheme.light(),
          home: const PairQrPage(identity: _me),
        ),
      );
      await tester.pump();

      final PairInvite? parsed = PairInvite.parse(
        tester.state<PairQrPageState>(find.byType(PairQrPage)).currentPayload,
      );
      expect(parsed?.deviceId, _me.id);
      expect(find.textContaining('this'), findsWidgets);
    });

    testWidgets('the code carries the address this device is reachable at', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: NexusTheme.light(),
          home: PairQrPage(
            identity: _me,
            addresses: () async => <String>['192.168.1.7', '100.64.0.9'],
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Identity, name and address in one code: who this is and where to find
      // it, so the scanning device has nothing left to guess.
      final PairInvite? parsed = PairInvite.parse(
        tester.state<PairQrPageState>(find.byType(PairQrPage)).currentPayload,
      );
      expect(parsed?.deviceId, _me.id);
      expect(parsed?.deviceName, 'This Phone');
      expect(parsed?.addresses, <String>['192.168.1.7', '100.64.0.9']);
      expect(find.text('Reachable at 192.168.1.7'), findsOneWidget);
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

    testWidgets('the same device twice is one row, and says so', (
      tester,
    ) async {
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

    testWidgets('an incomplete Nexus code is a different sentence', (
      tester,
    ) async {
      final _ScanHarnessState harness = await open(tester);

      // A `nexus://pair` code, but the device id is three characters — a paste
      // that lost its tail, not a device anybody can pair with.
      harness.feed('nexus://pair?v=1&id=abc&name=PC&port=51820&code=ABCD-2345');
      await tester.pump();

      expect(find.text(kNexusLegacyPairCodeText), findsOneWidget);
      expect(find.text(kNexusNotAPairCodeText), findsNothing);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
    });

    testWidgets('the mesh\u2019s own code pairs, address and all', (
      tester,
    ) async {
      final _ScanHarnessState harness = await open(tester);

      // What a Nexus device with the mesh running actually shows: the id, the
      // name, and the address it can be reached at.
      harness.feed(
        'nexus://pair?v=1&id=pc000000000000000000000000000001&name=Study+PC'
        '&port=51820&code=ABCD-2345&ip=192.168.1.20&ips=192.168.1.20,100.64.0.4',
      );
      await tester.pumpAndSettle();

      expect(harness.result?.deviceName, 'Study PC');
      expect(harness.result?.addresses, <String>['192.168.1.20', '100.64.0.4']);
      expect(harness.result?.port, 51820);
      // The one-time code is kept: the pairing already happened, and asking the
      // user to scan it again later would be asking twice for one thing.
      expect(harness.result?.code, 'ABCD-2345');
    });

    testWidgets('a live v2 code is refused in its own words', (tester) async {
      final _ScanHarnessState harness = await open(tester);
      final QrPairingToken token = QrPairingToken.generate(
        address: '192.168.1.9',
        port: 51820,
      );

      harness.feed(token.encode());
      await tester.pump();

      // It is a real Nexus code, so it must not be called a stranger's QR — and
      // it carries no device id by design, so there is nothing to store.
      expect(find.text(kNexusLivePairCodeText), findsOneWidget);
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
          MaterialApp(theme: NexusTheme.light(), home: const PairScanPage()),
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
