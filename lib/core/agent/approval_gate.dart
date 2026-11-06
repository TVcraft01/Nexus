// The single choke point between a step and the device.
//
// Every execution path passes [ApprovalGate.check] before a tool runs — the
// typed ask in `agent_session.dart` and the background run in
// `agent_runner.dart` both go through `Executor.run`, which calls this for
// every step. There is nowhere else a tool can be invoked from, so the model
// cannot bypass it: a plan is a proposal, and a proposal is not a permission.
//
// The decision is a product of three things and nothing else:
//
//   * the risk of the registered tool (never a value the model wrote);
//   * the policy the user stored on the agent;
//   * whether this run can ask the user at all.
//
// The levels are the three tiers, spelled plainly: `read` is low, `change` is
// medium, `destructive` is high. High is blocked by default — it needs a yes
// for that one action in that one run, and that yes is never stored.
import 'agent_records.dart';
import 'approval.dart';
import 'plan.dart';
import 'risk.dart';

enum GateDecision {
  /// The step may run.
  run,

  /// The step needs the user's yes. A run that cannot ask skips it and says so.
  needsApproval,

  /// The policy forbids this step outright; asking would not change it.
  blocked,
}

class GateVerdict {
  const GateVerdict(this.decision, this.why);

  final GateDecision decision;

  /// Why, in the words the dashboard and the log use. Never empty.
  final String why;

  bool get mayRun => decision == GateDecision.run;

  bool get needsUser => decision == GateDecision.needsApproval;
}

/// Asks the user, mid-run, for one action. Returns whether they said yes.
///
/// Passing one to `Executor.run` is the only way a step that needs approval
/// can run in an attended run; the answer is used for that step and thrown
/// away, so it cannot become a standing permission.
typedef ApprovalPrompter =
    Future<bool> Function(PlanStep step, GateVerdict verdict);

class ApprovalGate {
  const ApprovalGate();

  /// What to do with [step] under [policy].
  ///
  /// [attended] means this run can put a question in front of the user.
  /// [oneShot] is an approval made for this run — a plan-level yes from the
  /// session, or a per-action yes collected through an [ApprovalPrompter].
  GateVerdict check({
    required AgentApprovalPolicy policy,
    required PlanStep step,
    required bool attended,
    Approval? oneShot,
  }) {
    // A yes that names this exact step, made for this run. It is passed in and
    // never stored, so it stops existing when the run does.
    if (attended && oneShot != null && oneShot.covers(step)) {
      return const GateVerdict(
        GateDecision.run,
        'you approved this step for this run',
      );
    }
    if (step.risk == RiskTier.read &&
        policy != AgentApprovalPolicy.askEverything) {
      return const GateVerdict(
        GateDecision.run,
        'reading only, and your policy allows that',
      );
    }
    if (policy == AgentApprovalPolicy.readOnly) {
      return GateVerdict(
        GateDecision.blocked,
        '“${policy.label}” never runs a ${step.risk.level}-risk step',
      );
    }
    if (policy.allows(step.risk)) {
      return GateVerdict(
        GateDecision.run,
        '“${policy.label}” allows a ${step.risk.level}-risk step on its own',
      );
    }
    if (!attended) {
      return GateVerdict(
        GateDecision.needsApproval,
        'a scheduled run cannot ask, so this ${step.risk.level}-risk step was '
            'skipped',
      );
    }
    return GateVerdict(
      GateDecision.needsApproval,
      'a ${step.risk.level}-risk step needs your yes for this run',
    );
  }
}
