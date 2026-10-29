// Every action the assistant can take must be named by at least one test.
//
// This reads the source and the test directory as resources rather than
// mocking them, the same way capability_test.dart holds the registry to its
// own rules: a constant added to [AgentActions] without a test is invisible
// until someone reads every file, and this is the file that makes it visible.
//
// It is deliberately a weak assertion. "Named somewhere in test/" is not
// "asserted to parse" — test/command_inventive_test.dart is what asserts that
// for the phrasings people actually use. What this catches is the action that
// arrives with no coverage at all, which is how `music.play` and `alarm.show`
// reached main.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The `static const name = 'id'` pairs inside `class AgentActions`.
List<({String name, String id})> _actions() {
  final String source = File('lib/core/agent_contract.dart').readAsStringSync();
  final int start = source.indexOf('class AgentActions');
  expect(start, isNot(-1), reason: 'AgentActions moved — update this test');
  final int end = source.indexOf('\n}', start);
  final String body = source.substring(start, end);
  return <({String name, String id})>[
    for (final RegExpMatch m in RegExp(r"static const (\w+)\s*=\s*'([^']+)'")
        .allMatches(body))
      (name: m.group(1)!, id: m.group(2)!),
  ];
}

void main() {
  test('every action carries the id this test asks about', () {
    final List<({String name, String id})> actions = _actions();
    // A floor, not a target: the class has 69 today. Raising this is a
    // deliberate act, so an accidental deletion shows up here too.
    expect(actions.length, greaterThanOrEqualTo(69));
  });

  test('every AgentActions id is referenced by at least one test', () {
    final List<File> tests = Directory('test')
        .listSync(recursive: true)
        .whereType<File>()
        .where((File f) => f.path.endsWith('.dart'))
        .toList();
    final Map<String, String> contents = <String, String>{
      for (final File f in tests) f.path: f.readAsStringSync(),
    };

    final List<String> orphans = <String>[];
    for (final ({String name, String id}) action in _actions()) {
      final bool named = contents.values.any(
        (String t) => t.contains('AgentActions.${action.name}'),
      );
      final bool spelled = contents.values.any(
        (String t) => t.contains("'${action.id}'"),
      );
      if (!named && !spelled) orphans.add('${action.name} (${action.id})');
    }

    expect(
      orphans,
      isEmpty,
      reason: 'These actions have no test. Add one before shipping them:\n'
          '${orphans.join('\n')}',
    );
  });
}
