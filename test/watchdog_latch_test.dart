// Guards lib/core/watchdog_latch.dart.
//
// The latch exists because a boolean cleared in a `finally` is only sound while
// every await between entry and exit can finish. On 2026-10-07 one such await
// never returned on a phone, which left the flag set and stopped the mesh
// dialling for 51 minutes while everything about the app still looked healthy.
// These tests pin both halves of the replacement: it behaves exactly like the
// boolean while work is healthy, and it lets go on its own when it is not.
//
// The clock is injected, so none of this waits on real time.

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/watchdog_latch.dart';

/// A clock the test moves by hand.
class _Clock {
  DateTime now = DateTime.utc(2026, 1, 1, 12);
  DateTime call() => now;
  void advance(Duration by) => now = now.add(by);
}

void main() {
  late _Clock clock;

  setUp(() => clock = _Clock());

  test('a second acquire is refused while a pass is running', () {
    // The old semantics, unchanged: this is what keeps a second copy of the
    // worker from stacking on the first.
    final latch = WatchdogLatch(const Duration(seconds: 30), clock: clock.call);
    expect(latch.acquire(), isTrue);
    expect(latch.acquire(), isFalse);
    expect(latch.held, isTrue);
    latch.release();
  });

  test('release hands the latch back', () {
    final latch = WatchdogLatch(const Duration(seconds: 30), clock: clock.call);
    latch.acquire();
    latch.release();
    expect(latch.held, isFalse);
    expect(latch.acquire(), isTrue);
  });

  test('a pass that never finishes lets go by itself', () {
    // No release() is ever called here — which is precisely what an await that
    // never completes looks like from the latch's side.
    final latch = WatchdogLatch(const Duration(milliseconds: 40), clock: clock.call);
    expect(latch.acquire(), isTrue);

    clock.advance(const Duration(milliseconds: 39));
    expect(latch.held, isTrue, reason: 'still inside the interval');
    expect(latch.acquire(), isFalse);

    clock.advance(const Duration(milliseconds: 2));
    expect(latch.held, isFalse, reason: 'the latch must let go by itself');
    expect(latch.acquire(), isTrue, reason: 'the worker must run again');
  });

  test('a released pass cannot disable a later one', () {
    // The failure in the other direction: if release() left the old start time
    // behind, the next pass would look "still running" and be refused.
    final latch = WatchdogLatch(const Duration(milliseconds: 200), clock: clock.call);
    latch.acquire();
    latch.release();

    clock.advance(const Duration(milliseconds: 120));
    expect(latch.acquire(), isTrue, reason: 'the latch was handed back');

    clock.advance(const Duration(milliseconds: 120));
    expect(
      latch.held,
      isTrue,
      reason: "the current pass's own interval must still be running",
    );
    latch.release();
  });
}
