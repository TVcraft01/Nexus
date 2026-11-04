// Where the tiers are enforced.
//
// `Executor.run` is the only place a step's risk is checked against an
// approval, and it reads the risk off the validated step (which took it off the
// registered tool). The planner cannot get past this, and neither can a prompt
// injection: at worst one proposes a plan, and a plan is not an approval.
//
// The rest of the loop lives here too, because it is the same walk over the
// steps: the kill switch before every step, `run` then `verify` for each, the
// action-log line, and — when a step throws or fails to verify — the unwind
// newest-first through the rollback closures, saying out loud what came back
// and what did not.
import 'action_log.dart';
import 'approval.dart';
import 'kill_switch.dart';
import 'plan.dart';
import 'registry.dart';
import 'risk.dart';
import 'rollback.dart';
import 'verification.dart';

enum ExecutionStatus {
  /// Every step ran and verified.
  done,

  /// The stop switch was on, so the walk stopped where it was.
  stopped,

  /// A step failed and the ones before it were unwound.
  failed,
}

/// A step that ran and verified: what it said it did, and what was measured.
class VerifiedStep {
  const VerifiedStep({
    required this.step,
    required this.said,
    required this.verification,
  });

  final PlanStep step;
  final String said;
  final VerificationResult verification;
}

class ExecutionReport {
  const ExecutionReport({
    required this.status,
    required this.goal,
    this.verified = const <VerifiedStep>[],
    this.undone = const <RollbackResult>[],
    this.couldNotUndo = const <String>[],
    this.failure = '',
    this.stoppedAt,
  });

  final ExecutionStatus status;
  final String goal;

  /// Every step that ran and verified, in order.
  final List<VerifiedStep> verified;

  /// What the unwind put back, and what it could not.
  final List<RollbackResult> undone;
  final List<String> couldNotUndo;

  /// Why it failed, or why it stopped. Empty when [status] is done.
  final String failure;

  /// The step the stop switch stopped before.
  final PlanStep? stoppedAt;

  /// What changed, in the tools' own words — reading steps are not a change,
  /// so they are not in the "I did this" line.
  List<String> get changed => <String>[
    for (final step in verified)
      if (step.step.risk != RiskTier.read) step.said,
  ];

  /// What was read back for the steps that changed something.
  List<String> get measured => <String>[
    for (final step in verified)
      if (step.step.risk != RiskTier.read) step.verification.measured,
  ];
}

class Executor {
  Executor({
    required this.registry,
    KillSwitch? killSwitch,
    this.log,
    DateTime Function()? now,
  }) : killSwitch = killSwitch ?? KillSwitch(),
       _now = now ?? DateTime.now;

  final ToolRegistry registry;
  final KillSwitch killSwitch;
  final AgentActionLog? log;
  final DateTime Function() _now;

  /// Runs [plan] under [approval].
  ///
  /// Throws [TierNotApproved] — before anything runs — when a step that needs
  /// approval is not covered by it. Everything else comes back as a report,
  /// because "it failed and I put it back" is something the user needs to read,
  /// not an exception to catch.
  Future<ExecutionReport> run(
    Plan plan,
    Approval approval, {
    void Function(String progress)? onProgress,
  }) async {
    final verified = <VerifiedStep>[];
    for (final step in plan.steps) {
      if (killSwitch.tripped) {
        return ExecutionReport(
          status: ExecutionStatus.stopped,
          goal: plan.goal,
          verified: List<VerifiedStep>.unmodifiable(verified),
          stoppedAt: step,
          failure: 'the stop switch is on',
        );
      }
      if (step.risk.needsApproval && !approval.covers(step)) {
        // Nothing has run yet, so nothing has to be undone.
        throw TierNotApproved(step);
      }
      final tool = registry.lookup(step.tool);
      if (tool == null) {
        throw StateError(
          'the plan names ${step.tool}, which is not registered — the '
          'validator should have rejected it',
        );
      }

      onProgress?.call(step.description);

      final String said;
      final VerificationResult verification;
      try {
        said = await tool.run(step.args);
        verification = await tool.verify(step.args);
      } catch (error) {
        return _unwind(plan, verified, <PlanStep>[
          step,
        ], 'it stopped with an error: $error');
      }

      log?.record(
        ActionLogEntry(
          at: _now(),
          tool: step.tool,
          argDigest: argumentDigest(step.args),
          risk: step.risk,
          approved: approval.words.isEmpty
              ? 'automatic'
              : 'approved by you (${approval.words})',
          outcome: verification.ok ? 'done' : 'did not verify',
          verified: verification,
        ),
      );

      if (!verification.ok) {
        return _unwind(plan, verified, <PlanStep>[step], verification.reason);
      }
      verified.add(
        VerifiedStep(step: step, said: said, verification: verification),
      );
    }
    return ExecutionReport(
      status: ExecutionStatus.done,
      goal: plan.goal,
      verified: List<VerifiedStep>.unmodifiable(verified),
    );
  }

  /// Puts [newest] back, then the steps that completed, newest-first.
  ///
  /// The failing step goes first because it may have half-applied before its
  /// verification said no — the thing that restores it is its own rollback, and
  /// leaving it out would be the one case where a change is neither kept nor
  /// undone. Reading steps are skipped: they changed nothing, so there is
  /// nothing to put back and saying otherwise would be noise.
  Future<ExecutionReport> _unwind(
    Plan plan,
    List<VerifiedStep> verified,
    List<PlanStep> newest,
    String failure,
  ) async {
    final undone = <RollbackResult>[];
    final couldNotUndo = <String>[];
    final steps = <PlanStep>[
      ...newest.reversed,
      for (final step in verified.reversed) step.step,
    ];
    for (final step in steps) {
      if (step.risk == RiskTier.read) continue;
      final rollback = step.rollback;
      if (rollback == null) {
        couldNotUndo.add(step.description);
        continue;
      }
      try {
        undone.add(await rollback());
      } catch (error) {
        couldNotUndo.add('${step.description} ($error)');
      }
    }
    return ExecutionReport(
      status: ExecutionStatus.failed,
      goal: plan.goal,
      verified: List<VerifiedStep>.unmodifiable(verified),
      undone: List<RollbackResult>.unmodifiable(undone),
      couldNotUndo: List<String>.unmodifiable(couldNotUndo),
      failure: failure,
    );
  }
}
