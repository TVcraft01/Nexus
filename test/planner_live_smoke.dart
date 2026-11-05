// The planner against the model this PC actually has, on five messy asks.
//
// Not part of the suite: no `_test` suffix, so the default glob skips it, and it
// needs Ollama running with a model pulled. Run it explicitly:
//
//   flutter test test/planner_live_smoke.dart
//
// It measures two different things, because they fail differently:
//   * whether the model's reply can be read as JSON at all;
//   * whether the plan inside it survives `PlanValidator` — real tool names,
//     real argument names, nothing invented.
// The point is the rate, not a pass mark: a model that returns JSON every time
// and a valid plan half the time is a fact about the planner prompt that needs
// to be written down.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nexus/core/agent/plan_validator.dart';
import 'package:nexus/core/local_ai_service.dart' show AiTurn;
import 'package:nexus/core/agent/planner.dart';
import 'package:nexus/core/agent/registry.dart';
import 'package:nexus/core/agent/tools/command_runner.dart';
import 'package:nexus/core/agent/tools/detached_runner.dart';
import 'package:nexus/core/agent/tools/net_change_tools.dart';
import 'package:nexus/core/agent/tools/net_read_tools.dart';
import 'package:nexus/core/agent/tool.dart';
import 'package:nexus/core/agent/tools/revert_guard.dart';
import 'package:nexus/core/text_generation_backend.dart';

/// Ollama's `/api/generate`, one whole reply per call.
class _OllamaBackend implements TextGenerationBackend {
  /// The model Ollama was holding on this PC when this was written.
  static const String model = 'llama3.2:latest';

  @override
  Stream<String> generateStream(String prompt, {List<AiTurn>? history}) async* {
    final response = await http
        .post(
          Uri.parse('http://127.0.0.1:11434/api/generate'),
          headers: <String, String>{'content-type': 'application/json'},
          body: jsonEncode(<String, Object?>{
            'model': model,
            'prompt': prompt,
            'stream': false,
            'options': <String, Object?>{
              'temperature': 0.1,
              'num_predict': 400,
            },
          }),
        )
        .timeout(const Duration(minutes: 2));
    if (response.statusCode != 200) {
      throw StateError('ollama answered ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body);
    yield decoded is Map ? (decoded['response'] ?? '').toString() : '';
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

const List<String> _messyAsks = <String>[
  'my wifi is slow can you fix it',
  'turn off wifi power saving and tell me the signal',
  'set dns to 1.1.1.1 on my home network',
  'why does my internet keep dropping',
  'make my laptop use 5ghz only',
];

void main() {
  test('live: five messy asks through the real model and the validator', () async {
    final stateDir = Directory.systemTemp.createTempSync('nexus_planner_live');
    addTearDown(() => stateDir.deleteSync(recursive: true));
    final guard = RevertGuard(
      runner: _NoDetach(),
      stateDir: stateDir,
      window: const Duration(seconds: 5),
    );
    final registry = ToolRegistry(<Tool>[
      ...networkReadTools(_NoCommands()),
      ...networkChangeTools(runner: _NoCommands(), guard: guard),
    ]);
    final planner = Planner(backend: _OllamaBackend(), registry: registry);

    var readable = 0;
    var accepted = 0;
    for (final (index, ask) in _messyAsks.indexed) {
      final proposal = await planner.propose(goal: ask);
      final validation = PlanValidator(registry).validate(proposal);
      final ok = validation is PlanAccepted;
      if (proposal.readable) readable++;
      if (ok) accepted++;
      final detail = ok
          ? 'steps=${validation.plan.steps.map((step) => step.tool).join(',')}'
          : 'faults=${(validation as PlanRejected).faults.join(' | ')}';
      // ignore: avoid_print
      print(
        'ASK ${index + 1}: $ask\n'
        '  json=${proposal.readable} accepted=$ok $detail',
      );
    }

    // ignore: avoid_print
    print(
      'RESULT valid_json=$readable/${_messyAsks.length} '
      'accepted=$accepted/${_messyAsks.length}',
    );
    expect(
      readable,
      greaterThan(0),
      reason: 'the model has to answer at all for this to measure anything',
    );
  }, timeout: const Timeout(Duration(minutes: 5)));
}
