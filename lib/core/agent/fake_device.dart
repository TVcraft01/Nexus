// A device that exists only in a test.
//
// The acceptance conversations run offline: no network, no model, no phone. The
// tools change this object, their verification reads it back, and the tests
// assert on it — which is the same shape the real Linux tools will have in item
// 3, where the object in the middle is `nmcli` instead of a field.
//
// The mail usage log is three weeks of weekday activity, the kind a local log
// would hold, so the working-hours offer has something real to count.
import 'agent_records.dart';

class FakeDevice implements AgentRecords {
  FakeDevice({List<DateTime>? mailUsage, this.band = '2.4ghz'})
    : mailUsage = mailUsage ?? threeWeeksOfMailUse();

  /// The Wi-Fi band the device reports today.
  String band;

  bool guestNetwork = false;

  /// Saved agents, by name — the store the agent tools write.
  final Map<String, AgentDefinition> agents = <String, AgentDefinition>{};

  /// Drafts the mail tool has written, newest last.
  final List<String> drafts = <String>[];

  /// Auto-send, off unless the user turns it on. The acceptance conversation
  /// never turns it on.
  bool mailAutoSend = false;

  @override
  final List<DateTime> mailUsage;

  @override
  List<AgentDefinition> get savedAgents =>
      agents.values.toList(growable: false);

  @override
  AgentDefinition? agent(String name) => agents[name];
}

/// Three weeks of weekday mail activity, 09:00–18:00.
List<DateTime> threeWeeksOfMailUse({DateTime? today}) {
  final end = today ?? DateTime(2026, 11, 4);
  final out = <DateTime>[];
  for (var daysAgo = 21; daysAgo >= 1; daysAgo--) {
    final day = DateTime(
      end.year,
      end.month,
      end.day,
    ).subtract(Duration(days: daysAgo));
    if (day.weekday > DateTime.friday) continue;
    for (var hour = 9; hour < 18; hour += 2) {
      out.add(DateTime(day.year, day.month, day.day, hour, 15));
    }
  }
  return out;
}
