// Agent definitions on disk, and the usage log the working-hours offer reads.
//
// One JSON file in the app's private directory, the same shape as the rest of
// the device's own state (`lib/core/store.dart`): nothing here is ever sent
// anywhere. The file is written whole to a temporary path and then renamed, so
// a launch that is killed mid-write leaves the previous file rather than a
// half-readable one.
//
// The usage log is opt-in and off on a fresh install: "when do I actually use
// this" is a question about the user's own habits, and the answer is only
// useful if they chose to keep the record. While it is off, [recordUsage] does
// nothing and [mailUsage] is empty, so the session cannot offer hours it was
// never allowed to learn.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path_provider/path_provider.dart';

import 'agent_records.dart';

/// How many usage timestamps are kept. Three weeks of a working day is about
/// a hundred; five thousand is years of that, and still a small file.
const int kUsageLogLimit = 5000;

/// The stored shape's version. Bumped only when a field changes meaning; a
/// reader that meets a newer file keeps what it understands and leaves the
/// rest.
const int kAgentStoreVersion = 1;

class AgentStore implements AgentRecords {
  /// [explicitPath] is the test seam: a file to use instead of the platform's
  /// app-support folder. With neither a path nor a platform directory, the
  /// store is memory-only — which is what a test that only needs the data
  /// shapes should get.
  AgentStore({this.explicitPath});

  final String? explicitPath;

  File? _file;
  final Map<String, AgentDefinition> _agents = <String, AgentDefinition>{};
  final List<DateTime> _usage = <DateTime>[];
  bool _usageOptIn = false;
  bool _loaded = false;

  /// Whether reads found a usable file. False is an ordinary fresh install.
  bool get loaded => _loaded;

  /// Whether the user allowed the local usage log. Off until they say yes.
  bool get usageOptIn => _usageOptIn;

  @override
  List<AgentDefinition> get savedAgents =>
      List<AgentDefinition>.unmodifiable(_agents.values);

  @override
  AgentDefinition? agent(String name) => _agents[name.trim()];

  /// Only when the user opted in — an empty list is the honest answer, and the
  /// working-hours offer then says it has nothing to learn from.
  @override
  List<DateTime> get mailUsage => _usageOptIn
      ? List<DateTime>.unmodifiable(_usage)
      : const <DateTime>[];

  /// Every recorded timestamp, opt-in or not. Only for the store's own tests
  /// and the dashboard's count; the session never sees it while it is off.
  List<DateTime> get recordedUsage => List<DateTime>.unmodifiable(_usage);

  /// Reads the file. A missing file is a fresh install, and an unreadable one
  /// is reported once and then ignored — a store must not stop a launch.
  Future<void> load() async {
    final File? file = await _resolve();
    if (file == null || !await file.exists()) return;
    try {
      final Object? decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return;
      final Map<String, Object?> root = Map<String, Object?>.from(decoded);
      _usageOptIn = root['usageOptIn'] == true;
      _usage.clear();
      for (final Object? entry
          in (root['usage'] as List?) ?? const <Object?>[]) {
        final DateTime? at = entry is String ? DateTime.tryParse(entry) : null;
        if (at != null) _usage.add(at);
      }
      _agents.clear();
      for (final Object? raw in (root['agents'] as List?) ?? const <Object?>[]) {
        if (raw is! Map) continue;
        final AgentDefinition definition = AgentDefinition.fromJson(
          Map<String, Object?>.from(raw),
        );
        if (definition.name.isEmpty) continue;
        _agents[definition.name] = definition;
      }
      _loaded = true;
    } catch (error) {
      debugPrint('NEXUS agents: could not read ${file.path}: $error');
    }
  }

  /// Adds or replaces [definition] and writes the file.
  Future<bool> put(AgentDefinition definition) async {
    if (definition.name.trim().isEmpty) {
      throw ArgumentError.value(
        definition.name,
        'name',
        'an agent without a name cannot be saved',
      );
    }
    _agents[definition.name] = definition;
    return save();
  }

  /// Removes the agent called [name], writing the file. Returns whether one was
  /// there.
  Future<bool> remove(String name) async {
    final bool removed = _agents.remove(name.trim()) != null;
    if (removed) await save();
    return removed;
  }

  /// The user's answer to the usage log. Off means the recorded entries are
  /// dropped as well: a switch that keeps the history it was turned off for is
  /// not an opt-out.
  Future<bool> setUsageOptIn(bool allowed) async {
    _usageOptIn = allowed;
    if (!allowed) _usage.clear();
    return save();
  }

  /// Appends one timestamp, if the user opted in. Never throws: a run that
  /// cannot be logged is still a run that must not fail because of logging.
  Future<void> recordUsage(DateTime at) async {
    if (!_usageOptIn) return;
    _usage.add(at);
    if (_usage.length > kUsageLogLimit) {
      _usage.removeRange(0, _usage.length - kUsageLogLimit);
    }
    await save();
  }

  /// Writes the whole store. False when it could not be written; the in-memory
  /// state is kept either way so the session and the dashboard still work.
  Future<bool> save() async {
    final File? file = await _resolve();
    if (file == null) return false;
    try {
      await file.parent.create(recursive: true);
      final File temp = File('${file.path}.tmp');
      await temp.writeAsString(jsonEncode(_toJson()), flush: true);
      await temp.rename(file.path);
      return true;
    } catch (error) {
      debugPrint('NEXUS agents: could not write ${file.path}: $error');
      return false;
    }
  }

  Map<String, Object?> _toJson() => <String, Object?>{
    'version': kAgentStoreVersion,
    'usageOptIn': _usageOptIn,
    'usage': <String>[for (final at in _usage) at.toIso8601String()],
    'agents': <Map<String, Object?>>[
      for (final definition in _agents.values) definition.toJson(),
    ],
  };

  Future<File?> _resolve() async {
    final File? cached = _file;
    if (cached != null) return cached;
    final String? explicit = explicitPath;
    if (explicit != null && explicit.isNotEmpty) {
      return _file = File(explicit);
    }
    try {
      final Directory dir = await getApplicationSupportDirectory();
      return _file = File('${dir.path}${Platform.pathSeparator}agents.json');
    } catch (_) {
      // No platform directory (a bare test, a platform without one): the store
      // still works, it just does not outlive the process.
      return null;
    }
  }
}
