// The planner against the model this PC actually has, on ten messy asks.
//
// Not part of the suite: no `_test` suffix, so the default glob skips it, and it
// needs Ollama running with a model pulled. Run it explicitly:
//
//   flutter test test/planner_live_smoke.dart
//
// It measures the rate item 3b is about: a plan the validator accepts, or one
// clear question. Three things are counted separately because they fail
// differently:
//   * whether the ask was planned by the fast path, without a model at all;
//   * whether the model's reply could be read as JSON;
//   * whether the plan inside it survived `PlanValidator` — or became one
//     question instead of a guess.
//
// The backend sends the registry's schema in Ollama's `format` field, which is
// what structured outputs need; `calls` per ask shows how many repairs it took.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
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

const String _baseUrl = 'http://127.0.0.1:11434';

/// Ollama's `/api/generate`, one whole reply per call, with the schema in
/// `format` when the planner asks for one.
class _OllamaBackend implements TextGenerationBackend, StructuredGeneration {
  _OllamaBackend(this.model);

  final String model;

  /// How many replies this backend produced, so a repair is visible.
  int calls = 0;

  @override
  Stream<String> generateStream(String prompt, {List<AiTurn>? history}) =>
      _ask(prompt, null);

  @override
  Stream<String> generateStructured(
    String prompt, {
    required Map<String, Object?> schema,
    List<AiTurn>? history,
  }) => _ask(prompt, schema);

  Stream<String> _ask(String prompt, Map<String, Object?>? schema) async* {
    calls++;
    final response = await http
        .post(
          Uri.parse('$_baseUrl/api/generate'),
          headers: <String, String>{'content-type': 'application/json'},
          body: jsonEncode(<String, Object?>{
            'model': model,
            'prompt': prompt,
            'stream': false,
            'format': ?schema,
            'options': <String, Object?>{
              'temperature': 0.1,
              'num_predict': 500,
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

/// Clean, vague, wrong-tool traps, and asks with an argument left out.
const List<String> _messyAsks = <String>[
  'what is my wifi signal',
  'change my dns to 1.1.1.1',
  'my wifi is slow can you fix it',
  'set the band to 2.4ghz',
  'turn off wifi power saving',
  'why does my internet keep dropping',
  'make me use 5 ghz only',
  'set dns',
  'how fast is the link rate right now',
  'switch to 5ghz and set dns to 1.1.1.1',
];

Future<List<String>> _installedModels() async {
  final response = await http.get(Uri.parse('$_baseUrl/api/tags'));
  if (response.statusCode != 200) {
    throw StateError('ollama tags answered ${response.statusCode}');
  }
  final decoded = jsonDecode(response.body);
  final models = <String>[];
  if (decoded is Map) {
    for (final entry in decoded['models'] as List? ?? const <Object?>[]) {
      if (entry is Map && entry['name'] != null) {
        models.add(entry['name'].toString());
      }
    }
  }
  return models;
}

Future<({int answerable, int json, int fast, int planCalls})> _measure(
  String model,
  Directory stateDir,
  String? connection,
) async {
  final guard = RevertGuard(runner: _NoDetach(), stateDir: stateDir);
  final registry = ToolRegistry(<Tool>[
    ...networkReadTools(_NoCommands()),
    ...networkChangeTools(runner: _NoCommands(), guard: guard),
  ]);
  final backend = _OllamaBackend(model);
  final planner = Planner(
    backend: backend,
    registry: registry,
    fastPath: PlanFastPath(
      currentConnection: connection == null ? null : () => connection,
    ),
  );

  var answerable = 0;
  var json = 0;
  var fast = 0;
  var modelCalls = 0;

  for (final (index, ask) in _messyAsks.indexed) {
    backend.calls = 0;
    final proposal = await planner.propose(goal: ask);
    final validation = planner.validator.validate(proposal);
    final quick = proposal.notes.any(
      (note) => note.contains('without the model'),
    );
    if (quick) fast++;
    if (proposal.readable) json++;
    modelCalls += backend.calls;
    final ok = isAnswerable(validation);
    if (ok) answerable++;
    final detail = switch (validation) {
      PlanAccepted(:final plan) =>
        'steps=${plan.steps.map((step) => step.tool).join(',')}',
      PlanRejected(:final faults, :final questions) when faults.isEmpty =>
        'asks=${questions.join(' | ')}',
      PlanRejected(:final faults) => 'faults=${faults.join(' | ')}',
    };
    // ignore: avoid_print
    print(
      'ASK ${index + 1} [$model]: $ask\n'
      '  ok=$ok fast=$quick json=${proposal.readable} '
      'calls=${backend.calls} $detail',
    );
  }

  return (
    answerable: answerable,
    json: json,
    fast: fast,
    planCalls: modelCalls,
  );
}

void main() {
  test('live: ten messy asks, fast path, schema and repairs', () async {
    final stateDir = Directory.systemTemp.createTempSync('nexus_planner_live');
    addTearDown(() => stateDir.deleteSync(recursive: true));

    // The connection in use, so the fast path can plan a band or DNS change
    // without asking which network. Read-only: this never changes anything.
    final report = await readWifiReport(const SystemCommandRunner());
    // ignore: avoid_print
    print('CONNECTION=${report.connection} (${report.summary})');

    final installed = await _installedModels();
    // ignore: avoid_print
    print('INSTALLED=$installed');

    final models = <String>{
      'llama3.2:latest',
      if (installed.isNotEmpty)
        installed.reduce((a, b) => a.length >= b.length ? a : b),
    };

    for (final model in models) {
      final result = await _measure(model, stateDir, report.connection);
      // ignore: avoid_print
      print(
        'RESULT [$model] answerable=${result.answerable}/${_messyAsks.length} '
        'fast_path=${result.fast} readable_json=${result.json} '
        'model_calls=${result.planCalls}',
      );
      expect(
        result.json,
        greaterThan(0),
        reason: 'the model has to answer at all for this to measure anything',
      );
    }
    if (models.length == 1) {
      // ignore: avoid_print
      print(
        'NOTE: only one model is installed on this PC, so llama3.2:latest is '
        'both the "llama3.2" and the "largest installed" measurement.',
      );
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
