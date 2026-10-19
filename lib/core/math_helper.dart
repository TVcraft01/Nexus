// Arithmetic the shell answers itself.
//
// A language model is not a calculator, and the A25 proved it: asked "what is
// 6 times 7", the 1B model on the device answered
// `{"action":"set_timer","seconds":420}` — it read the two numbers as a length
// of time, set a seven-minute timer, and the shell said "Timer set for 7
// minutes." The user got no answer and an alarm they did not ask for.
//
// One operation between two numbers has exactly one answer, and nothing about
// it needs a model: no world knowledge, no phrasing, no judgement. So the shell
// reads that sentence itself and answers it — instantly, on this device, with
// no tokens spent and nothing to hallucinate. Everything with a word in it that
// is not an operator ("how many 6-inch tiles fit in a 7-foot room") is still
// the model's, which is where the rest of language lives.
//
// The sentence usually arrives spoken, not typed: a phone's recognizer can
// answer "six times seven" as readily as "6 * 7", and a voice-first app has to
// read both. [wordsToDigits] does that translation, so the parser below has one
// grammar (digits and symbols) rather than two.
//
// Deliberately narrow: one operator, two numbers, and nothing else in the
// sentence. Chains ("2 + 3 * 4"), parentheses and word problems fall through to
// the brain rather than being half-understood here.
library;

/// The number shape both operands share: an optional minus, whole or decimal.
const String _number = r'-?\d+(?:\.\d+)?';

/// The ways a person introduces a sum. Longest first: "what is the answer to
/// 2 + 2" must lose the whole prefix, not just "what is".
final RegExp _questionPrefix = RegExp(
  r'^(?:what is the answer to|what is|whats|how much is|calculate|compute|'
  r'work out|solve)\s+',
);

/// One operation between two numbers: word operators ("6 times 7"), the
/// symbols a keyboard writes ("15 * 4") and the ones a transcript produces
/// ("5 × 5").
final RegExp _operation = RegExp(
  '^($_number)\\s*'
  '(multiplied by|divided by|times|plus|minus|over|x|×|÷|[-+*/])\\s*'
  '($_number)\$',
);

/// The number words this file reads, and what each is worth.
///
/// Zero to twenty, then the tens to ninety, then a hundred. Enough for the
/// arithmetic someone says out loud ("twenty five minus five", "one hundred
/// divided by four"); `thousand` is deliberately absent, because a phone-sized
/// answer to a number that large is worth more care than a lookup table.
const Map<String, int> _numberWords = <String, int>{
  'zero': 0,
  'one': 1,
  'two': 2,
  'three': 3,
  'four': 4,
  'five': 5,
  'six': 6,
  'seven': 7,
  'eight': 8,
  'nine': 9,
  'ten': 10,
  'eleven': 11,
  'twelve': 12,
  'thirteen': 13,
  'fourteen': 14,
  'fifteen': 15,
  'sixteen': 16,
  'seventeen': 17,
  'eighteen': 18,
  'nineteen': 19,
  'twenty': 20,
  'thirty': 30,
  'forty': 40,
  'fifty': 50,
  'sixty': 60,
  'seventy': 70,
  'eighty': 80,
  'ninety': 90,
  'hundred': 100,
};

/// The number words longest first, so "fourteen" is not read as "four" and a
/// "teen" left over. The `\b` at each end is what keeps "someone" out of it.
final List<String> _numberWordPattern = _numberWords.keys.toList()
  ..sort((String a, String b) => b.length.compareTo(a.length));

/// A run of number words: "six", "twenty five", "one hundred twenty".
final RegExp _numberRun = RegExp(
  '\\b(?:${_numberWordPattern.join('|')})'
  '(?:\\s+(?:${_numberWordPattern.join('|')}))*\\b',
  caseSensitive: false,
);

/// A hyphen closed up between two words: the recognizer's "twenty-five".
final RegExp _numberHyphen = RegExp(r'\b([a-z]+)-([a-z]+)\b');

/// [text] with spoken numbers and operators written as digits and symbols.
///
/// "six times seven" → "6 * 7"; "twenty five minus five" → "25 - 5"; "one
/// hundred divided by four" → "100 / 4". The rest of the sentence — the
/// "what is" in front, the question mark behind — is left exactly as it was,
/// because [nexusMathAnswer] is what decides whether the whole sentence is a
/// sum and [wordsToDigits] must not decide that for it.
///
/// Numbers are read the way English builds them: a tens word adds, a unit after
/// it adds again ("twenty five" is 25), and `hundred` multiplies what came
/// before it ("two hundred five" is 205). The recognizer's hyphenated spelling
/// is read the same way.
String wordsToDigits(String text) {
  var out = text.toLowerCase();
  // A hyphen inside a compound number is a space to this reader. Only two
  // number words are joined — "twenty five - five" is a subtraction, and
  // treating its spaced minus as a hyphen would read 20 - 5 as 30.
  out = out.replaceAllMapped(_numberHyphen, (Match match) {
    final String left = match[1]!;
    final String right = match[2]!;
    if (_numberWords.containsKey(left) && _numberWords.containsKey(right)) {
      return '$left $right';
    }
    return match[0]!;
  });
  // Operators next: "divided by" has to go before a number word can be read
  // out of it, and the longest phrases go first so "multiplied by" is not left
  // as "multiplied *".
  out = out.replaceAll(RegExp(r'\bdivided\s+by\b'), '/');
  out = out.replaceAll(RegExp(r'\bmultiplied\s+by\b'), '*');
  out = out.replaceAll(RegExp(r'\btimes\b'), '*');
  out = out.replaceAll(RegExp(r'\bplus\b'), '+');
  out = out.replaceAll(RegExp(r'\bminus\b'), '-');
  return out.replaceAllMapped(_numberRun, (Match match) {
    final List<String> words = match[0]!.toLowerCase().split(RegExp(r'[\s-]+'));
    int total = 0;
    int current = 0;
    for (final String word in words) {
      final int value = _numberWords[word]!;
      if (value == 100) {
        total += (current == 0 ? 1 : current) * 100;
        current = 0;
      } else {
        current += value;
      }
    }
    return '${total + current}';
  });
}

/// The answer to a plain arithmetic question, said the way the thread says it
/// — "15 * 4 = 60" — or null when [text] is not one.
///
/// Null is the answer for everything this file does not claim: a sentence with
/// words in it, a chain of operations, a sum with a missing side. The caller
/// does the same thing with all of them — hands the turn to the model.
String? nexusMathAnswer(String text) {
  final String said = _normalise(wordsToDigits(text));
  if (said.isEmpty) return null;
  final String body = said.replaceFirst(_questionPrefix, '').trim();
  final RegExpMatch? match = _operation.firstMatch(body);
  if (match == null) return null;
  final String left = match.group(1)!;
  final String operator = match.group(2)!;
  final String right = match.group(3)!;
  final double a = double.parse(left);
  final double b = double.parse(right);

  final bool divides =
      operator == 'divided by' ||
      operator == 'over' ||
      operator == '÷' ||
      operator == '/';
  if (divides && b == 0) {
    // Not a number, and not something a text model should be asked either:
    // it is the one arithmetic question with a true answer that is not a
    // number, so the shell says it rather than leaving a hole.
    return "You can't divide by zero.";
  }

  final double result = switch (operator) {
    'plus' || '+' => a + b,
    'minus' || '-' => a - b,
    'times' || 'multiplied by' || 'x' || '×' || '*' => a * b,
    _ => a / b,
  };
  if (!result.isFinite) return null;
  return '$left ${_symbol(operator)} $right = ${_resultText(result)}';
}

/// [text] as this file reads it: lower-case, no apostrophe (so "what's" is
/// "whats"), no thousands separators, no closing punctuation, single spaces.
String _normalise(String text) {
  var out = text.toLowerCase().trim();
  out = out.replaceAll(RegExp("[’']"), '');
  out = out.replaceAll(RegExp(r'(?<=\d),(?=\d)'), '');
  out = out.replaceAll(RegExp(r'[?!.]+$'), '');
  // "2 + 2 = ?" is a question with the answer left blank; the equals sign is
  // punctuation, not an operand.
  out = out.replaceAll(RegExp(r'=\s*$'), '');
  return out.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// The operator as the echo writes it. One spelling per operation, so "6 times
/// 7" and "6 * 7" answer with the same sentence.
String _symbol(String operator) => switch (operator) {
  'plus' || '+' => '+',
  'minus' || '-' => '-',
  'divided by' || 'over' || '÷' || '/' => '/',
  _ => '*',
};

/// [value] without a pointless ".0", and without the trailing zeroes (or the
/// floating-point dust) that "0.1 + 0.2" would otherwise print.
String _resultText(double value) {
  if (value == value.roundToDouble() && value.abs() < 1e15) {
    return value.toInt().toString();
  }
  final String fixed = value.toStringAsFixed(6);
  return fixed.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
}
