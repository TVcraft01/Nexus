/// A re-entrancy latch that cannot be left set by an await that never
/// completes.
///
/// Every periodic worker in Nexus guards itself the same way: a boolean says
/// "one of these is already running", the worker checks it on entry and clears
/// it in a `finally`. That is correct exactly as long as every `await` between
/// the two can finish. When one cannot — a dial blocked inside the OS, a flush
/// into a peer that stopped reading, a filesystem call that never returns — the
/// `finally` never runs, the flag stays set, and the worker is a no-op for the
/// rest of the process's life while everything about the app still looks
/// healthy. Measured on a real phone (2026-10-07): the process alive, the
/// foreground service still holding its notification, and 51 minutes in which
/// no dial was made at all.
///
/// This replaces the boolean with a latch that lets go on its own:
///
/// ```dart
/// if (!latch.acquire()) return; // someone else is running, exactly as before
/// try {
///   ...awaited work...
/// } finally {
///   latch.release();
/// }
/// ```
///
/// A hung await therefore costs at most [interval] of silence instead of every
/// tick from then on.
///
/// It expires from a clock rather than a `Timer`, deliberately: a timer would
/// be a live object for as long as the guarded work is stuck, and a pending
/// timer is exactly what a fake-async widget test fails on ("a Timer is still
/// pending even after the widget tree was disposed"). Checking the clock when
/// someone asks is enough, because the only caller that cares is the next pass.
///
/// Two consequences worth being explicit about:
///
///   * [interval] must be longer than the slowest *healthy* pass, or a slow pass
///     and its successor would overlap. It is deliberately not "as short as
///     possible" — for a retry that may walk every address a peer has, that is
///     tens of seconds.
///   * once it has expired, a pass that is still stuck may finish later and run
///     beside a new one — and its `release()` then clears the *new* pass's
///     ownership. That is the intended trade: a duplicate presence ping is
///     cheap and idempotent, and never being reachable again is not.
class WatchdogLatch {
  WatchdogLatch(this.interval, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  /// How long a pass may hold the latch before the next caller may take it.
  /// Must exceed the slowest healthy pass; see the class comment.
  final Duration interval;

  final DateTime Function() _clock;
  DateTime? _startedAt;

  /// Whether a pass is currently considered to be running: the last acquisition
  /// was inside [interval].
  bool get held {
    final started = _startedAt;
    if (started == null) return false;
    return _clock().difference(started) < interval;
  }

  /// Takes the latch, or returns false while a pass that started less than
  /// [interval] ago is still considered to be running — in which case the
  /// caller does nothing, as it would with a plain boolean.
  bool acquire() {
    if (held) return false;
    _startedAt = _clock();
    return true;
  }

  /// Gives the latch back after a pass that finished on its own.
  void release() => _startedAt = null;
}
