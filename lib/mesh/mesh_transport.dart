// The connection-level transport seam.
//
// `ConnectionSupervisor` exists to keep a paired link alive across sleep,
// roam and radio changes. To be honest about what it can and cannot do, it
// must not know how the link is made — only who could be reached, whether a
// link is proven, when the peer was last heard from, and one cheap way to
// force a presence exchange now. That is this interface.
//
// The mesh has exactly one data transport today: a TCP session over the local
// network. LAN, Tailscale and an adb-reverse cable tunnel are all the same
// socket path (`MeshService._outboundSocket`), so `MeshService` is the single
// WiFi implementation and implements this interface directly — the same shape
// as its `FileFetchMesh` seam, where the mesh adapts itself to a narrow
// interface instead of growing a second transport. Nothing here speaks BLE:
// a presence-only beacon would arrive as a second implementation of this
// interface, and the supervisor would not change to accept it.
//
// The liveness member is "last **heard**", not "last seen", on purpose. The
// mesh keeps an unverified `_lastSeen` timestamp that advances when *we* send
// a ping — which keeps looking fresh while a dead route is quietly dialled —
// so a supervisor built on it would never notice a silent drop. What it
// reports here is the last time the peer itself proved it was there, over its
// authenticated connection.
//
// A test that registers a second fake transport without touching the
// supervisor is the proof that the seam is real: see
// `test/connection_supervisor_test.dart`.

/// One peer a transport can be asked about: a device that is already paired,
/// so reaching it needs no user action.
class TransportPeer {
  /// The peer's device id — stable across address changes and re-pairing.
  final String id;

  /// The peer's name, for anything that has to say which device it means.
  final String name;

  const TransportPeer({required this.id, required this.name});

  @override
  bool operator ==(Object other) => other is TransportPeer && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'TransportPeer($id, $name)';
}

/// What a connection supervisor needs from a transport.
///
/// Implementations must be cheap when nothing is wrong: the supervisor polls
/// [lastHeardAt] on every tick.
abstract class MeshTransport {
  /// The peers this transport could connect to: paired devices only. A
  /// device that is merely visible nearby is not reachable without the user,
  /// so it is not the supervisor's business.
  List<TransportPeer> peers();

  /// When [peerId] last *proved* it was there, or null if it never has.
  ///
  /// Proven means the peer itself sent something over its authenticated
  /// connection: a pong to one of our pings, a ping of its own, any frame we
  /// could decrypt with its session key. It must NOT advance because of
  /// anything we sent — a send into a dead socket succeeds locally often
  /// enough that "we wrote to them" is no evidence at all.
  ///
  /// The transport reports the timestamp; the supervisor decides, through its
  /// own injected clock, how much silence means the link is gone. Keeping
  /// that judgement outside the transport is what makes the heartbeat
  /// timeout testable.
  DateTime? lastHeardAt(String peerId);

  /// Runs one presence exchange now: pings every peer that could answer and
  /// re-dials any route that has died. Returns when the exchange has been
  /// *sent* — a reply arrives as a frame, which is what [lastHeardAt] reports
  /// on a later tick, because a dead route fails silently rather than
  /// throwing.
  ///
  /// Must be safe to call at any time: a call while one exchange is still
  /// running is a no-op.
  Future<void> beat();
}
