// The real run path: a stored agent's goal, planned and executed.
//
// This is the thing `AgentService` calls. It is the whole loop from the
// contract, with the background-run rules applied:
//
//   goal → plan (the item 3b planner) → validate → gate every step → execute
//
// Three properties it exists to keep:
//
//   * a run started by a schedule cannot ask, so a step that needs the user's
//     approval is skipped and reported, never run — and never approved by
//     waiting long enough;
//   * the agent's own tool list is a limit, not a suggestion: a plan naming a
//     tool the user did not give it is refused whole, before anything runs;
//   * what comes back is the executor's report, summarised in its own words, so
//     a run that only looked, one that skipped, one that was blocked and one
//     that failed all say exactly that.
import 'agent_records.dart';
import 'agent_service.dart' show AgentOutcome;
import 'approval.dart';
import 'executor.dart';
import 'kill_switch.dart';
import 'plan.dart';
import 'plan_validator.dart';
import 'planner.dart';
import 'run_log.dart';

class PlannedAgentRunner {
  PlannedAgentRunner({
    required this.planner,
    required this.validator,
    required this.executor,
    required this.runLog,
    required this.killSwitch,
    this.timeLimit = const Duration(minutes: 2),
    this.maxSteps = kMaxPlanSteps,
  });

  final Planner planner;
  final PlanValidator validator;
  final Executor executor;
  final RunLog runLog;

  /// The same switch the service halts, so "halt all" reaches a run that is
  /// already walking its steps.
  final KillSwitch killSwitch;

  /// How long one run may take. A model that hangs, or a tool that never
  /// returns, stops the run instead of holding the schedule hostage.
  final Duration timeLimit;

  /// How many steps one background run may have — the validator's cap again,
  /// because the plan arriving here is the model's, not the chat's.
  final int maxSteps;

  /// Runs [agent] and returns the sentence that becomes its last result, plus
  /// whether the run did what it set out to do.
  Future<AgentOutcome> call(AgentDefinition agent) async {
    if (killSwitch.tripped) {
      return const AgentOutcome(
        'not run: all agents are halted until you clear the halt',
        ok: false,
      );
    }

    final PlanValidation validation = validator.validate(
      await planner.propose(goal: agent.goal),
    );
    if (validation is PlanRejected) {
      final String said = <String>[
        ...validation.faults,
        ...validation.questions,
      ].join(' ');
      return AgentOutcome(
        'not run: it could not make a plan for “${agent.goal}”'
        '${said.isEmpty ? '' : '. $said'}',
        ok: false,
      );
    }
    final Plan plan = (validation as PlanAccepted).plan;
    if (plan.steps.isEmpty) {
      return AgentOutcome(
        'not run: the plan for “${agent.goal}” had no steps',
        ok: false,
      );
    }

    final ExecutionReport report = await executor.run(
      plan,
      // A scheduled run has no approval to show anyone: nothing is covered,
      // and every step goes through the gate on its own.
      Approval.none(plan: plan),
      policy: agent.approval,
      unattended: true,
      limits: RunLimits(
        maxSteps: maxSteps,
        timeLimit: timeLimit,
        allowedTools: agent.tools,
      ),
      agent: agent.name,
      runLog: runLog,
    );
    return AgentOutcome(
      report.summary,
      // A run that skipped a step for want of approval, or was blocked, did not
      // do what it set out to do — the dashboards must not colour it green.
      ok: report.status == ExecutionStatus.done && report.skipped.isEmpty,
    );
  }
}
