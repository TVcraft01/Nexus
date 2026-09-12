// The skill loop — Nexus's signature idea: watch which of its everyday
// skills the user genuinely reaches for, and get visibly better at the ones
// that matter. Pure Dart over the same ask-log lines the dream pass and the
// personal predictions read: one usage log, three readings. Nothing leaves
// the device; the ranking is derived fresh, like habits, never stored.
import 'dart:convert';

import 'capability.dart';

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

/// Ranks skills by genuine usage from ask-log lines (raw JSONL as written
/// by [QueryLog]): every ask whose route names a catalog action counts once.
/// Clarification answers (`teach:…`, `arg:…` routes), plain-message asks
/// (the time, a joke), and torn lines never count — an ask is genuine only
/// when a real skill ran. Most-used first, alphabetical on ties.
class SkillRanking {
  const SkillRanking();

  List<SkillUse> rank(Iterable<String> lines) {
    // The everyday skills are a *reading* of the capability registry, so this
    // file holds the ranking policy and nothing else — no labels, no phrases.
    final catalog = skillCatalog();
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
      if (!catalog.containsKey(route)) continue;
      counts[route] = (counts[route] ?? 0) + 1;
    }
    final ranked = [
      for (final entry in counts.entries)
        SkillUse(
          id: entry.key,
          label: catalog[entry.key]!.label,
          example: catalog[entry.key]!.example,
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