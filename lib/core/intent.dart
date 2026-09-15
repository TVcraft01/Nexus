// The intent layer — one owner of "how a person's sentence means a
// capability".
//
// The interpreter's catalogue is exact: 430 hand-listed phrases and 116
// patterns, and until this file anything outside them was simply
// "I don't understand". A read-only audit drove the brief's own example
// phrasings through the real interpreter and found three different failures,
// which is why this layer exists and why it has two kinds of rule:
//
//   * understood as the WRONG thing — "what's happening on my calendar?" and
//     "what is the forecast" matched the generic `what is X` memory fallback
//     and became memory lookups that end in a web search. A misparse is worse
//     than a miss: the user gets a confident, wrong answer.
//   * understood by NOBODY — "check my calendar", "help me out", "what can
//     nexus do", "what have you learned about me" fell to the teach loop even
//     though Nexus has the capability. A miss costs the user a lesson they
//     should not have needed.
//   * understood but IMPOSSIBLE — "generate an image of a cat" is a request
//     Nexus comprehends completely and cannot do. Reporting it as "I don't
//     understand" is a different, less honest sentence: it says the fault is
//     the user's phrasing when the fault is a missing capability.
//
// The registry ([kCapabilities]) stays the vocabulary: every rule below names
// an [AgentActions] constant, so a renamed action breaks the build instead of
// silently orphaning a rule, and `test/intent_test.dart` asserts every matched
// rule's id is a declared capability with a verified example.
//
// Two deliberate limits, both of which this file keeps rather than hides:
//  - the "can't do it" rules explain themselves in the user's terms and then
//    stop. They never substitute a lookalike action (no fake web search for an
//    image request).
//  - one ambiguity is modelled, not a general tie-breaker. "how is my day
//    looking" genuinely means either the schedule or the weather, and the
//    honest move is one question, not a guess. Anything wider is speculative
//    machinery with no phrasing to justify it yet.
import 'agent_contract.dart';

/// One phrase family that means [capability].
///
/// [needs] is a conjunction: every group must be satisfied, and a group is
/// satisfied by any one of its words. Words are matched whole, against the
/// already-normalized text (lowercase, accents stripped, filler and trailing
/// sentence punctuation removed by the interpreter). [forbids] is checked as
/// a plain substring, so a multi-word entry like `schedule a` can disqualify
/// the write-shaped reading of a phrase the read rule would otherwise claim.
class IntentRule {
  /// One of the [AgentActions] id constants.
  final String capability;

  /// Word groups; all must be satisfied, any word satisfies a group.
  final List<Set<String>> needs;

  /// Substrings that disqualify the rule when present.
  final Set<String> forbids;

  /// Builds the command this rule means. Returning null means "this sentence
  /// is not for me after all" — how a rule that recognizes a shape but cannot
  /// honestly read its arguments declines, so the resolver falls through to
  /// the next rule instead of guessing.
  final ParsedCommand? Function(IntentText text)? build;

  const IntentRule(
    this.capability, {
    required this.needs,
    this.forbids = const {},
    this.build,
  });
}

/// A normalized sentence, with the lookups a rule needs. Kept tiny on
/// purpose: every rule below is a keyword question about words the user
/// actually typed, not a grammar.
class IntentText {
  /// The normalized phrase the interpreter already produced.
  final String text;

  /// [text] split on whitespace, in order — order is what lets a multi-word
  /// phrase be matched without matching its words scattered apart.
  final List<String> tokens;

  /// [tokens] as a set, for O(1) single-word membership.
  final Set<String> words;

  IntentText(String text)
    : text = text,
      tokens = text.split(' ').where((w) => w.isNotEmpty).toList(),
      words = text.split(' ').where((w) => w.isNotEmpty).toSet();

  /// True when [word] appears as a whole word.
  bool has(String word) => words.contains(word);

  /// True when any word of [group] appears.
  bool anyOf(Set<String> group) => group.any(words.contains);

  /// True when [phrase] appears as consecutive whole words — what
  /// [IntentRule.forbids] needs for an entry like `new event`.
  bool contains(String phrase) {
    final parts = phrase.split(' ').where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty || parts.length > tokens.length) return false;
    for (var start = 0; start + parts.length <= tokens.length; start++) {
      var hit = true;
      for (var i = 0; i < parts.length; i++) {
        if (tokens[start + i] != parts[i]) {
          hit = false;
          break;
        }
      }
      if (hit) return true;
    }
    return false;
  }

  /// True when every group in [needs] is satisfied.
  bool satisfies(List<Set<String>> needs) => needs.every(anyOf);
}

/// A request Nexus understands and has no capability to perform. The message
/// is the whole point: it names what was understood, says plainly that Nexus
/// cannot do it, and stops — the failure mode this replaces was a lookalike
/// action (a web search) presented as if it answered the request.
class UnsupportedIntent {
  /// What the user is asking for, in their words — the recognition side.
  final List<Set<String>> needs;

  /// Substrings that disqualify it.
  final Set<String> forbids;

  /// The honest sentence shown instead of pretending.
  final String message;

  const UnsupportedIntent({
    required this.needs,
    this.forbids = const {},
    required this.message,
  });
}

/// One side of an ambiguous question: a capability, the words that name it in
/// an answer, and how to build its command when the user picks it.
class AmbiguousChoice {
  /// One of the [AgentActions] id constants.
  final String capability;

  /// Words that select this choice in the user's answer.
  final Set<String> words;

  /// How to say this choice back in the question.
  final String label;

  final ParsedCommand Function(IntentText text) build;

  const AmbiguousChoice({
    required this.capability,
    required this.words,
    required this.label,
    required this.build,
  });
}

/// A phrasing that genuinely means two different things. Modelled per
/// phrasing rather than as a general tie-breaker: a general one would need
/// overlapping keyword rules to exist, and today's rules deliberately do not
/// overlap, so the only honest way to reach the ambiguity state is to say
/// where it really is.
class AmbiguousPhrasing {
  /// The phrasings this was written for, word-boundary matched so one is
  /// recognized inside a longer sentence.
  final List<String> phrases;

  /// The same question asked in words [phrases] cannot enumerate.
  ///
  /// A phrasing list is a sample of how people ask; the shape is what they
  /// mean, and the shape reaches the phrasings the list cannot hold. The list
  /// this replaced held six exact forms, so the contracted ones — "what's my
  /// day looking like" — missed it and the generic `what is X` fallback
  /// answered them as a memory question about the literal phrase "my day
  /// looking like", which then offered to *remember* the user's answer.
  final bool Function(IntentText text)? shape;

  /// Words that answer the question before it is asked: a sentence carrying
  /// one of these names the reading it wants, so it is not a tie. Checked for
  /// both matching paths, because an exact phrasing inside a longer sentence
  /// ("how is my day looking **on my calendar**") must not outrank the word
  /// that decides it.
  final Set<String> decides;

  /// The one question that asks for the missing decision.
  final String question;

  /// The choices, in the order they are offered in [question].
  final List<AmbiguousChoice> choices;

  const AmbiguousPhrasing({
    required this.phrases,
    this.shape,
    this.decides = const {},
    required this.question,
    required this.choices,
  });

  /// Whether [text] is this question.
  bool claims(IntentText text) {
    if (text.anyOf(decides)) return false;
    return (shape?.call(text) ?? false) || phrases.any(text.contains);
  }

  /// The choice the user's [answer] names, or null when the answer names
  /// none of them — the caller re-asks rather than guessing.
  AmbiguousChoice? choiceFor(String answer) {
    final words = IntentText(answer).words;
    for (final choice in choices) {
      if (choice.words.any(words.contains)) return choice;
    }
    return null;
  }
}

/// What the layer concluded.
sealed class IntentResolution {
  const IntentResolution();
}

/// The sentence means [command].
class IntentMatched extends IntentResolution {
  final ParsedCommand command;
  const IntentMatched(this.command);
}

/// The sentence means one of several things; ask [phrasing.question].
class IntentAmbiguous extends IntentResolution {
  final AmbiguousPhrasing phrasing;
  const IntentAmbiguous(this.phrasing);
}

/// The sentence was understood and cannot be done, for the stated reason.
class IntentUnsupported extends IntentResolution {
  final String message;
  const IntentUnsupported(this.message);
}

/// The stages of understanding, in the order the resolver applies them.
///
/// Precedence used to be the shape of [IntentResolver.resolve]'s body: a
/// reader had to infer it from the order of statements, and nothing could
/// check it. It is data now — [kIntentStages] is the single declaration, the
/// resolver walks it, and `test/intent_precedence_test.dart` reads the same
/// list to prove that every rule is reachable and that a sentence two stages
/// could claim goes to the earlier one.
enum IntentStage {
  /// One sentence, two honest readings. Asking is the answer: guessing
  /// between them would be worse than one question.
  ambiguous,

  /// A question about a failure, which must not be answered as a request to
  /// attempt the thing that failed.
  diagnostic,

  /// Understood, and impossible here — said plainly instead of being turned
  /// into a lookalike action.
  unsupported,

  /// Understood, and Nexus can act.
  matched,
}

/// Every stage, in application order.
///
/// A stage missing from this list is a stage whose rules can never run, and a
/// stage listed twice asks the same question twice; the test pins both.
const List<IntentStage> kIntentStages = [
  IntentStage.ambiguous,
  IntentStage.diagnostic,
  IntentStage.unsupported,
  IntentStage.matched,
];

/// The resolver. Pure and stateless: the interpreter owns the normalized
/// text, and this decides only what it means.
class IntentResolver {
  const IntentResolver();

  /// Resolves [normalized] (already normalized by the interpreter) to a
  /// capability, an ambiguity or an unsupported request, or null when this
  /// layer has nothing to say — in which case the interpreter keeps whatever
  /// it would have done before, unchanged.
  ///
  /// The stages are applied in the order [kIntentStages] declares, so the
  /// precedence is one list rather than the shape of this body.
  IntentResolution? resolve(String normalized) {
    final text = IntentText(normalized);
    if (text.words.length < 2) return null;

    for (final stage in kIntentStages) {
      final resolution = _inStage(stage, text);
      if (resolution != null) return resolution;
    }
    return null;
  }

  /// What [stage] makes of [text], or null when it claims nothing.
  ///
  /// The switch is exhaustive on purpose: a stage added to [IntentStage]
  /// without a claim here does not compile, so the vocabulary of
  /// understanding and the order it is applied in cannot drift apart.
  IntentResolution? _inStage(IntentStage stage, IntentText text) =>
      switch (stage) {
        IntentStage.ambiguous => _ambiguity(text),
        // A question about a failure is not a request to attempt the thing
        // that failed: "why can't you generate an image" must diagnose, not
        // be answered by the image rule as though the user had asked for a
        // picture.
        IntentStage.diagnostic => switch (_match(kDiagnosticRules, text)) {
          final command? => IntentMatched(command),
          _ => null,
        },
        IntentStage.unsupported => _unsupported(text),
        IntentStage.matched => switch (_match(kIntentRules, text)) {
          final command? => IntentMatched(command),
          _ => null,
        },
      };

  IntentResolution? _ambiguity(IntentText text) {
    for (final ambiguous in kAmbiguousPhrasings) {
      if (ambiguous.claims(text)) return IntentAmbiguous(ambiguous);
    }
    return null;
  }

  IntentResolution? _unsupported(IntentText text) {
    for (final unsupported in kUnsupportedIntents) {
      if (!text.satisfies(unsupported.needs)) continue;
      if (unsupported.forbids.any(text.contains)) continue;
      return IntentUnsupported(unsupported.message);
    }
    return null;
  }

  /// The first rule in [rules] that claims [text], or null when none does.
  ///
  /// A rule may match its words and still decline: matching is a keyword
  /// question, and a rule whose arguments are not readable in this sentence
  /// is not really its own, so the next rule gets its turn.
  ParsedCommand? _match(List<IntentRule> rules, IntentText text) {
    for (final rule in rules) {
      if (!text.satisfies(rule.needs)) continue;
      if (rule.forbids.any(text.contains)) continue;
      final command = rule.build?.call(text);
      if (command != null) return command;
    }
    return null;
  }
}

// ---------------------------------------------------------------------------
// Argument extraction — the layer's own helper
// ---------------------------------------------------------------------------

/// The readers that turn a sentence's words into the arguments a capability
/// takes. They are part of the paraphrase layer, not a third matcher beside
/// it: every rule above builds its command with one of these, and the exact
/// catalogue reuses [cleanWeatherPlace] instead of keeping a second copy of
/// the same stoplist — the defect that prompted it (a weather question about
/// a city called "the morning") was the catalogue's own.
abstract final class IntentArgs {
  /// Weekday names and the week horizon they stand for, shared with the
  /// bounded follow-up context.
  static const Set<String> weekdayWords = {
    'week',
    'weekend',
    'monday',
    'tuesday',
    'wednesday',
    'thursday',
    'friday',
    'saturday',
    'sunday',
    'lundi',
    'mardi',
    'mercredi',
    'jeudi',
    'vendredi',
    'samedi',
    'dimanche',
  };

  /// Words that follow a place preposition without being one ("in the
  /// morning", "in two hours") — a weather question must not report them as a
  /// city.
  static const Set<String> _nonPlaceTail = {
    'the morning',
    'the afternoon',
    'the evening',
    'the night',
    'the week',
    'the weekend',
    'an hour',
    'a bit',
  };

  /// The calendar horizon the question asks about. The native side already
  /// understands exactly these three, so a phrase is mapped onto them rather
  /// than inventing a fourth: a named weekday is inside the week horizon.
  static String calendarWhen(IntentText text) {
    if (text.has('tomorrow') || text.has('demain')) return 'tomorrow';
    if (weekdayWords.any(text.words.contains) ||
        text.contains('next week') ||
        text.contains('this week')) {
      return 'week';
    }
    return 'today';
  }

  /// [raw] as a place name, or '' when it is really the time phrase the
  /// question carried — a phrase fragment presented as data is the same
  /// defect class as a punctuation mark captured into an argument.
  static String cleanWeatherPlace(String raw) {
    final place = raw.trim();
    if (place.isEmpty) return '';
    if (_nonPlaceTail.contains(place)) return '';
    if (RegExp(r'\d').hasMatch(place)) return '';
    // A place made only of determiners and time nouns is a time, not a place:
    // "what's the weather for this weekend" was captured as a city called
    // "this weekend", and "my day" as one called "my day". One rule for the
    // family, so a phrasing nobody listed — "next week", "these days", "the
    // next day" — is still read as the time it is rather than as somewhere to
    // look up. A real name is never made only of these words, so "new york"
    // stays a place.
    if (place.split(' ').every(_isTimeWord)) return '';
    return place;
  }

  /// Whether [word] only narrows a time — a determiner or a time noun.
  static bool _isTimeWord(String word) =>
      _placeDeterminers.contains(word) || _namesTime(word);

  /// Whether [word] names a unit of time, singular or plural.
  static bool _namesTime(String word) =>
      _timeNouns.contains(word) ||
      (word.endsWith('s') && _timeNouns.contains(word.substring(0, word.length - 1)));

  /// Determiners that turn a time noun into a time rather than a place.
  static const Set<String> _placeDeterminers = {
    'a',
    'all',
    'an',
    'each',
    'every',
    'her',
    'his',
    'its',
    'last',
    'my',
    'next',
    'our',
    'that',
    'the',
    'their',
    'these',
    'this',
    'those',
    'your',
  };

  /// Time nouns that, with a determiner, name a time rather than somewhere.
  static const Set<String> _timeNouns = {
    'day',
    'week',
    'weekend',
    'month',
    'year',
    'morning',
    'afternoon',
    'evening',
    'night',
    'hour',
    'minute',
    'time',
  };

  /// The place a weather question named, or '' when it named none ("is it
  /// going to rain" is about here). Only a trailing `in|at|for <words>`
  /// counts, so a phrase Nexus cannot parse never turns into a bogus city.
  static String weatherPlace(IntentText text) {
    final match = RegExp(
      r'\b(?:in|at|for) ([a-z][a-z\-]+(?: [a-z][a-z\-]+)*)$',
    ).firstMatch(text.text);
    if (match == null) return '';
    return cleanWeatherPlace(match.group(1)!);
  }

  /// Rain and umbrella questions are the same question, and the weather
  /// service already answers it with its own `rain` kind.
  static String weatherKind(IntentText text) =>
      text.anyOf(const {'rain', 'umbrella', 'raining'}) ? 'rain' : 'now';

  /// Words that point at something without naming it.
  ///
  /// Declared once because two layers must agree on what "no value at all"
  /// looks like: the rules here, and the catalogue's send family, which used
  /// to take "send this to my PC" as text to copy and "send this to the TV"
  /// as a contact called "this to the tv". In a typed conversation there is
  /// no selection and no previous message, so the pronoun has no referent.
  static const Set<String> unattachedWords = {
    'this',
    'that',
    'these',
    'those',
    'it',
    'them',
  };

  /// Whether [raw] is a demonstrative and nothing else — a phrase that names
  /// no value, as opposed to a value that happens to be a short word.
  static bool isUnattachedValue(String raw) {
    final words = raw
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty);
    return words.isNotEmpty && words.every(unattachedWords.contains);
  }

  /// The prepositions that introduce the recipient of a send or a copy, and
  /// the device nouns one can name.
  ///
  /// Declared once for the same reason as [unattachedWords]: the copy verb,
  /// the device-targeted send and the bare send all have to agree on what a
  /// recipient looks like, and they are three separate patterns.
  static const Set<String> recipientPrepositions = {'to', 'onto', 'on'};
  static const String deviceNouns =
      'phone|pc|computer|laptop|tablet|tv|television|devices|other devices|others';

  /// The recipient a phrase names at its head, or null when it names nobody:
  /// "to mom" → `mom`, "on my laptop" → `my laptop`, "hello to mom" → null.
  ///
  /// Null also covers the two ways a phrase seems to name someone and does
  /// not: no name after the preposition ("to"), and a name that is only a
  /// demonstrative ("to this", "to them"), which has no referent in a typed
  /// conversation — the same reasoning as [unattachedWords].
  ///
  /// A run of prepositions is consumed whole, because no name and no value is
  /// made of one: "send to to mom" names mom, never a person called
  /// "to mom". The rest of the object is the user's own words — this reads
  /// the recipient, it never rewrites it.
  static String? leadingRecipient(String raw) {
    final words =
        raw.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    var start = 0;
    while (start < words.length &&
        recipientPrepositions.contains(words[start])) {
      start++;
    }
    if (start == 0 || start == words.length) return null;
    final name = words.sublist(start).join(' ');
    return isUnattachedValue(name) ? null : name;
  }

  /// Whether [raw] carries a recipient instead of a value: "to my pc", "to
  /// mom", "this to", "hello on my fridge".
  ///
  /// A preposition is never part of the thing being sent, and no name is made
  /// of one, so such an object is neither a value to send nor a contact to
  /// send it to — reading it as either invents something the sentence never
  /// said. The rule is the class rather than a list of device names, because
  /// "send to mom" invented a person called "to mom" exactly as "send to my
  /// pc" did.
  static bool carriesRecipient(String raw) => raw
      .trim()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .any(recipientPrepositions.contains);

  /// Whether [raw] carries a recipient that names nobody: a preposition with
  /// no name after it ("to"), a name that is only a demonstrative ("to
  /// this"), or a recipient buried in an object that names no value ("this
  /// to", "hello to my fridge"). Such an object is neither a value to send
  /// nor a contact to send it to.
  static bool namesNoRecipient(String raw) =>
      carriesRecipient(raw) && leadingRecipient(raw) == null;
}

// ---------------------------------------------------------------------------
// The rules
// ---------------------------------------------------------------------------

/// Every matched rule, in priority order. Each names an [AgentActions] id.
final List<IntentRule> kIntentRules = [
  // --- Calendar: reading the schedule is a question, and people ask it many
  // ways. The audit showed two of the brief's four phrasings already matched
  // and two were answered as memory questions ("what's happening on my
  // calendar" → a web search for the phrase). A schedule word is enough on
  // its own: the exact catalogue above has already had its chance at app
  // launches ("open my calendar") and event creation.
  IntentRule(
    AgentActions.calendarRead,
    needs: [
      {'calendar', 'schedule', 'agenda', 'diary', 'planner', 'plans'},
      {
        'what',
        'whats',
        'anything',
        'any',
        'check',
        'show',
        'see',
        'view',
        'read',
        'look',
        'clear',
        'busy',
        'free',
        'happening',
        'going',
        'upcoming',
        'today',
        'tomorrow',
        'tonight',
        'next',
        'week',
        'on',
        'my',
        'the',
      },
    ],
    // A phrase that creates an event is not a question about one. The exact
    // catalogue handles "add X to my calendar" before this layer runs; these
    // entries keep the write-shaped readings it does not cover out of the
    // read rule, so the worst case is a miss, never a wrong action.
    forbids: {'add', 'create', 'book', 'put', 'move', 'new event', 'set up'},
    build: (text) => ParsedCommand(
      action: AgentActions.calendarRead,
      target: 'local',
      arguments: {'when': IntentArgs.calendarWhen(text)},
    ),
  ),

  // --- Weather: "what is the forecast" was a memory question about "the
  // forecast" that ended in a web search, and "do i need an umbrella" was
  // unknown. Both are the same question the weather service already answers.
  IntentRule(
    AgentActions.weatherGet,
    needs: [
      {'weather', 'forecast', 'rain', 'raining', 'umbrella', 'snow', 'sunny'},
      {
        'what',
        'whats',
        'will',
        'is',
        'do',
        'need',
        'going',
        'today',
        'tomorrow',
        'tonight',
        'week',
        'the',
        'it',
      },
    ],
    // "google the weather in paris" is a request to search, not a request for
    // the weather service — the user named the tool they want.
    forbids: {'google', 'search', 'look up', 'find'},
    build: (text) => ParsedCommand(
      action: AgentActions.weatherGet,
      target: 'local',
      arguments: {'place': IntentArgs.weatherPlace(text), 'kind': IntentArgs.weatherKind(text)},
    ),
  ),

  // --- Memory recall: "what have you learned about me" and "did you remember
  // what i told you" are the same question as "what do you know about me".
  // Declared before the help rule because its words are far less common: a
  // phrase that could read as either must go to the narrower reading.
  IntentRule(
    AgentActions.memoryRecall,
    needs: [
      {'know', 'learned', 'learnt', 'remember', 'remembered', 'told'},
      {'you', 'your', 'nexus'},
      {'me', 'about', 'i'},
    ],
    // "forget everything i told you" shares this rule's words but means the
    // opposite of a recall, and the catalogue's own forget rule answers it.
    // Declining here is what keeps a deletion request from being read as a
    // request to read everything back.
    forbids: {'forget'},
    build: (text) {
      // "…about <something>" names a topic, and a question about one of the
      // user's own things is a targeted recall — the exact catalogue owns
      // those, so decline and let it answer rather than listing everything.
      final topic = RegExp(r'\babout (?!me\b|us\b)\w').firstMatch(text.text);
      if (topic != null) return null;
      return const ParsedCommand(
        action: AgentActions.memoryRecall,
        target: 'local',
      );
    },
  ),

  // --- Help: the exact catalogue knows "help", "what can you do" and "what
  // are you able to do"; these are the same question phrased around them.
  IntentRule(
    AgentActions.helpGet,
    needs: [
      {'help', 'nexus', 'capabilities'},
      {'me', 'out', 'what', 'whats', 'can', 'could', 'able', 'capabilities'},
    ],
    build: (text) {
      // "help me <something>" is a request to do that something, not a
      // request to hear the catalogue — decline and let the phrase be
      // unknown or taught, rather than answering a different question.
      final ask = RegExp(r'\bhelp me (\w+)').firstMatch(text.text);
      if (ask != null &&
          !const {'out', 'please', 'here', 'learn'}.contains(ask.group(1))) {
        return null;
      }
      return const ParsedCommand(action: AgentActions.helpGet, target: 'local');
    },
  ),

  // --- Devices: the registry answer, not a search. "what devices do i have"
  // and "which devices are paired" are the same list as "show my devices".
  IntentRule(
    AgentActions.deviceList,
    // Plural only: the singular noun means "the device I am speaking from",
    // which is the exact catalogue's own class ("find my device"), answered
    // shortly after this layer. Claiming it here would turn a question about
    // one device into an inventory.
    needs: [
      {'devices'},
      {
        'what',
        'whats',
        'which',
        'list',
        'show',
        'see',
        'any',
        'all',
        'my',
        'paired',
        'connected',
        'have',
      },
    ],
    // Locating one device is a different question, and the catalogue's own
    // rules (above and below this layer) answer it. Declining here keeps a
    // singular "find my device" out of the plural list answer.
    // "…to my devices" is the clipboard broadcast ("copy hello to my
    // devices"), which the catalogue claims after this layer — declining
    // keeps it from being answered as an inventory.
    forbids: {
      'find',
      'where',
      'locate',
      'ring',
      'pair',
      'unpair',
      'forget',
      'copy',
      'paste',
      'send',
      'share',
      'sync',
      'clipboard',
    },
    // "what devices can you use" and "what can my devices do" are the same
    // registry lookup as "show my devices" and a different answer: not which
    // devices exist, but what each of them can actually do. The detail rides
    // on the command so the catalogue answers the question that was asked.
    build: (text) => ParsedCommand(
      action: AgentActions.deviceList,
      target: 'local',
      arguments: asksWhatDevicesCanDo(text)
          ? const {'detail': 'capabilities'}
          : const {},
    ),
  ),
];

/// Whether a device question is asking what the devices can *do*, rather than
/// which ones exist. One predicate for the whole class — "what devices can you
/// use", "what can my devices do", "which devices are able to play music" —
/// because they are one question phrased around the verb.
bool asksWhatDevicesCanDo(IntentText text) =>
    text.has('use') ||
    text.contains('able to') ||
    (text.has('can') && (text.has('do') || text.has('does')));

/// Questions about what Nexus just failed to do, answered from the failure it
/// recorded rather than from a guess about it.
///
/// Separate from [kIntentRules] because the resolver reads them *before* the
/// unsupported intents: "why can't you generate an image" names an image and
/// would otherwise be answered as a request for one.
final List<IntentRule> kDiagnosticRules = [
  // "why did you do that" / "what did you just do" — a question about the last
  // thing Nexus actually did, answered from the record it made while doing it.
  // Its words are narrow on purpose: "why do you *know* that" is a different
  // question (memory provenance, answered by the catalogue), and a rule that
  // claimed it here would replace a real answer about memory with a report
  // about actions.
  IntentRule(
    AgentActions.helpGet,
    needs: [
      {'why', 'what'},
      {'did', 'do', 'done'},
      {'you', 'that', 'this', 'it'},
    ],
    forbids: {
      'know',
      'knows',
      'knew',
      'remember',
      'remembered',
      'learn',
      'learned',
      'heard',
      'say',
      'said',
      'tell',
      'told',
      'talk',
      'chat',
      'infer',
    },
    build: (text) {
      // Only the shapes that really name an action. Anything else declines and
      // keeps whatever the catalogue would have answered — this rule must
      // never turn an unrelated question into a report of something Nexus did.
      final shape = RegExp(
        r'^(?:why|what) (?:did|do) you (?:just )?(?:do|done|did)\b',
      );
      if (!shape.hasMatch(text.text)) return null;
      return const ParsedCommand(
        action: AgentActions.helpGet,
        target: 'local',
        arguments: {'topic': 'actions'},
      );
    },
  ),

  IntentRule(
    AgentActions.helpGet,
    needs: [
      {'why', 'how'},
      {
        'cant',
        "can't",
        'cannot',
        'unable',
        'fail',
        'failed',
        'fails',
        'didnt',
        "didn't",
        'not',
      },
      {
        'you',
        'nexus',
        'it',
        'this',
        'that',
        'do',
        'does',
        'work',
        'working',
        'happen',
      },
    ],
    // "how come" is the one multi-word opener worth claiming; "how" alone is
    // left to the catalogue, which reads "how are you" as a greeting.
    build: (text) {
      if (text.has('how') && !text.contains('how come')) return null;
      return const ParsedCommand(
        action: AgentActions.helpGet,
        target: 'local',
        arguments: {'topic': 'why'},
      );
    },
  ),
];

/// Requests Nexus understands and genuinely cannot perform. Each one says so
/// in the user's terms and offers the nearest real thing instead of a
/// lookalike — the brief's rule is that no suggestion may stand in for a
/// capability that does not exist.
const List<UnsupportedIntent> kUnsupportedIntents = [
  UnsupportedIntent(
    // "generate an image of a cat", "make me a picture of a cat", "draw …".
    needs: [
      {
        'image',
        'picture',
        'photo',
        'drawing',
        'artwork',
        'illustration',
        'logo',
        'draw',
        'sketch',
        'paint',
      },
      {'generate', 'create', 'make', 'draw', 'sketch', 'paint', 'design', 'render', 'produce', 'of'},
    ],
    message:
        'I understand — you want an image made. Nexus cannot generate images: '
        'there is no image model here or on any paired device, so I will not '
        'pretend to try. I can open a search for one, or show you what Nexus '
        'can really do.',
  ),
  UnsupportedIntent(
    // "use my strongest computer", "which device is fastest" — the resource
    // map that would answer this does not exist yet, so saying "I don't
    // understand" would hide a missing capability behind the user's phrasing.
    needs: [
      {'strongest', 'fastest', 'powerful', 'powerfull', 'beefiest', 'best'},
      {'computer', 'device', 'pc', 'laptop', 'machine', 'node', 'server'},
    ],
    // The resource map exists as data and interfaces, but nothing routes work
    // through it on its own, so the honest sentence is about the missing
    // ranking rather than about a missing subsystem: the previous wording
    // told the user a component was unbuilt that is in fact on disk.
    message:
        'I can list the devices you have paired, but I do not rank them by '
        'power yet — nothing picks a device for a task on its own. Ask me '
        '"show my devices" and name the one you want.',
  ),
];

/// The words that pick one reading of "my day" for the user. A sentence that
/// names one is not a tie, and the rules that own those words answer it.
const Set<String> _dayReadings = {
  'calendar',
  'schedule',
  'agenda',
  'planner',
  'diary',
  'meetings',
  'appointments',
  'weather',
  'forecast',
  'rain',
  'umbrella',
  'sunny',
  'snow',
  'temperature',
};

/// The words a question about the day *opens* with. Position is what decides:
/// the same word inside a statement is a statement, and "my day was awful"
/// must reach the conversation rather than this question. Every phrasing the
/// list above holds opens with one of these.
const Set<String> _dayOpeners = {'how', 'what', 'whats', 'when', 'is', 'was'};

/// Whether the sentence asks how the user's *day* is going — the one question
/// that honestly means either the schedule or the weather.
///
/// A shape rather than a list of phrasings, and one predicate for the whole
/// family so a contraction cannot slip past it: `normalizePhrase` turns
/// "what's" into "what is", which is how "what's my day looking like" reached
/// the `what is X` fallback while the uncontracted "how is my day looking"
/// reached this question. "my day" is the subject and nothing here names a
/// reading or writes anything, so the honest answer is one question.
bool asksHowMyDayGoes(IntentText text) {
  if (text.tokens.isEmpty) return false;
  if (!_dayOpeners.contains(text.tokens.first)) return false;
  return text.contains('my day');
}

/// The one phrasing family that really means two things. Asking is the honest
/// answer here: the user said "my day", and picking the calendar or the
/// weather for them would be a guess dressed as understanding.
final List<AmbiguousPhrasing> kAmbiguousPhrasings = [
  AmbiguousPhrasing(
    phrases: [
      'how is my day looking',
      'how does my day look',
      'what does my day look like',
      'what is my day like',
      'how is my day',
      'how is my day going',
    ],
    shape: asksHowMyDayGoes,
    decides: _dayReadings,
    question: 'Your schedule, or the weather?',
    choices: [
      AmbiguousChoice(
        capability: AgentActions.calendarRead,
        words: {'schedule', 'calendar', 'agenda', 'plans', 'meetings', 'diary'},
        label: 'schedule',
        build: (text) => ParsedCommand(
          action: AgentActions.calendarRead,
          target: 'local',
          arguments: {'when': IntentArgs.calendarWhen(text)},
        ),
      ),
      AmbiguousChoice(
        capability: AgentActions.weatherGet,
        words: {'weather', 'forecast', 'rain', 'umbrella', 'temperature'},
        label: 'weather',
        build: (text) => ParsedCommand(
          action: AgentActions.weatherGet,
          target: 'local',
          arguments: {'place': IntentArgs.weatherPlace(text), 'kind': IntentArgs.weatherKind(text)},
        ),
      ),
    ],
  ),
];

// ---------------------------------------------------------------------------
// Follow-ups: the explicit, bounded context mechanism
// ---------------------------------------------------------------------------

/// A thing the user can add to the previous request instead of repeating it.
///
/// This is the whole conversational-context mechanism: an intent opts in by
/// declaring that it accepts [key], and a follow-up only fires when the
/// immediately preceding matched intent declared the same key. There is no
/// general "what did they mean by it" guessing, because that would need the
/// assistant to invent an antecedent it cannot verify — the audit's rule is
/// that a state with no real signal is not shown, and the same holds for an
/// answer with no real antecedent.
class FollowUp {
  /// The argument key this follow-up fills, e.g. `when`.
  final String key;

  /// The intent that must have just run for the follow-up to apply.
  final String capability;

  /// Words that, alone, mean "the same request with a new [key]".
  final Set<String> cueWords;

  /// Reads the new value out of the follow-up, or null when it does not
  /// carry one (then the phrase stays a normal unknown).
  final Object? Function(IntentText text) read;

  const FollowUp({
    required this.key,
    required this.capability,
    required this.cueWords,
    required this.read,
  });
}

/// A follow-up question that only carries a value ("what about saturday?").
const Set<String> _followUpLead = {
  'what',
  'whats',
  'and',
  'now',
  'how',
  'ok',
  'okay',
  'then',
  'about',
  'next',
  'this',
};

/// True when the phrase is a follow-up in shape: it leads with a cue and
/// carries no request of its own — a bare value, never a new sentence.
bool looksLikeFollowUp(IntentText text) {
  if (text.words.isEmpty) return false;
  if (!_followUpLead.contains(text.words.first)) return false;
  return text.words.length <= 6;
}

/// The follow-ups this pass supports, each backed by an argument the
/// capability genuinely reads. Only two intents qualify today, and that is
/// the honest count: a follow-up for an argument that is not read would be
/// pretending to have understood.
final List<FollowUp> kFollowUps = [
  FollowUp(
    key: 'when',
    capability: AgentActions.calendarRead,
    cueWords: {...IntentArgs.weekdayWords, 'today', 'tonight', 'tomorrow', 'demain'},
    read: IntentArgs.calendarWhen,
  ),
  FollowUp(
    key: 'mode',
    capability: AgentActions.volumeSet,
    cueWords: {'louder', 'quieter', 'softer'},
    read: (text) {
      if (text.anyOf(const {'louder', 'up'})) return 'up';
      if (text.anyOf(const {'quieter', 'softer', 'down'})) return 'down';
      return null;
    },
  ),
];

/// Resolves [normalized] against the intent that just ran. Returns the command
/// the follow-up means, or null when the phrase is not a follow-up of
/// [previousCapability] — in which case the caller keeps its normal handling.
ParsedCommand? resolveFollowUp(
  String normalized,
  String? previousCapability,
) {
  if (previousCapability == null) return null;
  final text = IntentText(normalized);
  if (!looksLikeFollowUp(text)) return null;
  for (final followUp in kFollowUps) {
    if (followUp.capability != previousCapability) continue;
    if (!followUp.cueWords.any(text.words.contains)) continue;
    final value = followUp.read(text);
    if (value == null) continue;
    return ParsedCommand(
      action: followUp.capability,
      target: 'local',
      arguments: {followUp.key: value},
    );
  }
  return null;
}
