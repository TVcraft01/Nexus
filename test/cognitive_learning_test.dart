import 'package:flutter_test/flutter_test.dart';

import 'package:nexus/core/cognitive_learning.dart';
import 'package:nexus/core/cognitive_state.dart';

void main() {
  group('CognitiveLearning', () {
    const learning = CognitiveLearning();

    test('turns an experience into durable memory', () {
      final at = DateTime(2026, 9, 11, 12);
      final state = learning.observe(
        const CognitiveState(),
        CognitiveExperience(
          text: 'The user prefers concise answers.',
          personId: 'user',
          at: at,
          salience: 0.9,
        ),
      );

      expect(state.memories, hasLength(1));
      expect(state.memories.single.content, contains('concise'));
      expect(state.people['user']?.vocabulary['user'], 1);
    });

    test('repeated experience strengthens rather than duplicates memory', () {
      final first = DateTime(2026, 9, 11, 12);
      final second = first.add(const Duration(hours: 2));
      var state = learning.observe(
        const CognitiveState(),
        CognitiveExperience(text: 'Nexus is local.', at: first),
      );
      state = learning.observe(
        state,
        CognitiveExperience(text: 'Nexus is local.', at: second),
      );

      expect(state.memories, hasLength(1));
      expect(state.memories.single.strength, 2);
      expect(state.memories.single.lastSeen, second);
    });

    test('sleep removes weak stale memories and preserves important ones', () {
      final now = DateTime(2026, 9, 11);
      final old = now.subtract(const Duration(days: 200));
      final state = CognitiveState(memories: [
        CognitiveMemory(
          id: 'weak',
          content: 'temporary detail',
          kind: 'experience',
          importance: 0.1,
          strength: 1,
          createdAt: old,
          lastSeen: old,
        ),
        CognitiveMemory(
          id: 'important',
          content: 'important preference',
          kind: 'preference',
          importance: 0.95,
          strength: 5,
          createdAt: old,
          lastSeen: old,
        ),
      ]);

      final slept = learning.sleep(state, now: now);

      expect(slept.lastConsolidatedAt, now);
      expect(slept.memories.map((m) => m.id), contains('important'));
      expect(slept.memories.map((m) => m.id), isNot(contains('weak')));
    });
  });
}
