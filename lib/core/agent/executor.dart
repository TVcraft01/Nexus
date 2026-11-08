// Where the tiers are enforced.
//
// `Executor.run` is the only place a step can reach a tool, and every step
// passes [ApprovalGate.check] first — read off the validated step, which took
// its risk off the registered tool. The planner cannot get past this, and
// neither can a prompt injection: at worst one proposes a plan, and a plan is
// not an approval.
//
// The walk is the same for a typed ask and for a background run, which is why
// there is one loop and not two. What differs is what a step that needs the
// user can do:
//
//   * an attended run with an [ApprovalPrompter] asks, and the yes covers that
//     step in that run only;
//   * an attended run with no way to ask throws [TierNotApproved] before the
//     step runs, which is how the session reports "not approved";
//   * an unattended run (a schedule) cannot ask, so it skips the step, records
//     "needs approval", and carries on — never waits, never assumes yes.
//
// The rest of the loop lives here too: the kill switch before every step, the
// run's tool list, step cap and time limit, `run` then `verify` for each step,
// the session's action-log line and the durable run log, and — when a step
// throws or fails to verify — the unwind newest-first through the rollback
// closures, saying out loud what came back and what did not.
import 'action_log.dart';
import 'agent_records.dart';
import 'approval.dart';
import 'approval_gate.dart';
import 'kill_switch.dart';
import 'plan.dart';
import 'plan_validator.dart' show kMaxPlanSteps;
import 'registry.dart';
import 'risk.dart';
import 'rollback.dart';
import 'run_log.dart';
import 'tool.dart';
import 'undo.dart';
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

/// A step the gate did not let run, and what the gate said about it.
class SkippedStep {
  const SkippedStep({required this.step, required this.verdict});

  final PlanStep step;
  final GateVerdict verdict;
}

/// What one run is allowed to be: the agent's tool list, and the two caps.
class RunLimits {
  const RunLimits({
    this.maxSteps = kMaxPlanSteps,
    this.timeLimit = const Duration(minutes: 2),
    this.allowedTools,
  });

  /// A longer plan is refused whole, before anything runs.
  final int maxSteps;

  /// Checked before every step; the run stops when it is passed.
  final Duration timeLimit;

  /// The agent's tools by registered name. Null means "no list" (a typed ask).
  final List<String>? allowedTools;

  bool allows(String tool) {
    final List<String>? list = allowedTools;
    if (list == null) return true;
    return list.contains(tool);
  }
}

class ExecutionReport {
  const ExecutionReport({
    required this.status,
    required this.goal,
    this.verified = const <VerifiedStep>[],
    this.skipped = const <SkippedStep>[],
    this.unverified = const <String>[],
    this.irreversible = const <String>[],
    this.undone = const <RollbackResult>[],
    this.couldNotUndo = const <String>[],
    this.failure = '',
    this.stoppedAt,
  });

  final ExecutionStatus status;
  final String goal;

  /// Every step that ran and verified, in order.
  final List<VerifiedStep> verified;

  /// Every step the gate held back, in order, with the gate's reason.
  final List<SkippedStep> skipped;

  /// Steps that ran but whose tool has no read-back, so "done" is all the code
  /// can honestly say about them.
  final List<String> unverified;

  /// Change steps whose tool offered no way to put them back.
  final List<String> irreversible;

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

  /// The run in plain words, saying what actually happened.
  ///
  /// Written for the agent's last-run line, where a cheerful "done" that hides
  /// a skipped step would be the one lie this whole path exists to prevent:
  /// every skipped or blocked step is named, and a failure says what it failed
  /// with instead of claiming success.
  String get summary {
    final List<String> parts = <String>[];
    if (status == ExecutionStatus.stopped) {
      parts.add(
        'stopped before '
        '“${stoppedAt?.description ?? 'the next step'}”: $failure',
      );
    } else if (status == ExecutionStatus.failed) {
      parts.add('failed: $failure');
      if (undone.isNotEmpty) {
        parts.add('put back: ${undone.map((r) => r.what).join('; ')}');
      }
      if (couldNotUndo.isNotEmpty) {
        parts.add('could not put back: ${couldNotUndo.join('; ')}');
      }
    }

    final List<String> changes = changed;
    if (changes.isNotEmpty) {
      parts.add('ran ${verified.length} step(s): ${changes.join('; ')}');
    } else if (verified.isNotEmpty) {
      parts.add(
        'ran ${verified.length} reading step(s), nothing changed',
      );
    } else if (status == ExecutionStatus.done) {
      parts.add('nothing ran');
    }

    final List<String> needs = <String>[
      for (final skip in skipped)
        if (skip.verdict.needsUser) skip.step.description,
    ];
    final List<String> blocked = <String>[
      for (final skip in skipped)
        if (!skip.verdict.needsUser) skip.step.description,
    ];
    if (needs.isNotEmpty) {
      parts.add(
        'skipped ${needs.length} step(s) that need your approval: '
        '${needs.join('; ')}',
      );
    }
    if (blocked.isNotEmpty) {
      parts.add('blocked ${blocked.length} step(s): ${blocked.join('; ')}');
    }
    if (unverified.isNotEmpty) {
      parts.add(
        'could not verify ${unverified.length} step(s), the tool has no '
        'read-back: ${unverified.join('; ')}',
      );
    }
    if (irreversible.isNotEmpty) {
      parts.add('cannot be put back: ${irreversible.join('; ')}');
    }
    return parts.map(_plain).join('. ');
  }

  static String _plain(String text) =>
      text.trim().replaceFirst(RegExp(r'[.]+$'), '');
}

class Executor {
  Executor({
    required this.registry,
    KillSwitch? killSwitch,
    ApprovalGate? gate,
    this.log,
    DateTime Function()? now,
  }) : killSwitch = killSwitch ?? KillSwitch(),
       gate = gate ?? const ApprovalGate(),
       _now = now ?? DateTime.now;

  final ToolRegistry registry;
  final KillSwitch killSwitch;
  final ApprovalGate gate;
  final AgentActionLog? log;
  final DateTime Function() _now;

  /// Runs [plan] under [approval] and [policy].
  ///
  /// Throws [TierNotApproved] — before the step that needs it — when an
  /// attended run needs a yes and has no way to ask for one. Everything else
  /// comes back as a report, because "it failed and I put it back" is something
  /// the user needs to read, not an exception to catch.
  Future<ExecutionReport> run(
    Plan plan,
    Approval approval, {
    void Function(String progress)? onProgress,
    AgentApprovalPolicy policy = AgentApprovalPolicy.askEveryChange,
    bool unattended = false,
    ApprovalPrompter? ask,
    RunLimits limits = const RunLimits(),
    String agent = '',
    RunLog? runLog,
    UndoJournal? undo,
  }) async {
    if (plan.steps.length > limits.maxSteps) {
      return ExecutionReport(
        status: ExecutionStatus.failed,
        goal: plan.goal,
        failure:
            'the plan has ${plan.steps.length} steps, more than the '
            '${limits.maxSteps} this run allows, so nothing ran',
      );
    }

    // The agent's tool list, checked before anything runs: a plan that names a
    // tool the user did not give it is not partly run.
    final List<PlanStep> offList = <PlanStep>[
      for (final step in plan.steps)
        if (!limits.allows(step.tool)) step,
    ];
    if (offList.isNotEmpty) {
      for (final step in offList) {
        await runLog?.record(
          RunLogEntry(
            at: _now(),
            agent: agent,
            tool: step.tool,
            args: step.args,
            risk: step.risk,
            decision: GateDecision.blocked,
            why: 'not on this agent’s tool list',
            outcome: 'refused',
          ),
        );
      }
      return ExecutionReport(
        status: ExecutionStatus.failed,
        goal: plan.goal,
        failure:
            '“${offList.first.tool}” is not on this agent’s tool list, so '
            'nothing ran',
      );
    }

    // A successful run's undo entries replace the previous run's; a typed ask
    // has no agent and records none.
    undo?.beginRun(agent);

    final DateTime startedAt = _now();
    final verified = <VerifiedStep>[];
    final skipped = <SkippedStep>[];
    final unverified = <String>[];
    final irreversible = <String>[];

    for (final step in plan.steps) {
      if (killSwitch.tripped) {
        return ExecutionReport(
          status: ExecutionStatus.stopped,
          goal: plan.goal,
          verified: List<VerifiedStep>.unmodifiable(verified),
          skipped: List<SkippedStep>.unmodifiable(skipped),
          unverified: List<String>.unmodifiable(unverified),
          irreversible: List<String>.unmodifiable(irreversible),
          stoppedAt: step,
          failure: 'the stop switch is on',
        );
      }
      final Duration elapsed = _now().difference(startedAt);
      if (elapsed > limits.timeLimit) {
        return ExecutionReport(
          status: ExecutionStatus.failed,
          goal: plan.goal,
          verified: List<VerifiedStep>.unmodifiable(verified),
          skipped: List<SkippedStep>.unmodifiable(skipped),
          unverified: List<String>.unmodifiable(unverified),
          irreversible: List<String>.unmodifiable(irreversible),
          failure:
              'the run passed its ${limits.timeLimit.inSeconds}s time limit '
              'before “${step.description}”',
        );
      }

      final GateVerdict checked = gate.check(
        policy: policy,
        step: step,
        attended: !unattended,
        oneShot: approval,
      );
      GateVerdict verdict = checked;
      if (verdict.needsUser) {
        if (!unattended && ask == null) {
          // The typed-ask path: it cannot run an unapproved step and will not
          // skip silently, so it stops here with the step named.
          throw TierNotApproved(step);
        }
        if (!unattended && ask != null) {
          final bool yes = await ask(step, verdict);
          if (!yes) {
            skipped.add(SkippedStep(step: step, verdict: verdict));
            await _record(
              runLog,
              agent,
              step,
              verdict,
              outcome: 'skipped: you did not approve it',
            );
            continue;
          }
          verdict = const GateVerdict(
            GateDecision.run,
            'you approved this step for this run',
          );
        } else {
          skipped.add(SkippedStep(step: step, verdict: verdict));
          await _record(
            runLog,
            agent,
            step,
            verdict,
            outcome: 'skipped: needs approval',
          );
          continue;
        }
      }
      if (verdict.decision == GateDecision.blocked) {
        skipped.add(SkippedStep(step: step, verdict: verdict));
        await _record(runLog, agent, step, verdict, outcome: 'blocked');
        continue;
      }

      final Tool? tool = registry.lookup(step.tool);
      if (tool == null) {
        throw StateError(
          'the plan names ${step.tool}, which is not registered — the '
          'validator should have rejected it',
        );
      }

      onProgress?.call(step.description);

      final String said;
      final VerificationResult verification;
      final bool verifiable = tool.verifiable;
      try {
        said = await tool.run(step.args);
        // A tool that cannot read its result back says so; the step is
        // reported as unverified, never as measured success.
        verification = verifiable
            ? await tool.verify(step.args)
            : const VerificationResult.ok('no read-back for this tool');
      } on ToolRefused catch (refused) {
        // Nothing was written, so there is nothing to put back — only the rule
        // that refused it, said as itself rather than as an error.
        await _record(
          runLog,
          agent,
          step,
          verdict,
          outcome: 'refused: ${refused.message}',
        );
        return _unwind(
          plan,
          verified,
          const <PlanStep>[],
          'refused: ${refused.message}',
          skipped: skipped,
          unverified: unverified,
          irreversible: irreversible,
        );
      } catch (error) {
        await _record(
          runLog,
          agent,
          step,
          verdict,
          outcome: 'failed',
          error: '$error',
        );
        return _unwind(
          plan,
          verified,
          <PlanStep>[step],
          'it stopped with an error: $error',
          skipped: skipped,
          unverified: unverified,
          irreversible: irreversible,
        );
      }

      log?.record(
        ActionLogEntry(
          at: _now(),
          tool: step.tool,
          argDigest: argumentDigest(step.args),
          risk: step.risk,
          approved: approval.granted && approval.words.isNotEmpty
              ? 'approved by you (${approval.words})'
              : verdict.why,
          outcome: verification.ok ? 'done' : 'did not verify',
          verified: verification,
        ),
      );
      await _record(
        runLog,
        agent,
        step,
        verdict,
        outcome: verification.ok ? 'done' : 'did not verify',
        error: verification.ok ? '' : verification.reason,
      );

      if (!verification.ok) {
        return _unwind(
          plan,
          verified,
          <PlanStep>[step],
          verification.reason,
          skipped: skipped,
          unverified: unverified,
          irreversible: irreversible,
        );
      }
      if (!verifiable) unverified.add(step.description);
      if (step.risk != RiskTier.read && step.rollback == null) {
        irreversible.add(step.description);
      }
      final Future<RollbackResult> Function()? rollback = step.rollback;
      if (rollback != null && step.risk != RiskTier.read) {
        undo?.record(
          UndoEntry(
            agent: agent,
            at: _now(),
            description: step.description,
            tool: step.tool,
            rollback: rollback,
          ),
        );
      }
      verified.add(
        VerifiedStep(step: step, said: said, verification: verification),
      );
    }
    return ExecutionReport(
      status: ExecutionStatus.done,
      goal: plan.goal,
      verified: List<VerifiedStep>.unmodifiable(verified),
      skipped: List<SkippedStep>.unmodifiable(skipped),
      unverified: List<String>.unmodifiable(unverified),
      irreversible: List<String>.unmodifiable(irreversible),
    );
  }

  /// One durable line. Never throws: the log is evidence, not a step.
  Future<void> _record(
    RunLog? runLog,
    String agent,
    PlanStep step,
    GateVerdict verdict, {
    required String outcome,
    String error = '',
  }) async {
    if (runLog == null) return;
    await runLog.record(
      RunLogEntry(
        at: _now(),
        agent: agent,
        tool: step.tool,
        args: step.args,
        risk: step.risk,
        decision: verdict.decision,
        why: verdict.why,
        outcome: outcome,
        error: error,
      ),
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
    String failure, {
    List<SkippedStep> skipped = const <SkippedStep>[],
    List<String> unverified = const <String>[],
    List<String> irreversible = const <String>[],
  }) async {
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
      skipped: List<SkippedStep>.unmodifiable(skipped),
      unverified: List<String>.unmodifiable(unverified),
      irreversible: List<String>.unmodifiable(irreversible),
      undone: List<RollbackResult>.unmodifiable(undone),
      couldNotUndo: List<String>.unmodifiable(couldNotUndo),
      failure: failure,
    );
  }
}
