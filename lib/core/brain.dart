// The conversational brain — a local large language model served by Ollama
// (https://ollama.com), talking over its HTTP API on 127.0.0.1:11434.
//
// Everything runs on the user's own machine: no cloud, no account, no data
// leaves the device. When Ollama is missing, unreachable, or has no model
// installed, every call returns null and the assistant simply falls back to
// its normal rule-based answers — the brain is an upgrade, never a
// dependency.
//
// Phase 1 scope: conversational replies only. The command layer keeps its
// fast path; only phrases the interpreter does not understand are handed to
// the model. Actions are never invented by the model — the system prompt
// tells it to point the user at the real commands instead.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

/// One turn of conversation, mirroring the OpenAI-style message shape Ollama
/// speaks: `role` is `user` or `assistant` (system goes in the prompt).
typedef ChatTurn = ({String role, String content});

/// The outcome of one brain call. [text] is the reply when there is one.
/// When it is null, [reachable] says whether Ollama itself answered: true
/// means the server is fine but produced nothing usable (empty reply), false
/// means there is no brain to reach (server down, no model, timeout, error).
/// The caller uses the distinction so a quiet empty reply never gets
/// reported as "brain offline".
typedef BrainReply = ({String? text, bool reachable});

/// The model names Nexus prefers, in order. The first one installed wins; if
/// none are, the brain uses whatever single model the user has pulled.
const kPreferredModels = [
  'llama3.2:3b',
  'llama3.2',
  'qwen2.5:3b',
  'llama3.1:8b',
  'phi3:mini',
  'gemma2:2b',
  'mistral:7b',
];

/// Talks to a local Ollama server. All methods return null on any failure —
/// the caller decides what to do when the brain is unavailable.
class LocalBrain {
  final String baseUrl;
  final List<String> preferredModels;
  final Duration tagsTimeout;
  final Duration chatTimeout;

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 3);

  /// The resolved model name, cached after the first successful discovery.
  String? _model;

  LocalBrain({
    String? baseUrl,
    this.preferredModels = kPreferredModels,
    this.tagsTimeout = const Duration(seconds: 3),
    this.chatTimeout = const Duration(seconds: 90),
  }) : baseUrl =
           (baseUrl ?? Platform.environment['NEXUS_OLLAMA_URL'] ??
               'http://127.0.0.1:11434').replaceAll(RegExp(r'/+$'), '');

  /// The name of the model to use, or null when Ollama is not running (or has
  /// no models). Cached after the first successful lookup; pass [refresh]
  /// to re-discover (a newly pulled preferred model upgrades the choice —
  /// this is what the status line's tap-to-retry does).
  Future<String?> availableModel({bool refresh = false}) async {
    if (!refresh && _model != null) return _model;
    final names = await _installedModels();
    if (names == null || names.isEmpty) return null;
    _model = _pickModel(names);
    return _model;
  }

  /// Sends one conversational exchange and returns the assistant's reply.
  /// [BrainReply.reachable] distinguishes "no brain to reach" from "the
  /// server answered but produced nothing", so callers can tell a quiet
  /// empty reply apart from an offline Ollama.
  Future<BrainReply> reply({
    required String system,
    required List<ChatTurn> history,
    double temperature = 0.7,
    int maxTokens = 300,
  }) async {
    final model = await availableModel();
    if (model == null) return (text: null, reachable: false);
    final messages = [
      (role: 'system', content: system),
      ...history,
    ];
    try {
      final request = await _client
          .postUrl(Uri.parse('$baseUrl/api/chat'))
          .timeout(chatTimeout);
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({
        'model': model,
        'messages': [
          for (final turn in messages) {'role': turn.role, 'content': turn.content},
        ],
        'stream': false,
        'options': {'temperature': temperature, 'num_predict': maxTokens},
      }));
      final response = await request.close().timeout(chatTimeout);
      if (response.statusCode != 200) {
        debugPrint('BRAIN: Ollama answered ${response.statusCode}');
        return (text: null, reachable: false);
      }
      final body = jsonDecode(
        await response.transform(utf8.decoder).join().timeout(chatTimeout),
      ) as Map<String, dynamic>;
      final content = ((body['message'] as Map<String, dynamic>?)?['content']
              as String?)
          ?.trim();
      if (content == null || content.isEmpty) {
        debugPrint('BRAIN: Ollama returned an empty reply');
        return (text: null, reachable: true);
      }
      return (text: content, reachable: true);
    } on Object catch (e) {
      debugPrint('BRAIN: no local brain ($e)');
      return (text: null, reachable: false);
    }
  }

  /// The installed model names, or null when Ollama itself is unreachable.
  Future<List<String>?> _installedModels() async {
    try {
      final request = await _client
          .getUrl(Uri.parse('$baseUrl/api/tags'))
          .timeout(tagsTimeout);
      final response = await request.close().timeout(tagsTimeout);
      if (response.statusCode != 200) return null;
      final body = jsonDecode(
        await response.transform(utf8.decoder).join().timeout(tagsTimeout),
      ) as Map<String, dynamic>;
      return [
        for (final model in (body['models'] as List<dynamic>? ?? []))
          (model as Map<String, dynamic>)['name'] as String?,
      ].whereType<String>().toList();
    } on Object catch (e) {
      debugPrint('BRAIN: no local brain ($e)');
      return null;
    }
  }

  /// Picks the first preferred model that is installed — an exact name wins,
  /// then any tag of that family (`llama3.2` matches `llama3.2:latest`) —
  /// otherwise the first model the user has at all.
  String? _pickModel(List<String> installed) {
    for (final preferred in preferredModels) {
      if (installed.contains(preferred)) return preferred;
      final family = installed.where((name) => name.startsWith('$preferred:'));
      if (family.isNotEmpty) return family.first;
    }
    return installed.first;
  }
}