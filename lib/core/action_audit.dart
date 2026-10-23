// The last few things Nexus did to the phone, in the order it did them.
//
// The chat thread already says what happened, but it says it in the place the
// user was looking when they asked. This is the other question a person has
// about an assistant that can hold the torch and the alarm clock: *what has it
// done lately, and when?* One line per action, newest first, kept in memory.
//
// In memory on purpose. A history of the torch and the dialer is a record of
// behaviour, and a record on disk outlives the reason it was kept; the question
// this answers ("what happened in the last few minutes?") is answered by the
// session. Nothing here is a log: [LogService] is the log, and it is the
// developer's.
//
// The label is the sentence the bubble showed, tidied of its full stop — one
// wording for the action, not two that drift apart as either side is edited.
library;

import 'package:flutter/foundation.dart' show ChangeNotifier, immutable, visibleForTesting;

/// How many lines survive a session. Fifty is several screens of scrolling and
/// still small enough to stay in memory; the screen shows the newest ten.
const int kAuditLimit = 50;

/// How many lines the Connections screen lists.
const int kAuditRecent = 10;

/// One executed action, stamped when it ran.
@immutable
class AuditEntry {
  const AuditEntry({required this.at, required this.action, required this.label});

  final DateTime at;

  /// The wire name (`set_flashlight`), so a caller can filter by action.
  final String action;

  /// What the bubble said, without its full stop: "Flashlight on".
  final String label;

  /// `10:42 AM` — the phone's own clock, twelve-hour, never the locale's.
  ///
  /// Written out rather than formatted because a list of times is read as a
  /// column, and a locale that renders 10:42 as "10:42" and 9:05 as "9:05"
  /// makes the column ragged. The app's other timestamps are 24-hour (the
  /// developer log); this one is for the user, so it says AM or PM.
  String get clock {
    final int hour = at.hour % 12 == 0 ? 12 : at.hour % 12;
    final String minute = at.minute.toString().padLeft(2, '0');
    return '$hour:$minute ${at.hour < 12 ? 'AM' : 'PM'}';
  }

  @override
  String toString() => '$clock $label';
}

/// The app-wide list, newest first.
class ActionAudit extends ChangeNotifier {
  ActionAudit();

  static ActionAudit? _instance;

  static ActionAudit get instance => _instance ??= ActionAudit();

  /// Tests only: forget the singleton and everything it recorded.
  @visibleForTesting
  static void debugReset() => _instance = null;

  final List<AuditEntry> _entries = <AuditEntry>[];

  /// Everything still remembered, newest first.
  List<AuditEntry> get entries => List<AuditEntry>.unmodifiable(_entries);

  bool get isEmpty => _entries.isEmpty;

  int get length => _entries.length;

  /// The newest [count] entries, newest first — ten by default, the number the
  /// Connections screen lists.
  List<AuditEntry> recent([int count = kAuditRecent]) =>
      List<AuditEntry>.unmodifiable(_entries.take(count));

  /// Records one action that actually ran.
  ///
  /// [at] is injected for the same reason every clock in this app is: a test
  /// pins "10:42 AM" instead of racing the second hand. The label loses its
  /// trailing full stop because it is a list item, not a sentence.
  void record({
    required String action,
    required String label,
    DateTime? at,
  }) {
    final String tidy = label.trim().replaceFirst(RegExp(r'[.]+$'), '');
    if (tidy.isEmpty) return;
    _entries.insert(
      0,
      AuditEntry(at: at ?? DateTime.now(), action: action, label: tidy),
    );
    if (_entries.length > kAuditLimit) {
      _entries.removeRange(kAuditLimit, _entries.length);
    }
    notifyListeners();
  }

  /// Forgets the list. The Developer log keeps its own lines.
  void clear() {
    if (_entries.isEmpty) return;
    _entries.clear();
    notifyListeners();
  }
}
