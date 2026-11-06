// What Nexus keeps about the agents it has made, and the usage log it learns
// hours from.
//
// Item 2 kept these in memory behind this interface. Item 4 makes them data:
// every field below is written to a JSON file by `agent_store.dart`, read by
// the background service (`agent_service.dart`) before it runs anything, and
// shown by the local dashboard. A definition says what the agent does, which
// tools it may use, when it runs, what it may do without asking, and where it
// stands right now — and each of those is a value the user can see and change,
// never something hidden in a running process.
import 'risk.dart';

/// What an agent may do without asking, chosen by the user and stored with the
/// definition.
///
/// This is a policy about the *agent's own* runs — the ones its schedule
/// starts. The executor still checks every step's tier against the approval it
/// was handed, and nothing here can lift `destructive` above asking: that tier
/// names a device and is asked every time, by the rule in `docs/AGENT_CORE.md`.
enum AgentApprovalPolicy {
  /// Every change the agent wants to make is asked, as it is for a typed ask.
  askEveryChange('ask me before every change'),

  /// Reading and reversible changes run on their own; destructive ones still
  /// ask.
  askDestructive('ask me only for destructive steps'),

  /// Only reading. A change is never run, so "read only" cannot quietly mean
  /// something else.
  readOnly('read only, never change anything'),

  /// Asks before every step, reading included. The strictest policy: a
  /// background run can do nothing at all under it, because a scheduled run
  /// has nobody to ask.
  askEverything('ask me before every step, reading included');

  const AgentApprovalPolicy(this.label);

  /// The policy in the words the dashboard and the session show.
  final String label;

  /// Whether a step of [tier] may run without being asked about. Destructive
  /// is false for every policy: high risk always needs a yes for that action,
  /// and a yes is never stored as a standing permission.
  bool allows(RiskTier tier) => switch (this) {
    AgentApprovalPolicy.askEveryChange => tier == RiskTier.read,
    AgentApprovalPolicy.askDestructive => tier != RiskTier.destructive,
    AgentApprovalPolicy.readOnly => tier == RiskTier.read,
    AgentApprovalPolicy.askEverything => false,
  };
}

/// Where an agent stands, as the service leaves it and the dashboard shows it.
enum AgentStatus {
  /// Not running: it does something only when the user starts it by hand.
  stopped('stopped'),

  /// Running: in its hours it is offered work on every tick.
  running('running'),

  /// The user paused it. Its hours still apply once it is started again.
  paused('paused');

  const AgentStatus(this.label);

  final String label;
}

class AgentDefinition {
  AgentDefinition({
    required this.name,
    required this.goal,
    required this.tools,
    this.schedule,
    this.approval = AgentApprovalPolicy.askEveryChange,
    this.status = AgentStatus.stopped,
    this.lastRunAt,
    this.lastResult = '',
  });

  final String name;

  /// What it does, in the user's words.
  final String goal;

  /// The tools it may use, by registered name. A drafts-only agent names
  /// `mail_drafts` and not `mail_auto_send`.
  final List<String> tools;

  /// When it runs: "9:00-18:00 on weekdays". Null means only when asked.
  String? schedule;

  /// What it may do without asking, when a run starts on its own.
  AgentApprovalPolicy approval;

  /// Where the service left it.
  AgentStatus status;

  /// The last time it ran, and what that run said. Both live in the stored
  /// definition on purpose: "it ran an hour ago and said it could not" is the
  /// answer to "is it working?", and a status without a reason is a guess.
  DateTime? lastRunAt;
  String lastResult;

  bool get draftsOnly =>
      tools.contains('mail_drafts') && !tools.contains('mail_auto_send');

  /// The stored form. Every value is a plain JSON type, and the enum names are
  /// the stored spelling — renaming one is a migration, as everywhere else in
  /// the store.
  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'goal': goal,
    'tools': tools,
    'schedule': schedule,
    'approval': approval.name,
    'status': status.name,
    'lastRunAt': lastRunAt?.toIso8601String(),
    'lastResult': lastResult,
  };

  /// Reads a stored definition, tolerantly: a field this version does not know
  /// is dropped, and a value it cannot read falls back to the safe default
  /// (`ask me before every change`, `stopped`) rather than throwing away the
  /// user's agent.
  factory AgentDefinition.fromJson(Map<String, Object?> json) {
    String text(String key) {
      final Object? value = json[key];
      return value is String ? value : '';
    }

    return AgentDefinition(
      name: text('name').trim(),
      goal: text('goal').trim(),
      tools: <String>[
        for (final Object? tool in (json['tools'] as List?) ?? const <Object?>[])
          if (tool is String && tool.trim().isNotEmpty) tool.trim(),
      ],
      schedule: text('schedule').trim().isEmpty ? null : text('schedule').trim(),
      approval: _approvalNamed(text('approval')),
      status: _statusNamed(text('status')),
      lastRunAt: DateTime.tryParse(text('lastRunAt')),
      lastResult: text('lastResult'),
    );
  }

  static AgentApprovalPolicy _approvalNamed(String name) {
    for (final policy in AgentApprovalPolicy.values) {
      if (policy.name == name) return policy;
    }
    return AgentApprovalPolicy.askEveryChange;
  }

  static AgentStatus _statusNamed(String name) {
    for (final status in AgentStatus.values) {
      if (status.name == name) return status;
    }
    return AgentStatus.stopped;
  }
}

abstract class AgentRecords {
  /// Every agent saved on this device.
  List<AgentDefinition> get savedAgents;

  AgentDefinition? agent(String name);

  /// When the user actually did the thing, oldest first — the local log the
  /// working-hours offer is learned from. Empty unless the user opted in;
  /// see [AgentStore.usageOptIn].
  List<DateTime> get mailUsage;
}
