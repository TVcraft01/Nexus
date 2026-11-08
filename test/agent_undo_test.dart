// Step 2's gaps, pinned offline: undo, unverifiable, irreversible, and a model
// that is not there.
//
// No network and no model: the planner is the scripted backend, the tools are
// the fakes or a local stub, and the store is a temporary directory.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent/agent_records.dart';
import 'package:nexus/core/agent/agent_runner.dart';
import 'package:nexus/core/agent/agent_service.dart';
import 'package:nexus/core/agent/agent_store.dart';
import 'package:nexus/core/agent/approval.dart';
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
import 'package:nexus/core/agent/undo.dart';
import 'package:nexus/core/agent/verification.dart';

import 'agent_fixtures.dart';

/// A medium-risk tool that changes state and says it cannot check the result.
class _UnverifiableTool extends Tool {
  int verifies = 0;

  @override
  String get name => 'settings_apply';

  @override
  String get description => 'Apply a setting this tool cannot read back.';

  @override
  RiskTier get risk => RiskTier.change;

  @override
  bool get reversible => true;

  @override
  bool get verifiable => false;

  @override
  Map<String, ToolArg> get args => const <String, ToolArg>{
    'value': ToolArg(ArgType.text, example: 'auto'),
  };

  @override
  Future<String> run(Map<String, Object?> args) async => 'applied it';

  @override
  Future<VerificationResult> verify(Map<String, Object?> args) async {
    verifies++;
    return const VerificationResult.ok('should not be called');
  }

  @override
  Future<RollbackResult> Function()? rollback(Map<String, Object?> args) =>
      () async => const RollbackResult.ok('put the old value back');
}

/// A medium-risk tool with no undo at all, declared reversible so it registers.
class _NoUndoTool extends Tool {
  @override
  String get name => 'settings_set';

  @override
  String get description => 'Change a setting with no way back.';

  @override
  RiskTier get risk => RiskTier.change;

  @override
  bool get reversible => true;

  @override
  Map<String, ToolArg> get args => const <String, ToolArg>{
    'value': ToolArg(ArgType.text, example: 'on'),
  };

  @override
  Future<String> run(Map<String, Object?> args) async => 'changed it';

  @override
  Future<VerificationResult> verify(Map<String, Object?> args) async =>
      const VerificationResult.ok('reads back changed');
}

Plan _validated(ToolRegistry registry, List<ProposedStep> steps) {
  final PlanValidation validation = PlanValidator(
    registry,
  ).validate(ProposedPlan(goal: 'do the drill', steps: steps));
  return (validation as PlanAccepted).plan;
}

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nexus-undo-');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('undo last run puts the change back, newest first, and logs it', () async {
    final FakeDevice device = FakeDevice();
    final ToolRegistry registry = ToolRegistry(fakeTools(device));
    final AgentStore store = AgentStore(
      explicitPath: '${dir.path}/agents.json',
    );
    await store.load();
    await store.put(
      AgentDefinition(
        name: 'Drill agent',
        goal: 'do the drill',
        tools: const <String>['wifi_set'],
        schedule: '9:00-18:00 on weekdays',
        approval: AgentApprovalPolicy.askDestructive,
      )..status = AgentStatus.running,
    );

    final UndoJournal undo = UndoJournal();
    final RunLog log = RunLog();
    final KillSwitch halt = KillSwitch();
    final AgentService service = AgentService(
      store: store,
      halt: halt,
      undo: undo,
      runLog: log,
      now: () => DateTime(2026, 11, 4, 10),
      runner: PlannedAgentRunner(
        planner: Planner(
          backend: ScriptedBackend(<String, String>{
            'do the drill':
                '{"goal": "do the drill", "steps": ['
                '{"tool": "wifi_set", "args": {"band": "auto", "guest": true}, '
                '"description": "Switch the Wi-Fi to the best speed"}], '
                '"questions": []}',
          }),
          registry: registry,
        ),
        validator: PlanValidator(registry),
        executor: Executor(registry: registry, killSwitch: halt),
        runLog: log,
        killSwitch: halt,
        undo: undo,
      ).call,
    );

    final AgentRun run = await service.runNow('Drill agent');
    expect(run.ok, isTrue, reason: run.result);
    expect(device.band, 'auto');
    expect(device.guestNetwork, isTrue);
    expect(service.canUndoLastRun('Drill agent'), isTrue);
    expect(log.entries.single.outcome, 'done');

    final List<RollbackResult> undone = await service.undoLastRun('Drill agent');
    expect(undone.single.ok, isTrue);
    expect(device.band, '2.4ghz', reason: 'the old band is back');
    expect(device.guestNetwork, isFalse);
    expect(
      store.agent('Drill agent')!.lastResult,
      contains('undid 1 step(s)'),
    );

    final RunLogEntry undoLine = log.entries.first;
    expect(undoLine.outcome, 'undone');
    expect(undoLine.tool, 'wifi_set');
    expect(undoLine.why, contains('undo the last run'));

    // One run is undone once.
    expect(service.canUndoLastRun('Drill agent'), isFalse);
    await expectLater(
      service.undoLastRun('Drill agent'),
      throwsA(isA<AgentServiceError>()),
    );
  });

  test('a tool that cannot read its result back is reported unverified', () async {
    final tool = _UnverifiableTool();
    final registry = ToolRegistry(<Tool>[tool]);
    final plan = _validated(registry, const <ProposedStep>[
      ProposedStep(
        tool: 'settings_apply',
        args: <String, Object?>{'value': 'auto'},
        description: 'Apply the setting',
      ),
    ]);

    final ExecutionReport report = await Executor(registry: registry).run(
      plan,
      Approval.none(plan: plan),
      policy: AgentApprovalPolicy.askDestructive,
      unattended: true,
      agent: 'Drill agent',
    );

    expect(report.status, ExecutionStatus.done);
    expect(tool.verifies, 0, reason: 'nothing pretended to check it');
    expect(report.unverified.single, 'Apply the setting');
    expect(report.summary, contains('could not verify 1 step(s)'));
    expect(report.summary, contains('Apply the setting'));
  });

  test('a change with no undo is named in the run summary', () async {
    final tool = _NoUndoTool();
    final registry = ToolRegistry(<Tool>[tool]);
    final plan = _validated(registry, const <ProposedStep>[
      ProposedStep(
        tool: 'settings_set',
        args: <String, Object?>{'value': 'on'},
        description: 'Turn the setting on',
      ),
    ]);

    final ExecutionReport report = await Executor(registry: registry).run(
      plan,
      Approval.none(plan: plan),
      policy: AgentApprovalPolicy.askDestructive,
      unattended: true,
      agent: 'Drill agent',
    );

    expect(report.status, ExecutionStatus.done);
    expect(report.irreversible.single, 'Turn the setting on');
    expect(report.summary, contains('cannot be put back'));
    // And nothing was offered to undo.
    expect(report.verified.single.step.rollback, isNull);
  });

  test('a model that cannot plan records a failure, not a success', () async {
    final FakeDevice device = FakeDevice();
    final ToolRegistry registry = ToolRegistry(fakeTools(device));
    final AgentStore store = AgentStore(
      explicitPath: '${dir.path}/agents.json',
    );
    await store.load();
    await store.put(
      AgentDefinition(
        name: 'Drill agent',
        goal: 'do the drill',
        tools: const <String>['wifi_status'],
        schedule: '9:00-18:00 on weekdays',
        approval: AgentApprovalPolicy.askDestructive,
      )..status = AgentStatus.running,
    );
    final RunLog log = RunLog();
    final KillSwitch halt = KillSwitch();

    // The scripted model has no reply for this ask, so it throws — which is
    // what a missing Ollama looks like to the planner.
    final AgentService service = AgentService(
      store: store,
      halt: halt,
      runLog: log,
      now: () => DateTime(2026, 11, 4, 10),
      runner: PlannedAgentRunner(
        planner: Planner(
          backend: ScriptedBackend(const <String, String>{}),
          registry: registry,
        ),
        validator: PlanValidator(registry),
        executor: Executor(registry: registry, killSwitch: halt),
        runLog: log,
        killSwitch: halt,
      ).call,
    );

    final AgentRun run = await service.runNow('Drill agent');

    expect(run.ok, isFalse);
    expect(run.result, startsWith('failed:'));
    expect(
      store.agent('Drill agent')!.lastResult,
      startsWith('failed:'),
    );
    expect(log.entries.single.outcome, 'failed');
    expect(log.entries.single.tool, 'planner');
  });
}
