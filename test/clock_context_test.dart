// The clock line every brain is given.
//
// The bug this pins is not subtle: asked "what time is it" at 14:24, the phone
// answered `{"time": "07:30"}` — a model inventing a value it had no way to
// know. The fix is a fact in the system turn, in words, on every request.
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/clock_context.dart';

void main() {
  test('the date and time are said in words, not in digits', () {
    // Written out because "19/10/2026" is exactly the form a model is likely
    // to confuse; the month and weekday are unambiguous in any locale.
    expect(
      spokenDateTime(DateTime(2026, 10, 19, 14, 24)),
      'Monday 19 October 2026, 14:24',
    );
    // Single-digit hours and minutes are padded, so a model reading the line
    // cannot mistake 09:05 for 9:5 or for a different field.
    expect(
      spokenDateTime(DateTime(2026, 1, 1, 9, 5)),
      'Thursday 1 January 2026, 09:05',
    );
    expect(
      spokenDateTime(DateTime(2026, 12, 31, 23, 59)),
      'Thursday 31 December 2026, 23:59',
    );
  });

  test('a system prompt keeps its rules and gains the clock', () {
    final String system = nexusSystemWithClock(
      'You are Nexus.',
      now: DateTime(2026, 10, 19, 14, 24),
    );

    // The persona is untouched and still first: the clock is an addition, not a
    // replacement for the rules the model runs under.
    expect(system, startsWith('You are Nexus.'));
    expect(system, contains('Monday 19 October 2026, 14:24'));
    expect(system, contains('never invent'));
  });

  test('a clock question is recognised, and a timer is not', () {
    // The shell answers these itself; the model has no clock.
    for (final String asked in <String>[
      'what time is it',
      'What time is it?',
      "what's the time",
      'what is the date',
      'what day is it',
      "what's today's date",
      'current time',
      'tell me the time',
    ]) {
      expect(isClockQuestion(asked), isTrue, reason: asked);
    }
    // Everything else stays the model's: a timer, a question that mentions a
    // time without asking for the clock, and an ordinary question.
    for (final String said in <String>[
      'set a timer for 10 minutes',
      'what time did the meeting start',
      'remind me at 6',
      'what is a mesh',
      '',
    ]) {
      expect(isClockQuestion(said), isFalse, reason: said);
    }
  });

  test('the line is built per call, so the time is the time now', () {
    // Two calls a minute apart are two different sentences: a clock captured
    // when the service was constructed would answer every later question with
    // the time the app started.
    expect(
      nexusClockLine(now: DateTime(2026, 10, 19, 14, 24)),
      isNot(nexusClockLine(now: DateTime(2026, 10, 19, 14, 25))),
    );
    // And the shell's own answer reads as a sentence, time first.
    expect(
      nexusClockAnswer(now: DateTime(2026, 10, 19, 15, 5)),
      "It's 15:05 on Monday 19 October 2026.",
    );
  });
}
