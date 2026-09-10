// LocalBrain against a fake Ollama server on loopback: model discovery,
// conversation payloads, and every graceful-degradation path.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/brain.dart';

void main() {
  late HttpServer server;
  late List<({String path, Map<String, dynamic>? json})> requests;

  /// Serves canned Ollama answers; the handler can be swapped per test.
  Future<void> start({
    Map<String, dynamic> Function()? tags,
    Map<String, dynamic> Function()? chat,
  }) async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    requests = [];
    server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      requests.add((
        path: request.uri.path,
        json: body.isEmpty ? null : jsonDecode(body) as Map<String, dynamic>,
      ));
      final Map<String, dynamic> response;
      switch (request.uri.path) {
        case '/api/tags':
          response = tags?.call() ?? {'models': []};
        case '/api/chat':
          response =
              chat?.call() ??
              {
                'model': 'llama3.2:3b',
                'message': {'role': 'assistant', 'content': 'hi there'},
                'done': true,
              };
        default:
          request.response.statusCode = 404;
          await request.response.close();
          return;
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(response));
      await request.response.close();
    });
  }

  tearDown(() async {
    await server.close(force: true);
  });

  LocalBrain brain({String? baseUrl}) =>
      LocalBrain(baseUrl: baseUrl ?? 'http://127.0.0.1:${server.port}');

  test('picks the preferred installed model and sends the conversation', () async {
    await start(tags: () => {
      'models': [
        {'name': 'mistral:7b'},
        {'name': 'llama3.2:3b'},
      ],
    });

    final reply = await brain().reply(
      system: 'You are Nexus.',
      history: [
        (role: 'user', content: 'hi'),
        (role: 'assistant', content: 'hello!'),
        (role: 'user', content: 'how are you?'),
      ],
    );

    expect(reply.text, 'hi there');
    expect(reply.reachable, isTrue);
    final chat = requests.singleWhere((r) => r.path == '/api/chat');
    expect(chat.json!['model'], 'llama3.2:3b');
    final messages = chat.json!['messages'] as List<dynamic>;
    expect(
      [for (final m in messages) m['role']],
      ['system', 'user', 'assistant', 'user'],
    );
    expect((messages.first as Map)['content'], 'You are Nexus.');
    expect((messages[3] as Map)['content'], 'how are you?');
    expect(chat.json!['stream'], false);
  });

  test('falls back to any installed model when none of the preferred exist',
      () async {
    await start(tags: () => {
      'models': [
        {'name': 'codellama:13b'},
      ],
    });

    expect(await brain().availableModel(), 'codellama:13b');
    expect((await brain().reply(system: 's', history: [])).text, 'hi there');
    final chat = requests.singleWhere((r) => r.path == '/api/chat');
    expect(chat.json!['model'], 'codellama:13b');
  });

  test('a preferred family matches any of its tags', () async {
    await start(tags: () => {
      'models': [
        {'name': 'llama3.2:latest'},
      ],
    });

    expect(await brain().availableModel(), 'llama3.2:latest');
  });

  test('refresh re-discovers the model after a new one is pulled', () async {
    var tags = {
      'models': [
        {'name': 'mistral:7b'},
      ],
    };
    await start(tags: () => tags);
    final b = brain();

    expect(await b.availableModel(), 'mistral:7b');
    tags = {
      'models': [
        {'name': 'llama3.2:3b'},
        {'name': 'mistral:7b'},
      ],
    };
    // The cache keeps the old choice…
    expect(await b.availableModel(), 'mistral:7b');
    // …and the retry re-discovers, upgrading to the preferred model.
    expect(await b.availableModel(refresh: true), 'llama3.2:3b');
  });

  test('returns null when Ollama has no models', () async {
    await start(tags: () => {'models': []});

    expect(await brain().availableModel(), isNull);
    final reply = await brain().reply(system: 's', history: []);
    expect(reply.text, isNull);
    expect(reply.reachable, isFalse);
    expect(requests.any((r) => r.path == '/api/chat'), isFalse);
  });

  test('returns null when Ollama is not running', () async {
    // Bind and close: the port is now free, so connecting is refused.
    final probe = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close(force: true);

    final offline = LocalBrain(baseUrl: 'http://127.0.0.1:$port');
    expect(await offline.availableModel(), isNull);
    final reply = await offline.reply(system: 's', history: []);
    expect(reply.text, isNull);
    expect(reply.reachable, isFalse);
  });

  test('an empty reply is reachable, not an outage', () async {
    await start(
      tags: () => {
        'models': [
          {'name': 'llama3.2:3b'},
        ],
      },
      chat: () => {
        'model': 'llama3.2:3b',
        'message': {'role': 'assistant', 'content': '   '},
        'done': true,
      },
    );

    final reply = await brain().reply(system: 's', history: []);
    expect(reply.text, isNull);
    expect(reply.reachable, isTrue); // the server answered — it is NOT down
  });

  test('returns null when Ollama answers with an error status', () async {
    // A 500 from the server must read as "no brain", not a crash.
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    requests = [];
    server.listen((request) async {
      await utf8.decoder.bind(request).join();
      request.response.statusCode = 500;
      await request.response.close();
    });

    final reply = await brain().reply(system: 's', history: []);
    expect(reply.text, isNull);
    expect(reply.reachable, isFalse);
  });

  test('normalizes a trailing slash in the base url', () async {
    await start(tags: () => {
      'models': [
        {'name': 'llama3.2:3b'},
      ],
    });

    expect(
      await LocalBrain(
        baseUrl: 'http://127.0.0.1:${server.port}/',
      ).availableModel(),
      'llama3.2:3b',
    );
  });

}
