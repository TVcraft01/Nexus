// The execution path's rules, pinned offline: no model, no network, no device.
//
//   * gate matrix: every risk x every policy x attended/unattended;
//   * a per-action yes runs that step in that run and is not remembered;
//   * a plan naming a tool outside the agent's list is refused whole;
//   * a tool that declares no risk is high;
//   * an unattended run skips a step that needs approval and says so;
//   * halting blocks scheduling and stops a run between steps;
//   * the step cap and the time limit trip before anything else does;
//   * the run log redacts secrets, rotates, and keeps a failure as a failure.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent/agent_records.dart';
import 'package:nexus/core/agent/agent_runner.dart';
import 'package:nexus/core/agent/agent_service.dart';
import 'package:nexus/core/agent/agent_store.dart';
import 'package:nexus/core/agent/approval.dart';
import 'package:nexus/core/agent/approval_gate.dart';
import 'package:nexus/core/agent/executor.dart';
import 'package:nexus/core/agent/fake_device.dart';
import 'package:nexus/core/agent/fake_tools.dart';
import 'package:nexus/core/agent/kill_switch.dart';
import 'package:nexus/core/agent/plan.dart';
import 'package:nexus/core/agent/plan_validator.dart';
import 'package:nexus/core/agent/planner.dart';
import 'package:nexus/core/agent/registry.dart';
import 'package:nexus/core/agent/risk.dart';
import 'package:nexus/core/agent/rollback.dart';
import 'package:nexus/core/agent/run_log.dart';
import 'package:nexus/core/agent/tool.dart';
import 'package:nexus/core/agent/verification.dart';

import 'agent_fixtures.dart';

/// A high-risk tool with a real rollback, so it may be registered.
class _NotesTool extends Tool {
  int calls = 0;

  @override
  String get name => 'wipe_notes';

  @override
  String get description => 'Delete every note on a device.';

  @override
  RiskTier get risk => RiskTier.destructive;

  @override
  bool get reversible => true;

  @override
  Map<String, ToolArg> get args => const <String, ToolArg>{
    'device': ToolArg(ArgType.text, example: 'this PC'),
  };

  @override
  Future<String> run(Map<String, Object?> args) async {
    calls++;
    return 'deleted the notes on ${args['device']}';
  }

  @override
  Future<VerificationResult> verify(Map<String, Object?> args) async =>
      const VerificationResult.ok('no notes left');

  @override
  Future<RollbackResult> Function()? rollback(Map<String, Object?> args) =>
      () async => const RollbackResult.ok('the notes are back');
}

/// A tool whose author never classified it: the default has to be high.
class _UndeclaredTool extends Tool {
  @override
  String get name => 'undeclared';

  @override
  String get description => 'Change something, classified by nobody.';

  @override
  bool get reversible => true;

  @override
  Map<String, ToolArg> get args => const <String, ToolArg>{};

  @override
  Future<String> run(Map<String, Object?> args) async => 'changed it';

  @override
  Future<VerificationResult> verify(Map<String, Object?> args) async =>
      const VerificationResult.ok('changed');

  @override
  Future<RollbackResult> Function()? rollback(Map<String, Object?> args) =>
      () async => const RollbackResult.ok('back');
}

/// A read that fails: the run must record a failure, not a success.
class _ExplodingTool extends Tool {
  @override
  String get name => 'explode';

  @override
  String get description => 'Read something and fail.';

  @override
  RiskTier get risk => RiskTier.read;

  @override
  Map<String, ToolArg> get args => const <String, ToolArg>{};

  @override
  Future<String> run(Map<String, Object?> args) async =>
      throw StateError('the disk is on fire');

  @override
  Future<VerificationResult> verify(Map<String, Object?> args) async =>
      const VerificationResult.ok('unreachable');
}

/// A read that counts its calls, for the cap and time-limit tests.
class _CountingTool extends Tool {
  int calls = 0;

  @override
  String get name => 'count_read';

  @override
  String get description => 'Read a number. Changes nothing.';

  @override
  RiskTier get risk => RiskTier.read;

  @override
  Map<String, ToolArg> get args => const <String, ToolArg>{};

  @override
  Future<String> run(Map<String, Object?> args) async {
    calls++;
    return 'read the number';
  }

  @override
  Future<VerificationResult> verify(Map<String, Object?> args) async =>
      const VerificationResult.ok('read it');
}

PlanStep _step(RiskTier risk, {String tool = 'wifi_status'}) => PlanStep(
  tool: tool,
  args: const <String, Object?>{},
  description: 'a step',
  risk: risk,
);

Plan _validated(ToolRegistry registry, List<ProposedStep> steps) {
  final PlanValidation validation = PlanValidator(
    registry,
  ).validate(ProposedPlan(goal: 'do the drill', steps: steps));
  return (validation as PlanAccepted).plan;
}

const String _twoStepPlan = '''
{"goal": "do the drill",
 "steps": [
   {"tool": "wifi_status", "args": {}, "description": "Look at the current Wi-Fi"},
   {"tool": "wifi_set", "args": {"band": "auto", "guest": true}, "description": "Switch Wi-Fi to the best speed"}
 ],
 "questions": []}''';

const String _wipePlan = '''
{"goal": "do the drill",
 "steps": [
   {"tool": "wipe_notes", "args": {"device": "this PC"}, "description": "Wipe the notes on this PC"}
 ],
 "questions": []}''';

const String _explodePlan = '''
{"goal": "do the drill",
 "steps": [
   {"tool": "explode", "args": {}, "description": "Read something"}
 ],
 "questions": []}''';

AgentDefinition _agent({
  List<String> tools = const <String>['wifi_status', 'wifi_set'],
  AgentApprovalPolicy approval = AgentApprovalPolicy.askDestructive,
}) => AgentDefinition(
  name: 'Drill agent',
  goal: 'do the drill',
  tools: tools,
  approval: approval,
);

PlannedAgentRunner _runner({
  required ToolRegistry registry,
  required String script,
  required KillSwitch halt,
  RunLog? runLog,
  Duration timeLimit = const Duration(minutes: 2),
  int maxSteps = 8,
}) => PlannedAgentRunner(
  planner: Planner(
    backend: ScriptedBackend(<String, String>{'do the drill': script}),
    registry: registry,
  ),
  validator: PlanValidator(registry),
  executor: Executor(registry: registry, killSwitch: halt),
  runLog: runLog ?? RunLog(),
  killSwitch: halt,
  timeLimit: timeLimit,
  maxSteps: maxSteps,
);

GateDecision _expected(AgentApprovalPolicy policy, RiskTier risk) {
  switch (risk) {
    case RiskTier.read:
      return policy == AgentApprovalPolicy.askEverything
          ? GateDecision.needsApproval
          : GateDecision.run;
    case RiskTier.change:
      if (policy == AgentApprovalPolicy.askDestructive) {
        return GateDecision.run;
      }
      return policy == AgentApprovalPolicy.readOnly
          ? GateDecision.blocked
          : GateDecision.needsApproval;
    case RiskTier.destructive:
      return policy == AgentApprovalPolicy.readOnly
          ? GateDecision.blocked
          : GateDecision.needsApproval;
  }
}

void main() {
  const ApprovalGate gate = ApprovalGate();

  test('the gate matrix: risk x policy x attended', () {
    for (final policy in AgentApprovalPolicy.values) {
      for (final risk in RiskTier.values) {
        for (final attended in <bool>[true, false]) {
          final GateVerdict verdict = gate.check(
            policy: policy,
            step: _step(risk),
            attended: attended,
          );
          expect(
            verdict.decision,
            _expected(policy, risk),
            reason: '${policy.name} x ${risk.name} attended=$attended',
          );
          expect(verdict.why, isNotEmpty);
        }
      }
    }
    expect(AgentApprovalPolicy.values, hasLength(4));
  });

  test('a yes for one action runs that step and is not remembered', () async {
    final plan = _validated(ToolRegistry(<Tool>[_NotesTool()]), const <
      ProposedStep
    >[
      ProposedStep(
        tool: 'wipe_notes',
        args: <String, Object?>{'device': 'this PC'},
        description: 'Wipe the notes on this PC',
      ),
    ]);
    for (final policy in AgentApprovalPolicy.values) {
      final GateVerdict verdict = gate.check(
        policy: policy,
        step: plan.steps.single,
        attended: true,
        oneShot: Approval.granted(
          plan: plan,
          words: 'yes, this one',
          at: DateTime(2026, 11, 4, 10),
        ),
      );
      expect(verdict.decision, GateDecision.run, reason: policy.name);
    }
    // Nobody approved it: still asked, whatever the policy.
    expect(
      gate
          .check(
            policy: AgentApprovalPolicy.askDestructive,
            step: plan.steps.single,
            attended: true,
          )
          .decision,
      GateDecision.needsApproval,
    );
  });

  test('a high-risk yes covers one run, not the next one', () async {
    final tool = _NotesTool();
    final registry = ToolRegistry(<Tool>[tool]);
    final plan = _validated(registry, const <ProposedStep>[
      ProposedStep(
        tool: 'wipe_notes',
        args: <String, Object?>{'device': 'this PC'},
        description: 'Wipe the notes on this PC',
      ),
    ]);
    final executor = Executor(registry: registry);

    final first = await executor.run(
      plan,
      Approval.none(plan: plan),
      policy: AgentApprovalPolicy.askDestructive,
      ask: (step, verdict) async => true,
    );
    expect(first.status, ExecutionStatus.done);
    expect(tool.calls, 1);
    expect(first.summary, contains('deleted the notes'));

    // Same plan, same policy, next run: it needs the user again.
    final second = await executor.run(
      plan,
      Approval.none(plan: plan),
      policy: AgentApprovalPolicy.askDestructive,
      unattended: true,
    );
    expect(tool.calls, 1, reason: 'the earlier yes is not standing');
    expect(second.skipped.single.verdict.decision, GateDecision.needsApproval);
    expect(second.summary, contains('need your approval'));
  });

  test('a tool outside the agent’s list is refused before anything runs', () async {
    final device = FakeDevice();
    final registry = ToolRegistry(fakeTools(device));
    final RunLog log = RunLog();

    final AgentOutcome outcome = await _runner(
      registry: registry,
      script: _twoStepPlan,
      halt: KillSwitch(),
      runLog: log,
    ).call(_agent(tools: const <String>['wifi_status']));

    expect(outcome.ok, isFalse);
    expect(outcome.said, contains('not on this agent’s tool list'));
    expect(device.band, '2.4ghz', reason: 'the second step never ran');
    expect(log.entries.single.tool, 'wifi_set');
    expect(log.entries.single.outcome, 'refused');
  });

  test('a tool that declares no risk is high, and asks', () {
    final tool = _UndeclaredTool();
    final registry = ToolRegistry(<Tool>[tool]);

    expect(tool.risk, RiskTier.destructive);
    expect(tool.risk.level, 'high');
    expect(registry.has('undeclared'), isTrue);
    expect(
      gate
          .check(
            policy: AgentApprovalPolicy.askDestructive,
            step: PlanStep(
              tool: 'undeclared',
              args: const <String, Object?>{},
              description: 'Change it',
              risk: tool.risk,
            ),
            attended: true,
          )
          .decision,
      GateDecision.needsApproval,
    );
  });

  test('an unattended run skips a step that needs approval, and says so', () async {
    final notes = _NotesTool();
    final registry = ToolRegistry(<Tool>[notes]);
    final RunLog log = RunLog();

    final AgentOutcome outcome = await _runner(
      registry: registry,
      script: _wipePlan,
      halt: KillSwitch(),
      runLog: log,
    ).call(_agent(tools: const <String>['wipe_notes']));

    expect(notes.calls, 0);
    expect(outcome.ok, isFalse);
    expect(outcome.said, contains('skipped 1 step(s) that need your approval'));
    expect(outcome.said, contains('Wipe the notes on this PC'));
    expect(log.entries.single.decision, GateDecision.needsApproval);
    expect(log.entries.single.outcome, 'skipped: needs approval');
    expect(log.entries.single.agent, 'Drill agent');
  });

  test('a policy that allows changes lets a medium step run unattended', () async {
    final device = FakeDevice();
    final registry = ToolRegistry(fakeTools(device));

    final AgentOutcome ran = await _runner(
      registry: registry,
      script: _twoStepPlan,
      halt: KillSwitch(),
    ).call(_agent());
    expect(device.band, 'auto');
    expect(ran.ok, isTrue);
    expect(ran.said, contains('ran 2 step(s)'));

    device.band = '2.4ghz';
    final AgentOutcome asked = await _runner(
      registry: registry,
      script: _twoStepPlan,
      halt: KillSwitch(),
    ).call(_agent(approval: AgentApprovalPolicy.askEveryChange));
    expect(device.band, '2.4ghz', reason: 'a change was not allowed to run');
    expect(asked.said, contains('need your approval'));
  });

  test('halting stops scheduling and manual runs until it is cleared', () async {
    final Directory dir = Directory.systemTemp.createTempSync('nexus-halt-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final AgentStore store = AgentStore(
      explicitPath: '${dir.path}/agents.json',
    );
    await store.load();
    final AgentDefinition agent = _agent(tools: const <String>['wifi_status'])
      ..schedule = '9:00-18:00 on weekdays'
      ..status = AgentStatus.running;
    await store.put(agent);

    var calls = 0;
    final AgentService service = AgentService(
      store: store,
      halt: KillSwitch(),
      now: () => DateTime(2026, 11, 4, 10),
      runner: (agent) async {
        calls++;
        return const AgentOutcome('ran the drill');
      },
    );

    service.haltAll();
    expect(service.halted, isTrue);
    expect(await service.tick(), isEmpty);
    expect(calls, 0);
    await expectLater(
      service.runNow('Drill agent'),
      throwsA(isA<AgentServiceError>()),
    );
    expect(calls, 0);

    service.resumeAgents();
    expect(service.halted, isFalse);
    expect(await service.tick(), hasLength(1));
    expect(calls, 1);
  });

  test('a halt stops a run at the next step boundary', () async {
    final counting = _CountingTool();
    final registry = ToolRegistry(<Tool>[counting]);
    final plan = _validated(registry, const <ProposedStep>[
      ProposedStep(tool: 'count_read', description: 'First read'),
      ProposedStep(tool: 'count_read', description: 'Second read'),
    ]);
    final KillSwitch halt = KillSwitch();

    final ExecutionReport report = await Executor(
      registry: registry,
      killSwitch: halt,
    ).run(
      plan,
      Approval.none(plan: plan),
      policy: AgentApprovalPolicy.askDestructive,
      unattended: true,
      onProgress: (line) => halt.trip(),
    );

    expect(report.status, ExecutionStatus.stopped);
    expect(report.stoppedAt!.description, 'Second read');
    expect(counting.calls, 1, reason: 'the step already started finished');
    expect(report.summary, contains('stop switch'));
  });

  test('a plan longer than the step cap runs nothing', () async {
    final counting = _CountingTool();
    final registry = ToolRegistry(<Tool>[counting]);
    final plan = _validated(registry, const <ProposedStep>[
      ProposedStep(tool: 'count_read', description: 'One'),
      ProposedStep(tool: 'count_read', description: 'Two'),
      ProposedStep(tool: 'count_read', description: 'Three'),
    ]);

    final ExecutionReport report = await Executor(registry: registry).run(
      plan,
      Approval.none(plan: plan),
      limits: const RunLimits(maxSteps: 2),
    );

    expect(report.status, ExecutionStatus.failed);
    expect(report.failure, contains('more than the 2'));
    expect(counting.calls, 0);
  });

  test('the time limit stops the run before the next step', () async {
    final counting = _CountingTool();
    final registry = ToolRegistry(<Tool>[counting]);
    final plan = _validated(registry, const <ProposedStep>[
      ProposedStep(tool: 'count_read', description: 'One'),
      ProposedStep(tool: 'count_read', description: 'Two'),
    ]);
    var ticks = 0;
    DateTime clock() =>
        DateTime(2026, 11, 4, 10).add(Duration(seconds: ticks++ * 10));

    final ExecutionReport report = await Executor(
      registry: registry,
      now: clock,
    ).run(
      plan,
      Approval.none(plan: plan),
      limits: const RunLimits(timeLimit: Duration(seconds: 15)),
    );

    expect(report.status, ExecutionStatus.failed);
    expect(report.failure, contains('time limit'));
    expect(report.verified, hasLength(1), reason: 'the first step finished');
    expect(counting.calls, 1);
  });

  test('a failing tool is recorded as a failure, not a success', () async {
    final registry = ToolRegistry(<Tool>[_ExplodingTool()]);
    final RunLog log = RunLog();

    final AgentOutcome outcome = await _runner(
      registry: registry,
      script: _explodePlan,
      halt: KillSwitch(),
      runLog: log,
    ).call(_agent(tools: const <String>['explode']));

    expect(outcome.ok, isFalse);
    expect(outcome.said, startsWith('failed:'));
    expect(outcome.said, contains('the disk is on fire'));
    expect(log.entries.single.outcome, 'failed');
    expect(log.entries.single.error, contains('the disk is on fire'));
  });

  test('the run log redacts secrets in arguments', () async {
    final Directory dir = Directory.systemTemp.createTempSync('nexus-log-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final RunLog log = RunLog(explicitPath: '${dir.path}/runs.jsonl');

    await log.record(
      RunLogEntry(
        at: DateTime(2026, 11, 4, 10),
        agent: 'Drill agent',
        tool: 'wifi_set',
        args: <String, Object?>{
          'password': 'hunter2',
          'apiKey': 'short',
          'session_id': 'abc',
          'value': 'auto',
          'config': <String, Object?>{'token': 'nested-secret'},
          'opaque': List<String>.filled(30, 'A').join(),
        },
        risk: RiskTier.change,
        decision: GateDecision.run,
        why: 'allowed',
        outcome: 'done',
      ),
    );

    final Map<String, Object?> written = log.entries.single.toJson();
    final Map<Object?, Object?> args = written['args']! as Map<Object?, Object?>;
    expect(args['password'], '[redacted]');
    expect(args['apiKey'], '[redacted]');
    expect(args['session_id'], '[redacted]');
    expect(args['value'], 'auto');
    expect((args['config']! as Map<Object?, Object?>)['token'], '[redacted]');
    expect(args['opaque'], '[redacted]');

    final String onDisk = await File('${dir.path}/runs.jsonl').readAsString();
    expect(onDisk, isNot(contains('hunter2')));
    expect(onDisk, isNot(contains('nested-secret')));
    expect(onDisk, contains('[redacted]'));
    expect(jsonDecode(onDisk.trim()), isA<Map<String, Object?>>());
  });

  test('the run log is capped and rotated', () async {
    final Directory dir = Directory.systemTemp.createTempSync('nexus-rotate-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final String path = '${dir.path}/runs.jsonl';
    final RunLog log = RunLog(explicitPath: path, limit: 3);

    for (var i = 0; i < 6; i++) {
      await log.record(
        RunLogEntry(
          at: DateTime(2026, 11, 4, 10).add(Duration(minutes: i)),
          agent: 'Drill agent',
          tool: 'wifi_status',
          risk: RiskTier.read,
          decision: GateDecision.run,
          why: 'reading only',
          outcome: 'ran $i',
        ),
      );
    }

    expect(log.entries, hasLength(3));
    expect(log.entries.first.outcome, 'ran 5', reason: 'newest first');
    final List<String> lines = await File(path).readAsLines();
    expect(lines, hasLength(3), reason: 'never more than the cap');
    final Map<String, Object?> oldest = Map<String, Object?>.from(
      jsonDecode(lines.first) as Map,
    );
    expect(oldest['outcome'], 'ran 3', reason: 'the file keeps the newest');
    expect(await File('$path.1').exists(), isTrue, reason: 'one generation');

    // Reading it back gives the same entries, newest first.
    final RunLog reloaded = RunLog(explicitPath: path, limit: 3);
    await reloaded.load();
    expect(reloaded.entries, hasLength(3));
    expect(reloaded.entries.first.outcome, 'ran 5');
  });
}
