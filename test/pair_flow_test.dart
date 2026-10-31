// The pairing flow, driven the way a person drives it: tap "Pair a device",
// pick one of the two answers, and see what the screen does with the result.
//
// The camera is the one thing here that cannot run, so it is the one thing the
// tests replace — `debugPairScannerOverride` stands in for the whole scanner
// page where the test is about the list, and `PairScanPage.cameraBuilder`
// stands in for the sensor where the test is about the page itself. Everything
// between those two seams (the JSON payload, the parse, the store, the notice)
// is the real code.
import 'dart:io' show Directory;

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent_contract.dart' show AgentActions;
import 'package:nexus/core/identity.dart' show DeviceInfo;
import 'package:nexus/core/pair_bridge.dart';
import 'package:nexus/core/pair_invite.dart';
import 'package:nexus/core/paired_devices.dart';
import 'package:nexus/core/qr_pairing.dart' show QrPairingToken;
import 'package:nexus/core/store.dart' show NexusStore;
import 'package:nexus/mesh/file_transfer_service.dart' show kFileTransferPort;
import 'package:nexus/mesh/mesh_service.dart'
    as mesh
    show MeshService, PairResult, PairedDevice;
import 'package:nexus/main_ui.dart'
    show
        DevicesTab,
        PairPhonePage,
        PairPhonePageState,
        kNexusCapsAssumed,
        kNexusCapsNoneAnnounced,
        kNexusCapsNoneYet,
        kNexusCapsOffline,
        kNexusCapsVerified,
        kNexusConfirmAction,
        kNexusMeshPairingToggle,
        kNexusNotConnected,
        kNexusPairingOffTurnOn,
        kNexusQrValidity,
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

/// The same device, as a code from *this* build: a transfer token, a mesh code
/// and the port the mesh is listening on. A scan of this one pairs.
const PairInvite _oceanMesh = PairInvite(
  deviceName: 'Ocean Phone',
  deviceId: 'oceanphone00000000000000000000001',
  publicKey: 'ocean-key',
  addresses: <String>['192.168.1.9'],
  port: kFileTransferPort,
  code: 'OCEAN-TOKEN',
  meshCode: 'ABCD-2345',
  meshPort: 51820,
);

/// A mesh with no sockets.
///
/// The point of these tests is what the *screen* does with a pairing it was
/// told about, so the network is the one thing replaced: [pairWithCandidates]
/// answers with what the test said, and everything between the scanner and the
/// paired list (the mesh-code check, the ordering, the row) is the real bridge.
class _FakeMesh extends mesh.MeshService {
  _FakeMesh({
    required super.identity,
    required super.store,
    List<mesh.PairedDevice>? peers,
    Set<String>? online,
    this.refusal,
    this.pairedId,
    this.pairedName = 'peer',
  }) : _peers = <mesh.PairedDevice>[...?peers],
       _online = <String>{...?online};

  final List<mesh.PairedDevice> _peers;
  final Set<String> _online;

  /// What a pairing answers, or null for "yes".
  final mesh.PairResult? refusal;

  /// The id and name a successful pairing records — the peer the code named.
  final String? pairedId;
  final String pairedName;

  /// Every pair request this mesh answered, so a test can see what was dialled.
  final List<({List<String> addresses, int port, String code})> calls =
      <({List<String> addresses, int port, String code})>[];

  /// The peer goes quiet: presence is the mesh's answer, so the row follows it.
  void goOffline(String id) {
    _online.remove(id);
    notifyListeners();
  }

  void goOnline(String id) {
    _online.add(id);
    notifyListeners();
  }

  @override
  List<mesh.PairedDevice> get pairedDevices =>
      List<mesh.PairedDevice>.unmodifiable(_peers);

  @override
  bool isOnline(String id) => _online.contains(id);

  @override
  bool isPaired(String id) => _peers.any((p) => p.id == id);

  @override
  Future<mesh.PairResult> pairWithCandidates({
    required List<String> addresses,
    required int port,
    required String code,
  }) async {
    calls.add((addresses: addresses, port: port, code: code));
    final mesh.PairResult? refused = refusal;
    if (refused != null) return refused;
    final String id = pairedId ?? 'paired-${_peers.length}';
    _peers.add(
      mesh.PairedDevice(
        id: id,
        name: pairedName,
        platform: 'android',
        address: addresses.first,
        port: port,
        pairingSecret: code,
      ),
    );
    notifyListeners();
    return mesh.PairResult.ok(pairedName);
  }
}

/// One peer as the mesh records it.
mesh.PairedDevice _meshPeer({
  required String id,
  required String name,
  String platform = 'android',
  String address = '192.168.1.44',
  int port = 51820,
  Set<String> caps = const <String>{},
  bool announced = false,
  bool verified = false,
}) => mesh.PairedDevice(
  id: id,
  name: name,
  platform: platform,
  address: address,
  port: port,
  pairingSecret: 'secret',
  lastVerified: DateTime(2026, 10, 27, 9),
  announcedCaps: caps.toSet(),
  capabilitiesAnnounced: announced,
  announcedCapsVerified: verified,
);

/// A fixed identity, so the QR the page draws is the QR the test parses.
const PairIdentity _me = PairIdentity(
  name: 'This Phone',
  id: 'thisphone0000000000000000000000001',
  publicKey: 'this-key',
);

/// The same identity with its transfer token already loaded — the token is a
/// preference read, and a test that asserts on both secrets has to state it.
const PairIdentity _meWithToken = PairIdentity(
  name: 'This Phone',
  id: 'thisphone0000000000000000000000001',
  publicKey: 'this-key',
  token: 'FILE-TOKEN',
);

/// Puts the screen on a phone-sized frame with the app's own theme, which is
/// what the tokens and the row metrics were chosen against.
Future<void> _pumpDevices(
  WidgetTester tester, {
  required PairedDevices paired,
  mesh.MeshService? mesh,
}) async {
  PairedDevices.override = () => paired;
  await tester.pumpWidget(
    MaterialApp(
      theme: NexusTheme.light(),
      home: Scaffold(body: DevicesTab(mesh: mesh)),
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
  late Directory tmp;
  late NexusStore meshStore;

  setUp(() async {
    // A fresh store per test: the list is persisted, so a shared one would let
    // one test's pairing show up in the next.
    store = MemoryPairedDevicesStore();
    paired = PairedDevices(store: store);
    PairIdentity.override = () => _me;
    // The mesh's own store: pairing is a preference the mesh reads live, and a
    // test that flips the switch has to see the same value the mesh will.
    tmp = await Directory.systemTemp.createTemp('nexus_pair_flow');
    meshStore = NexusStore(explicitPath: '${tmp.path}/mesh.json')
      ..pairingEnabled = true;
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
    PairedDevices.override = null;
    NearbyDevices.debugOverride = null;
    NearbyDevices.debugReset();
    PairIdentity.override = null;
    PairIdentity.debugReset();
    debugPairScannerOverride = null;
  });

  /// A mesh for one test: no sockets, the presence the test states, and a
  /// pairing that answers yes unless the test says otherwise.
  _FakeMesh fakeMesh({
    List<mesh.PairedDevice>? peers,
    Set<String>? online,
    mesh.PairResult? refusal,
    String? pairedId,
    String pairedName = 'peer',
    bool pairingEnabled = true,
  }) {
    meshStore.pairingEnabled = pairingEnabled;
    return _FakeMesh(
      identity: DeviceInfo(
        id: 'thisphone0000000000000000000000001',
        name: 'This Phone',
        platform: 'android',
      ),
      store: meshStore,
      peers: peers,
      online: online,
      refusal: refusal,
      pairedId: pairedId,
      pairedName: pairedName,
    );
  }

  /// A paired list that starts empty, so a test's screen holds only the rows
  /// it named — the seed's two example machines would otherwise make every
  /// "Not connected" count a count of them too.
  PairedDevices rowsFor(List<PairedDevice> rows) =>
      PairedDevices(store: MemoryPairedDevicesStore(), seed: rows);

  /// One row as the shell writes it when a device scans this one's code.
  PairedDevice shellRow({
    required String id,
    required String name,
    String platform = 'android',
    String address = '192.168.1.44',
    int port = 51820,
    String code = 'TOKEN-2345',
  }) => PairedDevice(
    id: id,
    name: name,
    publicKey: 'peer-key',
    detail: 'Paired just now',
    online: true,
    addresses: <String>[address],
    port: port,
    code: code,
    platform: platform,
  );

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
      // The cards are taller than the old rows, so the pairing action sits
      // below the fold on the test surface — the thumb scrolls to it.
      await _revealDevices(tester, find.text(kNexusPairTitle));
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
      await _revealDevices(tester, find.text(nearby.status));
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
      await _revealDevices(tester, find.text('Seen just now at 192.168.1.44'));
      expect(find.text('Seen just now at 192.168.1.44'), findsOneWidget);
    });

    testWidgets('mesh pairing is a switch, off until it is turned on', (
      tester,
    ) async {
      await _pumpDevices(
        tester,
        paired: paired,
        mesh: fakeMesh(pairingEnabled: false),
      );
      await _revealDevices(tester, find.byKey(kNexusMeshPairingToggle));

      // Off is stated in the user's words, not only in a switch position: a
      // hidden default is the thing this row exists to avoid.
      expect(
        find.text(
          'Off — no device can pair with this one until you turn this on.',
        ),
        findsOneWidget,
      );
      final Finder toggle = find.descendant(
        of: find.byKey(kNexusMeshPairingToggle),
        matching: find.byType(Switch),
      );
      expect(tester.widget<Switch>(toggle).value, isFalse);

      await tester.tap(toggle);
      await tester.pumpAndSettle();

      expect(tester.widget<Switch>(toggle).value, isTrue);
      // The store, not the widget: the mesh reads this value on the next
      // inbound request, so what is saved is what actually decides.
      expect(meshStore.pairingEnabled, isTrue);
    });

    testWidgets('a row the mesh does not know says so, and offers to pair', (
      tester,
    ) async {
      final PairedDevices shell = rowsFor(<PairedDevice>[
        shellRow(id: _kettle.id, name: 'Kitchen tablet'),
      ]);
      await _pumpDevices(tester, paired: shell, mesh: fakeMesh());

      // A file destination with no mesh pairing is not an offline device: the
      // mesh has never met it, and the row says that instead of a grey dot.
      expect(find.text(kNexusNotConnected), findsOneWidget);

      await tester.tap(
        find.byKey(ValueKey<String>('pair-again-${_kettle.id}')),
      );
      await tester.pumpAndSettle();

      // "Pair again" is the way back to a pairing, not a notice that says it
      // once existed.
      expect(find.text(kNexusScanQrLabel), findsOneWidget);
    });

    testWidgets('a proved capability list is chips with the verified word', (
      tester,
    ) async {
      final PairedDevices shell = rowsFor(<PairedDevice>[
        shellRow(id: _kettle.id, name: 'Kitchen tablet'),
      ]);
      await _pumpDevices(
        tester,
        paired: shell,
        mesh: fakeMesh(
          peers: <mesh.PairedDevice>[
            _meshPeer(
              id: _kettle.id,
              name: 'Kitchen tablet',
              caps: <String>{
                AgentActions.screenshot,
                AgentActions.flashlightToggle,
              },
              announced: true,
              verified: true,
            ),
          ],
          online: <String>{_kettle.id},
        ),
      );

      expect(find.text('Screenshot'), findsOneWidget);
      expect(find.text('Flashlight'), findsOneWidget);
      expect(find.text(kNexusCapsVerified), findsOneWidget);
    });

    testWidgets('a list that arrived unproved is chips, said as announced', (
      tester,
    ) async {
      final PairedDevices shell = rowsFor(<PairedDevice>[
        shellRow(id: _kettle.id, name: 'Kitchen tablet'),
      ]);
      await _pumpDevices(
        tester,
        paired: shell,
        mesh: fakeMesh(
          peers: <mesh.PairedDevice>[
            _meshPeer(
              id: _kettle.id,
              name: 'Kitchen tablet',
              caps: <String>{AgentActions.screenshot},
              announced: true,
            ),
          ],
          online: <String>{_kettle.id},
        ),
      );

      expect(find.text('Screenshot'), findsOneWidget);
      expect(find.text(kNexusCapsAssumed), findsOneWidget);
      expect(find.text(kNexusCapsVerified), findsNothing);
    });

    testWidgets('a peer that announced nothing says so, without a fallback', (
      tester,
    ) async {
      final PairedDevices shell = rowsFor(<PairedDevice>[
        shellRow(id: _kettle.id, name: 'Kitchen tablet'),
      ]);
      await _pumpDevices(
        tester,
        paired: shell,
        mesh: fakeMesh(
          peers: <mesh.PairedDevice>[
            _meshPeer(id: _kettle.id, name: 'Kitchen tablet'),
          ],
          online: <String>{_kettle.id},
        ),
      );

      // Never announced is its own sentence: the platform's capabilities are
      // not substituted for what this device actually said.
      expect(find.text(kNexusCapsNoneYet), findsOneWidget);
      expect(find.text(kNexusCapsNoneAnnounced), findsNothing);
    });

    testWidgets('a peer that announced an empty list is a different sentence', (
      tester,
    ) async {
      final PairedDevices shell = rowsFor(<PairedDevice>[
        shellRow(id: _kettle.id, name: 'Kitchen tablet'),
      ]);
      await _pumpDevices(
        tester,
        paired: shell,
        mesh: fakeMesh(
          peers: <mesh.PairedDevice>[
            _meshPeer(
              id: _kettle.id,
              name: 'Kitchen tablet',
              announced: true,
              verified: true,
            ),
          ],
          online: <String>{_kettle.id},
        ),
      );

      expect(find.text(kNexusCapsNoneAnnounced), findsOneWidget);
      expect(find.text(kNexusCapsNoneYet), findsNothing);
    });

    testWidgets('a peer going offline collapses its chips to Offline', (
      tester,
    ) async {
      final PairedDevices shell = rowsFor(<PairedDevice>[
        shellRow(id: _kettle.id, name: 'Kitchen tablet'),
      ]);
      final _FakeMesh fake = fakeMesh(
        peers: <mesh.PairedDevice>[
          _meshPeer(
            id: _kettle.id,
            name: 'Kitchen tablet',
            caps: <String>{AgentActions.screenshot},
            announced: true,
            verified: true,
          ),
        ],
        online: <String>{_kettle.id},
      );
      await _pumpDevices(tester, paired: shell, mesh: fake);
      expect(find.text('Screenshot'), findsOneWidget);

      fake.goOffline(_kettle.id);
      await tester.pump();

      // Gone, not greyed. A dimmed chip still reads as a claim about a device
      // that is not answering, and the row has one honest word for that.
      expect(find.text('Screenshot'), findsNothing);
      final Text line = tester.widget<Text>(
        find.byKey(ValueKey<String>('caps-${_kettle.id}')),
      );
      expect(line.data, kNexusCapsOffline);
    });

    testWidgets('a device that paired into this one appears on the list', (
      tester,
    ) async {
      // It scanned our code, so the mesh knows it and nothing wrote a shell row.
      await _pumpDevices(
        tester,
        paired: rowsFor(<PairedDevice>[]),
        mesh: fakeMesh(
          peers: <mesh.PairedDevice>[
            _meshPeer(id: 'study-pc-000000000000000000001', name: 'Study PC'),
          ],
          online: <String>{'study-pc-000000000000000000001'},
        ),
      );

      expect(find.text('Study PC'), findsOneWidget);
      expect(find.textContaining('Paired over the mesh'), findsOneWidget);
    });
  });

  group('the pairing sheet', () {
    testWidgets('opens with both answers', (tester) async {
      await _pumpDevices(tester, paired: paired);
      await _revealDevices(tester, find.text(kNexusPairTitle));

      await tester.tap(find.text(kNexusPairTitle));
      await tester.pumpAndSettle();

      expect(find.text(kNexusScanQrLabel), findsOneWidget);
      expect(find.text(kNexusShowQrLabel), findsOneWidget);
    });

    testWidgets(
      'Show my QR code opens a code that parses back as this device',
      (tester) async {
        await _pumpDevices(tester, paired: paired);
        await _revealDevices(tester, find.text(kNexusPairTitle));

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

    testWidgets('the code carries the mesh pairing and the mesh port', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: NexusTheme.light(),
          home: PairQrPage(
            identity: _meWithToken,
            mesh: fakeMesh(),
            addresses: () async => <String>['192.168.1.7'],
          ),
        ),
      );
      await tester.pumpAndSettle();

      final PairInvite? parsed = PairInvite.parse(
        tester.state<PairQrPageState>(find.byType(PairQrPage)).currentPayload,
      );
      // Both secrets in one code: the transfer token under `code`, and the
      // five-minute mesh code under `mesh_code` with the port it dials.
      expect(parsed?.code, isNotEmpty);
      expect(parsed?.meshCode, isNotEmpty);
      expect(parsed?.meshCode, isNot(parsed?.code));
      expect(parsed?.meshPort, 51820);
      expect(parsed?.port, kFileTransferPort);
      expect(find.text(kNexusQrValidity), findsOneWidget);
    });

    testWidgets('with pairing off the page says so instead of drawing a code', (
      tester,
    ) async {
      final _FakeMesh fake = fakeMesh(pairingEnabled: false);
      await tester.pumpWidget(
        MaterialApp(
          theme: NexusTheme.light(),
          home: PairQrPage(identity: _me, mesh: fake),
        ),
      );
      await tester.pumpAndSettle();

      // A code on screen that the mesh will refuse is a scan that fails
      // silently on the other device, so there is no code on screen.
      expect(find.byType(QrImageView), findsNothing);
      expect(find.text('Mesh pairing is off'), findsOneWidget);

      await tester.tap(find.byKey(kNexusPairingOffTurnOn));
      await tester.pumpAndSettle();

      expect(meshStore.pairingEnabled, isTrue);
      expect(find.byType(QrImageView), findsOneWidget);
      final PairInvite? parsed = PairInvite.parse(
        tester.state<PairQrPageState>(find.byType(PairQrPage)).currentPayload,
      );
      expect(parsed?.meshCode, isNotEmpty);
    });

    testWidgets('a page with no mesh still draws its file code', (
      tester,
    ) async {
      // The old behaviour is kept for exactly one case — a page built with no
      // mesh behind it — and the scanning side is what refuses it, with the
      // "update Nexus" sentence rather than a half pairing.
      await tester.pumpWidget(
        MaterialApp(
          theme: NexusTheme.light(),
          home: const PairQrPage(identity: _me),
        ),
      );
      await tester.pumpAndSettle();

      final PairInvite? parsed = PairInvite.parse(
        tester.state<PairQrPageState>(find.byType(PairQrPage)).currentPayload,
      );
      expect(parsed?.deviceId, _me.id);
      expect(parsed?.meshCode, isEmpty);
      expect(find.text(kNexusQrValidity), findsNothing);
    });

    testWidgets('the PC\u2019s Pair Phone code carries the mesh pairing too', (
      tester,
    ) async {
      // The other door into the same room: a phone scans this from Settings on
      // the PC. Without a mesh code the phone now refuses it as an old code, so
      // this page has to mint one as well.
      await tester.pumpWidget(
        MaterialApp(
          theme: NexusTheme.light(),
          home: PairPhonePage(
            mesh: fakeMesh(),
            identity: _meWithToken,
            addresses: () async => <String>['192.168.1.100'],
          ),
        ),
      );
      await tester.pumpAndSettle();

      final PairInvite? parsed = PairInvite.parse(
        tester
            .state<PairPhonePageState>(find.byType(PairPhonePage))
            .currentPayload,
      );
      expect(parsed?.deviceId, _me.id);
      expect(parsed?.code, 'FILE-TOKEN');
      expect(parsed?.meshCode, isNotEmpty);
      expect(parsed?.meshCode, isNot(parsed?.code));
      expect(parsed?.meshPort, 51820);
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
      await _pumpDevices(
        tester,
        paired: paired,
        mesh: fakeMesh(
          pairedId: _oceanMesh.deviceId,
          pairedName: 'Ocean Phone',
        ),
      );
      debugPairScannerOverride = (BuildContext context) async => _oceanMesh;
      await _revealDevices(tester, find.text(kNexusPairTitle));

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
      await _pumpDevices(
        tester,
        paired: paired,
        mesh: fakeMesh(
          pairedId: _oceanMesh.deviceId,
          pairedName: 'Ocean Phone',
        ),
      );
      debugPairScannerOverride = (BuildContext context) async => _oceanMesh;

      for (int i = 0; i < 2; i++) {
        await _revealDevices(tester, find.text(kNexusPairTitle));
        await tester.tap(find.text(kNexusPairTitle));
        await tester.pumpAndSettle();
        await tester.tap(find.text(kNexusScanQrLabel));
        await tester.pumpAndSettle();
      }

      expect(find.text('Ocean Phone is already paired.'), findsOneWidget);
      // The sheet leaves the list scrolled down to the pairing row, and the
      // card this test counts is above it: a lazy list has unmounted what is
      // off the top, so scroll back before counting rows. One row is what is
      // being asserted, not where on the page it happens to sit.
      for (
        int i = 0;
        i < 6 && find.text('Ocean Phone').evaluate().isEmpty;
        i++
      ) {
        await tester.drag(find.byType(Scrollable).first, const Offset(0, 400));
        await tester.pumpAndSettle();
      }
      expect(find.text('Ocean Phone'), findsOneWidget);
      expect(
        paired.devices.where((PairedDevice d) => d.id == _ocean.deviceId),
        hasLength(1),
      );
    });

    testWidgets('a scan dials the mesh code and the mesh port', (tester) async {
      final _FakeMesh fake = fakeMesh(
        pairedId: _oceanMesh.deviceId,
        pairedName: 'Ocean Phone',
      );
      await _pumpDevices(tester, paired: paired, mesh: fake);
      debugPairScannerOverride = (BuildContext context) async => _oceanMesh;
      await _revealDevices(tester, find.text(kNexusPairTitle));

      await tester.tap(find.text(kNexusPairTitle));
      await tester.pumpAndSettle();
      await tester.tap(find.text(kNexusScanQrLabel));
      await tester.pumpAndSettle();

      // Two ports in one code, and the pairing uses the mesh's: 51820, not the
      // file link's 51821. Dialling the file port would knock on the wrong
      // listener and read as "the other device did not answer".
      expect(fake.calls.single.addresses, <String>['192.168.1.9']);
      expect(fake.calls.single.port, 51820);
      expect(fake.calls.single.code, 'ABCD-2345');
      // The row keeps the file link's port, because that is what a transfer
      // dials.
      final PairedDevice row = paired.devices.firstWhere(
        (PairedDevice d) => d.id == _oceanMesh.deviceId,
      );
      expect(row.port, kFileTransferPort);
      expect(row.code, 'OCEAN-TOKEN');
    });

    testWidgets('a code from an older build asks for a fresh one', (
      tester,
    ) async {
      final _FakeMesh fake = fakeMesh();
      await _pumpDevices(tester, paired: paired, mesh: fake);
      // `_ocean` is a code from before this pass: a transfer token and no
      // `mesh_code`. Pairing it would write the half-state the bridge refuses.
      debugPairScannerOverride = (BuildContext context) async => _ocean;
      await _revealDevices(tester, find.text(kNexusPairTitle));

      await tester.tap(find.text(kNexusPairTitle));
      await tester.pumpAndSettle();
      await tester.tap(find.text(kNexusScanQrLabel));
      await tester.pumpAndSettle();

      expect(find.text(kPairNeedsFreshCodeText), findsOneWidget);
      expect(paired.contains(_ocean.deviceId), isFalse);
      // Nothing was dialled: an old code is not a network problem.
      expect(fake.calls, isEmpty);
    });

    testWidgets('a refused pairing writes no row and says why', (tester) async {
      final _FakeMesh fake = fakeMesh(
        refusal: const mesh.PairResult.failure('The other device declined.'),
      );
      await _pumpDevices(tester, paired: paired, mesh: fake);
      debugPairScannerOverride = (BuildContext context) async => _oceanMesh;
      await _revealDevices(tester, find.text(kNexusPairTitle));

      await tester.tap(find.text(kNexusPairTitle));
      await tester.pumpAndSettle();
      await tester.tap(find.text(kNexusScanQrLabel));
      await tester.pumpAndSettle();

      expect(find.text('The other device declined.'), findsOneWidget);
      // Both records or neither: the mesh refused, so no row appeared.
      expect(paired.contains(_oceanMesh.deviceId), isFalse);
    });

    testWidgets('backing out of the camera changes nothing', (tester) async {
      await _pumpDevices(tester, paired: paired);
      debugPairScannerOverride = (BuildContext context) async => null;
      await _revealDevices(tester, find.text(kNexusPairTitle));

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
