// The reminder engine: turning "take out the trash at 8" and "call mom in
// 5 minutes" into a text and a due time, and deciding what is due now.
// Pure Dart with an injectable clock — the view owns the list, persistence
// and the mesh; this module only decides the words, the times and the due
// checks, so it is testable without widgets.
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;

/// One reminder the assistant promised to say back to the user later.
class Reminder {
  final String id;
  final String text;
  final DateTime dueAt;

  const Reminder({required this.id, required this.text, required this.dueAt});

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'dueAt': dueAt.toIso8601String(),
  };

  /// A torn or foreign line never breaks a reminder.
  static Reminder? fromJsonLine(String line) {
    try {
      final data = jsonDecode(line) as Map<String, dynamic>?;
      if (data == null) return null;
      final id = data['id']?.toString();
      final text = data['text']?.toString();
      final dueAt = DateTime.tryParse(data['dueAt']?.toString() ?? '');
      if (id == null || text == null || dueAt == null) return null;
      return Reminder(id: id, text: text, dueAt: dueAt);
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

  /// The reminders whose time has come, oldest due first.
  List<Reminder> dueNow(Iterable<Reminder> all, DateTime now) {
    final out = all.where((r) => !r.dueAt.isAfter(now)).toList()
      ..sort((a, b) => a.dueAt.compareTo(b.dueAt));
    return out;
  }
}