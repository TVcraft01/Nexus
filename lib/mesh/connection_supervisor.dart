// Keeps every paired link alive, in one place.
//
// The mesh is meant to be reachable without the user doing anything: after a
// laptop lid closes, a phone roams off WiFi, or the radio drops and comes
// back, a paired device should be reachable again by itself. Today each piece
// of that lives somewhere else — presence pings on a fixed timer, reconnect
// logic inside the send path, nothing at all for a network change — so a link
// that dies quietly stays dead until something tries to use it.
//
// This supervisor owns that job:
//
//   * it watches each paired peer's silence (the *heartbeat*): while a peer is
//     healthy the supervisor drives a presence exchange every
//     [heartbeatInterval], and a peer that has not been heard from for longer
//     than [heartbeatTimeout] is declared down — seconds, not the mesh's
//     presence window. "Heard from" means the peer proved it was there, never
//     "we sent it something": a write into a dead route succeeds locally often
//     enough that a dead peer would otherwise look healthy forever;
//   * when a peer is down it retries with capped exponential backoff,
//     [initialBackoff] doubling to [maxBackoff] (2s -> 60s by default), so a
//     device that is off is not hammered and a device that comes back is
//     redialled quickly;
//   * when the network itself changes — WiFi back after sleep, WiFi to
//     cellular, radio off and on — it reconnects at once instead of waiting
//     out a backoff that belonged to the old network;
//   * it starts and stops with the mesh, which is exactly what the Android
//     foreground service keeps alive, so a backgrounded phone keeps
//     reconnecting with the window closed.
//
// What it does not promise: a link that cannot exist. Airplane mode, radios
// off, or a phone held in the OS's deep suspend state is not reachable from
// anywhere, and no supervisor can change that. The promise is *automatic*
// reconnection — sub-minute and needs no user action — not permanent presence.
//
// Which side owns what, because it used to be split and that made the
// countdown a lie. The supervisor owns *scheduling*: when a paired peer is
// dialled — every [heartbeatInterval] while it is up, on the backoff curve
// while it is down, at once on a network change. The mesh owns *reporting*:
// whether a peer has proved it is there ([MeshTransport.lastHeardAt]) and the
// one cheap way to dial now ([MeshTransport.beat]). The mesh's own periodic
// sweep deliberately leaves paired peers alone while this supervisor is
// running (`MeshService._presenceSweep`), so there is exactly one dialer per
// peer and the retry schedule here is the one on the wire. Measured before
// that change, on a real phone: dials every ~30 s regardless of the backoff
// the UI was displaying, which is what made the connectivity-monitor fast
// path impossible to prove — two dialers, one of them unaccounted for.
//
// The clock, the transport and the source of network changes are all
// injected, so the retry curve, the network-change fast path and the
// heartbeat timeout are proven by unit tests against fakes rather than by
// waiting on real timers. See `test/connection_supervisor_test.dart`.

import 'dart:async';

import 'package:flutter/foundation.dart' show ChangeNotifier;

import 'mesh_transport.dart';

/// What the supervisor believes about one peer right now. Read-only snapshot
/// for anything that has to show "online" or "reconnecting".
class PeerLink {
  final String id;
  final String name;

  /// True while the peer has been heard from inside the heartbeat timeout.
  final bool up;

  /// Failed reconnect attempts since the peer last answered. 0 while up.
  final int attempts;

  /// When the peer last proved it was there, or null if never.
  final DateTime? lastHeard;

  /// When the next reconnect attempt is due, while [up] is false.
  final DateTime? nextAttemptAt;

  const PeerLink({
    required this.id,
    required this.name,
    required this.up,
    required this.attempts,
    this.lastHeard,
    this.nextAttemptAt,
  });
}

/// Automatic reconnection for every paired device.
class ConnectionSupervisor extends ChangeNotifier {
  ConnectionSupervisor({
    required this.transport,
    this.networkChanges,
    DateTime Function()? clock,
    this.tickInterval = const Duration(seconds: 1),
    this.heartbeatInterval = const Duration(seconds: 3),
    this.heartbeatTimeout = const Duration(seconds: 9),
    this.initialBackoff = const Duration(seconds: 2),
    this.maxBackoff = const Duration(seconds: 60),
    this.backoffFactor = 2,
  }) : _clock = clock ?? DateTime.now;

  /// The link this supervisor keeps alive.
  final MeshTransport transport;

  /// Where a network change is heard (see `mesh/connectivity_monitor.dart`).
  /// Null off Android, where nothing reports one: the heartbeat's timeout is
  /// then the only thing that notices a dead link.
  final Stream<void>? networkChanges;

  /// How often the supervisor looks at the links. [start] runs the timer;
  /// tests pass a value no real timer reaches and drive [tick] by hand.
  final Duration tickInterval;

  /// How often a healthy peer gets a presence exchange. Short enough that a
  /// silent drop is noticed in seconds, long enough not to be chatter: one
  /// small frame each way.
  final Duration heartbeatInterval;

  /// How much silence means the link is gone. Three missed beats, so a single
  /// lost frame is not a drop, and — deliberately — below the mesh's own
  /// 25 s presence window, so the supervisor notices a dead link first.
  final Duration heartbeatTimeout;

  /// The first retry wait after a drop, doubled up to [maxBackoff].
  final Duration initialBackoff;

  /// The retry ceiling: 2s, 4s, 8s, 16s, 32s, 60s, 60s, ... forever. A
  /// capped wait means an unreachable device costs one ping a minute, and a
  /// device that comes back is still redialled within the minute.
  final Duration maxBackoff;

  /// The backoff multiplier.
  final num backoffFactor;

  final DateTime Function() _clock;

  final Map<String, _LinkState> _links = {};
  Timer? _timer;
  StreamSubscription<void>? _subscription;
  bool _running = false;
  bool _ticking = false;

  /// Whether the supervisor is watching. The Android foreground service keeps
  /// the mesh running, and the mesh starts and stops this with itself.
  bool get running => _running;

  /// A snapshot of every peer the last tick saw.
  List<PeerLink> get links => [
    for (final entry in _links.entries)
      PeerLink(
        id: entry.key,
        name: entry.value.name,
        up: entry.value.up,
        attempts: entry.value.attempts,
        lastHeard: entry.value.lastHeard,
        nextAttemptAt: entry.value.nextAttemptAt,
      ),
  ];

  /// The wait before attempt number [attempt] (1-based). Doubling from
  /// [initialBackoff] and never above [maxBackoff].
  Duration backoffFor(int attempt) {
    var wait = initialBackoff.inMilliseconds;
    for (var i = 1; i < attempt; i++) {
      wait = (wait * backoffFactor).round();
      if (wait >= maxBackoff.inMilliseconds) return maxBackoff;
    }
    return wait >= maxBackoff.inMilliseconds
        ? maxBackoff
        : Duration(milliseconds: wait);
  }

  /// Starts watching: a timer at [tickInterval] plus the network-change
  /// stream. Called when the mesh starts — on Android that is inside the
  /// foreground service, so this survives the window being closed.
  Future<void> start() async {
    if (_running) return;
    _running = true;
    _subscription = networkChanges?.listen((_) {
      unawaited(onNetworkChanged());
    });
    _timer = Timer.periodic(tickInterval, (_) => unawaited(tick()));
    // Look now rather than a tick from now: a mesh that starts next to a
    // device it has paired with should not spend its first second "offline".
    await tick();
  }

  /// Stops watching and forgets the link state, so the next [start] judges
  /// each peer from what the transport reports rather than from stale waits.
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _timer?.cancel();
    _timer = null;
    await _subscription?.cancel();
    _subscription = null;
    final had = _links.isNotEmpty;
    _links.clear();
    if (had) notifyListeners();
  }

  /// A network change: every wait that was counting down was measured against
  /// a network that no longer exists, so throw the waits away and try at once.
  /// A 60 s wait for a WiFi that is already back would be exactly the kind of
  /// silent delay this class exists to remove.
  Future<void> onNetworkChanged() async {
    if (!_running) return;
    for (final state in _links.values) {
      state.attempts = 0;
      state.nextAttemptAt = null;
      state.lastBeatAt = null;
    }
    await tick();
  }

  /// One pass over the links: notice silence, retry what is due.
  Future<void> tick() async {
    if (!_running || _ticking) return;
    _ticking = true;
    var changed = false;
    var beat = false;
    try {
      final now = _clock();
      final peers = transport.peers();

      // A device that was unpaired or forgotten is nobody's link any more.
      final present = {for (final peer in peers) peer.id};
      final gone = _links.keys.where((id) => !present.contains(id)).toList();
      for (final id in gone) {
        _links.remove(id);
        changed = true;
      }

      // One presence exchange covers every peer the transport knows, so the
      // pass decides *whether* to beat rather than beating per peer.
      for (final peer in peers) {
        final state = _links.putIfAbsent(
          peer.id,
          () => _LinkState(name: peer.name),
        );
        state.name = peer.name;
        final seen = transport.lastHeardAt(peer.id);
        state.lastHeard = seen;
        final silence = seen == null ? null : now.difference(seen);

        if (silence != null && silence <= heartbeatTimeout) {
          // Heard from inside the timeout: the link is up. If it was down,
          // this is the recovery, and either way any retries that were
          // counting down are void — the curve starts over from scratch.
          if (!state.up) {
            state.up = true;
            changed = true;
          }
          if (state.attempts != 0 || state.nextAttemptAt != null) {
            state.attempts = 0;
            state.nextAttemptAt = null;
            changed = true;
          }
          // Keep beating while healthy: this is the heartbeat, and it is what
          // makes silence mean something. Without it the supervisor would
          // only inherit the mesh's own 8 s cadence and could not call a
          // silent peer dead in seconds without false alarms.
          if (_beatDue(state, now)) {
            state.lastBeatAt = now;
            beat = true;
          }
          continue;
        }

        // Silence past the timeout. A peer we have never heard from is not
        // "down" yet on the first look — the beat that is about to go out is
        // the first evidence either way, and calling a fresh link dead for
        // one tick would show the user a reconnecting device that is fine.
        // From the second look, silence with no answer *is* a drop.
        if (state.up && (seen != null || state.attempts > 0)) {
          state.up = false;
          changed = true;
        }
        final due = state.nextAttemptAt;
        if (due != null && now.isBefore(due)) continue;
        // One attempt. Whether it worked is decided by the next tick, because
        // the answer arrives as a frame that moves [MeshTransport.lastHeardAt]
        // — not as anything beat() could return.
        state.attempts += 1;
        state.nextAttemptAt = now.add(backoffFor(state.attempts));
        state.lastBeatAt = now;
        changed = true;
        beat = true;
      }
    } finally {
      _ticking = false;
    }
    if (changed) notifyListeners();
    // Dial *after* releasing the latch, and without waiting for the exchange.
    // Nothing here needs its result: whether a beat worked is decided by a
    // later tick, because the answer arrives as a frame that moves
    // [MeshTransport.lastHeardAt], and `beat()` is idempotent while one
    // exchange is still running. Waiting is what let a transport that never
    // answers — one dial blocked inside the OS — stop the schedule for good:
    // the latch above was held across the await, so every later tick returned
    // at the guard on this method's first line, and because the mesh's own
    // sweep leaves a supervised peer alone (`MeshService._presenceSweep`),
    // nothing dialled that peer again. Observed shape on a real phone
    // (2026-10-07): a live process, a foreground service still holding its
    // notification, and not one dial for 51 minutes.
    if (beat) unawaited(transport.beat());
  }

  bool _beatDue(_LinkState state, DateTime now) {
    final last = state.lastBeatAt;
    return last == null || now.difference(last) >= heartbeatInterval;
  }
}

class _LinkState {
  String name;
  bool up = true;
  int attempts = 0;
  DateTime? lastHeard;
  DateTime? lastBeatAt;
  DateTime? nextAttemptAt;

  _LinkState({required this.name});
}
