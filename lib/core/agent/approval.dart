// Who said yes, to what, in whose words.
//
// The approval object is the thing that makes "the user agreed" checkable
// rather than remembered. It names the exact steps it covers, so "yes" to step
// one is never "yes" to step three, and the executor asks `covers(step)` before
// every change — a plan that grew a step after the question cannot run it.
import 'plan.dart';
import 'risk.dart';

/// Thrown by the executor when a step that needs approval was not covered by
/// the one it was given. Nothing in the plan ran.
class TierNotApproved implements Exception {
  const TierNotApproved(this.step);

  final PlanStep step;

  @override
  String toString() =>
      'TierNotApproved(${step.tool}, ${step.risk.name}, '
      '${step.description})';
}

class Approval {
  const Approval._({
    required this.granted,
    required this.steps,
    required this.words,
    required this.at,
  });

  /// The user said yes to [plan]'s steps, in [words].
  ///
  /// [words] is empty for the approval a plan of pure reads runs under: nobody
  /// was asked, because nothing changed.
  Approval.granted({required Plan plan, required String words, DateTime? at})
    : this._(
        granted: true,
        steps: List<PlanStep>.unmodifiable(plan.steps),
        words: words.trim(),
        at: at ?? DateTime.now(),
      );

  /// No plan-level approval at all, because nobody was shown the plan — a
  /// background run. Nothing is covered: its steps are gated one by one.
  Approval.none({required Plan plan, DateTime? at})
    : this._(
        granted: false,
        steps: const <PlanStep>[],
        words: '',
        at: at ?? DateTime.now(),
      );

  /// The user said no. Nothing is granted, and nothing runs.
  Approval.denied({required Plan plan, required String words, DateTime? at})
    : this._(
        granted: false,
        steps: const <PlanStep>[],
        words: words.trim(),
        at: at ?? DateTime.now(),
      );

  final bool granted;

  /// The steps that were shown and granted.
  final List<PlanStep> steps;

  /// What the user actually typed.
  final String words;

  final DateTime at;

  /// Whether [step] may run under this approval.
  bool covers(PlanStep step) => granted && steps.contains(step);
}

/// The question the user answers before a plan runs: every step, in order,
/// with its tier and what that tier means.
///
/// One question for the whole plan, not one per step: a person deciding whether
/// Nexus may set up their Wi-Fi wants the list in front of them, and every line
/// says what it will cost them.
String askApproval(Plan plan) {
  final lines = <String>[
    for (final (index, step) in plan.steps.indexed)
      '${index + 1}. ${_plain(step.description)} — '
          '${step.risk.label}: ${step.risk.promise}.',
  ];
  return '${lines.join('\n')}\n\nWant me to do it?';
}

String _plain(String text) => text.trim().replaceFirst(RegExp(r'[.]+$'), '');
