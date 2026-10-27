/// The seam between the shell's paired list and the mesh's pairing.
///
/// Before this file the two lists were two answers to one question. A scan added
/// a row to [PairedDevices] and stopped there: the row said "Paired", the mesh
/// had never heard of the device, and nothing on the row could actually reach it
/// except a file transfer. Meanwhile a device that paired by scanning *our* code
/// existed only in the mesh, so it was absent from the list the user reads.
///
/// The rule this file exists to enforce: **a scan pairs the mesh or it adds no
/// row.** One scan, one answer. The mesh goes first because it is the half that
/// can fail; the row is written only after the peer has accepted, so a row that
/// exists is a pairing that exists.
///
/// What is deliberately *not* here: [PairedDevices] does not become a projection
/// of the mesh (that is the next pass), and nothing in this file changes the
/// wire format. It reads what Phase 2 already announces — [PeerPresence] — and
/// joins it onto the shell's row by device id.
library;

import '../mesh/mesh_service.dart' show MeshService, PairResult;
import 'pair_invite.dart';
import 'paired_devices.dart';

/// What the scanner says about a code that carries no mesh code.
///
/// This is the old-QR case, and it is the whole reason the sentence exists: a
/// code written before this pass pairs files only, and completing it silently
/// would be the half-state the bridge refuses. `mesh_code` absent is not a
/// malformed payload — it is a code from a build that did not have one.
const String kPairNeedsFreshCodeText =
    'Ask the other device to update Nexus and show a fresh code.';

/// A code with nowhere to dial. Rare (a device with no interface up), and its
/// own sentence because "update Nexus" would send the user to the wrong repair.
const String kPairNoAddressText =
    'That code has no address to connect to — ask the other device to show a '
    'fresh code.';

/// The message for a shell that has no mesh behind it.
///
/// Not a user-facing state in a shipped build — `main_ui.main()` always starts
/// the mesh — but a widget test builds the shell without one, and a test that
/// silently wrote a row would be testing a build nobody ships.
const String kPairNoMeshText =
    'Mesh pairing is not running here, so this device cannot pair.';

/// How one scan ended, in the words the screen says.
class PairOutcome {
  const PairOutcome.paired(this.peerName)
    : ok = true,
      added = true,
      message = '';

  const PairOutcome.alreadyPaired(this.peerName)
    : ok = true,
      added = false,
      message = '';

  const PairOutcome.failure(this.message)
    : ok = false,
      added = false,
      peerName = null;

  /// True when both records exist (or both already did).
  final bool ok;

  /// True when this scan is what added the row.
  final bool added;

  /// The name to say, when there is one.
  final String? peerName;

  /// The sentence for the notice. Empty for success — [notice] is the one to
  /// show, and it is what the screen already said before this pass.
  final String message;

  /// The notice text for either ending.
  String get notice => ok
      ? (added ? 'Paired with $peerName' : '$peerName is already paired.')
      : message;
}

/// Pairs the device a QR described: the mesh first, the row second.
///
/// [invite] is what the scanner read. On success both sides hold a
/// `PairDevice`; on any failure neither side wrote anything here, which is the
/// property the tests pin rather than the sentences.
Future<PairOutcome> pairScannedDevice({
  required MeshService mesh,
  required PairInvite invite,
  required PairedDevices paired,
}) async {
  final int port = invite.meshPort > 0 ? invite.meshPort : invite.port;
  // Checked before anything is dialled: an old code is not a network problem,
  // and retrying it would produce a timeout that says nothing about the cause.
  if (invite.meshCode.isEmpty) {
    return const PairOutcome.failure(kPairNeedsFreshCodeText);
  }
  if (invite.addresses.isEmpty || port <= 0) {
    return const PairOutcome.failure(kPairNoAddressText);
  }
  // Already both: asking the peer to pair again would spend its code and
  // rewrite the row for no change. A row without a mesh pairing is *not* this
  // case — that one is repaired by pairing.
  if (paired.contains(invite.deviceId) && mesh.isPaired(invite.deviceId)) {
    return PairOutcome.alreadyPaired(invite.deviceName);
  }
  final PairResult result = await mesh.pairWithCandidates(
    addresses: invite.addresses,
    port: port,
    code: invite.meshCode,
  );
  if (!result.ok) {
    return PairOutcome.failure(result.error ?? 'Pairing failed.');
  }
  // The mesh accepted, so the row is truthful. `add` answers false when an
  // older row was already there — the pairing it was missing is now made, which
  // is an improvement the notice should not call a duplicate, but "already
  // paired" is still the true sentence for that row.
  final bool added = paired.add(invite);
  return added
      ? PairOutcome.paired(invite.deviceName)
      : PairOutcome.alreadyPaired(invite.deviceName);
}

/// What the mesh knows about one peer right now.
///
/// The three-state capability rule lives in these four fields, and the reason
/// they are carried together is that no one of them answers the question:
///
/// - [announced] false: a legacy peer that has never sent a list. The row says
///   so, and the platform's own defaults are *not* substituted for it.
/// - [announced] true, [caps] empty: the peer said it can do nothing. That is
///   an answer, not a missing one, and the row says it differently.
/// - [announced] true, [caps] non-empty, [verified] false: the list arrived,
///   but not on a frame this device proved who sent. Shown as announced.
/// - [announced] true, [caps] non-empty, [verified] true: proved.
///
/// [online] is the mesh's honest-presence answer (a verified exchange in the
/// last 25 s), never "the row was written online".
class PeerPresence {
  const PeerPresence({
    required this.online,
    required this.announced,
    required this.verified,
    required this.caps,
  });

  final bool online;
  final bool announced;
  final bool verified;
  final Set<String> caps;
}

/// The mesh's record for [id], or null when the mesh has never paired it.
///
/// Null is meaningful and is not "offline": it is the shell row that only knows
/// how to send files, and the row says "Not connected · pair again" instead of
/// drawing an OFFLINE badge over a device the mesh has never met.
PeerPresence? peerPresence(MeshService? mesh, String id) {
  if (mesh == null) return null;
  for (final peer in mesh.pairedDevices) {
    if (peer.id != id) continue;
    return PeerPresence(
      online: mesh.isOnline(id),
      announced: peer.capabilitiesAnnounced,
      verified: peer.announcedCapsVerified,
      caps: peer.announcedCaps,
    );
  }
  return null;
}

/// Rows for peers the mesh knows and [paired] does not.
///
/// This is the other direction of the same join, and it is not hypothetical: a
/// device that scans *our* QR pairs into the mesh through `acceptQrPairing` or
/// the classic code, and nothing on that path writes a shell row. Without this
/// the person who just paired with us would not appear in our own Devices tab.
///
/// The row has no transfer token — the peer never gave us one — so it is a
/// device we can see, ping and show, but not a file destination until it scans
/// our code back.
List<PairedDevice> meshOnlyRows(MeshService? mesh, PairedDevices paired) {
  if (mesh == null) return const <PairedDevice>[];
  return <PairedDevice>[
    for (final peer in mesh.pairedDevices)
      if (!paired.contains(peer.id))
        PairedDevice(
          id: peer.id,
          name: peer.name,
          publicKey: '',
          detail: 'Paired over the mesh · scan its code to send files',
          addresses: peer.addresses.isEmpty
              ? <String>[peer.address]
              : peer.addresses,
          port: peer.port,
          platform: peer.platform,
        ),
  ];
}
