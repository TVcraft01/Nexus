import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus/core/ollama_service.dart';

/// The PC's Ollama, on the wire.
///
/// The shell's own tests fake the *service* (see `main_ui_test.dart`), because
/// what they care about is what the screen does. These tests fake the *socket*,
/// because what they care about is what goes out and what comes back — the
/// request body Ollama is actually sent, and the four ways it can fail.
void main() {
  /// A service whose HTTP client is [handler], with a timeout short enough that
  /// a test can sit through it.
  OllamaService serviceFor(
    Future<http.Response> Function(http.Request request) handler, {
    Duration timeout = const Duration(seconds: 2),
    String baseUrl = 'http://192.168.1.100:11434',
  }) => OllamaService(
    baseUrl: baseUrl,
    timeout: timeout,
    client: MockClient(handler),
  );

  test('posts the plainest generate request and returns the response', () async {
    late http.Request seen;
    final OllamaService ollama = serviceFor((http.Request request) async {
      seen = request;
      return http.Response(
        jsonEncode(<String, Object?>{
          'model': kNexusOllamaModel,
          'response': '  Your Downloads folder has six items.  ',
          'done': true,
        }),
        200,
      );
    });

    final String answer = await ollama.generateResponse('what is in Downloads?');

    // The answer is the field, trimmed: Ollama's leading and trailing whitespace
    // is not the model's opinion about spacing.
    expect(answer, 'Your Downloads folder has six items.');

    // The request: the documented endpoint, and the three fields the design
    // names — `stream: false` above all, since streaming would make the live
    // page's "Thinking…" and the chat's placeholder both lies.
    expect(seen.method, 'POST');
    expect(seen.url.toString(), 'http://192.168.1.100:11434/api/generate');
    expect(seen.headers['Content-Type'], contains('application/json'));
    expect(jsonDecode(seen.body), <String, Object?>{
      'model': kNexusOllamaModel,
      'prompt': 'what is in Downloads?',
      'stream': false,
    });
  });

  test('a PC that is not there is one sentence, not a stack trace', () async {
    final OllamaService ollama = serviceFor(
      (http.Request request) async =>
          throw http.ClientException('Connection refused'),
    );

    await expectLater(
      ollama.generateResponse('hello'),
      throwsA(
        isA<OllamaException>().having(
          (OllamaException e) => e.message,
          'message',
          kNexusOllamaUnreachableText,
        ),
      ),
    );
  });

  test('a PC that is there but silent times out the same way', () async {
    final OllamaService ollama = serviceFor((http.Request request) async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      return http.Response('{"response":"too late"}', 200);
    }, timeout: const Duration(milliseconds: 30));

    await expectLater(
      ollama.generateResponse('hello'),
      throwsA(
        isA<OllamaException>().having(
          (OllamaException e) => e.message,
          'message',
          kNexusOllamaUnreachableText,
        ),
      ),
    );
  });

  test('an HTTP error names the status and the likely fix', () async {
    final OllamaService ollama = serviceFor(
      (http.Request request) async =>
          http.Response('{"error":"model not found"}', 404),
    );

    await expectLater(
      ollama.generateResponse('hello'),
      throwsA(
        isA<OllamaException>().having(
          (OllamaException e) => e.message,
          'message',
          allOf(contains('HTTP 404'), contains(kNexusOllamaModel)),
        ),
      ),
    );
  });

  test('a body that is not JSON is reported as an unreachable PC', () async {
    // The shape of a captive portal, or of the wrong port on the right machine:
    // something answers, and it is not Ollama.
    final OllamaService ollama = serviceFor(
      (http.Request request) async =>
          http.Response('<html><body>Sign in to Wi-Fi</body></html>', 200),
    );

    await expectLater(
      ollama.generateResponse('hello'),
      throwsA(
        isA<OllamaException>().having(
          (OllamaException e) => e.message,
          'message',
          kNexusOllamaUnreachableText,
        ),
      ),
    );
  });

  test('a 200 with nothing in it is its own sentence', () async {
    final OllamaService ollama = serviceFor(
      (http.Request request) async => http.Response('{"response":"   "}', 200),
    );

    await expectLater(
      ollama.generateResponse('hello'),
      throwsA(
        isA<OllamaException>().having(
          (OllamaException e) => e.message,
          'message',
          contains('answered with nothing'),
        ),
      ),
    );
  });

  test('a real socket in the shape of Ollama is answered for real', () async {
    // The fakes above prove what the service *sends*; this proves it can send it
    // — a real HTTP server on a real port, speaking the one response shape
    // Ollama speaks. It is the closest thing to the PC that can run in CI, and it
    // covers the part MockClient cannot: the socket, the headers, the encoding,
    // and a body that arrives in one piece.
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() => server.close(force: true));

    String? modelSeen;
    String? promptSeen;
    server.listen((HttpRequest request) async {
      expect(request.method, 'POST');
      expect(request.uri.path, '/api/generate');
      final Map<String, dynamic> payload =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      modelSeen = payload['model'] as String?;
      promptSeen = payload['prompt'] as String?;
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(<String, Object?>{
          'response': 'A local answer.',
          'done': true,
        }));
      await request.response.close();
    });

    final OllamaService ollama = OllamaService(
      baseUrl: 'http://127.0.0.1:${server.port}',
    );
    final String answer = await ollama.generateResponse('is anyone home?');

    expect(answer, 'A local answer.');
    expect(modelSeen, kNexusOllamaModel);
    expect(promptSeen, 'is anyone home?');
  });

  test('a port with nothing behind it is the unreachable sentence', () async {
    // Bind and immediately close, so the port is almost certainly free: this is
    // the phone-on-another-network case, minus the phone.
    final HttpServer probe = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final int port = probe.port;
    await probe.close();

    final OllamaService ollama = OllamaService(
      baseUrl: 'http://127.0.0.1:$port',
      timeout: const Duration(seconds: 2),
    );

    await expectLater(
      ollama.generateResponse('hello'),
      throwsA(
        isA<OllamaException>().having(
          (OllamaException e) => e.message,
          'message',
          kNexusOllamaUnreachableText,
        ),
      ),
    );
  });

  test('the default host is the machine the desktop build runs on', () {
    // A phone has to be pointed at the PC with
    // `--dart-define=NEXUS_OLLAMA_HOST=…`; the desktop build, which runs beside
    // Ollama, needs no argument at all.
    expect(const OllamaService().baseUrl, 'http://localhost:11434');
    expect(const OllamaService().model, kNexusOllamaModel);
    expect(const OllamaService().timeout, const Duration(seconds: 30));
  });
}
