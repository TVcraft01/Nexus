// What the brains are told about the clock.
//
// Both of them guessed. Asked "what time is it" on the A25, the 1B model on the
// device answered `{"time": "07:30"}` at 14:24 — a plausible-looking value it
// had no way to know, shown to the user as though it were the time. A language
// model has no clock: it has a training cutoff, and everything after it is
// invention that reads like fact.
//
// So the clock is put in the one place a model treats as instruction rather than
// as something to answer: the system turn. It is appended by the services, not
// by a screen, because every caller must get it — the thread, the live page, and
// any future surface — and a brain that is only told the time on some screens is
// a brain that lies on the others.
//
// The line states the clock *and* the rule, in that order: a small model follows
// one instruction far better than it infers one.
library;

/// [system] with the device's current date and time appended.
///
/// [now] is a test seam: a test that pins the phrase needs a fixed clock, and a
/// clock read inside this function would make its assertion depend on the hour
/// the test ran.
String nexusSystemWithClock(String system, {DateTime? now}) =>
    '$system\n\n${nexusClockLine(now: now)}';

/// The sentence itself: what time it is, said the way a person would say it.
String nexusClockLine({DateTime? now}) {
  final DateTime at = now ?? DateTime.now();
  return 'The current date and time on this device is ${spokenDateTime(at)}. '
      'Answer questions about the date or time from that, and never invent or '
      'estimate one.';
}

/// Whether [text] is a question about the current time or date.
///
/// Measured, twice, on the A25: a 0.5B model with the clock in its system turn
/// and a `get_time` action in its vocabulary still answered "07:30" at 14:24.
/// A model that cannot know the time cannot be trusted with the question, so the
/// shell recognises the question itself and answers from its own clock — the
/// same rule it already applies to "set brightness to 60", where the closed
/// vocabulary lives on this side of the seam.
///
/// Deliberately narrow: a sentence that merely mentions time ("set a timer",
/// "what time did the meeting start") is not a clock question and is still the
/// model's to answer. Each pattern is anchored at the start of the sentence, so
/// "what time is it in Tokyo" is the only generous case — and there the phone's
/// own timezone is still a better answer than a guess.
bool isClockQuestion(String text) {
  final String said = text
      .toLowerCase()
      // Apostrophes close up rather than split: "what's" is "whats", not "what s".
      .replaceAll(RegExp("[’']"), '')
      .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (said.isEmpty) return false;
  const List<String> starts = <String>[
    'what time is it',
    'what time it is',
    'whats the time',
    'what is the time',
    'whats the date',
    'what is the date',
    'what day is it',
    'whats today',
    'what is today',
    'what date is it',
    'todays date',
    'todays time',
    'current time',
    'current date',
    'the time please',
    'the date please',
    'tell me the time',
    'tell me the date',
    'time now',
    'date today',
  ];
  return starts.any(said.startsWith);
}

/// The clock as the shell answers it: "It's 15:05 on Monday 19 October 2026."
///
/// Time first, because that is what was asked for; the date follows so a
/// follow-up ("and the date?") is already answered. Both come from the same
/// reading, so the two halves can never disagree.
String nexusClockAnswer({DateTime? now}) {
  final DateTime at = now ?? DateTime.now();
  return 'It\'s ${_clock(at)} on ${_date(at)}.';
}

/// [at] as "Sunday 19 October 2026, 14:24".
///
/// Written out rather than handed to `intl`: this is one line of a prompt, it
/// must read the same on every device whatever locale the phone is set to, and
/// a model reads "19 October 2026" more reliably than "19/10/2026" — the numeric
/// forms are exactly the ones it is likely to confabulate.
String spokenDateTime(DateTime at) => '${_date(at)}, ${_clock(at)}';

/// "14:24" — 24-hour, zero-padded, so a model reading it cannot take 9:5 for
/// a minute and a half.
String _clock(DateTime at) =>
    '${at.hour.toString().padLeft(2, '0')}:'
    '${at.minute.toString().padLeft(2, '0')}';

/// "Monday 19 October 2026".
String _date(DateTime at) {
  const List<String> weekdays = <String>[
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];
  const List<String> months = <String>[
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  return '${weekdays[at.weekday - 1]} ${at.day} ${months[at.month - 1]} '
      '${at.year}';
}
