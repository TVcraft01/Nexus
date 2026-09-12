// The skill loop: ranking genuine skill usage from the ask log.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/capability.dart';
import 'package:nexus/core/skills.dart';

/// One ask-log line in the exact shape QueryLog.i.ask writes.
String _ask(String input, String route) => jsonEncode({
  'ts': '2026-09-05T10:00:00.000',
  'kind': 'ask',
  'input': input,
  'status': 'succeeded',
  'route': route,
  'detail': '',
});

void main() {
  test('ranks skills by genuine usage, most used first', () {
    const ranking = SkillRanking();
    final ranked = ranking.rank([
      _ask('set a timer for 5 minutes', 'timer.set'),
      _ask('call mom', 'comm.call'),
      _ask('set a timer for 10 minutes', 'timer.set'),
      _ask('search for cats', 'search.web'),
      _ask('call dad', 'comm.call'),
      _ask('call grandma', 'comm.call'),
    ]);
    expect(
      [for (final s in ranked) s.id],
      ['comm.call', 'timer.set', 'search.web'],
    );
    expect(ranked.first.uses, 3);
    expect(ranked.first.label, 'Calls');
    expect(ranked.first.example, 'call mom');
  });

  test('only genuine skill routes count', () {
    const ranking = SkillRanking();
    final ranked = ranking.rank([
      _ask('set a timer for 5 minutes', 'timer.set'),
      _ask('what time is it', 'message'), // a plain answer, not a skill
      _ask('anything', 'teach:anything'), // a teach answer, not a skill
      _ask('open youtube', 'app.open'), // approval-pending is still intent
      'not json at all', // a torn line never counts
      jsonEncode({
        'kind': 'sync', // not an ask at all
        'route': 'timer.set',
        'phrase': 'x',
        'meaning': 'y',
      }),
    ]);
    // Tied at one use each — alphabetical by label (Apps before Timers).
    expect(
      [for (final s in ranked) s.id],
      ['app.open', 'timer.set'],
    );
    expect(ranked.first.uses, 1);
  });

  test('alphabetical on ties', () {
    final ranked = const SkillRanking().rank([
      _ask('open youtube', 'app.open'),
      _ask('search for cats', 'search.web'),
    ]);
    expect(
      [for (final s in ranked) s.id],
      ['app.open', 'search.web'],
    );
  });

  test('an empty or foreign log ranks empty', () {
    expect(const SkillRanking().rank(const []), isEmpty);
    expect(const SkillRanking().rank(['junk', '']), isEmpty);
  });

  test('the catalog is non-empty and every skill has a label and example', () {
    final catalog = skillCatalog();
    expect(catalog, isNotEmpty);
    for (final entry in catalog.entries) {
      expect(entry.value.label, isNotEmpty);
      expect(entry.value.example, isNotEmpty);
    }
  });
}