// The agent, for real, on this PC: the installed Ollama model plans, the real
// network tools run, and the gate and the log do their work.
//
// Not part of the suite: no `_test` suffix, so the default glob skips it. It
// needs Ollama running with a model pulled, and it reads the real Wi-Fi state.
// Run it explicitly:
//
//   flutter test test/agent_live_smoke.dart
//
// Four things are printed, each prefixed so the evidence can be pasted whole:
//
//   MODEL=          the model that was resolved and used
//   A/…             a low-risk agent, scheduled, run with runNow
//   B/…             a high-risk step in an unattended run: skipped, logged
//   C/…             the same run with no Ollama answering: a recorded failure
//
// The high-risk proof uses a stand-in tool instead of a real destructive one:
// this build has no delete/install/command tool, and adding one to prove a gate
// would be the opposite of the point. The gate, the executor, the service, the
// store and the log are the real ones; only the tool and the plan are stated.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent/agent_records.dart';
import 'package:nexus/core/agent/agent_runner.dart';
import 'package:nexus/core/agent/agent_service.dart';
import 'package:nexus/core/agent/agent_store.dart';
import 'package:nexus/core/agent/agent_tools.dart';
import 'package:nexus/core/agent/executor.dart';
import 'package:nexus/core/agent/fast_path.dart';
import 'package:nexus/core/agent/kill_switch.dart';
import 'package:nexus/core/agent/ollama_backend.dart';
import 'package:nexus/core/agent/plan_validator.dart';
import 'package:nexus/core/agent/planner.dart';
import 'package:nexus/core/agent/registry.dart';
import 'package:nexus/core/agent/risk.dart';
import 'package:nexus/core/agent/rollback.dart';
import 'package:nexus/core/agent/run_log.dart';
import 'package:nexus/core/agent/tool.dart';
import 'package:nexus/core/agent/tools/detached_runner.dart';
import 'package:nexus/core/agent/tools/revert_guard.dart';
import 'package:nexus/core/agent/undo.dart';
import 'package:nexus/core/agent/verification.dart';

import 'agent_fixtures.dart';

/// A high-risk tool that would delete a saved profile. It counts its calls so
/// the evidence can show it was never executed.
class _ProfileDeleteTool extends Tool {
  int calls = 0;

  @override
  String get name => 'wifi_profile_delete';

  @override
  String get description => 'Delete a saved Wi-Fi profile on a device.';

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
    return 'deleted the profile on ${args['device']}';
  }

  @override
  Future<VerificationResult> verify(Map<String, Object?> args) async =>
      const VerificationResult.ok('the profile is gone');

  @override
  Future<RollbackResult> Function()? rollback(Map<String, Object?> args) =>
      () async => const RollbackResult.ok('the profile is back');
}

void main() {
  test('live: one real agent runs end to end on this PC', () async {
    final Directory dir = Directory.systemTemp.createTempSync('nexus-live-');
    final AgentStore store = AgentStore(
      explicitPath: '${dir.path}/agents.json',
    );
    await store.load();
    final RunLog log = RunLog(explicitPath: '${dir.path}/agent-runs.jsonl');
    final KillSwitch halt = KillSwitch();
    final UndoJournal undo = UndoJournal();
    final RevertGuard guard = RevertGuard(
      runner: const SystemDetachedRunner(),
      stateDir: Directory('${dir.path}/revert'),
    );
    final ToolRegistry registry = realAgentTools(guard: guard);
    final OllamaBackend backend = OllamaBackend();
    final AgentService service = AgentService(
      store: store,
      halt: halt,
      undo: undo,
      runLog: log,
      runner: PlannedAgentRunner(
        planner: Planner(backend: backend, registry: registry),
        validator: PlanValidator(registry),
        executor: Executor(registry: registry, killSwitch: halt),
        runLog: log,
        killSwitch: halt,
        undo: undo,
      ).call,
    );

    String model;
    try {
      model = await backend.resolveModel();
    } catch (error) {
      model = 'UNAVAILABLE: $error';
    }
    // ignore: avoid_print
    print('MODEL=$model');
    // ignore: avoid_print
    print('TOOLS=${registry.names.join(',')}');

    Future<void> show(String tag, String name) async {
      final int before = log.entries.length;
      final AgentRun run = await service.runNow(name);
      // ignore: avoid_print
      print('$tag/RESULT ok=${run.ok} said=${run.result}');
      // ignore: avoid_print
      print('$tag/STORED=${store.agent(name)!.lastResult}');
      final List<RunLogEntry> added = log.entries.take(
        log.entries.length - before,
      ).toList().reversed.toList();
      for (final RunLogEntry entry in added) {
        // ignore: avoid_print
        print('$tag/LOG ${entry.line}');
      }
    }

    await _withAgent(store, 'Wi-Fi check', 'check my wifi signal and speed');
    await show('A', 'Wi-Fi check');

    // A2: the same ask with the fast path switched off, so the installed model
    // is the thing that makes the plan and the real tools are still the ones
    // that run. Diagnostic, not a proof: the installed 2 GB model planned this
    // ask in one measured probe (two read steps, 56s) and asked a clarifying
    // question on another attempt, so the assertion below is that the run is
    // either planned or honestly reported as not run — never a hang, never a
    // false success.
    final KillSwitch modelHalt = KillSwitch();
    final AgentStore modelStore = AgentStore(
      explicitPath: '${dir.path}/agents.json',
    );
    await modelStore.load();
    final AgentService modelService = AgentService(
      store: modelStore,
      halt: modelHalt,
      runLog: log,
      runner: PlannedAgentRunner(
        planner: Planner(
          backend: backend,
          registry: registry,
          fastPath: const PlanFastPath.off(),
        ),
        validator: PlanValidator(registry),
        executor: Executor(registry: registry, killSwitch: modelHalt),
        runLog: log,
        killSwitch: modelHalt,
      ).call,
    );
    // Naming the tools keeps the ask unambiguous for a 2 GB model: the
    // catalogue it sees holds the change tools too (the agent's allow-list is
    // enforced at execution, not in the prompt), and open-ended wordings made
    // it ask which band and which DNS servers instead of reading. Measured
    // with the real prompt: this wording plans two read steps in about 56s.
    await _withAgent(
      modelStore,
      'Model check',
      'Run wifi_status and wifi_signal on this PC and tell me what they report. '
      'You have everything you need; ask no questions.',
    );
    final int beforeA2 = log.entries.length;
    final AgentRun runA2 = await modelService.runNow('Model check');
    // ignore: avoid_print
    print('A2/RESULT ok=${runA2.ok} said=${runA2.result}');
    // ignore: avoid_print
    print('A2/STORED=${modelStore.agent('Model check')!.lastResult}');
    for (final RunLogEntry entry in log.entries
        .take(log.entries.length - beforeA2)
        .toList()
        .reversed) {
      // ignore: avoid_print
      print('A2/LOG ${entry.line}');
    }
    // ignore: avoid_print
    print('A2/PLANNER_CALLS=${backend.calls}');

    // B: a high-risk step, unattended. The plan is stated so the evidence does
    // not depend on how the model words a delete.
    final _ProfileDeleteTool deleter = _ProfileDeleteTool();
    final ToolRegistry risky = ToolRegistry(<Tool>[
      ...registry.tools,
      deleter,
    ]);
    final KillSwitch riskyHalt = KillSwitch();
    final RunLog riskyLog = RunLog(
      explicitPath: '${dir.path}/agent-runs.jsonl',
    );
    await riskyLog.load();
    final AgentStore riskyStore = AgentStore(
      explicitPath: '${dir.path}/agents.json',
    );
    await riskyStore.load();
    final AgentService riskyService = AgentService(
      store: riskyStore,
      halt: riskyHalt,
      runLog: riskyLog,
      runner: PlannedAgentRunner(
        planner: Planner(
          backend: ScriptedBackend(<String, String>{
            'wipe a saved wifi profile on this PC':
                '{"goal": "wipe a saved wifi profile on this PC", "steps": ['
                '{"tool": "wifi_profile_delete", "args": {"device": "this PC"}, '
                '"description": "Delete the saved Wi-Fi profile on this PC"}], '
                '"questions": []}',
          }),
          registry: risky,
        ),
        validator: PlanValidator(risky),
        executor: Executor(registry: risky, killSwitch: riskyHalt),
        runLog: riskyLog,
        killSwitch: riskyHalt,
      ).call,
    );
    final AgentDefinition riskyAgent = AgentDefinition(
      name: 'Profile cleaner',
      goal: 'wipe a saved wifi profile on this PC',
      tools: const <String>['wifi_profile_delete'],
      schedule: '9:00-18:00 on weekdays',
      approval: AgentApprovalPolicy.askDestructive,
    )..status = AgentStatus.running;
    await riskyStore.put(riskyAgent);
    final int beforeB = riskyLog.entries.length;
    final AgentRun runB = await riskyService.runNow('Profile cleaner');
    // ignore: avoid_print
    print('B/RESULT ok=${runB.ok} said=${runB.result}');
    // ignore: avoid_print
    print('B/TOOL_CALLS=${deleter.calls}');
    final List<RunLogEntry> addedB = riskyLog.entries
        .take(riskyLog.entries.length - beforeB)
        .toList()
        .reversed
        .toList();
    for (final RunLogEntry entry in addedB) {
      // ignore: avoid_print
      print('B/LOG ${entry.line}');
    }

    // C: no Ollama answering, on a goal the fast path does not know — so the
    // model really is the thing that fails.
    final OllamaBackend dead = OllamaBackend(
      baseUrl: 'http://127.0.0.1:9',
      timeout: const Duration(seconds: 5),
    );
    final KillSwitch deadHalt = KillSwitch();
    final AgentStore deadStore = AgentStore(
      explicitPath: '${dir.path}/agents.json',
    );
    await deadStore.load();
    final AgentService deadService = AgentService(
      store: deadStore,
      halt: deadHalt,
      now: () => DateTime(2026, 11, 6, 10),
      runner: PlannedAgentRunner(
        planner: Planner(
          backend: dead,
          registry: registry,
          fastPath: const PlanFastPath.off(),
        ),
        validator: PlanValidator(registry),
        executor: Executor(registry: registry, killSwitch: deadHalt),
        runLog: log,
        killSwitch: deadHalt,
      ).call,
    );
    final int beforeC = log.entries.length;
    final AgentRun runC = await deadService.runNow('Model check');
    // ignore: avoid_print
    print('C/RESULT ok=${runC.ok} said=${runC.result}');
    // ignore: avoid_print
    print('C/STORED=${deadStore.agent('Model check')!.lastResult}');
    for (final RunLogEntry entry in log.entries
        .take(log.entries.length - beforeC)
        .toList()
        .reversed) {
      // ignore: avoid_print
      print('C/LOG ${entry.line}');
    }

    expect(model, isNot(contains('UNAVAILABLE')));
    expect(runB.ok, isFalse);
    expect(
      runA2.ok || runA2.result.startsWith('not run:'),
      isTrue,
      reason: 'the model either planned it or asked a question, never hung',
    );
    expect(deleter.calls, 0);
    expect(runC.ok, isFalse);
  }, timeout: const Timeout(Duration(minutes: 5)));
}

/// Stores an agent whose only tools are the three read-only network ones.
Future<void> _withAgent(AgentStore store, String name, String goal) async {
  await store.put(
    AgentDefinition(
      name: name,
      goal: goal,
      tools: const <String>['wifi_status', 'wifi_signal', 'wifi_speed'],
      schedule: '9:00-18:00 on weekdays',
      approval: AgentApprovalPolicy.askDestructive,
    )..status = AgentStatus.running,
  );
}
