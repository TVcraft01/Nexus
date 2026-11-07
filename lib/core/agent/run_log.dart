// The audit log: one line per step an agent tried, on this device only.
//
// This is not the opt-in usage log. The usage log (`agent_store.dart`) records
// *when the user did something*, is off until they say yes, and exists to learn
// working hours — it is about the user's habits, so keeping it is their choice.
// This log records *what an agent did with its hands*: the tool, the risk, the
// gate's decision and why, and the outcome. It is on by default because a
// safety record the user has to remember to switch on is not a safety record,
// and because it is the only way to check a run's claims after the fact. The
// two are separate files with separate rules, and nothing here ever feeds the
// working-hours offer.
//
// Append-only: a line is written when the step happens and never edited. The
// file is capped ([kRunLogLimit]) and rotated — the previous generation is
// kept as `<path>.1`, the current one is cut back to the newest entries — so it
// cannot grow without bound on a machine that runs for months.
//
// Arguments are redacted before they are written: a key that names a secret, a
// value that looks like a token, and anything under such a key one level down.
// The log is for auditing decisions, not for copying credentials onto disk.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path_provider/path_provider.dart';

import 'approval_gate.dart' show GateDecision;
import 'risk.dart';

/// How many lines the current file keeps before it rotates.
const int kRunLogLimit = 2000;

/// Keys whose value is a secret by its name.
final RegExp _secretKey = RegExp(
  r'pass|token|secret|key|auth|cookie|credential|pin|salt|session',
  caseSensitive: false,
);

/// A value that looks like a token rather than a word: long, and only the
/// characters a key is made of. Short words (`auto`, `this PC`) pass through.
final RegExp _opaque = RegExp(r'^[A-Za-z0-9_\-+/=]{24,}$');

/// [args] with anything secret-looking replaced by `[redacted]`.
Map<String, Object?> redactArgs(Map<String, Object?> args) =>
    <String, Object?>{
      for (final entry in args.entries)
        entry.key: _secretKey.hasMatch(entry.key)
            ? '[redacted]'
            : redactValue(entry.value),
    };

/// One argument value, redacted. Exposed because a nested map is redacted the
/// same way as the top level.
Object? redactValue(Object? value) {
  if (value is String) {
    if (_opaque.hasMatch(value)) return '[redacted]';
    return value.length > 200 ? '${value.substring(0, 200)}…' : value;
  }
  if (value is Map) {
    return redactArgs(<String, Object?>{
      for (final entry in value.entries) '${entry.key}': entry.value,
    });
  }
  if (value is List) return <Object?>[for (final item in value) redactValue(item)];
  return value;
}

class RunLogEntry {
  const RunLogEntry({
    required this.at,
    required this.agent,
    required this.tool,
    required this.risk,
    required this.decision,
    required this.why,
    required this.outcome,
    this.args = const <String, Object?>{},
    this.error = '',
  });

  final DateTime at;

  /// The agent the step belonged to. Empty for a typed ask.
  final String agent;

  final String tool;

  /// Already redacted when it comes from [RunLog.record]; this constructor
  /// keeps whatever it is given so a test can state the real arguments.
  final Map<String, Object?> args;

  final RiskTier risk;
  final GateDecision decision;

  /// The gate's own sentence: why this step ran, was skipped or was blocked.
  final String why;

  /// `ran`, `skipped: needs approval`, `blocked`, `refused`, `failed`,
  /// `did not verify`.
  final String outcome;

  /// What went wrong, when something did.
  final String error;

  Map<String, Object?> toJson() => <String, Object?>{
    'at': at.toIso8601String(),
    'agent': agent,
    'tool': tool,
    'args': redactArgs(args),
    'risk': risk.name,
    'decision': decision.name,
    'why': why,
    'outcome': outcome,
    'error': error,
  };

  factory RunLogEntry.fromJson(Map<String, Object?> json) {
    String text(String key) {
      final Object? value = json[key];
      return value is String ? value : '';
    }

    return RunLogEntry(
      at: DateTime.tryParse(text('at')) ?? DateTime.fromMillisecondsSinceEpoch(0),
      agent: text('agent'),
      tool: text('tool'),
      args: json['args'] is Map
          ? <String, Object?>{
              for (final entry in (json['args']! as Map).entries)
                '${entry.key}': entry.value,
            }
          : const <String, Object?>{},
      risk: _riskNamed(text('risk')),
      decision: _decisionNamed(text('decision')),
      why: text('why'),
      outcome: text('outcome'),
      error: text('error'),
    );
  }

  /// One line, as `program` output and the tests read it.
  String get line {
    String two(int value) => value.toString().padLeft(2, '0');
    final String clock =
        '${two(at.hour)}:${two(at.minute)}:${two(at.second)}';
    final String who = agent.isEmpty ? '' : ' $agent';
    // `$this.why` would interpolate `this` and leave a literal ".why" behind;
    // the braces are what make the field itself the thing that is printed.
    final String why = this.why.isEmpty ? '' : ' (${this.why})';
    final String failed = error.isEmpty ? '' : ' — $error';
    return '$clock$who $tool [${risk.level}] ${decision.name}$why: '
        '$outcome$failed';
  }

  static RiskTier _riskNamed(String name) {
    for (final risk in RiskTier.values) {
      if (risk.name == name) return risk;
    }
    return RiskTier.destructive;
  }

  static GateDecision _decisionNamed(String name) {
    for (final decision in GateDecision.values) {
      if (decision.name == name) return decision;
    }
    return GateDecision.blocked;
  }
}

class RunLog {
  /// [explicitPath] is the test seam. With no path and no platform directory
  /// the log is memory-only, capped the same way.
  RunLog({this.explicitPath, this.limit = kRunLogLimit});

  final String? explicitPath;
  final int limit;

  File? _file;
  final List<RunLogEntry> _entries = <RunLogEntry>[];

  /// Newest first.
  List<RunLogEntry> get entries => List<RunLogEntry>.unmodifiable(_entries);

  Future<void> load() async {
    final File? file = await _resolve();
    if (file == null || !await file.exists()) return;
    try {
      final List<RunLogEntry> read = <RunLogEntry>[];
      for (final line in await file.readAsLines()) {
        if (line.trim().isEmpty) continue;
        final Object? decoded = jsonDecode(line);
        if (decoded is! Map) continue;
        read.add(
          RunLogEntry.fromJson(Map<String, Object?>.from(decoded)),
        );
      }
      _entries
        ..clear()
        ..addAll(read.reversed);
      _trim();
    } catch (error) {
      debugPrint('NEXUS agents: could not read ${file.path}: $error');
    }
  }

  /// Appends one line. Never throws: a run must not fail because its audit
  /// line could not be written — the failure is reported instead.
  Future<void> record(RunLogEntry entry) async {
    final RunLogEntry redacted = RunLogEntry(
      at: entry.at,
      agent: entry.agent,
      tool: entry.tool,
      args: redactArgs(entry.args),
      risk: entry.risk,
      decision: entry.decision,
      why: entry.why,
      outcome: entry.outcome,
      error: entry.error,
    );
    _entries.insert(0, redacted);
    final File? file = await _resolve();
    if (file == null) {
      _trim();
      return;
    }
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(
        '${jsonEncode(redacted.toJson())}\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (error) {
      debugPrint('NEXUS agents: could not append to ${file.path}: $error');
    }
    if (_entries.length > limit) await _rotate(file);
  }

  void _trim() {
    if (_entries.length > limit) {
      _entries.removeRange(limit, _entries.length);
    }
  }

  /// Keeps the previous generation as `<path>.1`, then rewrites the current
  /// file with the newest [limit] entries, oldest first.
  Future<void> _rotate(File file) async {
    _trim();
    try {
      final File archive = File('${file.path}.1');
      if (await file.exists()) {
        if (await archive.exists()) await archive.delete();
        await file.rename(archive.path);
      }
      final String body = <String>[
        for (final entry in _entries.reversed) jsonEncode(entry.toJson()),
      ].join('\n');
      final File temp = File('${file.path}.tmp');
      await temp.writeAsString('$body\n', flush: true);
      await temp.rename(file.path);
    } catch (error) {
      debugPrint('NEXUS agents: could not rotate ${file.path}: $error');
    }
  }

  Future<File?> _resolve() async {
    final File? cached = _file;
    if (cached != null) return cached;
    final String? explicit = explicitPath;
    if (explicit != null && explicit.isNotEmpty) {
      return _file = File(explicit);
    }
    try {
      final Directory dir = await getApplicationSupportDirectory();
      return _file = File('${dir.path}${Platform.pathSeparator}agent-runs.jsonl');
    } catch (_) {
      return null;
    }
  }
}
