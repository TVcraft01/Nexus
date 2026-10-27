// The pairing bridge: one scan, both records or neither.
//
// Two layers are tested here and they are deliberately different in kind. The
// first group is a real pairing over real loopback sockets — two `MeshService`
// instances, a code one of them minted, and the invite a QR would have carried.
// That is the case a mock cannot prove: the code has to arrive on the other side
// through `_handlePairRequest`, be accepted, and be persisted on both.
//
// The second group is the decisions the bridge makes before any socket opens —
// an old code, a code with nowhere to dial, a pairing the peer refuses. Those
// are the ones that decide whether a row is written, so they are pinned
// separately rather than inferred from the happy path.
import 'dart:io' show Directory;

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/identity.dart' show DeviceInfo;
import 'package:nexus/core/pair_bridge.dart';
import 'package:nexus/core/pair_invite.dart';
import 'package:nexus/core/paired_devices.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/mesh/file_transfer_service.dart' show kFileTransferPort;
import 'package:nexus/mesh/mesh_service.dart'
    show MeshService, PairingSession;

/// Waits for [condition], or fails the test with the last state it saw.
Future<void> _waitFor(bool Function() condition, {String? reason}) async {
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 6));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail(reason ?? 'condition was still false after 6 s');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

void main() {
  late Directory tmp;
  late NexusStore storeA;
  late NexusStore storeB;
  late MeshService meshA;
  late MeshService meshB;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('nexus_pair_bridge');
    storeA = NexusStore(explicitPath: '${tmp.path}/a.json')
      ..port = 53410
      ..pairingEnabled = true;
    storeB = NexusStore(explicitPath: '${tmp.path}/b.json')
      ..port = 53411
      ..pairingEnabled = true;
    await storeA.save();
    await storeB.save();
    meshA = MeshService(
      identity: DeviceInfo(id: 'bridge-a', name: 'Study PC', platform: 'linux'),
      store: storeA,
      connectTimeout: const Duration(milliseconds: 400),
    );
    meshB = MeshService(
      identity: DeviceInfo(id: 'bridge-b', name: 'Kitchen tablet', platform: 'android'),
      store: storeB,
      connectTimeout: const Duration(milliseconds: 400),
    );
  });

  tearDown(() async {
    await meshA.stop();
    await meshB.stop();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  /// What the study PC's QR carries: who it is, where it is, the file token it
  /// would have, and the mesh code it is showing right now.
  PairInvite inviteFrom(MeshService host, PairingSession session) => PairInvite(
    deviceName: host.identity.name,
    deviceId: host.identity.id,
    publicKey: 'host-key',
    addresses: <String>['127.0.0.1'],
    port: kFileTransferPort,
    code: 'HOST-TOKEN',
    meshCode: session.code,
    meshPort: host.port,
  );

  group('a scan over real loopback', () {
    test('pairs both sides, and writes the row on the scanning side', () async {
      await meshA.start();
      await meshB.start();
      final PairingSession session = meshA.beginPairing();
      final PairedDevices shell = PairedDevices(
        store: MemoryPairedDevicesStore(),
        seed: const <PairedDevice>[],
      );

      final PairOutcome outcome = await pairScannedDevice(
        mesh: meshB,
        invite: inviteFrom(meshA, session),
        paired: shell,
      );

      expect(outcome.ok, isTrue, reason: outcome.message);
      expect(outcome.added, isTrue);
      expect(outcome.notice, 'Paired with Study PC');
      // Both records, both sides: the mesh on the scanner, the mesh on the
      // host, and the shell row only on the scanner.
      expect(meshB.isPaired('bridge-a'), isTrue);
      expect(meshA.isPaired('bridge-b'), isTrue);
      expect(shell.contains('bridge-a'), isTrue);
      expect(shell.devices.single.port, kFileTransferPort);
      expect(shell.devices.single.code, 'HOST-TOKEN');

      // Phase 2's evidence arrives on the pairing itself: the host's capability
      // list, proved by the exchange that just happened.
      await _waitFor(
        () =>
            meshB.pairedDevices.isNotEmpty &&
            meshB.pairedDevices.single.announcedCapsVerified,
        reason: 'the host never announced a proved capability list',
      );
      expect(meshB.pairedDevices.single.announcedCaps, isNotEmpty);
      final PeerPresence? presence = peerPresence(meshB, 'bridge-a');
      expect(presence, isNotNull);
      expect(presence!.announced, isTrue);
      expect(presence.verified, isTrue);
      expect(presence.caps, isNotEmpty);
    });

    test('a second scan of the same device adds no second row', () async {
      await meshA.start();
      await meshB.start();
      final PairingSession session = meshA.beginPairing();
      final PairInvite invite = inviteFrom(meshA, session);
      final PairedDevices shell = PairedDevices(
        store: MemoryPairedDevicesStore(),
        seed: const <PairedDevice>[],
      );

      final PairOutcome first = await pairScannedDevice(
        mesh: meshB,
        invite: invite,
        paired: shell,
      );
      final PairOutcome second = await pairScannedDevice(
        mesh: meshB,
        invite: invite,
        paired: shell,
      );

      expect(first.added, isTrue);
      expect(second.ok, isTrue);
      expect(second.added, isFalse);
      expect(second.notice, 'Study PC is already paired.');
      expect(shell.devices, hasLength(1));
    });

    test('a pairing the host refuses writes nothing here', () async {
      await meshA.start();
      await meshB.start();
      // No `beginPairing` on the host, so it has no code to accept: the request
      // decrypts under a key nobody is waiting for.
      final PairedDevices shell = PairedDevices(
        store: MemoryPairedDevicesStore(),
        seed: const <PairedDevice>[],
      );
      final PairInvite invite = PairInvite(
        deviceName: 'Study PC',
        deviceId: 'bridge-a',
        publicKey: 'host-key',
        addresses: <String>['127.0.0.1'],
        port: kFileTransferPort,
        code: 'HOST-TOKEN',
        meshCode: 'ABCD-2345',
        meshPort: meshA.port,
      );

      final PairOutcome outcome = await pairScannedDevice(
        mesh: meshB,
        invite: invite,
        paired: shell,
      );

      expect(outcome.ok, isFalse);
      expect(shell.devices, isEmpty);
      expect(meshB.isPaired('bridge-a'), isFalse);
    });
  });

  group('the decisions made before a socket opens', () {
    test('an old code asks for a fresh one, and dials nothing', () async {
      final PairedDevices shell = PairedDevices(
        store: MemoryPairedDevicesStore(),
        seed: const <PairedDevice>[],
      );
      // A code from before this pass: a file token and no mesh code at all.
      const PairInvite old = PairInvite(
        deviceName: 'Old Phone',
        deviceId: 'oldphone00000000000000000000001',
        publicKey: 'old-key',
        addresses: <String>['127.0.0.1'],
        port: kFileTransferPort,
        code: 'OLD-TOKEN',
      );

      final PairOutcome outcome = await pairScannedDevice(
        mesh: meshB,
        invite: old,
        paired: shell,
      );

      expect(outcome.ok, isFalse);
      expect(outcome.message, kPairNeedsFreshCodeText);
      expect(shell.devices, isEmpty);
    });

    test('a mesh code with no address is its own sentence', () async {
      final PairedDevices shell = PairedDevices(
        store: MemoryPairedDevicesStore(),
        seed: const <PairedDevice>[],
      );
      const PairInvite nowhere = PairInvite(
        deviceName: 'Nowhere',
        deviceId: 'nowhere000000000000000000000001',
        publicKey: 'key',
        port: kFileTransferPort,
        code: 'TOKEN-2345',
        meshCode: 'ABCD-2345',
        meshPort: 51820,
      );

      final PairOutcome outcome = await pairScannedDevice(
        mesh: meshB,
        invite: nowhere,
        paired: shell,
      );

      expect(outcome.ok, isFalse);
      expect(outcome.message, kPairNoAddressText);
      expect(shell.devices, isEmpty);
    });

    test('a shell row the mesh has no pairing for is repairable, not paired', () async {
      // The state an upgrade leaves behind: a row from an older build whose
      // device the mesh has never met. It must not be reported as already
      // paired, because pairing it again is the fix.
      final PairedDevices shell = PairedDevices(
        store: MemoryPairedDevicesStore(),
        seed: <PairedDevice>[
          const PairedDevice(
            id: 'bridge-a',
            name: 'Study PC',
            publicKey: '',
            addresses: <String>['127.0.0.1'],
            port: kFileTransferPort,
            code: 'HOST-TOKEN',
          ),
        ],
      );

      await meshA.start();
      final PairingSession session = meshA.beginPairing();
      final PairOutcome outcome = await pairScannedDevice(
        mesh: meshB,
        invite: inviteFrom(meshA, session),
        paired: shell,
      );

      expect(outcome.ok, isTrue, reason: outcome.message);
      expect(meshB.isPaired('bridge-a'), isTrue);
      expect(shell.devices, hasLength(1));
    });
  });

  group('the join onto the shell list', () {
    test('a device that paired into this one becomes a row', () async {
      await meshA.start();
      await meshB.start();
      final PairingSession session = meshA.beginPairing();
      final PairedDevices hostShell = PairedDevices(
        store: MemoryPairedDevicesStore(),
        seed: const <PairedDevice>[],
      );

      // B scans A's code: A stores B in the mesh and no shell row is written
      // on A's side.
      final PairOutcome outcome = await pairScannedDevice(
        mesh: meshB,
        invite: inviteFrom(meshA, session),
        paired: PairedDevices(
          store: MemoryPairedDevicesStore(),
          seed: const <PairedDevice>[],
        ),
      );
      expect(outcome.ok, isTrue, reason: outcome.message);

      final List<PairedDevice> extra = meshOnlyRows(meshA, hostShell);
      expect(extra, hasLength(1));
      expect(extra.single.id, 'bridge-b');
      expect(extra.single.name, 'Kitchen tablet');
      expect(extra.single.port, storeB.port);
      // A mesh-only row is not a file destination: the token belongs to the
      // other device and was never given to this one.
      expect(extra.single.code, isEmpty);
    });

    test('a device both lists know is not listed twice', () async {
      await meshA.start();
      await meshB.start();
      final PairingSession session = meshA.beginPairing();
      final PairedDevices shell = PairedDevices(
        store: MemoryPairedDevicesStore(),
        seed: const <PairedDevice>[],
      );
      await pairScannedDevice(
        mesh: meshB,
        invite: inviteFrom(meshA, session),
        paired: shell,
      );

      expect(meshOnlyRows(meshB, shell), isEmpty);
    });
  });
}
