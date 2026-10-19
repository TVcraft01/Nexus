// Arithmetic the shell answers itself.
//
// The A25 is why this file exists: asked "what is 6 times 7", the 1B model on
// the phone answered `{"action":"set_timer","seconds":420}` and the shell set a
// seven-minute timer. A sum has an answer that does not need a model, so the
// shell computes it — and these are the sentences it claims and declines.
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/math_helper.dart';

void main() {
  group('the shapes the shell answers', () {
    test('a question in words', () {
      expect(nexusMathAnswer('what is 6 times 7'), '6 * 7 = 42');
      expect(nexusMathAnswer('What is 2 plus 2?'), '2 + 2 = 4');
      expect(nexusMathAnswer('what is 9 minus 12'), '9 - 12 = -3');
      expect(nexusMathAnswer('what is 10 divided by 4'), '10 / 4 = 2.5');
      expect(nexusMathAnswer('how much is 3 multiplied by 5'), '3 * 5 = 15');
    });

    test('a bare expression, typed', () {
      expect(nexusMathAnswer('15 * 4'), '15 * 4 = 60');
      expect(nexusMathAnswer('2+2'), '2 + 2 = 4');
      expect(nexusMathAnswer('100 / 8'), '100 / 8 = 12.5');
      expect(nexusMathAnswer('7 - 10'), '7 - 10 = -3');
    });

    test('the symbols a transcript produces', () {
      expect(nexusMathAnswer('5 × 5'), '5 * 5 = 25');
      expect(nexusMathAnswer('12 ÷ 3'), '12 / 3 = 4');
      expect(nexusMathAnswer('6 x 7'), '6 * 7 = 42');
    });

    test('the other ways a person asks', () {
      expect(nexusMathAnswer("what's 4 + 9"), '4 + 9 = 13');
      expect(nexusMathAnswer('calculate 8 * 8'), '8 * 8 = 64');
      expect(nexusMathAnswer('work out 2.5 + 1.5'), '2.5 + 1.5 = 4');
      expect(nexusMathAnswer('what is the answer to 12 / 4'), '12 / 4 = 3');
      expect(nexusMathAnswer('2 + 2 = ?'), '2 + 2 = 4');
    });

    test('a thousands separator is read, not treated as punctuation', () {
      expect(nexusMathAnswer('1,000 + 1'), '1000 + 1 = 1001');
    });

    test('the result has no floating-point dust', () {
      // 0.1 + 0.2 is 0.30000000000000004 in a double; the thread says 0.3.
      expect(nexusMathAnswer('0.1 + 0.2'), '0.1 + 0.2 = 0.3');
    });

    test('division by zero is answered in words', () {
      // The one sum with a true answer that is not a number. Saying it is
      // better than handing the question on, where the model can only invent.
      expect(nexusMathAnswer('5 divided by 0'), "You can't divide by zero.");
      expect(nexusMathAnswer('5 / 0'), "You can't divide by zero.");
    });
  });

  group('the sentences it declines', () {
    test('a word problem is not arithmetic', () {
      expect(
        nexusMathAnswer('how many 6-inch tiles fit in a 7-foot room'),
        null,
      );
      expect(nexusMathAnswer('what is 2 plus 2 apples'), null);
    });

    test('a chain of operations is left to the model', () {
      // One operation, two numbers: a chain would need precedence rules the
      // shell would then have to explain.
      expect(nexusMathAnswer('2 + 3 * 4'), null);
      expect(nexusMathAnswer('7 plus 3 times 2'), null);
    });

    test('an incomplete sum is not one', () {
      expect(nexusMathAnswer('2 +'), null);
      expect(nexusMathAnswer('what is plus 2'), null);
    });

    test('an ordinary question survives', () {
      expect(nexusMathAnswer('what is the weather'), null);
      expect(nexusMathAnswer('tell me a joke'), null);
      expect(nexusMathAnswer('set a timer for 5 minutes'), null);
      expect(nexusMathAnswer('what time is it'), null);
    });

    test('a date is not a division', () {
      expect(nexusMathAnswer('19/10/2026'), null);
    });
  });
}
