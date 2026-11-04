// The rules the executor exists to enforce, each pinned by a test that would
// fail if the rule were only a sentence in the prompt.
//
//   * an unregistered tool fails the whole plan, and nothing runs;
//   * a change not covered by the approval throws before anything runs, and
//     "yes" to step one is not "yes" to step three;
//   * a step that does not verify is put back, newest-first;
//   * the kill switch is checked before every step, not once at the start;
//   * a destructive step has to name its device in the words the user reads;
//   * a tool that makes a change it cannot undo may not be registered.
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent/approval.dart';
import 'package:nexus/core/agent/executor.dart';
import 'package:nexus/core/agent/fake_device.dart';
import 'package:nexus/core/agent/fake_tools.dart';
import 'package:nexus/core/agent/kill_switch.dart';
import 'package:nexus/core/agent/plan.dart';
import 'package:nexus/core/agent/plan_validator.dart';
import 'package:nexus/core/agent/registry.dart';
import 'package:nexus/core/agent/risk.dart';
import 'package:nexus/core/agent/rollback.dart';
import 'package:nexus/core/agent/tool.dart';
import 'package:nexus/core/agent/verification.dart';

/// A change that applies and then fails its own verification — the half-applied
/// state the unwind exists for.
class _HalfAppliedTool extends Tool {
  bool restored = false;

  @override
  String get name => 'network_off';

  @override
  String get description => 'Turn the network off on this device.';

  @override
  RiskTier get risk => RiskTier.change;

  @override
  bool get reversible => true;

  @override
  Map<String, ToolArg> get args => const <String, ToolArg>{};

  @override
  Future<String> run(Map<String, Object?> args) async =>
      'turned the network off';

  @override
  Future<VerificationResult> verify(Map<String, Object?> args) async =>
      const VerificationResult.failed('the network still answers');

  @override
  Future<RollbackResult> Function()? rollback(Map<String, Object?> args) =>
      () async {
        restored = true;
        return const RollbackResult.ok('network back on');
      };
}

/// A destructive step, to check the device-name rule.
class _ResetTool extends Tool {
  @override
  String get name => 'reset_network';

  @override
  String get description => 'Reset the network settings on a device.';

  @override
  RiskTier get risk => RiskTier.destructive;

  @override
  bool get reversible => true;

  @override
  Map<String, ToolArg> get args => const <String, ToolArg>{
    'device': ToolArg(ArgType.text, example: 'this PC'),
  };

  @override
  Future<String> run(Map<String, Object?> args) async => 'reset the network';

  @override
  Future<VerificationResult> verify(Map<String, Object?> args) async =>
      const VerificationResult.ok('settings at defaults');

  @override
  Future<RollbackResult> Function()? rollback(Map<String, Object?> args) =>
      () async => const RollbackResult.ok('settings restored');
}

/// A change with no rollback: refused at registration.
class _UnreversibleTool extends Tool {
  @override
  String get name => 'rewrite_everything';

  @override
  String get description => 'Change a setting that cannot be changed back.';

  @override
  RiskTier get risk => RiskTier.change;

  @override
  Map<String, ToolArg> get args => const <String, ToolArg>{};

  @override
  Future<String> run(Map<String, Object?> args) async => 'changed it';

  @override
  Future<VerificationResult> verify(Map<String, Object?> args) async =>
      const VerificationResult.ok('changed');
}

Plan _validated(ToolRegistry registry, List<ProposedStep> steps) {
  final validation = PlanValidator(registry)
      .validate(ProposedPlan(goal: 'test', steps: steps));
  return (validation as PlanAccepted).plan;
}

void main() {
  test('an unregistered tool fails the whole plan and nothing runs', () {
    final device = FakeDevice();
    final registry = ToolRegistry(fakeTools(device));

    final validation = PlanValidator(registry).validate(
      const ProposedPlan(
        goal: 'set up wifi and then wipe the disk',
        steps: <ProposedStep>[
          ProposedStep(tool: 'wifi_status', description: 'Look at Wi-Fi'),
          ProposedStep(tool: 'delete_everything', description: 'Delete it all'),
        ],
      ),
    );

    expect(validation, isA<PlanRejected>());
    final rejected = validation as PlanRejected;
    expect(rejected.faults.single, contains('delete_everything'));
    expect(rejected.faults.single, contains('not a tool I have'));
    expect(device.band, '2.4ghz');
  });

  test(
    'a change the approval does not cover throws before anything runs',
    () async {
      final device = FakeDevice();
      final registry = ToolRegistry(fakeTools(device));
      final plan = _validated(registry, const <ProposedStep>[
        ProposedStep(
          tool: 'wifi_status',
          description: 'Look at the current Wi-Fi settings',
        ),
        ProposedStep(
          tool: 'wifi_set',
          args: <String, Object?>{'band': 'auto', 'guest': true},
          description: 'Switch Wi-Fi to the best speed',
        ),
      ]);
      final executor = Executor(registry: registry);

      // "Yes" to the reading step is not "yes" to the change: this approval was
      // built from a plan holding only the first step.
      final narrow = Plan(goal: plan.goal, steps: <PlanStep>[plan.steps.first]);
      final approval = Approval.granted(plan: narrow, words: 'yes');
      await expectLater(
        executor.run(plan, approval),
        throwsA(isA<TierNotApproved>()),
      );
      expect(device.band, '2.4ghz');
      expect(device.guestNetwork, isFalse);
    },
  );

  test('a denial covers nothing, so a change cannot run', () async {
    final device = FakeDevice();
    final registry = ToolRegistry(fakeTools(device));
    final plan = _validated(registry, const <ProposedStep>[
      ProposedStep(
        tool: 'wifi_set',
        args: <String, Object?>{'band': 'auto', 'guest': true},
        description: 'Switch Wi-Fi to the best speed',
      ),
    ]);
    final approval = Approval.denied(plan: plan, words: 'no');
    expect(approval.covers(plan.steps.single), isFalse);
    await expectLater(
      Executor(registry: registry).run(plan, approval),
      throwsA(isA<TierNotApproved>()),
    );
    expect(device.band, '2.4ghz');
  });

  test('a step that does not verify is put back', () async {
    final tool = _HalfAppliedTool();
    final registry = ToolRegistry(<Tool>[tool]);
    final plan = _validated(registry, const <ProposedStep>[
      ProposedStep(tool: 'network_off', description: 'Turn the network off'),
    ]);

    final report = await Executor(registry: registry)
        .run(plan, Approval.granted(plan: plan, words: 'yes'));

    expect(report.status, ExecutionStatus.failed);
    expect(report.failure, contains('still answers'));
    expect(tool.restored, isTrue, reason: 'the half-applied change is undone');
    expect(report.undone.single.ok, isTrue);
    expect(report.undone.single.what, 'network back on');
    expect(report.couldNotUndo, isEmpty);
    expect(report.verified, isEmpty);
  });

  test('a failing verification also unwinds the steps before it', () async {
    final device = FakeDevice();
    final half = _HalfAppliedTool();
    final registry = ToolRegistry(<Tool>[WifiSetupTool(device), half]);
    final plan = _validated(registry, const <ProposedStep>[
      ProposedStep(
        tool: 'wifi_set',
        args: <String, Object?>{'band': '5ghz', 'guest': true},
        description: 'Switch Wi-Fi to 5 GHz',
      ),
      ProposedStep(tool: 'network_off', description: 'Turn the network off'),
    ]);

    final report = await Executor(registry: registry)
        .run(plan, Approval.granted(plan: plan, words: 'yes'));

    expect(report.status, ExecutionStatus.failed);
    expect(half.restored, isTrue);
    expect(device.band, '2.4ghz', reason: 'the Wi-Fi change came back too');
    expect(device.guestNetwork, isFalse);
    expect(report.undone, hasLength(2));
  });

  test('the kill switch is checked before every step', () async {
    final device = FakeDevice();
    final registry = ToolRegistry(fakeTools(device));
    final plan = _validated(registry, const <ProposedStep>[
      ProposedStep(
        tool: 'wifi_set',
        args: <String, Object?>{'band': 'auto', 'guest': true},
        description: 'First: switch Wi-Fi to the best speed',
      ),
      ProposedStep(
        tool: 'agent_create',
        args: <String, Object?>{
          'name': 'Mail drafter',
          'goal': 'draft replies',
          'tools': 'mail_drafts',
        },
        description: 'Second: save an agent',
      ),
    ]);
    final kill = KillSwitch();
    final executor = Executor(registry: registry, killSwitch: kill);

    final report = await executor.run(
      plan,
      Approval.granted(plan: plan, words: 'yes'),
      onProgress: (line) {
        if (line.startsWith('First')) kill.trip();
      },
    );

    expect(report.status, ExecutionStatus.stopped);
    expect(report.stoppedAt!.description, startsWith('Second'));
    expect(device.band, 'auto', reason: 'the step already running finished');
    expect(
      device.savedAgents,
      isEmpty,
      reason: 'the step after the switch never started',
    );
  });

  test('a destructive step has to name its device', () {
    final registry = ToolRegistry(<Tool>[_ResetTool()]);

    final unnamed = PlanValidator(registry).validate(
      const ProposedPlan(
        goal: 'reset the network',
        steps: <ProposedStep>[
          ProposedStep(tool: 'reset_network', description: 'Reset the network'),
        ],
      ),
    );
    expect(unnamed, isA<PlanRejected>());
    expect(
      (unnamed as PlanRejected).faults.join(' '),
      contains('names no device'),
    );

    final unspoken = PlanValidator(registry).validate(
      const ProposedPlan(
        goal: 'reset the network',
        steps: <ProposedStep>[
          ProposedStep(
            tool: 'reset_network',
            args: <String, Object?>{'device': 'this PC'},
            description: 'Reset the network',
          ),
        ],
      ),
    );
    expect(unspoken, isA<PlanRejected>());
    expect(
      (unspoken as PlanRejected).faults.join(' '),
      contains('has to name the device (this PC)'),
    );

    final named = PlanValidator(registry).validate(
      const ProposedPlan(
        goal: 'reset the network',
        steps: <ProposedStep>[
          ProposedStep(
            tool: 'reset_network',
            args: <String, Object?>{'device': 'this PC'},
            description: 'Reset the network on this PC',
          ),
        ],
      ),
    );
    expect(named, isA<PlanAccepted>());
    expect(
      (named as PlanAccepted).plan.steps.single.risk,
      RiskTier.destructive,
    );
  });

  test('a tool that cannot undo its change may not be registered', () {
    expect(() => ToolRegistry(<Tool>[_UnreversibleTool()]), throwsStateError);
  });
}
