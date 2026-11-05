// Planner reliability, offline: the schema, the repair loop, the questions, and
// the goals that never reach the model.
//
// The live rate against a real model is measured separately in
// `test/planner_live_smoke.dart`. What is pinned here is the machinery that
// makes that rate possible — a schema built from the registry, a rejected plan
// sent back with its faults at most twice, and a question instead of a guess
// whenever an argument was never said.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent/fast_path.dart';
import 'package:nexus/core/agent/plan_validator.dart';
import 'package:nexus/core/agent/planner.dart';
import 'package:nexus/core/agent/registry.dart';
import 'package:nexus/core/agent/tools/command_runner.dart';
import 'package:nexus/core/agent/tools/detached_runner.dart';
import 'package:nexus/core/agent/tools/net_change_tools.dart';
import 'package:nexus/core/agent/tools/net_read_tools.dart';
import 'package:nexus/core/agent/tools/revert_guard.dart';
import 'package:nexus/core/agent/tool.dart';
import 'package:nexus/core/local_ai_service.dart' show AiTurn;
import 'package:nexus/core/text_generation_backend.dart';

/// A model that answers from a list, in order, and remembers what it was asked.
class _Scripted implements TextGenerationBackend {
  _Scripted(this.replies);

  final List<String> replies;
  final List<String> prompts = <String>[];

  @override
  Stream<String> generateStream(String prompt, {List<AiTurn>? history}) async* {
    prompts.add(prompt);
    final index = prompts.length - 1;
    yield index < replies.length ? replies[index] : replies.last;
  }
}

/// The same, plus the structured-output capability.
class _Structured extends _Scripted implements StructuredGeneration {
  _Structured(super.replies);

  final List<Map<String, Object?>> schemas = <Map<String, Object?>>[];

  @override
  Stream<String> generateStructured(
    String prompt, {
    required Map<String, Object?> schema,
    List<AiTurn>? history,
  }) {
    schemas.add(schema);
    return generateStream(prompt, history: history);
  }
}

class _NoCommands implements CommandRunner {
  @override
  Future<CommandResult> run(String executable, List<String> args) async =>
      const CommandResult(exitCode: 1, stdout: '', stderr: 'not run');
}

class _NoDetach implements DetachedRunner {
  @override
  Future<int> start(String scriptPath) async => 0;
}

const String _goodPlan =
    '{"goal":"read the wifi","steps":[{"tool":"wifi_status","args":{},'
    '"description":"Read the Wi-Fi status"}],"questions":[]}';

/// A plan with a step that has no description — a validator fault.
const String _noDescription =
    '{"goal":"read the wifi","steps":[{"tool":"wifi_status","args":{},'
    '"description":""}],"questions":[]}';

const String _madeUpTool =
    '{"goal":"read the wifi","steps":[{"tool":"wifi_magic","args":{},'
    '"description":"Do something magic"}],"questions":[]}';

const String _bandNoArgs =
    '{"goal":"change the band","steps":[{"tool":"wifi_band_set","args":{},'
    '"description":"Change the band"}],"questions":[]}';

void main() {
  late Directory dir;
  late ToolRegistry registry;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nexus_planner_reliability');
    final guard = RevertGuard(runner: _NoDetach(), stateDir: dir);
    registry = ToolRegistry(<Tool>[
      ...networkReadTools(_NoCommands()),
      ...networkChangeTools(runner: _NoCommands(), guard: guard),
    ]);
  });

  tearDown(() => dir.deleteSync(recursive: true));

  Planner plannerFor(
    TextGenerationBackend backend, {
    String? connection,
  }) => Planner(
    backend: backend,
    registry: registry,
    fastPath: PlanFastPath(currentConnection: () => connection),
  );

  test('the schema has one branch per registered tool', () {
    final schema = plannerFor(_Scripted(<String>[_goodPlan])).schema;
    final steps = (schema['properties']! as Map)['steps'] as Map;
    final items = steps['items'] as Map;
    final branches = (items['anyOf']! as List).cast<Map<Object?, Object?>>();

    Map<Object?, Object?> branchFor(String name) => branches.firstWhere(
      (branch) =>
          (((branch['properties']! as Map)['tool']! as Map)['enum']! as List)
                  .single ==
              name,
    );

    expect(branches, hasLength(registry.names.length));
    expect(
      <String>[
        for (final branch in branches)
          (((branch['properties']! as Map)['tool']! as Map)['enum']! as List)
                  .single
              as String,
      ]..sort(),
      registry.names,
    );

    // A read-only tool takes no arguments, so its step cannot gain one — this
    // is the failure the old shared `args` object caused on llama3.2.
    final statusArgs =
        (branchFor('wifi_status')['properties']! as Map)['args']! as Map;
    expect(statusArgs['properties'], isEmpty);
    expect(statusArgs['additionalProperties'], isFalse);

    // A change tool's branch carries exactly its own arguments, with types.
    final bandArgs =
        (branchFor('wifi_band_set')['properties']! as Map)['args']! as Map;
    final bandProps = bandArgs['properties']! as Map;
    expect(bandProps.keys, containsAll(<String>['connection', 'value']));
    expect((bandProps['connection']! as Map)['type'], 'string');
    expect(
      (branchFor('wifi_status')['required'] as List),
      containsAll(<String>['tool', 'args', 'description']),
    );
  });

  test('a structured backend is handed the schema with the prompt', () async {
    final backend = _Structured(<String>[_goodPlan]);

    final proposal = await plannerFor(backend).propose(goal: 'how is my wifi');

    expect(backend.schemas, hasLength(1));
    expect(
      ((backend.schemas.single['properties']! as Map)['steps']! as Map)['type'],
      'array',
    );
    expect(PlanValidator(registry).validate(proposal), isA<PlanAccepted>());
  });

  test('a rejected plan is sent back with its faults, and the repair is used', () async {
    final backend = _Scripted(<String>[_noDescription, _goodPlan]);
    final planner = plannerFor(backend);

    final proposal = await planner.propose(goal: 'how is my wifi');

    expect(backend.prompts, hasLength(2));
    expect(
      backend.prompts.last,
      contains('the step has no plain-words description'),
      reason: 'the model is shown the rule it actually broke',
    );
    final validation = planner.validator.validate(proposal);
    expect(validation, isA<PlanAccepted>());
    expect(
      (validation as PlanAccepted).notes.join(' '),
      contains('one repair'),
    );
  });

  test('the repair loop gives up after two repairs, not never', () async {
    final backend = _Scripted(<String>[_madeUpTool]);
    final planner = plannerFor(backend);

    final proposal = await planner.propose(goal: 'how is my wifi');

    expect(backend.prompts, hasLength(3), reason: 'first answer plus two repairs');
    final validation = planner.validator.validate(proposal);
    expect(validation, isA<PlanRejected>());
    expect(
      (validation as PlanRejected).faults.join(' '),
      contains('wifi_magic'),
    );
    expect(proposal.notes.join(' '), contains('3 times'));
  });

  test('missing arguments become one plain-words question, never a guess', () async {
    final backend = _Scripted(<String>[_bandNoArgs]);
    final planner = plannerFor(backend);

    final proposal = await planner.propose(
      goal: 'do the wi-fi thing on my laptop',
    );
    final validation = planner.validator.validate(proposal);

    expect(backend.prompts, hasLength(1), reason: 'a question is an answer');
    expect(validation, isA<PlanRejected>());
    final rejected = validation as PlanRejected;
    expect(rejected.faults, isEmpty);
    expect(rejected.questions, hasLength(1));
    expect(rejected.questions.single, contains('connection'));
    expect(rejected.questions.single, contains('value'));
    expect(isAnswerable(validation), isTrue);
  });

  test('a known read is planned without asking the model', () async {
    final backend = _Scripted(<String>[_goodPlan]);
    final planner = plannerFor(backend);

    final signal = await planner.propose(goal: 'what is my wifi signal');
    final speed = await planner.propose(goal: 'how fast is the link rate');
    final status = await planner.propose(goal: 'wifi status please');

    expect(
      <String>[
        signal.steps.single.tool,
        speed.steps.single.tool,
        status.steps.single.tool,
      ],
      <String>['wifi_signal', 'wifi_speed', 'wifi_status'],
    );
    expect(backend.prompts, isEmpty, reason: 'no model was asked anything');
    expect(
      signal.notes.join(' '),
      contains('without the model'),
      reason: 'the plan says it took the cheap path',
    );
  });

  test('a known band change uses the connection in use, and no model', () async {
    final backend = _Scripted(<String>[_goodPlan]);
    final planner = plannerFor(backend, connection: 'Freebox-CA82DC');

    final plan = await planner.propose(goal: 'make my laptop use 5ghz only');

    expect(backend.prompts, isEmpty);
    expect(plan.steps.single.tool, 'wifi_band_set');
    expect(plan.steps.single.args['connection'], 'Freebox-CA82DC');
    expect(plan.steps.single.args['value'], 'a');
    expect(PlanValidator(registry).validate(plan), isA<PlanAccepted>());
  });

  test('"change my DNS" is not planned as a band change', () async {
    final backend = _Scripted(<String>[_goodPlan]);
    final planner = plannerFor(backend, connection: 'Freebox-CA82DC');

    final plan = await planner.propose(goal: 'change my dns to 1.1.1.1');
    final trap = await planner.propose(goal: 'set the band to 2.4ghz');

    expect(plan.steps.single.tool, 'wifi_dns_set');
    expect(plan.steps.single.args['value'], '1.1.1.1');
    expect(trap.steps.single.tool, 'wifi_band_set');
    expect(trap.steps.single.args['value'], 'bg');
    expect(backend.prompts, isEmpty);
  });

  test('a missing value is asked for, not invented', () async {
    final backend = _Scripted(<String>[_goodPlan]);
    final planner = plannerFor(backend);

    final dns = await planner.propose(goal: 'change my dns');
    final band = await planner.propose(goal: 'switch to 5ghz');

    expect(dns.steps, isEmpty);
    expect(dns.questions.single, contains('DNS servers'));
    expect(band.steps, isEmpty);
    expect(band.questions.single, contains('connection'));
    expect(backend.prompts, isEmpty, reason: 'an ask is cheaper than a guess');
  });

  test('an unknown goal still goes to the model', () async {
    final backend = _Scripted(<String>[_goodPlan]);
    final planner = plannerFor(backend);

    await planner.propose(goal: 'write me a haiku about my wifi router');

    expect(backend.prompts, hasLength(1));
    expect(backend.prompts.single, contains('The ask: write me a haiku'));
  });
}
