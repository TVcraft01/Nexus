import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/dream.dart';

/// The dream pass mines teach-loop dead ends out of the query log so each
/// can be taught once and never fail again.
void main() {
  const dream = DreamPass();

  // Realistic lines: an unknown asked twice (the second entry's input is the
  // user's re-ask answer "no" — the phrase must come from the route), one
  // phrase since understood, one succeeded ask, a torn line, a fact event.
  final lines = [
    '{"ts":"t","kind":"ask","input":"bring me home","status":"needsInfo","route":"teach:bring me home","detail":""}',
    '{"ts":"t","kind":"ask","input":"no","status":"needsInfo","route":"teach:bring me home","detail":""}',
    '{"ts":"t","kind":"ask","input":"wake me at 7","status":"needsInfo","route":"teach:wake me at 7","detail":""}',
    '{"ts":"t","kind":"ask","input":"show my devices","status":"succeeded","route":"message","detail":""}',
    'not json at all',
    '{"ts":"t","kind":"fact","op":"remember","text":"x"}',
  ];

  test('groups dead-end phrases, counts repeats, sorts most-asked first', () {
    final insights = dream.unknownPhrases(lines);
    expect(insights.map((i) => i.phrase).toList(), [
      'bring me home',
      'wake me at 7',
    ]);
    expect(insights.first.count, 2);
  });

  test(
    'a taught phrase leaves the list; a now-understood one never enters',
    () {
      expect(
        dream
            .unknownPhrases(lines, exclude: {'bring me home'})
            .map((i) => i.phrase),
        ['wake me at 7'],
      );
      // A stale route can carry a phrase the interpreter understands by
      // now (a pattern landed since) — it must never be shown.
      final understoodNow = [
        ...lines,
        '{"ts":"t","kind":"ask","input":"no","status":"needsInfo","route":"teach:show my devices","detail":""}',
      ];
      expect(dream.unknownPhrases(understoodNow).map((i) => i.phrase), [
        'bring me home',
        'wake me at 7',
      ]);
    },
  );

  test('empty or unreadable history is an empty dream, never an error', () {
    expect(dream.unknownPhrases(const []), isEmpty);
  });

  group('learnable — the dream teaches itself from what the user taught', () {
    // "tex mom" asked three times as a fresh ask, plus one session's
    // answer entry ("no") that must not count as persistence.
    final reasked = [
      '{"ts":"t","kind":"ask","input":"tex mom","status":"needsInfo","route":"teach:tex mom","detail":""}',
      '{"ts":"t","kind":"ask","input":"tex mom","status":"needsInfo","route":"teach:tex mom","detail":""}',
      '{"ts":"t","kind":"ask","input":"tex mom","status":"needsInfo","route":"teach:tex mom","detail":""}',
      '{"ts":"t","kind":"ask","input":"no","status":"needsInfo","route":"teach:tex mom","detail":""}',
    ];

    test('proposes the user\'s own taught meaning for a close variant', () {
      final learns = dream.learnable(
        reasked,
        learned: {'text mom': 'call tvcraft01'},
      );
      expect(learns, hasLength(1));
      expect(learns.first.phrase, 'tex mom');
      expect(learns.first.meaning, 'call tvcraft01');
      expect(learns.first.source, 'text mom');
      // Persistence counts fresh asks only — the "no" answer is one
      // session, not a re-ask.
      expect(learns.first.count, 3);
    });

    test('a single fresh ask is a one-off typo, not worth proposing', () {
      final learns = dream.learnable(
        reasked.take(1),
        learned: {'text mom': 'call tvcraft01'},
      );
      expect(learns, isEmpty);
    });

    test('a phrase already taught is never proposed', () {
      expect(
        dream.learnable(reasked, learned: {'tex mom': 'call tvcraft01'}),
        isEmpty,
      );
    });

    test('without a close taught phrase there is nothing to learn from', () {
      expect(
        dream.learnable(reasked, learned: {'show my devices': 'show my devices'}),
        isEmpty,
      );
    });

    test('a meaning the teach funnel would refuse is never proposed', () {
      expect(
        dream.learnable(reasked, learned: {'text mom': 'gibberish not a command'}),
        isEmpty,
      );
    });

    test('a taught phrase of its own closes the gap for good', () {
      final learned = dream.learnable(reasked, learned: {'text mom': 'call tvcraft01'});
      // After the dream proposal is applied, the phrase enters learned and
      // vanishes from the next pass — self-cleaning like the gap list.
      final next = dream.learnable(
        reasked,
        learned: {'text mom': 'call tvcraft01', 'tex mom': 'call tvcraft01'},
      );
      expect(learned, isNotEmpty);
      expect(next, isEmpty);
    });
  });
}
