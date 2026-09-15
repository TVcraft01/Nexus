// How a sentence is understood has two levels of precedence, and this file
// holds both to behaviour:
//
//  * the rank of the layers (kInterpretLayers): the exact catalogue outranks
//    the paraphrase layer, which outranks the generic fallbacks;
//  * the order of the paraphrase layer's own stages (kIntentStages), each of
//    which is a different finding about the same sentence.
//
// The rules of each stage are read from the same lists the resolver reads, so a
// new rule is covered without editing this file — and a rule no sentence can
// reach, or one that changes a phrase the catalogue owns, fails here instead of
// shipping.
import 'package:flutter_test/flutter_test.dart';

import 'package:nexus/core/agent_contract.dart';
import 'package:nexus/core/capability.dart';
import 'package:nexus/core/command_interpreter.dart';
import 'package:nexus/core/intent.dart';

/// One claim a stage makes about a sentence: the word groups that must all
/// appear, the phrases that disqualify it, and what the layer says it means.
class _Claim {
  final IntentStage stage;

  /// How a failure names this rule to whoever has to fix it.
  final String label;

  final List<Set<String>> needs;
  final Set<String> forbids;

  /// The literal phrase, for a claim that is one (an ambiguity) — word groups
  /// alone would accept the phrase's words in any order.
  final String? phrase;

  /// The capability the stage says this sentence resolves to, or null for a
  /// stage whose answer is not an action ([IntentStage.ambiguous] and
  /// [IntentStage.unsupported]).
  final String? action;

  /// Present when the rule can still decline a sentence whose words it
  /// matches, so a sentence the rule itself refuses is not its sentence.
  final ParsedCommand? Function(IntentText text)? build;

  /// The claim's own predicate, for a class that holds one. An ambiguity
  /// declares which words answer it before it is asked, so the mirror asks the
  /// class instead of restating those words here and drifting apart from them.
  final bool Function(IntentText text)? declares;

  const _Claim(
    this.stage,
    this.label, {
    required this.needs,
    this.forbids = const {},
    this.phrase,
    this.action,
    this.build,
    this.declares,
  });
}

/// The rules of [stage], read from the same lists the resolver reads.
///
/// The switch is exhaustive on [IntentStage]: a new stage does not compile
/// until it is described here, so this cannot silently lose a stage the way a
/// hand-copied list could. Every rule of an existing stage is read from its
/// list, so a new rule is covered without editing this mirror.
List<_Claim> _claimsIn(IntentStage stage) => switch (stage) {
  IntentStage.ambiguous => [
    for (final ambiguity in kAmbiguousPhrasings)
      for (final phrase in ambiguity.phrases)
        _Claim(
          stage,
          'ambiguous: "$phrase"',
          needs: [
            for (final word in phrase.split(' ')) {word},
          ],
          phrase: phrase,
          declares: ambiguity.claims,
        ),
  ],
  IntentStage.diagnostic => [
    for (var i = 0; i < kDiagnosticRules.length; i++)
      _Claim(
        stage,
        'diagnostic #$i (${kDiagnosticRules[i].capability})',
        needs: kDiagnosticRules[i].needs,
        forbids: kDiagnosticRules[i].forbids,
        action: kDiagnosticRules[i].capability,
        build: kDiagnosticRules[i].build,
      ),
  ],
  IntentStage.unsupported => [
    for (var i = 0; i < kUnsupportedIntents.length; i++)
      _Claim(
        stage,
        'unsupported #$i',
        needs: kUnsupportedIntents[i].needs,
        forbids: kUnsupportedIntents[i].forbids,
      ),
  ],
  IntentStage.matched => [
    for (var i = 0; i < kIntentRules.length; i++)
      _Claim(
        stage,
        'matched #$i (${kIntentRules[i].capability})',
        needs: kIntentRules[i].needs,
        forbids: kIntentRules[i].forbids,
        action: kIntentRules[i].capability,
        build: kIntentRules[i].build,
      ),
  ],
};

/// Whether [claim] still claims [text] — the same question the resolver asks
/// its own rules.
bool _claims(_Claim claim, IntentText text) {
  if (claim.declares != null && !claim.declares!(text)) return false;
  if (claim.phrase != null && !text.contains(claim.phrase!)) return false;
  if (!text.satisfies(claim.needs)) return false;
  if (claim.forbids.any(text.contains)) return false;
  if (claim.build != null && claim.build!(text) == null) return false;
  return true;
}

/// Whether [result] is the answer [claim]'s stage declares for it.
bool _answers(_Claim claim, InterpretResult result) => switch (claim.stage) {
  IntentStage.ambiguous => result.outcome == InterpretOutcome.ambiguous,
  IntentStage.unsupported => result.outcome == InterpretOutcome.unsupported,
  IntentStage.diagnostic ||
  IntentStage.matched =>
    result.outcome == InterpretOutcome.matched &&
        result.command?.action == claim.action,
};

/// The sentence [claim] describes, built from its own words in group order.
String _sentenceFor(_Claim claim) =>
    {for (final group in claim.needs) group.first}.join(' ');

/// The interpreter's own normalization, because a sentence normalization
/// rewrites is not the rule's sentence: "nexus out" loses its wake word and
/// arrives as the single word "out".
IntentText _asTheLayerSees(String sentence) =>
    IntentText(CommandInterpreter.normalizePhrase(sentence));

/// Why [claim] is not reached, or null when it is.
///
/// This is the guard the brief asks for: a rule that a reader can write but
/// nobody can use — because an earlier stage, an earlier rule in the same
/// stage, or the exact catalogue answers its sentence differently — comes back
/// here as a sentence to explain.
String? _unreached(_Claim claim) {
  final sentence = _sentenceFor(claim);
  final seen = _asTheLayerSees(sentence);
  if (!_claims(claim, seen)) return null; // not this rule's sentence
  final result = const CommandInterpreter().interpret(sentence);
  if (_answers(claim, result)) return null;
  final got = result.command?.action ?? result.outcome.name;
  return '${claim.label} claims "$sentence" but got "$got"';
}

/// Every claim of every stage that a user cannot actually reach.
List<String> _unreachedClaims() => [
  for (final stage in kIntentStages)
    for (final claim in _claimsIn(stage)) ?_unreached(claim),
];

void main() {
  group('the stage order is declared, complete, and applied', () {
    test('every stage is declared exactly once', () {
      expect(
        kIntentStages.toSet(),
        IntentStage.values.toSet(),
        reason:
            'kIntentStages must name every stage: a stage missing from it can '
            'never run, and a duplicate asks the same rules twice.',
      );
      expect(kIntentStages.length, IntentStage.values.length);
    });

    test('every rule is reached, and answered as its stage declares', () {
      final claims = [
        for (final stage in kIntentStages) ..._claimsIn(stage),
      ];
      expect(
        claims.length,
        greaterThanOrEqualTo(9),
        reason: 'the check must cover the layer\'s rules, not an empty list',
      );
      expect(
        _unreachedClaims(),
        isEmpty,
        reason:
            'a rule listed here is one no sentence can reach: an earlier '
            'stage, an earlier rule in the same stage, or the exact catalogue '
            'answers its sentence instead.',
      );
    });

    test('a sentence two stages can claim is answered by the earlier one', () {
      final violations = <String>[];
      var exercised = 0;
      for (final earlier in kIntentStages) {
        for (final later in kIntentStages) {
          if (earlier.index >= later.index) continue;
          for (final a in _claimsIn(earlier)) {
            for (final b in _claimsIn(later)) {
              final sentence = {...a.needs.map((g) => g.first), ...b.needs.map((g) => g.first)}
                  .join(' ');
              final seen = _asTheLayerSees(sentence);
              if (!_claims(a, seen) || !_claims(b, seen)) continue;
              exercised++;
              final resolution = const IntentResolver().resolve(seen.text);
              final answers = switch (earlier) {
                IntentStage.ambiguous => resolution is IntentAmbiguous,
                IntentStage.unsupported => resolution is IntentUnsupported,
                IntentStage.diagnostic ||
                IntentStage.matched =>
                  resolution is IntentMatched &&
                      resolution.command.action == a.action,
              };
              if (!answers) {
                violations.add(
                  '${earlier.name} + ${later.name}: "$sentence" was answered by '
                  '${resolution.runtimeType} instead of ${earlier.name}',
                );
              }
            }
          }
        }
      }
      expect(
        exercised,
        greaterThan(0),
        reason: 'no two stages could both claim a sentence, so the order of '
            'kIntentStages was not exercised at all',
      );
      expect(violations, isEmpty);
    });

    test('the check would notice a rule that is stolen', () {
      // A deliberately wrong claim: the catalogue answers "what time is it",
      // so a stage claiming the same words for devices must be reported.
      const stolen = _Claim(
        IntentStage.matched,
        'a rule that cannot be reached',
        needs: [
          {'time'},
          {'is'},
        ],
        action: AgentActions.deviceList,
      );
      expect(_unreached(stolen), isNotNull);
    });
  });

  group('the exact catalogue keeps the phrases it already owns', () {
    test('the layers are declared in application order', () {
      expect(kInterpretLayers, [
        InterpretLayer.catalogue,
        InterpretLayer.paraphrase,
        InterpretLayer.fallback,
      ]);
      expect(
        kInterpretLayers.map((layer) => layer.name).toSet().length,
        kInterpretLayers.length,
      );
    });

    test('the catalogue outranks the paraphrase layer', () {
      // Sentences built to satisfy both an ambiguity phrase and a device rule.
      // The catalogue claims them first and its answer stands — the promise
      // the declaration makes. Reordering the interpreter so the layer runs
      // first fails this test, because the layer would ask a question instead.
      for (final sentence in const [
        'what does my day look like devices',
        'what is my day like devices',
      ]) {
        final norm = CommandInterpreter.normalizePhrase(sentence);
        expect(
          const IntentResolver().resolve(norm),
          isA<IntentAmbiguous>(),
          reason: 'the layer reads "$sentence" as its own',
        );
        final result = const CommandInterpreter().interpret(sentence);
        expect(
          result.command?.action,
          AgentActions.deviceList,
          reason: 'the catalogue owns "$sentence" and its answer stands',
        );
      }
    });

    test('the layer is invisible on every phrase the catalogue advertises', () {
      // The phrase corpus is the catalogue's own vocabulary: the suggestions it
      // offers and the examples the capability registry advertises. For these,
      // the paraphrase layer may add nothing and change nothing — it exists for
      // the phrasings the catalogue does not own.
      final phrases = <String>{
        ...CommandInterpreter.suggestionCatalog,
        for (final capability in kCapabilities) ...[
          ?capability.example,
          ...capability.helpPhrases,
        ],
      };
      const withLayer = CommandInterpreter();
      const withoutLayer = CommandInterpreter(paraphrase: false);
      final changed = <String>[];
      for (final phrase in phrases) {
        final on = withLayer.interpret(phrase);
        final off = withoutLayer.interpret(phrase);
        if (on.outcome != off.outcome ||
            on.command?.action != off.command?.action) {
          changed.add(
            '"$phrase": without the layer it is '
            '${off.command?.action ?? off.outcome.name}, with it '
            '${on.command?.action ?? on.outcome.name}',
          );
        }
      }
      expect(
        phrases.length,
        greaterThanOrEqualTo(80),
        reason: 'the corpus must be the advertised vocabulary, not a sample of '
            'phrases chosen because they pass',
      );
      expect(
        changed,
        isEmpty,
        reason: 'a difference here means an intent rule has taken a phrase the '
            'catalogue already answers: either the rule is wrong, or the '
            'catalogue\'s phrase should change. The layer adds understanding to '
            'the phrasings the catalogue does not own, and only there.',
      );
    });

    test('the layer outranks the generic fallback, which is why it is there', () {
      // With the layer off, "whats forecast" is a memory question about the
      // literal phrase "forecast" and then a web search. The layer is between
      // that and the weather the user asked for.
      const withoutLayer = CommandInterpreter(paraphrase: false);
      expect(
        withoutLayer.interpret('whats forecast').command?.action,
        AgentActions.memoryQuestion,
      );
      expect(
        const CommandInterpreter().interpret('whats forecast').command?.action,
        AgentActions.weatherGet,
      );
    });
  });
}
