import 'dart:convert';

import 'command_interpreter.dart';

/// One phrase the user keeps asking, with how often.
class Habit {
  final String phrase;
  final int count;

  const Habit(this.phrase, this.count);
}

/// Personal predictions: the phrases this user actually asks most, mined
/// from the ask log — the assistant's sense of routine. It offers them
/// before being asked, the way a human assistant would learn your habits.
/// Pure Dart over the query log's JSON lines — no model, no network.
///
/// Only *real asks* count: entries logged while a clarification was open
/// carry the user's typed *answer* (\"yes\", the correction, a playlist
/// name) — those live in the `teach:`/`which:` routes and are skipped, as
/// are bare agreement words, so \"yes\" can never become a suggestion.
class Predictions {
  const Predictions();

  static const _answerWords = {
    'yes', 'yep', 'yeah', 'sure', 'ok', 'okay', 'y',
    'no', 'nope', 'do it', 'go ahead',
  };

  /// The user's most-asked phrases, most frequent first (alphabetical on
  /// ties). [lines] are raw JSONL lines as written by [QueryLog]. Returns
  /// at most [limit] phrases.
  List<Habit> habits(Iterable<String> lines, {int limit = 6}) {
    final counts = <String, (int count, String display)>{};
    for (final line in lines) {
      final Map<String, dynamic> entry;
      try {
        entry = jsonDecode(line) as Map<String, dynamic>;
      } catch (_) {
        continue; // a torn or foreign line never breaks a prediction
      }
      if (entry['kind'] != 'ask') continue;
      final route = entry['route']?.toString() ?? '';
      // teach:/which: entries log the user's answer, not a fresh ask.
      if (route.startsWith('teach:') || route.startsWith('which:')) continue;
      final input = entry['input']?.toString().trim() ?? '';
      if (input.isEmpty || _answerWords.contains(input.toLowerCase())) {
        continue;
      }
      final norm = CommandInterpreter.normalizePhrase(input);
      if (norm.isEmpty) continue;
      final previous = counts[norm];
      counts[norm] = ((previous?.$1 ?? 0) + 1, input);
    }
    final habits = [
      for (final entry in counts.entries) Habit(entry.value.$2, entry.value.$1),
    ];
    habits.sort((a, b) {
      final byCount = b.count.compareTo(a.count);
      if (byCount != 0) return byCount;
      return a.phrase.toLowerCase().compareTo(b.phrase.toLowerCase());
    });
    return habits.take(limit).toList(growable: false);
  }
}
