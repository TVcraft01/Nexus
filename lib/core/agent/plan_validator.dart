// The gate between a model's plan and the user's eyes.
//
// Four rules, all enforced before anything is shown or run (see
// `docs/AGENT_CORE.md`):
//
//  1. every tool is registered — an unknown name fails the whole plan, it is
//     never skipped;
//  2. every argument matches its declared type, and a missing required one
//     becomes a question rather than a guessed default;
//  3. no plan is longer than [kMaxPlanSteps] — a longer one is a model looping;
//  4. the tier comes from the registered tool, and a destructive step has to
//     name its device in the words the user reads.
//
// A rejected plan is not an error page: [PlanRejected] carries faults and
// questions, and the session says them in the user's words.
import 'plan.dart';
import 'registry.dart';
import 'risk.dart';
import 'tool.dart';

/// How many steps one plan may have. Eight is already a long list in a chat
/// bubble, and a model that wants a tenth is usually repeating itself.
const int kMaxPlanSteps = 8;

sealed class PlanValidation {
  const PlanValidation({this.notes = const <String>[]});

  /// Planner faults worth logging and reporting, but not worth blocking.
  final List<String> notes;
}

final class PlanAccepted extends PlanValidation {
  const PlanAccepted(this.plan, {super.notes});

  final Plan plan;
}

final class PlanRejected extends PlanValidation {
  const PlanRejected(
    this.faults, {
    this.questions = const <String>[],
    super.notes,
  });

  /// Why nothing in this plan can run, in sentences the user can read.
  final List<String> faults;

  /// What has to be answered first. Several questions and no steps is the
  /// planner offering choices rather than asking for arguments.
  final List<String> questions;
}

class PlanValidator {
  const PlanValidator(this.registry);

  final ToolRegistry registry;

  PlanValidation validate(ProposedPlan proposed) {
    final faults = <String>[];
    final questions = <String>[...proposed.questions];

    if (!proposed.readable) {
      faults.add('I could not read a plan out of what the model wrote.');
    }
    if (proposed.readable &&
        proposed.steps.isEmpty &&
        proposed.questions.isEmpty) {
      faults.add('The plan has no steps.');
    }
    if (proposed.steps.length > kMaxPlanSteps) {
      faults.add(
        'The plan has ${proposed.steps.length} steps; more than '
        '$kMaxPlanSteps is a model going round in circles, so nothing ran.',
      );
    }

    final steps = <PlanStep>[];
    for (final proposedStep in proposed.steps) {
      final step = _step(proposedStep, faults, questions);
      if (step != null) steps.add(step);
    }

    if (faults.isNotEmpty || questions.isNotEmpty) {
      return PlanRejected(
        List<String>.unmodifiable(faults),
        questions: List<String>.unmodifiable(questions),
        notes: proposed.notes,
      );
    }
    return PlanAccepted(
      Plan(goal: proposed.goal, steps: List<PlanStep>.unmodifiable(steps)),
      notes: proposed.notes,
    );
  }

  /// One step, or null when it cannot be run. Every problem it finds is added
  /// to [faults] or [questions] — a rejected plan says everything wrong with
  /// it at once, not one complaint per attempt.
  PlanStep? _step(
    ProposedStep proposed,
    List<String> faults,
    List<String> questions,
  ) {
    final tool = registry.lookup(proposed.tool);
    if (tool == null) {
      faults.add(
        '“${proposed.tool}” is not a tool I have, so nothing in this plan ran.',
      );
      return null;
    }

    var sound = true;
    final missing = <String>[];
    for (final entry in tool.args.entries) {
      final Object? value = proposed.args[entry.key];
      if (value == null) {
        if (entry.value.required) missing.add(entry.key);
        continue;
      }
      final String? fault = _typeFault(entry.value.type, value);
      if (fault != null) {
        faults.add('${tool.name}: “${entry.key}” $fault.');
        sound = false;
      }
    }
    if (missing.isNotEmpty) {
      // One question per step, not one per argument: the user should not have
      // to answer the same step three times because three values were absent.
      questions.add(_questionFor(tool, missing));
    }
    for (final key in proposed.args.keys) {
      if (!tool.args.containsKey(key)) {
        faults.add('${tool.name} has no argument called “$key”.');
        sound = false;
      }
    }
    if (proposed.description.trim().isEmpty) {
      faults.add('${tool.name}: the step has no plain-words description.');
      sound = false;
    }
    if (tool.risk == RiskTier.destructive) {
      final String? device = tool.deviceName(proposed.args);
      if (device == null) {
        faults.add(
          '${tool.name} loses data or access, and the step names no device — '
          'a destructive step has to say which device it is about.',
        );
        sound = false;
      } else if (!proposed.description.toLowerCase().contains(
        device.toLowerCase(),
      )) {
        faults.add(
          'A destructive step has to name the device ($device) in the words '
          'the user reads: “${proposed.description}”.',
        );
        sound = false;
      }
    }
    if (!sound) return null;

    return PlanStep(
      tool: tool.name,
      args: Map<String, Object?>.unmodifiable(proposed.args),
      description: proposed.description.trim(),
      // Read off the registered tool. There is no other source for this.
      risk: tool.risk,
      rollback: tool.rollback(proposed.args),
    );
  }

  static String _questionFor(Tool tool, List<String> args) {
    final named = args
        .map((arg) => '“${arg.replaceAll('_', ' ')}”')
        .join(' and ');
    return 'What should ${tool.name} use for $named?';
  }

  static String? _typeFault(ArgType type, Object? value) => switch (type) {
    ArgType.text =>
      value is String && value.trim().isNotEmpty ? null : 'has to be some text',
    ArgType.flag => value is bool ? null : 'has to be true or false',
    ArgType.whole => value is int ? null : 'has to be a whole number',
  };
}

/// Whether [validation] counts as a usable answer from the planner.
///
/// Item 3b's target is "a plan the validator accepts, or one clear question".
/// A rejection whose only problem is something the plan has to ask about is a
/// good answer — counting it as a failure would push the planner toward
/// guessing an argument, which is the one thing that must never happen.
bool isAnswerable(PlanValidation validation) {
  if (validation is PlanAccepted) return true;
  final rejected = validation as PlanRejected;
  return rejected.faults.isEmpty && rejected.questions.isNotEmpty;
}
