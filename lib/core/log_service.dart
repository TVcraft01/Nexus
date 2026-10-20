// The last few hundred lines the app said about itself, kept where the user can
// read them when something goes wrong.
//
// This is deliberately a small ring buffer rather than a file. A log is useful
// in the minute after a failure and a liability after a week: it can hold a
// sentence the user typed, and a file that grows without a bound is a file that
// eventually holds a conversation. Five hundred lines is enough to cover the
// launch and the action that failed, and small enough to stay in memory.
//
// [install] replaces Flutter's `debugPrint` with a version that records first
// and prints second, so the lines the rest of the app already writes — AI
// timings, action failures, speech errors — are captured without every call
// site having to know this service exists.
library;

import 'package:flutter/foundation.dart'
    show
        ChangeNotifier,
        DebugPrintCallback,
        debugPrint,
        immutable,
        visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

/// How many lines survive. Old lines fall off the front.
const int kLogLineLimit = 500;

/// The preference that remembers the hidden tab was unlocked.
const String kDeveloperModeKey = 'developer_mode';

/// One line, stamped when it was written.
@immutable
class LogLine {
  const LogLine({required this.at, required this.text});

  final DateTime at;
  final String text;

  /// `14:03:27.412  AI: answer in 1840ms`
  String get display {
    final String h = at.hour.toString().padLeft(2, '0');
    final String m = at.minute.toString().padLeft(2, '0');
    final String s = at.second.toString().padLeft(2, '0');
    final String ms = at.millisecond.toString().padLeft(3, '0');
    return '$h:$m:$s.$ms  $text';
  }
}

/// The app's in-memory log, and the hidden developer tab's state.
class LogService extends ChangeNotifier {
  LogService();

  static LogService? _instance;

  static LogService get instance => _instance ??= LogService();

  /// Tests only: forget the singleton and any captured lines.
  @visibleForTesting
  static void debugReset() => _instance = null;

  final List<LogLine> _lines = <LogLine>[];

  bool _developerUnlocked = false;
  bool _attached = false;

  /// The lines, oldest first.
  List<LogLine> get lines => List<LogLine>.unmodifiable(_lines);

  bool get isEmpty => _lines.isEmpty;

  int get length => _lines.length;

  /// Whether the hidden tab should be offered.
  bool get developerUnlocked => _developerUnlocked;

  /// Reads the remembered unlock once. A missing preference is simply a locked
  /// app — never a failed launch.
  Future<void> attach() async {
    if (_attached) return;
    _attached = true;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      _developerUnlocked = prefs.getBool(kDeveloperModeKey) ?? false;
      if (_developerUnlocked) notifyListeners();
    } catch (_) {
      // The log works without the preference store; only the tab stays hidden.
    }
  }

  /// Records [message], splitting multi-line output so the limit counts lines
  /// rather than calls.
  void log(String message) {
    final String trimmed = message.trimRight();
    if (trimmed.isEmpty) return;
    final DateTime now = DateTime.now();
    for (final String line in trimmed.split('\n')) {
      if (line.trim().isEmpty) continue;
      _lines.add(LogLine(at: now, text: line));
    }
    if (_lines.length > kLogLineLimit) {
      _lines.removeRange(0, _lines.length - kLogLineLimit);
    }
    notifyListeners();
  }

  /// Unlocks Developer Logs and remembers it for the next launch.
  Future<void> unlockDeveloperMode() async {
    if (!_developerUnlocked) {
      _developerUnlocked = true;
      notifyListeners();
    }
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kDeveloperModeKey, true);
    } catch (_) {
      // The tab still works for this session.
    }
  }

  /// Forgets every captured line. The app's earlier `debugPrint`s are already
  /// on the platform log and cannot be recalled; this clears the page.
  void clear() {
    if (_lines.isEmpty) return;
    _lines.clear();
    notifyListeners();
  }

  /// The whole buffer as one clipboard-ready block.
  String exportText() => _lines.map((LogLine line) => line.display).join('\n');

  /// Keeps the app's own debug output, and records it on the way past.
  ///
  /// The original callback is captured before the variable is reassigned: the
  /// default implementation does not call `debugPrint` again, so there is no
  /// loop, and the platform still receives every line it always did.
  static bool _installed = false;

  static void install() {
    // Hot restart runs `main` again; a second wrapper would record every line
    // twice and print it through the first wrapper again.
    if (_installed) return;
    _installed = true;
    final DebugPrintCallback original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) LogService.instance.log(message);
      original(message, wrapWidth: wrapWidth);
    };
  }
}
