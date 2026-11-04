// A plan is data.
//
// Two shapes, on purpose. [ProposedPlan] is what came out of the model: tool
// names as strings, arguments as decoded JSON, no tiers. [Plan] is what the
// validator produced from it: every tool resolved against the registry, every
// argument checked, every tier read off the tool, every rollback closure
// captured. Only a [Plan] can reach the executor, so "the model wrote the risk"
// is not a rule anyone has to remember — there is no field for it.
import 'risk.dart';
import 'rollback.dart';

/// One step as the model wrote it. Untrusted in every field.
class ProposedStep {
  const ProposedStep({
    required this.tool,
    this.args = const <String, Object?>{},
    required this.description,
  });

  final String tool;
  final Map<String, Object?> args;
  final String description;
}

/// A whole plan as the model wrote it. [readable] is false when no JSON plan
/// could be read at all, which is a different failure from a plan that says
/// nothing, and is reported as itself.
class ProposedPlan {
  const ProposedPlan({
    required this.goal,
    this.steps = const <ProposedStep>[],
    this.questions = const <String>[],
    this.notes = const <String>[],
    this.readable = true,
  });

  final String goal;
  final List<ProposedStep> steps;

  /// What it must ask before it can plan — or, when there are several and no
  /// steps, the choices it is offering.
  final List<String> questions;

  /// Planner faults worth saying out loud but not worth blocking a plan over
  /// (the model wrote a risk tier, for one). Logged, ignored, reported.
  final List<String> notes;

  final bool readable;
}

/// One validated step: a registered tool, checked arguments, the tier that
/// tool already had, and the closure that puts it back.
class PlanStep {
  const PlanStep({
    required this.tool,
    required this.args,
    required this.description,
    required this.risk,
    this.rollback,
  });

  final String tool;
  final Map<String, Object?> args;
  final String description;
  final RiskTier risk;
  final Future<RollbackResult> Function()? rollback;
}

class Plan {
  const Plan({
    required this.goal,
    required this.steps,
    this.questions = const <String>[],
  });

  final String goal;
  final List<PlanStep> steps;
  final List<String> questions;
}
