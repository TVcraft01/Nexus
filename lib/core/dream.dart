import 'dart:convert';

import 'command_interpreter.dart';

/// One phrase the assistant had to give up on, with how often.
class DreamInsight {
  final String phrase;
  final int count;

  const DreamInsight(this.phrase, this.count);
}

/// A fix the dream pass found on its own: [phrase] kept failing as a fresh
/// ask, and the user has since taught [source] — close enough that the
/// assistant can propose learning [phrase] as [meaning] in one tap. The
/// meaning is never invented: it is the user's own teaching, applied to
/// their own variant.
class DreamLearn {
  final String phrase;
  final String meaning;
  final String source;
  final int count;

  const DreamLearn({
    required this.phrase,
    required this.meaning,
    required this.source,
    required this.count,
  });
}

/// The dream pass: read what users actually asked, keep the phrases the
/// assistant had to give up on, and surface them so each one can be taught
/// once and never fail again. Pure Dart over the query log's JSON lines —
/// no model, no network, nothing leaves the device.
class DreamPass {
  const DreamPass();

  /// Parsed teach-loop entries: the failed phrase (normalized) and the raw
  /// input that produced the entry — the phrase itself on a fresh ask, the
  /// user's typed answer ("no", a correction) on re-asks within one session.
  static Iterable<(String phrase, String input)> _teachEntries(
    Iterable<String> lines,
  ) sync* {
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
      final norm = CommandInterpreter.normalizePhrase(phrase);
      if (norm.isEmpty) continue;
      yield (norm, entry['input']?.toString() ?? '');
    }
  }

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
    for (final (norm, _) in _teachEntries(lines)) {
      if (exclude.contains(norm)) continue;
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

  /// Self-improvement proposals: a phrase the user kept re-asking (a fresh
  /// ask at least [minCount] times — one session's answers don't count) that
  /// maps cleanly onto a phrase the user has since taught. The fix is never
  /// invented: it is the user's own teaching, applied to their own variant,
  /// and the caller only ever offers it — a wrong guess stays a question.
  List<DreamLearn> learnable(
    Iterable<String> lines, {
    required Map<String, String> learned,
    int minCount = 2,
  }) {
    final interpreter = const CommandInterpreter();
    final counts = <String, int>{};
    for (final (norm, input) in _teachEntries(lines)) {
      if (learned.containsKey(norm)) continue;
      if (interpreter.interpret(norm).outcome != InterpretOutcome.unknown) {
        continue; // understood by now — not a gap anymore
      }
      // Only a fresh re-ask is evidence of persistence — the user's typed
      // answer inside one session ("no", a correction) is not.
      if (CommandInterpreter.normalizePhrase(input) != norm) continue;
      counts[norm] = (counts[norm] ?? 0) + 1;
    }
    final out = <DreamLearn>[];
    for (final e in counts.entries) {
      if (e.value < minCount) continue;
      final phrase = e.key;
      // Same conservative guard as the live near-matching: short phrases
      // are too ambiguous to guess at.
      if (phrase.length < 6) continue;
      String? bestSource;
      var bestScore = 0.0;
      for (final taught in learned.entries) {
        final score = CommandInterpreter.phraseSimilarity(phrase, taught.key);
        if (score > bestScore) {
          bestScore = score;
          bestSource = taught.key;
        }
      }
      if (bestSource == null || bestScore < 0.68) continue;
      final meaning = learned[bestSource]!;
      // A proposed meaning that can't be learned would dead-end the card —
      // the teach funnel refuses it, so the dream must never propose it.
      if (interpreter.interpret(meaning).outcome != InterpretOutcome.matched) {
        continue;
      }
      out.add(DreamLearn(
        phrase: phrase,
        meaning: meaning,
        source: bestSource,
        count: e.value,
      ));
    }
    out.sort((a, b) {
      final byCount = b.count.compareTo(a.count);
      return byCount != 0 ? byCount : a.phrase.compareTo(b.phrase);
    });
    return out;
  }
}