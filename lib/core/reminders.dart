// The reminder engine: turning "take out the trash at 8" and "call mom in
// 5 minutes" into a text and a due time, deciding what is due now, and —
// since the architecture pass — owning the live list, the ticking due-check
// and the one-shot fire. Pure Dart with an injectable clock; the edges
// (store persistence, mesh broadcast, thread messages) are callbacks the
// view wires, so the engine is testable without widgets.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart'
    show ChangeNotifier, visibleForTesting;

/// One reminder the assistant promised to say back to the user later.
///
/// A fired reminder stays in the list with [fired] set — spent, never
/// re-fired, and pruned after a week — so the store always tells the truth
/// about what already rang, including across a restart the firing itself
/// did not survive.
class Reminder {
  final String id;
  final String text;
  final DateTime dueAt;
  final bool fired;

  const Reminder({
    required this.id,
    required this.text,
    required this.dueAt,
    this.fired = false,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'dueAt': dueAt.toIso8601String(),
    'fired': fired,
  };

  /// A torn or foreign line never breaks a reminder. Lines written before
  /// the fired flag existed read as unfired — they never rang under the
  /// new semantics, so treating them as spent would lose them silently.
  static Reminder? fromJsonLine(String line) {
    try {
      final data = jsonDecode(line) as Map<String, dynamic>?;
      if (data == null) return null;
      final id = data['id']?.toString();
      final text = data['text']?.toString();
      final dueAt = DateTime.tryParse(data['dueAt']?.toString() ?? '');
      if (id == null || text == null || dueAt == null) return null;
      return Reminder(id: id, text: text, dueAt: dueAt, fired: data['fired'] == true);
    } catch (_) {
      return null;
    }
  }
}

class Reminders {
  const Reminders();

  /// Test seam: a fixed clock for deterministic due checks and parsing.
  @visibleForTesting
  static DateTime Function()? nowOverride;

  static DateTime now() => nowOverride?.call() ?? DateTime.now();

  /// Splits "take out the trash at 8pm" into the text and its due time.
  /// Supports "at HH(:MM)?(am|pm)?" (today) and "in N minute(s)|hour(s)"
  /// (relative). Returns null when no time is present — the caller then
  /// answers honestly instead of pretending a reminder was set.
  (String text, DateTime dueAt)? splitTime(String raw, DateTime now) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;

    // "in 5 minutes" / "in 2 hours" — relative, always today.
    final rel = RegExp(
      r'^(.*?)\s+in\s+(\d+)\s*(minute|min|minutes|mins|hour|hours|hr|hrs)$',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (rel != null) {
      final n = int.parse(rel.group(2)!);
      final unit = rel.group(3)!.toLowerCase();
      final isHour = unit.startsWith('h');
      final seconds = (isHour ? 3600 : 60) * n;
      final text = rel.group(1)!.trim();
      if (text.isEmpty || seconds <= 0) return null;
      return (text, now.add(Duration(seconds: seconds)));
    }

    // "at 8" / "at 8pm" / "at 8:30pm" / "at 14:30" — today at that time.
    final abs = RegExp(
      r'^(.*?)\s+at\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (abs != null) {
      final text = abs.group(1)!.trim();
      if (text.isEmpty) return null;
      var hour = int.parse(abs.group(2)!);
      final minute = int.tryParse(abs.group(3) ?? '') ?? 0;
      final meridiem = abs.group(4)?.toLowerCase();
      if (hour > 23 || minute > 59) return null;
      if (meridiem == 'pm' && hour < 12) hour += 12;
      if (meridiem == 'am' && hour == 12) hour = 0;
      return (
        text,
        DateTime(now.year, now.month, now.day, hour, minute),
      );
    }
    return null;
  }

  /// The reminders whose time has come, oldest due first. Spent ones never
  /// come: a fired reminder is history, not a promise.
  List<Reminder> dueNow(Iterable<Reminder> all, DateTime now) {
    final out = all.where((r) => !r.fired && !r.dueAt.isAfter(now)).toList()
      ..sort((a, b) => a.dueAt.compareTo(b.dueAt));
    return out;
  }
}

/// The reminder lifecycle: the live list, the ticking due-check, and the
/// one-shot fire. Owns the state; the view renders and wires the edges
/// (store persistence, mesh broadcast, thread messages) through callbacks,
/// exactly like [CommandService]'s memory funnel.
class ReminderEngine extends ChangeNotifier {
  /// How often the assistant checks whether any promise is due.
  static const _checkEvery = Duration(seconds: 15);

  final List<Reminder> _reminders = [];

  /// The reminder that fired and is waiting for a "Done" — shown as a
  /// banner until acknowledged. The latest fire wins.
  Reminder? fired;

  Timer? _timer;

  /// Edge callbacks the composition root (the view) wires. All fire-and-
  /// forget by design; the engine never touches the store or the mesh.

  /// The list changed — persist this device's copy.
  void Function(List<Reminder> reminders)? onPersist;

  /// A reminder was registered HERE — tell every paired device so it
  /// fires wherever the user is.
  void Function(Reminder reminder)? onBroadcast;

  /// A reminder fired — the view says it in the thread.
  void Function(Reminder reminder)? onFired;

  List<Reminder> get reminders => List.unmodifiable(_reminders);

  /// Seeds this device's copy from the store (a promise made before a
  /// restart still fires). The store already holds these — no persist.
  /// Spent lines are not seeded: they rang, and the engine holds promises,
  /// not history.
  void seed(Iterable<String> lines) {
    for (final line in lines) {
      final reminder = Reminder.fromJsonLine(line);
      if (reminder == null || reminder.fired) continue;
      if (_reminders.any((r) => r.id == reminder.id)) continue;
      _reminders.add(reminder);
    }
    notifyListeners();
  }

  /// Starts the periodic due-check. The view calls this from initState.
  void start() {
    _timer ??= Timer.periodic(_checkEvery, (_) => check());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Registers a promise made on THIS device: kept here, persisted, and
  /// told to every paired device.
  void register(String text, DateTime dueAt) {
    final reminder = Reminder(
      id: 'r-${DateTime.now().microsecondsSinceEpoch}',
      text: text,
      dueAt: dueAt,
    );
    _add(reminder);
    onBroadcast?.call(reminder);
    check();
  }

  /// Adopts a reminder set on a paired device, live (no restart needed).
  /// The mesh already persisted it when no assistant was listening. A spent
  /// line is not adopted: it rang on the peer, and must not ring here.
  void adopt(String line) {
    final reminder = Reminder.fromJsonLine(line);
    if (reminder == null || reminder.fired) return;
    if (_reminders.any((r) => r.id == reminder.id)) return;
    _add(reminder);
    check();
  }

  /// The fired banner has been seen — it goes away until the next fire.
  void acknowledge() {
    if (fired == null) return;
    fired = null;
    notifyListeners();
  }

  void _add(Reminder reminder) {
    _reminders.add(reminder);
    onPersist?.call(_reminders);
    notifyListeners();
  }

  /// How long a spent reminder is kept before it is pruned. The mark must
  /// outlive a restart (so a firing the restart interrupted is never
  /// repeated), but history is not a log — a week is enough to be sure.
  static const spentKeep = Duration(days: 7);

  /// Fires every reminder whose time has come — an assistant message in the
  /// thread and a banner until acknowledged, all without anyone asking. A
  /// fired reminder is spent: marked, persisted as spent, and never fired
  /// again (one shot, like a real reminder).
  void check() {
    final now = Reminders.now();
    final due = const Reminders().dueNow(_reminders, now);
    // Spent lines older than a week are history nobody needs. Pruning is a
    // change too, so the store hears about it even when nothing fires.
    final before = _reminders.length;
    _reminders.removeWhere(
      (r) => r.fired && r.dueAt.isBefore(now.subtract(spentKeep)),
    );
    if (due.isEmpty) {
      if (_reminders.length != before) {
        onPersist?.call(_reminders);
        notifyListeners();
      }
      return;
    }
    for (final reminder in due) {
      final spent = Reminder(
        id: reminder.id,
        text: reminder.text,
        dueAt: reminder.dueAt,
        fired: true,
      );
      final index = _reminders.indexWhere((r) => r.id == reminder.id);
      if (index >= 0) {
        _reminders[index] = spent;
      }
      fired = spent;
      onFired?.call(spent);
    }
    onPersist?.call(_reminders);
    notifyListeners();
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}