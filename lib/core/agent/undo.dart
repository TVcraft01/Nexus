// What a finished run left that can be put back.
//
// The executor already unwinds its own steps when a later one fails. This is the
// other case: a run that *succeeded*, and the user now wants it undone. The
// rollback closures captured at validation time are held here, per agent, for
// the last run only — one undo per run, newest run wins.
//
// The closures live in memory and are not persisted. That is deliberate for
// this step: a real undo across a restart needs the before-state on disk, and a
// tool that re-reads it can already do that itself (the network tools keep a
// detached revert timer for exactly that). What this must never do is claim an
// undo it did not perform: every result, good or bad, is returned and logged.
import 'rollback.dart';

/// One reversible step of a run, with the closure that puts it back.
class UndoEntry {
  const UndoEntry({
    required this.agent,
    required this.at,
    required this.description,
    required this.tool,
    required this.rollback,
  });

  final String agent;
  final DateTime at;

  /// The step in the user's words, as the run reported it.
  final String description;
  final String tool;

  /// Puts this one step back. Called by `AgentService.undoLastRun`, newest
  /// first.
  final Future<RollbackResult> Function() rollback;
}

/// The undo entries of each agent's last run.
class UndoJournal {
  final Map<String, List<UndoEntry>> _byAgent = <String, List<UndoEntry>>{};

  /// Starts a run: whatever the previous run left is no longer "last".
  void beginRun(String agent) {
    if (agent.trim().isEmpty) return;
    _byAgent[agent.trim()] = <UndoEntry>[];
  }

  /// Adds one reversible step, as it verifies.
  void record(UndoEntry entry) {
    if (entry.agent.trim().isEmpty) return;
    (_byAgent[entry.agent.trim()] ??= <UndoEntry>[]).add(entry);
  }

  /// Oldest first, as the run performed them.
  List<UndoEntry> lastRun(String agent) =>
      List<UndoEntry>.unmodifiable(_byAgent[agent.trim()] ?? const <UndoEntry>[]);

  bool canUndo(String agent) => lastRun(agent).isNotEmpty;

  /// Takes the entries out, so one run is undone once.
  List<UndoEntry> takeLastRun(String agent) {
    final List<UndoEntry> entries = lastRun(agent);
    _byAgent.remove(agent.trim());
    return entries;
  }
}
