import 'dart:convert';

import 'command_interpreter.dart';

/// One phrase the assistant had to give up on, with how often.
class DreamInsight {
  final String phrase;
  final int count;

  const DreamInsight(this.phrase, this.count);
}

/// The dream pass: read what users actually asked, keep the phrases the
/// assistant had to give up on, and surface them so each one can be taught
/// once and never fail again. Pure Dart over the query log's JSON lines —
/// no model, no network, nothing leaves the device.
class DreamPass {
  const DreamPass();

  /// Phrases logged as teach-loop dead ends, most frequent first. Phrases
  /// since taught (or now understood outright) are skipped, so the list
  /// self-cleans as the assistant learns. [lines] are raw JSONL lines as
  /// written by [QueryLog].
  List<DreamInsight> unknownPhrases(
    Iterable<String> lines, {
    Set<String> exclude = const {},
  }) {
    final interpreter = const CommandInterpreter();
    final counts = <String, int>{};
    for (final line in lines) {
      final Map<String, dynamic> entry;
      try {
        entry = jsonDecode(line) as Map<String, dynamic>;
      } catch (_) {
        continue; // a torn or foreign line never breaks the dream
      }
      if (entry['kind'] != 'ask') continue;
      final route = entry['route']?.toString() ?? '';
      if (!route.startsWith('teach:')) continue;
      // The phrase lives in the route — the logged input is the user's
      // typed answer whenever a question was open ("no", the correction,
      // the same typo again), never the phrase that failed.
      final phrase = route.substring('teach:'.length).trim();
      if (phrase.isEmpty) continue;
      final norm = CommandInterpreter.normalizePhrase(phrase);
      if (norm.isEmpty || exclude.contains(norm)) continue;
      if (interpreter.interpret(norm).outcome != InterpretOutcome.unknown) {
        continue; // understood by now — not a gap anymore
      }
      counts[norm] = (counts[norm] ?? 0) + 1;
    }
    final insights = [
      for (final e in counts.entries) DreamInsight(e.key, e.value),
    ];
    insights.sort((a, b) {
      final byCount = b.count.compareTo(a.count);
      return byCount != 0 ? byCount : a.phrase.compareTo(b.phrase);
    });
    return insights;
  }
}
