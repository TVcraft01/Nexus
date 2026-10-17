// The on-device model, unit-tested with no native library, no model file, and
// no widget tree: the lazy load, the idle unload, the model pick, the
// download-and-verify, the queue, and the two seams the assistant really uses
// — an unknown phrase reaches the model, a command never does.
//
// The runtime is a fake ([LlmRuntime]); the *download* is not: those tests run
// a real HTTP server on loopback, so the URL is real, the bytes are real, and
// the hash is checked for real. test/llm_live_smoke.dart is where a real
// model, a real native runtime, and a real answer are proven.
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent_contract.dart';
import 'package:nexus/core/brain.dart';
import 'package:nexus/core/command_interpreter.dart';
import 'package:nexus/core/command_service.dart';
import 'package:nexus/core/conversation.dart';
import 'package:nexus/core/conversation_engine.dart';
import 'package:nexus/core/llm.dart';
import 'package:nexus/core/local_model_brain.dart';

/// A runtime that answers without a native library: it records the lifecycle
/// and the prompts, and hands back whatever the test told it to.
class _FakeRuntime implements LlmRuntime {
  _FakeRuntime({
    this.reply = 'Hello! I run inside Nexus now.',
    this.delay = Duration.zero,
    this.failToLoad = false,
  });

  String reply;
  Duration delay;
  bool failToLoad;

  /// The pieces a streaming generation yields. Empty means "the whole reply as
  /// one piece" — the shape a runtime with no stream to offer has.
  List<String> chunks = const <String>[];

  /// Throw after the first piece: how a model that dies mid-answer looks.
  bool failMidStream = false;

  int loads = 0;
  int unloads = 0;
  int disposes = 0;
  final List<List<ChatTurn>> prompts = [];
  final List<int> maxTokenAsks = [];

  @override
  Future<void> load(
    String modelPath, {
    required int contextSize,
    required int threads,
  }) async {
    if (failToLoad) throw StateError('no native runtime on this machine');
    loads++;
  }

  @override
  Future<String> generate(
    List<ChatTurn> messages, {
    required int maxTokens,
    required double temperature,
  }) async {
    prompts.add(messages);
    maxTokenAsks.add(maxTokens);
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    return reply;
  }

  @override
  Stream<String> generateStream(
    List<ChatTurn> messages, {
    required int maxTokens,
    required double temperature,
  }) async* {
    prompts.add(messages);
    maxTokenAsks.add(maxTokens);
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    final List<String> pieces = chunks.isEmpty ? <String>[reply] : chunks;
    var sent = 0;
    for (final String piece in pieces) {
      yield piece;
      sent++;
      if (failMidStream && sent == 1) throw StateError('the model stopped');
    }
  }

  @override
  Future<void> unload() async {
    unloads++;
  }

  @override
  Future<void> dispose() async {
    disposes++;
  }
}

/// A brain to fall back on, in the one case a fallback exists for.
class _FakeFallback extends LocalBrain {
  String? replyText = 'answer from the machine';
  int replyCalls = 0;

  @override
  Future<String?> availableModel({bool refresh = false}) async =>
      replyText == null ? null : 'llama3.2:3b';

  @override
  Future<BrainReply> reply({
    required String system,
    required List<ChatTurn> history,
    double temperature = 0.7,
    int maxTokens = 300,
  }) {
    replyCalls++;
    return Future.value((text: replyText, reachable: replyText != null));
  }
}

String _sha256Hex(List<int> bytes) => Sha256()
    .toSync()
    .hashSync(bytes)
    .bytes
    .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
    .join();

/// A models directory that already holds [model]'s file — a device after its
/// first download, with none of the downloading.
Directory _cachedDir(LlmModel model) {
  final dir = Directory.systemTemp.createTempSync('nexus_llm_test');
  File('${dir.path}/${model.name}.gguf').writeAsBytesSync([1, 2, 3]);
  return dir;
}

/// Tolerant by design: two owners of one temp directory (the test and the
/// helper that built the [Llm]) both clean up after themselves.
void _rm(Directory dir) {
  if (dir.existsSync()) dir.deleteSync(recursive: true);
}

/// A [Llm] over a fake runtime, with a model already on disk unless the test
/// is about downloading.
Llm _llmWith(
  _FakeRuntime runtime, {
  LlmModel model = kPhoneModel,
  Directory? dir,
  Duration idleTimeout = const Duration(minutes: 5),
}) {
  final models = dir ?? _cachedDir(model);
  addTearDown(() => _rm(models));
  return Llm(
    model: model,
    runtime: runtime,
    modelsDir: () async => models,
    idleTimeout: idleTimeout,
  );
}

/// Serves [payload] once per request on loopback, optionally slowly, and
/// counts the hits — the network the download path really talks to.
Future<(HttpServer, List<int>)> _serve(
  List<int> payload, {
  Duration lag = Duration.zero,
  int status = 200,
}) async {
  final hits = <int>[];
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    hits.add(request.uri.path.length);
    if (lag > Duration.zero) await Future<void>.delayed(lag);
    request.response.statusCode = status;
    request.response.add(payload);
    await request.response.close();
  });
  addTearDown(() => server.close(force: true));
  return (server, hits);
}

void main() {
  group('which model this device runs', () {
    test('a phone gets the small model, whatever memory it reports', () {
      expect(
        modelForDevice(platform: TargetPlatform.android, ramBytes: 12 << 30),
        same(kPhoneModel),
      );
    });

    test('a desktop gets the larger model when it has the memory', () {
      expect(
        modelForDevice(
          platform: TargetPlatform.linux,
          ramBytes: kLlmRamFloorBytes,
        ),
        same(kDesktopModel),
      );
      expect(
        modelForDevice(platform: TargetPlatform.linux, ramBytes: 2 << 30),
        same(kPhoneModel),
      );
    });

    test('memory we cannot read picks the model that always fits', () {
      expect(
        modelForDevice(platform: TargetPlatform.windows, ramBytes: null),
        same(kPhoneModel),
      );
    });

    test('this machine really reports memory through /proc/meminfo', () {
      // Not a guess: the same file Android reads, so the rule above is proven
      // against a real value on the platform both sides share.
      if (Platform.isLinux) {
        final ram = totalRamBytes();
        expect(ram, isNotNull);
        expect(ram ?? 0, greaterThan(0));
      }
    });
  });

  group('lazy loading and the idle unload', () {
    test('nothing loads until a question, and the model loads once', () async {
      final runtime = _FakeRuntime(reply: 'Hi there.');
      final llm = _llmWith(runtime);

      expect(runtime.loads, 0, reason: 'constructing must do no work');
      expect(llm.status, LlmStatus.idle);

      expect(await llm.complete('hello'), 'Hi there.');
      expect(runtime.loads, 1);
      expect(llm.status, LlmStatus.ready);

      expect(await llm.complete('again'), 'Hi there.');
      expect(runtime.loads, 1, reason: 'the loaded model is reused');
      expect(runtime.prompts, hasLength(2));
    });

    test('the idle unload frees the model, and the next question reloads it',
        () async {
      final runtime = _FakeRuntime();
      final llm = _llmWith(runtime, idleTimeout: const Duration(milliseconds: 40));

      await llm.complete('hello');
      expect(llm.status, LlmStatus.ready);

      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(runtime.unloads, 1, reason: 'idle means give the memory back');
      expect(llm.status, LlmStatus.idle);

      await llm.complete('again');
      expect(runtime.loads, 2, reason: 'the file is still there; only the '
          'weights were dropped');
    });

    test('two questions at once are answered one after the other', () async {
      final runtime = _FakeRuntime(delay: const Duration(milliseconds: 30));
      final llm = _llmWith(runtime);

      // The runtime underneath allows exactly one generation at a time, and
      // two callers (a typed question, a spoken one) really do arrive
      // together. Both must be answered.
      final answers = await Future.wait([
        llm.complete('first'),
        llm.complete('second'),
      ]);

      expect(answers, ['Hello! I run inside Nexus now.', 'Hello! I run inside Nexus now.']);
      expect(runtime.prompts, hasLength(2));
      expect(
        runtime.prompts.last.map((turn) => turn.content),
        contains('second'),
        reason: 'the queue is first-in first-out, not a race',
      );
    });

    test('a machine with no runtime answers nothing, and does not throw',
        () async {
      final runtime = _FakeRuntime(failToLoad: true);
      final llm = _llmWith(runtime);

      expect(await llm.complete('hello'), '');
      expect(llm.status, LlmStatus.unavailable);
    });

    test('dispose is final and frees the runtime', () async {
      final runtime = _FakeRuntime();
      final llm = _llmWith(runtime);
      await llm.complete('hello');

      await llm.dispose();
      expect(runtime.disposes, 1);
      expect(await llm.complete('anything'), '');
    });
  });

  group('the model file', () {
    test('a first question starts the download without waiting for it',
        () async {
      final payload = List<int>.generate(64 * 1024, (i) => i % 251);
      final (server, hits) =
          await _serve(payload, lag: const Duration(milliseconds: 200));
      final model = LlmModel(
        name: 'served-0.5b',
        url: 'http://127.0.0.1:${server.port}/model.gguf',
        sha256: _sha256Hex(payload),
        bytes: payload.length,
      );
      final dir = Directory.systemTemp.createTempSync('nexus_llm_download');
      addTearDown(() => _rm(dir));
      final runtime = _FakeRuntime();
      final llm = _llmWith(runtime, model: model, dir: dir);

      final asked = DateTime.now();
      expect(await llm.complete('hello'), '',
          reason: 'minutes of somebody else\'s network are not a question\'s time');
      expect(
        DateTime.now().difference(asked),
        lessThan(const Duration(seconds: 1)),
      );
      expect(llm.status, LlmStatus.downloading);

      // The fetch keeps going, and the next question finds a model.
      await _until(() async => (await llm.modelName()) != null);
      expect(hits, hasLength(1));
      expect(File('${dir.path}/served-0.5b.gguf').existsSync(), isTrue);
      expect(
        File('${dir.path}/served-0.5b.gguf.part').existsSync(),
        isFalse,
        reason: 'a cache never holds a half file',
      );

      expect(await llm.complete('hello'), 'Hello! I run inside Nexus now.');
      expect(runtime.loads, 1);
    });

    test('a file that fails its hash is discarded, never loaded', () async {
      final promised = List<int>.generate(4096, (i) => i % 97);
      // The server hands back different bytes than the hash pins — a truncated
      // transfer, a proxy with opinions, a swapped file.
      final (server, _) =
          await _serve(List<int>.generate(4096, (i) => (i * 3) % 97));
      final lying = LlmModel(
        name: 'swapped-0.5b',
        url: 'http://127.0.0.1:${server.port}/model.gguf',
        sha256: _sha256Hex(promised),
        bytes: promised.length,
      );
      final dir = Directory.systemTemp.createTempSync('nexus_llm_bad_hash');
      addTearDown(() => _rm(dir));
      final runtime = _FakeRuntime();
      final llm = _llmWith(runtime, model: lying, dir: dir);

      await llm.warmUp();

      expect(llm.status, LlmStatus.unavailable);
      expect(await llm.modelName(), isNull);
      expect(File('${dir.path}/${lying.name}.gguf').existsSync(), isFalse);
      expect(File('${dir.path}/${lying.name}.gguf.part').existsSync(), isFalse);
      expect(runtime.loads, 0, reason: 'a wrong file is never loaded');
      expect(await llm.complete('hello'), '');
    });

    test('a cached model is fetched once, ever', () async {
      final payload = List<int>.generate(2048, (i) => i % 31);
      final (server, hits) = await _serve(payload);
      final model = LlmModel(
        name: 'once-0.5b',
        url: 'http://127.0.0.1:${server.port}/model.gguf',
        sha256: _sha256Hex(payload),
        bytes: payload.length,
      );
      final dir = Directory.systemTemp.createTempSync('nexus_llm_once');
      addTearDown(() => _rm(dir));
      final llm = _llmWith(_FakeRuntime(), model: model, dir: dir);

      await llm.warmUp();
      await llm.unload();
      await llm.warmUp();

      expect(hits, hasLength(1), reason: 'the file is the cache');
      expect(await llm.modelName(), isNotNull);
    });
  });

  group('streaming', () {
    test('an answer is handed over in pieces, in order', () async {
      final runtime = _FakeRuntime()
        ..chunks = <String>['Nexus ', 'streams ', 'tokens.'];
      final llm = _llmWith(runtime);

      expect(
        await llm.completeStream('hello', system: 'system').toList(),
        <String>['Nexus ', 'streams ', 'tokens.'],
      );
      expect(runtime.loads, 1);
      // The same exchange [complete] sends: the system turn, then the words.
      expect(runtime.prompts.single.first.role, 'system');
      expect(runtime.prompts.single.last.content, 'hello');
    });

    test('a model that stops mid-answer fails the stream, keeping its pieces',
        () async {
      final runtime = _FakeRuntime()
        ..chunks = <String>['half an ', 'answer']
        ..failMidStream = true;
      final llm = _llmWith(runtime);

      final pieces = <String>[];
      await expectLater(
        llm.completeStream('hello').listen(pieces.add).asFuture<void>(),
        throwsA(isA<StateError>()),
      );
      expect(
        pieces,
        <String>['half an '],
        reason: 'the caller has the words it has already shown',
      );
    });

    test('a runtime with no stream to offer answers in one piece', () async {
      // The seam's contract has to hold for a runtime that only knows how to
      // answer whole — which is every fake that is not about streaming.
      final llm = _llmWith(_FakeRuntime(reply: 'whole answer'));
      expect(
        await llm.completeStream('hello').toList(),
        <String>['whole answer'],
      );
    });

    test('a stream and a one-shot answer one after the other', () async {
      final runtime = _FakeRuntime(reply: 'the whole answer')
        ..chunks = <String>['stream', 'ed'];
      final llm = _llmWith(runtime);

      expect(
        await llm.completeStream('first').toList(),
        <String>['stream', 'ed'],
      );
      expect(await llm.complete('second'), 'the whole answer');
      expect(runtime.prompts.map((p) => p.last.content), <String>[
        'first',
        'second',
      ]);
    });
  });

  group('the brain the assistant talks to', () {
    test('an unknown phrase is answered by the model', () async {
      final runtime = _FakeRuntime(reply: 'Because air scatters blue light.');
      final brain = LocalModelBrain(llm: _llmWith(runtime));
      final engine = ConversationEngine();
      await engine.probe(brain);
      expect(engine.brainHealth, BrainHealth.online);

      // What the command layer really says about a sentence that is not a
      // command: the teach card, which is the one thing the conversation
      // hangs off.
      final service = CommandService(devices: () => const []);
      final result = service.execute('why is the sky blue');
      expect(result.dispatch, isA<AgentClarification>());
      expect(
        (result.dispatch as AgentClarification).key,
        startsWith('teach:'),
      );

      engine.appendResult(result, asUser: 'why is the sky blue');
      await engine.converse(
        brain: brain,
        input: 'why is the sky blue',
        original: result,
        context: () => const ConversationContext(),
      );

      final reply = (engine.entries.last.result!.dispatch as AgentMessage).text;
      expect(reply, 'Because air scatters blue light.');
      expect(runtime.prompts, hasLength(1));
      expect(runtime.prompts.single.last.content, 'why is the sky blue');
    });

    test('a phrase Nexus already has an answer for never reaches the model',
        () async {
      // "hello" is Nexus's own greeting — a capability card, on purpose. The
      // model answers what the command layer does not understand, and
      // nothing else: a model that re-answered everything Nexus already
      // knows would be a slower, vaguer Nexus.
      final runtime = _FakeRuntime(reply: 'generic model greeting');
      final brain = LocalModelBrain(llm: _llmWith(runtime));
      final engine = ConversationEngine();
      await engine.probe(brain);

      final service = CommandService(devices: () => const []);
      final result = service.execute('hello');
      expect(result.dispatch, isA<AgentMessage>());
      expect(
        (result.dispatch as AgentMessage).text,
        contains('Ask me anything'),
        reason: 'the greeting is Nexus\'s own card, not the model\'s',
      );
      // Nothing here is a teach card, so nothing here can start a
      // conversation: the model is never asked.
      expect(runtime.prompts, isEmpty);
      expect(engine.entries, isEmpty);
    });

    test('a file fetch is a command, and never reaches the model', () {
      const interpreter = CommandInterpreter();
      final interpreted = interpreter.interpret(
        CommandInterpreter.normalizePhrase('get report.pdf from my pc'),
      );
      expect(interpreted.outcome, InterpretOutcome.matched);
      expect(interpreted.command!.action, AgentActions.fileFetch);
      expect(interpreted.command!.arguments['filename'], 'report.pdf');

      // And the layer above agrees with that reading: a fetch raises its own
      // question or its own action, never the teach card a conversation
      // hangs off — so a real fetch can never ask the model to answer it.
      final service = CommandService(devices: () => const []);
      final dispatch = service.execute('get report.pdf from my pc').dispatch;
      final teachKey = dispatch is AgentClarification ? dispatch.key : '';
      expect(teachKey.startsWith('teach:'), isFalse);
    });

    test('unknown "who is" and "why" questions reach the model', () async {
      // Both reported failures, end to end: the command layer must raise
      // the teach card (never a web search), and the conversation must hand
      // the exact phrase to the model.
      for (final phrase in [
        'why can i be a cat',
        'who is albert einstein',
        'who is john',
      ]) {
        final runtime = _FakeRuntime(reply: 'An answer from the model.');
        final brain = LocalModelBrain(llm: _llmWith(runtime));
        final engine = ConversationEngine();
        await engine.probe(brain);

        final service = CommandService(devices: () => const []);
        final result = service.execute(phrase);
        final dispatch = result.dispatch;
        expect(dispatch, isA<AgentClarification>(), reason: phrase);
        expect(
          (dispatch as AgentClarification).key.startsWith('teach:'),
          isTrue,
          reason: phrase,
        );

        engine.appendResult(result, asUser: phrase);
        await engine.converse(
          brain: brain,
          input: phrase,
          original: result,
          context: () => const ConversationContext(),
        );
        expect(runtime.prompts, hasLength(1), reason: phrase);
        expect(runtime.prompts.single.last.content, phrase, reason: phrase);
        expect(
          (engine.entries.last.result!.dispatch as AgentMessage).text,
          'An answer from the model.',
          reason: phrase,
        );
      }
    });

    test('the model is handed the persona, the history, and the token cap',
        () async {
      final runtime = _FakeRuntime(reply: 'ok');
      final llm = _llmWith(runtime);
      final brain = LocalModelBrain(llm: llm);

      await brain.reply(
        system: 'You are Nexus, a local assistant.',
        history: const [
          (role: 'user', content: 'what time is it'),
          (role: 'assistant', content: 'Half past nine.'),
          (role: 'user', content: 'and the weather?'),
        ],
        maxTokens: 128,
      );

      final prompt = runtime.prompts.single;
      expect(prompt.first.role, 'system');
      expect(prompt.first.content, contains('You are Nexus'));
      expect(prompt.last.content, 'and the weather?');
      expect(prompt.where((turn) => turn.role == 'assistant'), hasLength(1));
      expect(runtime.maxTokenAsks.single, 128);
    });

    test('the status line names the model only when the file is here', () async {
      final cached = LocalModelBrain(llm: _llmWith(_FakeRuntime()));
      expect(await cached.availableModel(), kPhoneModel.label);

      final emptyDir = Directory.systemTemp.createTempSync('nexus_llm_cold');
      addTearDown(() => _rm(emptyDir));
      final cold = LocalModelBrain(
        llm: _llmWith(_FakeRuntime(), dir: emptyDir),
        fallback: _FakeFallback(),
      );
      expect(await cold.availableModel(), 'llama3.2:3b',
          reason: 'a machine with Ollama is not a machine with no brain');
    });

    test('a model that cannot answer hands over to the fallback', () async {
      final fallback = _FakeFallback();
      final brain = LocalModelBrain(
        llm: _llmWith(_FakeRuntime(reply: '')),
        fallback: fallback,
      );

      final reply = await brain.reply(
        system: 'system',
        history: const [(role: 'user', content: 'hello')],
      );

      expect(reply.text, 'answer from the machine');
      expect(fallback.replyCalls, 1);
    });

    test('a model still fetching its file reports an offline brain, honestly',
        () async {
      // The fetch this starts is pointed at a server that does not have the
      // file, so the suite never touches the network the real model lives on.
      final (server, _) = await _serve(const [], status: 404);
      final unavailable = LlmModel(
        name: 'unreachable-0.5b',
        url: 'http://127.0.0.1:${server.port}/model.gguf',
        sha256: '00' * 32,
        bytes: 1024,
      );
      final emptyDir = Directory.systemTemp.createTempSync('nexus_llm_fetching');
      addTearDown(() => _rm(emptyDir));
      final brain = LocalModelBrain(
        llm: _llmWith(_FakeRuntime(), model: unavailable, dir: emptyDir),
      );

      final reply = await brain.reply(
        system: 'system',
        history: const [(role: 'user', content: 'hello')],
      );

      expect(reply.text, isNull);
      expect(reply.reachable, isFalse,
          reason: 'no model yet is not the same as a model with nothing to say');
    });
  });
}

/// Waits for [condition] to hold, up to a few seconds — for work that is
/// deliberately not on the caller's clock.
Future<void> _until(Future<bool> Function() condition) async {
  for (var i = 0; i < 100; i++) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail('condition never held');
}
