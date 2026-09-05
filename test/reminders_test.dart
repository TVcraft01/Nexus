import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/reminders.dart';

void main() {
  final now = DateTime(2026, 9, 5, 19, 59); // a Friday, 7:59pm

  group('splitTime', () {
    test('"at 8pm" parses to 20:00 today, text stripped', () {
      final split = const Reminders().splitTime(
        'take out the trash at 8pm',
        now,
      );
      expect(split, isNotNull);
      expect(split!.$1, 'take out the trash');
      expect(split.$2, DateTime(2026, 9, 5, 20));
    });

    test('"at 8" without meridiem is taken literally', () {
      final split = const Reminders().splitTime('buy milk at 8', now)!;
      expect(split.$2, DateTime(2026, 9, 5, 8));
    });

    test('"at 8:30pm" keeps the minutes', () {
      final split = const Reminders().splitTime('call mom at 8:30pm', now)!;
      expect(split.$1, 'call mom');
      expect(split.$2, DateTime(2026, 9, 5, 20, 30));
    });

    test('"at 14:30" is 24-hour time', () {
      final split = const Reminders().splitTime('meeting at 14:30', now)!;
      expect(split.$2, DateTime(2026, 9, 5, 14, 30));
    });

    test('"in 5 minutes" / "in 2 hours" are relative to now', () {
      final m = const Reminders().splitTime('stretch in 5 minutes', now)!;
      expect(m.$1, 'stretch');
      expect(m.$2, now.add(const Duration(minutes: 5)));

      final h = const Reminders().splitTime('water the plants in 2 hours', now)!;
      expect(h.$2, now.add(const Duration(hours: 2)));
    });

    test('no time present returns null — the catalog must ask, never pretend', () {
      expect(const Reminders().splitTime('buy milk', now), isNull);
      expect(const Reminders().splitTime('', now), isNull);
      expect(const Reminders().splitTime('take out the trash at', now), isNull);
    });

    test('nonsense times are refused, not silently accepted', () {
      expect(const Reminders().splitTime('x at 25:00', now), isNull);
      expect(const Reminders().splitTime('x at 8:70', now), isNull);
    });
  });

  group('dueNow', () {
    final engine = const Reminders();
    Reminder r(String id, DateTime at) =>
        Reminder(id: id, text: id, dueAt: at);

    test('fired when the time has come, oldest first; future ones wait', () {
      final due = engine.dueNow(
        [
          r('later', now.add(const Duration(minutes: 5))),
          r('older', now.subtract(const Duration(minutes: 1))),
          r('exact', now),
        ],
        now,
      );
      expect(due.map((d) => d.id), ['older', 'exact']);
    });

    test('empty and future-only lists fire nothing', () {
      expect(engine.dueNow(const [], now), isEmpty);
      expect(
        engine.dueNow([r('soon', now.add(const Duration(minutes: 1)))], now),
        isEmpty,
      );
    });
  });

  group('round trip', () {
    test('a reminder survives its JSON line, torn lines never break it', () {
      final reminder = Reminder(
        id: 'r-1',
        text: 'take out the trash',
        dueAt: DateTime(2026, 9, 5, 20),
      );
      final line = '{"id":"r-1","text":"take out the trash",'
          '"dueAt":"2026-09-05T20:00:00.000"}';
      final back = Reminder.fromJsonLine(line)!;
      expect(back.id, reminder.id);
      expect(back.text, reminder.text);
      expect(back.dueAt, reminder.dueAt);
      expect(Reminder.fromJsonLine('garbage{'), isNull);
      expect(Reminder.fromJsonLine(''), isNull);
    });
  });
}