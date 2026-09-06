import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/reminders.dart';

/// Edge coverage for [ReminderEngine]: boundaries (past-due, empty, torn),
/// ordering (fire-before-persist, broadcast-on-register), one-shot
/// semantics, acknowledge guards, and timer cleanup. The widget playtest
/// covers the happy lifecycle through the real view; these hit the corners.
void main() {
  final t0 = DateTime(2026, 9, 6, 8);

  ReminderEngine engine() {
    final e = ReminderEngine();
    // A fresh engine per test: the clock override is reset in tearDown and
    // edge callbacks are wired per test to record events.
    return e;
  }

  test('a past-due register fires immediately, once, and leaves no trace', () {
    Reminders.nowOverride = () => t0;
    addTearDown(() => Reminders.nowOverride = null);
    final e = engine();
    final fired = <Reminder>[];
    final persisted = <List<Reminder>>[];
    var broadcast = 0;
    e.onFired = fired.add;
    e.onBroadcast = (_) => broadcast++;
    e.onPersist = persisted.add;

    e.register('stretch', t0.subtract(const Duration(minutes: 1)));

    expect(fired, hasLength(1), reason: 'already due -> fires immediately');
    expect(fired.single.text, 'stretch');
    expect(e.reminders, isEmpty, reason: 'fired reminders are spent');
    expect(broadcast, 1, reason: 'registered here -> told to peers');
    // Fire is visible before the persist lands, matching the old view code
    // (thread message appended, then the store write).
    expect(persisted.last, isEmpty, reason: 'the spent list is persisted');
  });

  test('a future register stays silent until the clock catches up, then '
      'fires exactly once (one shot)', () {
    Reminders.nowOverride = () => t0;
    addTearDown(() => Reminders.nowOverride = null);
    final e = engine();
    final fired = <Reminder>[];
    e.onFired = fired.add;

    e.register('stretch', t0.add(const Duration(minutes: 5)));
    expect(fired, isEmpty);
    expect(e.reminders, hasLength(1));

    // Not due yet — a check must be a no-op.
    e.check();
    expect(fired, isEmpty);
    expect(e.reminders, hasLength(1));

    Reminders.nowOverride = () => t0.add(const Duration(minutes: 6));
    e.check();
    expect(fired, hasLength(1));
    expect(e.reminders, isEmpty, reason: 'one shot — gone after firing');

    // A later check must not re-fire anything.
    e.check();
    expect(fired, hasLength(1));
  });

  test('torn and duplicate adopts are no-ops; a real one is adopted live', () {
    Reminders.nowOverride = () => t0;
    addTearDown(() => Reminders.nowOverride = null);
    final e = engine();
    final fired = <Reminder>[];
    var persists = 0;
    e.onFired = fired.add;
    e.onPersist = (_) => persists++;

    // Torn line never breaks the engine.
    e.adopt('not json');
    e.adopt('{"id":"x"}'); // missing fields
    expect(e.reminders, isEmpty);
    expect(persists, 0);

    final line = jsonEncode(Reminder(
      id: 'r-peer',
      text: 'call mom',
      dueAt: t0.add(const Duration(hours: 1)),
    ).toJson());
    e.adopt(line);
    expect(e.reminders, hasLength(1));
    expect(persists, 1, reason: 'adopted reminders persist locally too');

    // The same reminder arriving again must not double-register.
    e.adopt(line);
    expect(e.reminders, hasLength(1));
    expect(persists, 1);
  });

  test('two due at once: both messages, the last fire is the banner, both '
      'leave the list', () {
    Reminders.nowOverride = () => t0;
    addTearDown(() => Reminders.nowOverride = null);
    final e = engine();
    final fired = <Reminder>[];
    e.onFired = fired.add;

    e.adopt(jsonEncode(Reminder(
      id: 'r-1',
      text: 'first',
      dueAt: t0.subtract(const Duration(minutes: 2)),
    ).toJson()));
    e.adopt(jsonEncode(Reminder(
      id: 'r-2',
      text: 'second',
      dueAt: t0.subtract(const Duration(minutes: 1)),
    ).toJson()));
    // Both adopted and already due — the adopt's own check fired them.
    expect(fired.map((r) => r.text), ['first', 'second']);
    expect(e.fired?.text, 'second', reason: 'the latest fire is the banner');
    expect(e.reminders, isEmpty);
  });

  test('acknowledge guards: clearing nothing is a no-op, clearing the '
      'banner notifies listeners', () {
    Reminders.nowOverride = () => t0;
    addTearDown(() => Reminders.nowOverride = null);
    final e = engine();
    var notifies = 0;
    e.addListener(() => notifies++);

    e.acknowledge(); // nothing fired yet
    expect(notifies, 0, reason: 'nothing changed -> no rebuild');
    expect(e.fired, isNull);

    e.register('stretch', t0.subtract(const Duration(minutes: 1)));
    expect(e.fired, isNotNull);
    final before = notifies;
    e.acknowledge();
    expect(e.fired, isNull);
    expect(notifies, greaterThan(before), reason: 'banner cleared -> rebuild');
  });

  test('seed loads the store copy without persisting, and dedupes', () {
    final e = engine();
    var persists = 0;
    e.onPersist = (_) => persists++;

    final line = jsonEncode(Reminder(
      id: 'r-old',
      text: 'water plants',
      dueAt: t0.add(const Duration(hours: 3)),
    ).toJson());
    e.seed([line, line, 'garbage']);
    expect(e.reminders, hasLength(1));
    expect(persists, 0, reason: 'the store already holds these — no write');
  });

  testWidgets('start/stop/dispose: the ticker is owned and released', (
    tester,
  ) async {
    // Freeze the clock: the fixed t0 date must never go stale — once the
    // suite runs past 09:00 on that day the "1 hour from now" reminder is
    // already due and silently fires, emptying the list mid-test.
    Reminders.nowOverride = () => t0;
    addTearDown(() => Reminders.nowOverride = null);
    final e = ReminderEngine();
    e.onPersist = (_) {};
    // A pending reminder so each tick does real work.
    e.adopt(jsonEncode(Reminder(
      id: 'r',
      text: 'tick',
      dueAt: t0.add(const Duration(hours: 1)),
    ).toJson()));

    e.start();
    await tester.pump(const Duration(seconds: 30));
    // Two ticks elapsed (every 15s) with no due work — silent and safe;
    // a second start must not double the ticker.
    e.start();

    e.stop();
    await tester.pump(const Duration(minutes: 5));
    // The ticker must be gone: flutter_test's teardown fails the test if a
    // timer is still pending after stop + dispose.
    e.dispose();
    expect(e.reminders, hasLength(1));
  });

  test('empty engine: register-less checks and stops are harmless', () {
    final e = engine();
    e.start();
    e.check();
    e.check();
    e.stop();
    e.dispose();
  });
}