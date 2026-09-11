import 'cognitive_state.dart';

/// An observation captured during an active session. It is intentionally
/// transient until a consolidation pass decides that it deserves durable
/// memory.
class CognitiveExperience {
  final String text;
  final String? personId;
  final DateTime at;
  final double salience;

  const CognitiveExperience({
    required this.text,
    this.personId,
    required this.at,
    this.salience = 0.5,
  });
}

/// Deterministic, model-independent learning substrate. It does not pretend
/// to train neural weights. Instead it lets Nexus acquire durable state from
/// experience, which is suitable for a phone and can later be fed back into
/// any local model.
class CognitiveLearning {
  const CognitiveLearning();

  CognitiveState observe(
    CognitiveState state,
    CognitiveExperience experience,
  ) {
    final content = experience.text.trim();
    if (content.isEmpty) return state;

    final memories = List<CognitiveMemory>.from(state.memories);
    final existingIndex = memories.indexWhere(
      (m) => m.content.toLowerCase() == content.toLowerCase(),
    );
    if (existingIndex >= 0) {
      memories[existingIndex] = memories[existingIndex].reinforce(
        at: experience.at,
        importanceBoost: experience.salience * 0.05,
      );
    } else {
      final id = '${experience.at.microsecondsSinceEpoch}-${memories.length}';
      memories.add(CognitiveMemory(
        id: id,
        content: content,
        kind: 'experience',
        importance: experience.salience.clamp(0.0, 1.0),
        strength: 1,
        createdAt: experience.at,
        lastSeen: experience.at,
      ));
    }

    var next = state.copyWith(memories: memories);
    if (experience.personId != null) {
      final id = experience.personId!;
      final profile = next.people[id] ?? SocialProfile(
        personId: id,
        lastSeen: experience.at,
      );
      next = next.copyWith(
        people: {
          ...next.people,
          id: profile.observeWords(_words(content), at: experience.at),
        },
      );
    }
    return next;
  }

  /// The first "sleep" implementation: consolidate recent experiences,
  /// strengthen repeated patterns, and forget weak stale memories. It is
  /// intentionally bounded so a phone never accumulates an unbounded brain.
  CognitiveState sleep(
    CognitiveState state, {
    required DateTime now,
    Duration retention = const Duration(days: 90),
    int maxMemories = 1000,
  }) {
    final cutoff = now.subtract(retention);
    final kept = <CognitiveMemory>[];
    for (final memory in state.memories) {
      final ageDays = now.difference(memory.lastSeen).inHours / 24.0;
      final decay = ageDays <= 0 ? 0.0 : ageDays / retention.inDays;
      final effective = memory.importance +
          (memory.strength - 1) * 0.05 -
          decay * 0.25;
      if (memory.lastSeen.isAfter(cutoff) || effective >= 0.35) {
        kept.add(memory);
      }
    }
    kept.sort((a, b) {
      final aScore = _score(a, now);
      final bScore = _score(b, now);
      return bScore.compareTo(aScore);
    });
    if (kept.length > maxMemories) {
      kept.removeRange(maxMemories, kept.length);
    }
    return state.copyWith(
      memories: kept,
      lastConsolidatedAt: now,
    );
  }

  double _score(CognitiveMemory memory, DateTime now) {
    final ageDays = now.difference(memory.lastSeen).inHours / 24.0;
    return memory.importance + memory.strength * 0.05 - ageDays * 0.002;
  }

  Iterable<String> _words(String text) sync* {
    for (final raw in text.toLowerCase().split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))) {
      if (raw.length >= 3) yield raw;
    }
  }
}
