// The background service on the PC: it holds each agent's status, decides when
// a run is due, and runs it with the policy the user stored on the definition.
//
// Three things it deliberately does not do:
//
// - it does not plan. The runner it is given is what turns "draft replies in my
//   style" into steps; this file only decides *when* that happens and records
//   what it said. That seam is why the service is testable without a model.
// - it does not approve anything above the stored policy. The policy travels
//   with the run and the executor still enforces every tier; `destructive`
//   always asks, whatever the policy says.
// - it does not run an agent that is paused or stopped, outside its hours, or
//   while the halt is on. A schedule that is not being met is a bug the user
//   can see in the stored status, not a run that happens quietly anyway.
//
// A tick is idempotent within the minute: the same minute never runs the same
// agent twice, so a timer that fires late or twice is harmless.
import 'dart:async';

import 'agent_records.dart';
import 'agent_store.dart';
import 'kill_switch.dart';

/// What one run of an agent came back with: the sentence the user reads, and
/// whether the run actually did what it set out to do.
///
/// [ok] is not "the process did not crash" — it is false for a run that was
/// refused, blocked, skipped a step for want of approval, or failed a
/// verification. The service stores it, so a dashboard cannot show a green run
/// that did nothing.
class AgentOutcome {
  const AgentOutcome(this.said, {this.ok = true});

  final String said;
  final bool ok;
}

/// What running one agent did, kept newest-first for the dashboard.
class AgentRun {
  const AgentRun({
    required this.agent,
    required this.at,
    required this.result,
    required this.ok,
  });

  final String agent;
  final DateTime at;
  final String result;
  final bool ok;
}

/// The thing the service calls to actually do an agent's work. Injected so a
/// test states it and the product wires planning without moving the service;
/// the sentence it returns is what the user reads as this agent's last result.
typedef AgentRunner = Future<AgentOutcome> Function(AgentDefinition agent);

/// The service said no, with a sentence for the dashboard or the session.
class AgentServiceError implements Exception {
  const AgentServiceError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The hours in a definition, read from the user's own words: "9:00-18:00 on
/// weekdays". Both dashes are accepted because both get typed, and a schedule
/// nobody can parse is one the service treats as "only when asked" — the
/// visible, safe answer.
class AgentSchedule {
  const AgentSchedule({
    required this.startMinute,
    required this.endMinute,
    this.weekdaysOnly = false,
    this.weekendsOnly = false,
  });

  /// Minutes from midnight, inclusive start, exclusive end.
  final int startMinute;
  final int endMinute;
  final bool weekdaysOnly;
  final bool weekendsOnly;

  static final RegExp _shape = RegExp(
    r'^\s*(\d{1,2}):(\d{2})\s*[-\u2013]\s*(\d{1,2}):(\d{2})\s*'
    r'(?:on\s+(weekdays|weekends))?\s*$',
    caseSensitive: false,
  );

  /// The schedule [text] names, or null when it names none this service can
  /// keep.
  static AgentSchedule? parse(String? text) {
    if (text == null) return null;
    final RegExpMatch? match = _shape.firstMatch(text.trim());
    if (match == null) return null;
    final int startHour = int.parse(match.group(1)!);
    final int startMin = int.parse(match.group(2)!);
    final int endHour = int.parse(match.group(3)!);
    final int endMin = int.parse(match.group(4)!);
    if (startHour > 23 || endHour > 23 || startMin > 59 || endMin > 59) {
      return null;
    }
    final int start = startHour * 60 + startMin;
    final int end = endHour * 60 + endMin;
    if (end <= start) return null;
    final String? days = match.group(5)?.toLowerCase();
    return AgentSchedule(
      startMinute: start,
      endMinute: end,
      weekdaysOnly: days == 'weekdays',
      weekendsOnly: days == 'weekends',
    );
  }

  /// Whether [at] is inside the window. The end is exclusive: 18:00 is not
  /// inside "9:00-18:00", so a run cannot start twice at the boundary.
  bool covers(DateTime at) {
    if (weekdaysOnly && at.weekday > DateTime.friday) return false;
    if (weekendsOnly && at.weekday <= DateTime.friday) return false;
    final int minute = at.hour * 60 + at.minute;
    return minute >= startMinute && minute < endMinute;
  }
}

class AgentService {
  AgentService({
    required this.store,
    required this.runner,
    KillSwitch? halt,
    DateTime Function()? now,
    this.tickEvery = const Duration(minutes: 1),
  }) : halt = halt ?? KillSwitch(),
       _now = now ?? DateTime.now;

  final AgentStore store;
  final AgentRunner runner;

  /// The one global stop. Shared with the executor that runs the steps, so
  /// halting reaches a run that is already walking them, not only the next one.
  final KillSwitch halt;
  final Duration tickEvery;
  final DateTime Function() _now;

  Timer? _timer;
  bool _ticking = false;
  final List<AgentRun> _runs = <AgentRun>[];

  /// How many runs are remembered for the dashboard.
  static const int runHistoryLimit = 100;

  /// Newest first.
  List<AgentRun> get runs => List<AgentRun>.unmodifiable(_runs);

  bool get ticking => _timer != null;

  /// Whether all agents are halted.
  bool get halted => halt.tripped;

  /// The one global stop. Nothing new starts; a run in progress stops before
  /// its next step, because the same switch is checked there.
  void haltAll() => halt.trip();

  /// Clears the halt. Nothing is resumed automatically: each agent's stored
  /// status still decides whether it runs.
  void resumeAgents() => halt.reset();

  /// Starts the periodic tick. The timer only calls [tick]; a process that is
  /// asleep simply misses ticks, which the minute guard makes harmless.
  void startTicking() {
    _timer ??= Timer.periodic(tickEvery, (_) => unawaited(tick()));
  }

  void stopTicking() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> dispose() async {
    stopTicking();
  }

  /// Turns the agent on. From `paused` this resumes it; a stopped agent starts
  /// stopped-plus-scheduled, and it runs only inside its hours.
  Future<AgentDefinition> start(String name) async {
    final AgentDefinition agent = _required(name);
    agent.status = AgentStatus.running;
    await store.put(agent);
    return agent;
  }

  /// Stops it until the user starts it again. Pausing is not stopping: the
  /// hours and the definition stay, and one click resumes.
  Future<AgentDefinition> pause(String name) async {
    final AgentDefinition agent = _required(name);
    if (agent.status == AgentStatus.stopped) {
      throw AgentServiceError('“${agent.name}” is not running, so there is '
          'nothing to pause.');
    }
    agent.status = AgentStatus.paused;
    await store.put(agent);
    return agent;
  }

  Future<AgentDefinition> stop(String name) async {
    final AgentDefinition agent = _required(name);
    agent.status = AgentStatus.stopped;
    await store.put(agent);
    return agent;
  }

  /// Whether [agent] should run at [at]: on, and inside its hours. An agent
  /// with no schedule is never due — it runs when the user asks, which is what
  /// "only when asked" means.
  bool isDue(AgentDefinition agent, DateTime at) {
    if (agent.status != AgentStatus.running) return false;
    final AgentSchedule? schedule = AgentSchedule.parse(agent.schedule);
    return schedule != null && schedule.covers(at);
  }

  /// Runs every agent that is due, at most once per agent per minute.
  Future<List<AgentRun>> tick({DateTime? at}) async {
    final DateTime now = at ?? _now();
    if (halt.tripped) return const <AgentRun>[];
    if (_ticking) return const <AgentRun>[];
    _ticking = true;
    final List<AgentRun> ran = <AgentRun>[];
    try {
      for (final AgentDefinition agent in store.savedAgents) {
        if (!isDue(agent, now)) continue;
        if (_ranThisMinute(agent, now)) continue;
        final AgentRun? run = await _run(agent, now);
        if (run != null) ran.add(run);
      }
    } finally {
      _ticking = false;
    }
    return ran;
  }

  /// Runs [name] now, whatever its hours — the button on the dashboard. The
  /// status is unchanged: a manual run of a stopped agent does not switch it
  /// on.
  Future<AgentRun> runNow(String name, {DateTime? at}) async {
    if (halt.tripped) {
      throw const AgentServiceError(
        'all agents are halted; clear the halt before running one',
      );
    }
    final AgentDefinition agent = _required(name);
    final AgentRun run = await _run(agent, at ?? _now()) ??
        (throw const AgentServiceError('that agent is already starting'));
    return run;
  }

  bool _ranThisMinute(AgentDefinition agent, DateTime at) {
    final DateTime? last = agent.lastRunAt;
    if (last == null) return false;
    return last.year == at.year &&
        last.month == at.month &&
        last.day == at.day &&
        last.hour == at.hour &&
        last.minute == at.minute;
  }

  Future<AgentRun?> _run(AgentDefinition agent, DateTime at) async {
    String result;
    bool ok = true;
    try {
      final AgentOutcome outcome = await runner(agent);
      result = outcome.said;
      ok = outcome.ok;
    } catch (error) {
      result = 'it failed: $error';
      ok = false;
    }
    agent
      ..lastRunAt = at
      ..lastResult = result;
    await store.put(agent);
    // Only after the user opted in; a refusal to learn is not a log entry.
    await store.recordUsage(at);
    final AgentRun run = AgentRun(
      agent: agent.name,
      at: at,
      result: result,
      ok: ok,
    );
    _runs.insert(0, run);
    if (_runs.length > runHistoryLimit) {
      _runs.removeRange(runHistoryLimit, _runs.length);
    }
    return run;
  }

  AgentDefinition _required(String name) {
    final AgentDefinition? agent = store.agent(name);
    if (agent == null) {
      throw AgentServiceError('there is no agent called “${name.trim()}”');
    }
    return agent;
  }
}
