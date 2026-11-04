// One line per step that actually ran.
//
// In memory for the session, like `lib/core/action_audit.dart`: the question it
// answers — "what has it done, and did it check?" — is about now, and a durable
// record of what an assistant changed is a decision for the user (item 4 asks
// for their opt-in). Each line carries the tier, the approval that allowed it,
// the outcome and the measured verification, so a claim in the chat can be
// checked against a line here.
import 'risk.dart';
import 'verification.dart';

/// How many lines a session keeps. The same fifty as the action audit: several
/// screens, still small enough to stay in memory.
const int kActionLogLimit = 50;

class ActionLogEntry {
  const ActionLogEntry({
    required this.at,
    required this.tool,
    required this.argDigest,
    required this.risk,
    required this.approved,
    required this.outcome,
    this.verified,
  });

  final DateTime at;
  final String tool;

  /// A short fingerprint of the arguments. The line only has to tell two calls
  /// apart, and an argument can be a file path or a name that should not be
  /// copied into a log.
  final String argDigest;

  final RiskTier risk;

  /// Who allowed it: "automatic" for a read, or the user's own words.
  final String approved;

  /// "done" or "did not verify".
  final String outcome;

  final VerificationResult? verified;

  String get line {
    final String clock =
        '${at.hour.toString().padLeft(2, '0')}:'
        '${at.minute.toString().padLeft(2, '0')}';
    final result = verified;
    final measure = result == null ? '' : ', verified ${result.measured}';
    return '$clock $tool $argDigest (${risk.label}, $approved) '
        '$outcome$measure';
  }
}

/// The session's log, newest first.
class AgentActionLog {
  final List<ActionLogEntry> _entries = <ActionLogEntry>[];

  /// Newest first.
  List<ActionLogEntry> get entries =>
      List<ActionLogEntry>.unmodifiable(_entries);

  bool get isEmpty => _entries.isEmpty;

  void record(ActionLogEntry entry) {
    _entries.insert(0, entry);
    if (_entries.length > kActionLogLimit) {
      _entries.removeRange(kActionLogLimit, _entries.length);
    }
  }

  void clear() => _entries.clear();

  List<String> get lines => [for (final entry in _entries) entry.line];
}

/// A stable, short fingerprint of a step's arguments.
///
/// FNV-1a over the sorted keys and their values: enough to tell two calls to
/// the same tool apart, short enough to sit in a log line, and it does not
/// pretend to be a security hash.
String argumentDigest(Map<String, Object?> args) {
  final keys = args.keys.toList()..sort();
  final joined = [for (final key in keys) '$key=${args[key]}'].join('&');
  var hash = 0x811c9dc5;
  for (final unit in joined.codeUnits) {
    hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}
