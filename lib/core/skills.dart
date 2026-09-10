// The skill loop — Nexus's signature idea: watch which of its everyday
// skills the user genuinely reaches for, and get visibly better at the ones
// that matter. Pure Dart over the same ask-log lines the dream pass and the
// personal predictions read: one usage log, three readings. Nothing leaves
// the device; the ranking is derived fresh, like habits, never stored.
import 'dart:convert';

import 'agent_contract.dart';

/// One ranked skill: the action id, how the assistant names it, a canonical
/// one-tap example that always parses (suggestions run verbatim), and how
/// many genuine asks it got.
class SkillUse {
  final String id;
  final String label;
  final String example;
  final int uses;

  const SkillUse({
    required this.id,
    required this.label,
    required this.example,
    required this.uses,
  });
}

/// The everyday skills the assistant tracks and how it talks about them.
/// Every example must be fully understood by the interpreter — a tapped chip
/// runs verbatim. Actions outside this catalog still work; they just do not
/// shape the rankings.
const kSkillCatalog = <String, ({String label, String example})>{
  AgentActions.timerSet: (label: 'Timers', example: 'set a timer for 5 minutes'),
  AgentActions.reminderSet: (
    label: 'Reminders',
    example: 'remind me to buy milk',
  ),
  AgentActions.alarmSet: (label: 'Alarms', example: 'set an alarm for 7am'),
  AgentActions.callPlace: (label: 'Calls', example: 'call mom'),
  AgentActions.messageSend: (label: 'Texts', example: 'text mom saying hi'),
  AgentActions.emailSend: (label: 'Email', example: 'email mom saying hi'),
  AgentActions.appOpen: (label: 'Apps', example: 'open youtube'),
  AgentActions.openUrl: (label: 'Open', example: 'open github.com'),
  AgentActions.webSearch: (label: 'Search', example: 'search for cats'),
  AgentActions.weatherGet: (label: 'Weather', example: 'what is the weather'),
  AgentActions.noteCreate: (label: 'Notes', example: 'note that buy milk'),
  AgentActions.shoppingListAdd: (
    label: 'Shopping list',
    example: 'add milk to my shopping list',
  ),
  AgentActions.mediaPlay: (label: 'Music', example: 'play music'),
  AgentActions.volumeSet: (label: 'Volume', example: 'volume up'),
  AgentActions.flashlightToggle: (label: 'Flashlight', example: 'flashlight on'),
  AgentActions.deviceList: (label: 'Devices', example: 'show my devices'),
  AgentActions.systemInfo: (label: 'System info', example: 'system info'),
};

/// Ranks skills by genuine usage from ask-log lines (raw JSONL as written
/// by [QueryLog]): every ask whose route names a catalog action counts once.
/// Clarification answers (`teach:…`, `arg:…` routes), plain-message asks
/// (the time, a joke), and torn lines never count — an ask is genuine only
/// when a real skill ran. Most-used first, alphabetical on ties.
class SkillRanking {
  const SkillRanking();

  List<SkillUse> rank(Iterable<String> lines) {
    final counts = <String, int>{};
    for (final line in lines) {
      final Map<String, dynamic> entry;
      try {
        entry = jsonDecode(line) as Map<String, dynamic>;
      } catch (_) {
        continue; // a torn or foreign line never shapes a ranking
      }
      if (entry['kind'] != 'ask') continue;
      final route = entry['route']?.toString() ?? '';
      if (!kSkillCatalog.containsKey(route)) continue;
      counts[route] = (counts[route] ?? 0) + 1;
    }
    final ranked = [
      for (final entry in counts.entries)
        SkillUse(
          id: entry.key,
          label: kSkillCatalog[entry.key]!.label,
          example: kSkillCatalog[entry.key]!.example,
          uses: entry.value,
        ),
    ];
    ranked.sort((a, b) {
      final byUses = b.uses.compareTo(a.uses);
      if (byUses != 0) return byUses;
      return a.label.toLowerCase().compareTo(b.label.toLowerCase());
    });
    return ranked;
  }
}