import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/predictions.dart';

const Predictions predictions = Predictions();

String ask(String input, String route) =>
    '{"ts":"t","kind":"ask","input":"$input","status":"succeeded","route":"$route","detail":""}';

void main() {
  test('most-asked phrases come first, alphabetical on ties', () {
    final habits = predictions.habits([
      ask('what time is it', 'message'),
      ask('roll a dice', 'message'),
      ask('what time is it', 'message'),
      ask('what time is it', 'message'),
      ask('roll a dice', 'message'),
      ask('battery', 'message'),
    ]);
    expect(habits.map((h) => h.phrase), ['what time is it', 'roll a dice', 'battery']);
    expect(habits.map((h) => h.count), [3, 2, 1]);
  });

  test('answers to open questions never become suggestions', () {
    // teach:/which: routes log the user's typed answer, not a fresh ask.
    final habits = predictions.habits([
      ask('no', 'teach:bring me home'),
      ask('show my devices', 'teach:bring me home'),
      ask('Chill Mix', 'which:media.play.playlist'),
      ask('what time is it', 'message'),
    ]);
    expect(habits.map((h) => h.phrase), ['what time is it']);
  });

  test('bare agreement words never become suggestions', () {
    final habits = predictions.habits([
      ask('yes', 'message'),
      ask('okay', 'message'),
      ask('sure', 'message'),
      ask('go ahead', 'message'),
    ]);
    expect(habits, isEmpty);
  });

  test('torn lines, foreign kinds and empty inputs are skipped', () {
    final habits = predictions.habits([
      'not json at all',
      '{"ts":"t","kind":"ask","input":"what time is it","status":"succeeded","route":"message","detail":""}',
      '{"ts":"t","kind":"other","input":"what time is it","route":"message","detail":""}',
      '{"ts":"t","kind":"ask","input":"   ","route":"message","detail":""}',
    ]);
    expect(habits.map((h) => h.phrase), ['what time is it']);
    expect(habits.single.count, 1);
  });

  test('limit caps the returned phrases', () {
    final habits = predictions.habits([
      ask('a', 'message'),
      ask('b', 'message'),
      ask('c', 'message'),
      ask('d', 'message'),
    ], limit: 2);
    expect(habits.length, 2);
  });
}
