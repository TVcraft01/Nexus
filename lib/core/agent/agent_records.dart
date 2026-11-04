// What Nexus keeps about the agents it has made, and the usage log it learns
// hours from.
//
// The session answers two questions about its own records without a model in
// the loop — "what agents do I have" and "when do I actually use this" — and
// those answers have to come from the store the tools wrote, not from a
// sentence a model made up. Item 4 replaces the fake store with the real one
// behind this interface; nothing else about the session has to move.
class AgentDefinition {
  AgentDefinition({
    required this.name,
    required this.goal,
    required this.tools,
    this.schedule,
  });

  final String name;

  /// What it does, in the user's words.
  final String goal;

  /// The tools it may use, by registered name. A drafts-only agent names
  /// `mail_drafts` and not `mail_auto_send`.
  final List<String> tools;

  /// When it runs: "9:00-18:00 on weekdays". Null means only when asked.
  String? schedule;

  bool get draftsOnly =>
      tools.contains('mail_drafts') && !tools.contains('mail_auto_send');
}

abstract class AgentRecords {
  /// Every agent saved on this device.
  List<AgentDefinition> get savedAgents;

  AgentDefinition? agent(String name);

  /// When the user actually did the thing, oldest first — the local log the
  /// working-hours offer is learned from.
  List<DateTime> get mailUsage;
}
