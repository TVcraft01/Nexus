// The real text-generation backend for agent planning: Ollama on this PC.
//
// It is the same contract the scripted test backend implements
// (`TextGenerationBackend` + `StructuredGeneration`), so the planner, the
// schema and the repair loop are unchanged — only the model is real.
//
// Two rules this file exists to keep:
//
//   * a model that is not running, has no model pulled, or answers nothing
//     usable is a *failure with a reason*, thrown as [OllamaUnavailable]. The
//     runner turns that into a failed run with that sentence; it never becomes
//     a hang (every call has a timeout) and never becomes a success;
//   * the model is the installed one. Nothing is downloaded here: if Ollama has
//     no model, the error says how to install one rather than pulling it.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../local_ai_service.dart' show AiTurn;
import '../text_generation_backend.dart';

/// Ollama cannot answer, for [message] — the sentence a run reports.
class OllamaUnavailable implements Exception {
  const OllamaUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

class OllamaBackend implements TextGenerationBackend, StructuredGeneration {
  OllamaBackend({
    this.baseUrl = 'http://127.0.0.1:11434',
    this.model,
    this.timeout = const Duration(seconds: 150),
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String baseUrl;

  /// The model to ask. Null means "the installed one", resolved once from
  /// `/api/tags` — the largest model installed, which is the best one this PC
  /// has without downloading anything.
  final String? model;

  /// How long one reply may take. Measured on this PC: a cold `llama3.2`
  /// planning prompt takes 20–60s while the machine is busy, so 90s was too
  /// tight and 150s is a bound rather than a guess — long enough to finish,
  /// short enough that a wedged model does not hold a scheduled run forever.
  /// The planner asks up to three times, so a run is still bounded by
  /// 3 × this.
  final Duration timeout;

  final http.Client _client;

  String? _resolved;

  /// How many replies this backend produced, so a repair is visible.
  int calls = 0;

  /// The model that will be asked, resolved and cached.
  Future<String> resolveModel() async {
    final String given = model?.trim() ?? '';
    if (given.isNotEmpty) return given;
    final String? cached = _resolved;
    if (cached != null) return cached;

    final http.Response response;
    try {
      response = await _client
          .get(Uri.parse('$baseUrl/api/tags'))
          .timeout(const Duration(seconds: 5));
    } catch (error) {
      throw OllamaUnavailable(
        'Ollama is not answering at $baseUrl (${_short(error)}). Start it, or '
        'install it, and try again.',
      );
    }
    if (response.statusCode != 200) {
      throw OllamaUnavailable(
        'Ollama answered ${response.statusCode} for /api/tags.',
      );
    }
    final List<({String name, int size})> installed = <({String name, int size})>[];
    try {
      final Object? decoded = jsonDecode(response.body);
      if (decoded is Map) {
        for (final Object? entry
            in (decoded['models'] as List?) ?? const <Object?>[]) {
          if (entry is! Map) continue;
          final String name = (entry['name'] ?? '').toString().trim();
          if (name.isEmpty) continue;
          final int size = entry['size'] is int ? entry['size'] as int : 0;
          installed.add((name: name, size: size));
        }
      }
    } on FormatException {
      throw const OllamaUnavailable('Ollama’s model list was not readable.');
    }
    if (installed.isEmpty) {
      throw const OllamaUnavailable(
        'Ollama is running but has no model installed. Pull one first, for '
        'example “ollama pull llama3.2”.',
      );
    }
    installed.sort((a, b) => b.size.compareTo(a.size));
    return _resolved = installed.first.name;
  }

  @override
  Stream<String> generateStream(String prompt, {List<AiTurn>? history}) =>
      _ask(prompt, null, history);

  @override
  Stream<String> generateStructured(
    String prompt, {
    required Map<String, Object?> schema,
    List<AiTurn>? history,
  }) => _ask(prompt, schema, history);

  Stream<String> _ask(
    String prompt,
    Map<String, Object?>? schema,
    List<AiTurn>? history,
  ) async* {
    calls++;
    final String chosen = await resolveModel();

    final http.Response response;
    try {
      response = await _client
          .post(
            Uri.parse('$baseUrl/api/generate'),
            headers: const <String, String>{'content-type': 'application/json'},
            body: jsonEncode(<String, Object?>{
              'model': chosen,
              'prompt': _withHistory(prompt, history),
              'stream': false,
              'format': ?schema,
              'options': <String, Object?>{
                'temperature': 0.1,
                'num_predict': 500,
              },
            }),
          )
          .timeout(timeout);
    } catch (error) {
      throw OllamaUnavailable(
        'the model call to $baseUrl failed (${_short(error)}).',
      );
    }
    if (response.statusCode != 200) {
      throw OllamaUnavailable(
        'Ollama answered ${response.statusCode} for /api/generate.',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw const OllamaUnavailable('Ollama’s reply was not readable JSON.');
    }
    if (decoded is! Map) {
      throw const OllamaUnavailable('Ollama’s reply was not an object.');
    }
    yield (decoded['response'] ?? '').toString();
  }

  /// The earlier turns, folded into the prompt: `/api/generate` takes one text,
  /// and a planner prompt is one object anyway.
  static String _withHistory(String prompt, List<AiTurn>? history) {
    if (history == null || history.isEmpty) return prompt;
    final List<String> lines = <String>[
      for (final AiTurn turn in history)
        '${turn.fromUser ? 'You' : 'Nexus'}: ${turn.text}',
    ];
    return 'Earlier conversation:\n${lines.join('\n')}\n\n$prompt';
  }

  static String _short(Object error) => error.toString().split('\n').first;
}
