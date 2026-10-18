// The device's own brain, and the chain that reaches for the PC when it cannot
// answer.
//
// The runtime is a fake ([LlmRuntime]) — that is how llamadart is mocked here:
// the package's only job in this design is load/generate/unload behind a seam,
// and the seam is what these tests drive. The *download* is not faked: the last
// group serves real bytes from a real loopback server, so the URL, the hash and
// the `.part`-then-rename are exercised as they ship (the same shape as
// test/llm_test.dart, where that behaviour is first defined).
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus/core/ai_status.dart';
import 'package:nexus/core/brain.dart';
import 'package:nexus/core/llm.dart';
import 'package:nexus/core/local_ai_service.dart';
import 'package:nexus/core/ollama_service.dart';
import 'package:nexus/core/on_device_ai_service.dart';
import 'package:nexus/core/on_device_model.dart';

/// The llamadart runtime, as far as this app is concerned: load, answer, unload.
class _FakeRuntime implements LlmRuntime {
  _FakeRuntime({this.failToLoad = false});

  String reply = 'Answered here, on this device.';
  bool failToLoad;

  /// The pieces a streaming generation yields, in order. Empty means the whole
  /// reply as one piece.
  List<String> chunks = const <String>[];

  /// Throw after the first piece: a model that dies mid-answer.
  bool failMidStream = false;

  int loads = 0;
  int unloads = 0;
  int disposes = 0;
  final List<List<ChatTurn>> prompts = [];

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
    return reply;
  }

  @override
  Stream<String> generateStream(
    List<ChatTurn> messages, {
    required int maxTokens,
    required double temperature,
  }) async* {
    prompts.add(messages);
    final List<String> pieces = chunks.isEmpty ? <String>[reply] : chunks;
    var sent = 0;
    for (final String piece in pieces) {
      yield piece;
      sent++;
      if (failMidStream && sent == 1) throw StateError('the model stopped');
    }
  }

  @override
  Future<void> unload() async => unloads++;

  @override
  Future<void> dispose() async => disposes++;
}

/// A brain with a canned answer or a canned failure, and a log of what it was
/// asked — the PC in the fallback tests, and any brain whose *behaviour* is the
/// subject rather than its transport.
class _FakeBrain extends LocalAiService {
  _FakeBrain({this.reply = 'from the PC', this.failure, this.pieces = const <String>[]});

  String reply;
  Object? failure;

  /// The pieces [generateResponseStream] yields. Empty means the whole reply as
  /// one piece — a brain with nothing to stream, like the PC's Ollama.
  final List<String> pieces;

  /// Throw once this many pieces have been handed over, or null to end
  /// normally. Zero is a failure before the first word; one is a failure in the
  /// middle of an answer.
  int? failAfter;

  final List<String> prompts = <String>[];

  /// What each streamed answer was told to remember, in the order the questions
  /// were asked — the only way a test can see the live page's memory.
  final List<List<AiTurn>> histories = <List<AiTurn>>[];

  @override
  Future<String> generateResponse(String prompt) async {
    prompts.add(prompt);
    final Object? thrown = failure;
    if (thrown != null) throw thrown;
    return reply;
  }

  @override
  Stream<String> generateResponseStream(
    String prompt, {
    List<AiTurn> history = const <AiTurn>[],
  }) async* {
    prompts.add(prompt);
    histories.add(history);
    final Object? thrown = failure;
    if (thrown != null) throw thrown;
    final List<String> streamed = pieces.isEmpty ? <String>[reply] : pieces;
    var sent = 0;
    for (final String piece in streamed) {
      final int? after = failAfter;
      if (after != null && sent >= after) throw StateError('the brain stopped');
      yield piece;
      sent++;
    }
  }
}

String _sha256Hex(List<int> bytes) => Sha256()
    .toSync()
    .hashSync(bytes)
    .bytes
    .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
    .join();

/// A device with a model directory (and no model in it, unless a test writes
/// one) and the service that would use it.
class _Device {
  _Device(this.dir, this.runtime)
    : model = OnDeviceModel(
        model: LlmModel(
          name: 'model',
          url: 'http://127.0.0.1:1/model.gguf',
          sha256: _sha256Hex(const <int>[1, 2, 3]),
          bytes: 3,
        ),
        directory: () async => dir,
      );

  final Directory dir;
  final _FakeRuntime runtime;
  final OnDeviceModel model;

  File get file => File('${dir.path}/model.gguf');

  /// A model file, as a finished download would leave one.
  void writeModel() => file.writeAsBytesSync(<int>[1, 2, 3]);

  OnDeviceAiService service() => OnDeviceAiService(
    model: model,
    llm: Llm(
      model: model.model,
      runtime: runtime,
      modelsDir: model.directoryFor,
    ),
  );
}

_Device _device({bool failToLoad = false}) {
  final dir = Directory.systemTemp.createTempSync('nexus_on_device');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return _Device(dir, _FakeRuntime(failToLoad: failToLoad));
}

/// Serves [payload] once per request on loopback — the network a download
/// really talks to.
Future<HttpServer> _serve(List<int> payload) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((HttpRequest request) async {
    request.response.statusCode = 200;
    request.response.add(payload);
    await request.response.close();
  });
  addTearDown(() => server.close(force: true));
  return server;
}

void main() {
  group('the on-device brain', () {
    test(
      'a missing model file is a ModelNotFoundException, not a download',
      () async {
        final device = _device();
        final service = device.service();

        await expectLater(
          service.generateResponse('hello'),
          throwsA(isA<ModelNotFoundException>()),
        );
        // The point of the type: the caller can ask the PC instead, and nothing
        // has been loaded or fetched on this phone.
        expect(device.runtime.loads, 0);
        expect(device.file.existsSync(), isFalse);
        expect(await service.isModelPresent(), isFalse);
      },
    );

    test('a model file on this device answers, and gets the prompt', () async {
      final device = _device();
      device.writeModel();
      final service = device.service();

      expect(
        await service.generateResponse('what is a mesh?'),
        'Answered here, on this device.',
      );
      expect(device.runtime.loads, 1);

      // One exchange: the persona and the action rules first, then the user's
      // words. The rules are part of the same turn because the model has to know
      // the five actions before it can ask for one.
      final List<ChatTurn> prompt = device.runtime.prompts.single;
      expect(prompt.first.role, 'system');
      expect(prompt.first.content, kNexusOnDeviceSystem);
      expect(prompt.first.content, contains(kNexusOnDeviceSystemPrompt));
      expect(prompt.first.content, contains('"action":"set_flashlight"'));
      expect(prompt.last.role, 'user');
      expect(prompt.last.content, 'what is a mesh?');
    });

    test(
      'a model that cannot load says so, and does not pretend to answer',
      () async {
        final device = _device(failToLoad: true);
        device.writeModel();

        await expectLater(
          device.service().generateResponse('hello'),
          throwsA(
            isA<OnDeviceAiException>()
                .having(
                  (e) => e.message,
                  'message',
                  contains('could not be loaded'),
                )
                .having((e) => e, 'type', isNot(isA<ModelNotFoundException>())),
          ),
        );
      },
    );

    test(
      'a model that says nothing is a failure, not an empty reply',
      () async {
        final device = _device();
        device.writeModel();
        device.runtime.reply = '   ';

        await expectLater(
          device.service().generateResponse('hello'),
          throwsA(
            isA<OnDeviceAiException>().having(
              (e) => e.message,
              'message',
              contains('did not answer'),
            ),
          ),
        );
      },
    );
  });

  group('the fallback chain', () {
    test('no model on this device: the PC answers', () async {
      final device = _device();
      final pc = _FakeBrain(reply: 'Answered by the PC.');
      final brain = FallbackAiService(onDevice: device.service(), pc: pc);

      expect(await brain.generateResponse('hello'), 'Answered by the PC.');
      expect(pc.prompts, <String>['hello']);
    });

    test('an answer from this device never reaches the PC', () async {
      final device = _device();
      device.writeModel();
      final pc = _FakeBrain();
      final brain = FallbackAiService(onDevice: device.service(), pc: pc);

      expect(
        await brain.generateResponse('hello'),
        'Answered here, on this device.',
      );
      expect(
        pc.prompts,
        isEmpty,
        reason: 'the device answered; the PC is not a second opinion',
      );
    });

    test(
      'neither brain: the one sentence the shell shows as a notice',
      () async {
        final device = _device();
        final brain = FallbackAiService(
          onDevice: device.service(),
          pc: _FakeBrain(
            failure: const OllamaException(kNexusOllamaUnreachableText),
          ),
        );

        await expectLater(
          brain.generateResponse('hello'),
          throwsA(
            isA<OllamaException>().having(
              (e) => e.message,
              'message',
              kNexusOllamaUnreachableText,
            ),
          ),
        );
      },
    );

    test('a PC that fails in an unexpected way is still "no AI"', () async {
      final device = _device();
      final brain = FallbackAiService(
        onDevice: device.service(),
        pc: _FakeBrain(failure: StateError('a socket nobody planned for')),
      );

      await expectLater(
        brain.generateResponse('hello'),
        throwsA(
          isA<OllamaException>().having(
            (e) => e.message,
            'message',
            kNexusOllamaUnreachableText,
          ),
        ),
      );
    });

    test(
      'a device that fails for a non-model reason still asks the PC',
      () async {
        final device = _device(failToLoad: true);
        device.writeModel();
        final pc = _FakeBrain(reply: 'The PC picked it up.');
        final brain = FallbackAiService(onDevice: device.service(), pc: pc);

        expect(await brain.generateResponse('hello'), 'The PC picked it up.');
        expect(pc.prompts, <String>['hello']);
      },
    );
  });

  group('the model file', () {
    test(
      'downloads model.gguf with progress, verifies it, keeps no part',
      () async {
        final payload = List<int>.generate(64 * 1024, (i) => i % 251);
        final server = await _serve(payload);
        final dir = Directory.systemTemp.createTempSync('nexus_model_download');
        addTearDown(() {
          if (dir.existsSync()) dir.deleteSync(recursive: true);
        });
        final model = OnDeviceModel(
          model: LlmModel(
            name: 'model',
            url: 'http://127.0.0.1:${server.port}/model.gguf',
            sha256: _sha256Hex(payload),
            bytes: payload.length,
          ),
          directory: () async => dir,
        );
        final progress = <double>[];

        expect(await model.download(onProgress: progress.add), isTrue);

        final File file = File('${dir.path}/$kOnDeviceModelFileName');
        expect(file.existsSync(), isTrue);
        expect(
          File('${file.path}.part').existsSync(),
          isFalse,
          reason: 'a finished download leaves no half file behind',
        );
        expect(await model.isPresent(), isTrue);
        expect(await model.sizeBytes(), payload.length);

        // The bar starts at nothing and ends full: a user watching it must not
        // see a download that looks already half done.
        expect(progress.first, 0);
        expect(progress.last, 1);
        expect(progress, orderedEquals([...progress]..sort()));
      },
    );

    test('a file that fails its hash is discarded and never loaded', () async {
      final promised = List<int>.generate(4096, (i) => i % 97);
      final server = await _serve(
        List<int>.generate(4096, (i) => (i * 3) % 97),
      );
      final dir = Directory.systemTemp.createTempSync('nexus_model_bad_hash');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final model = OnDeviceModel(
        model: LlmModel(
          name: 'model',
          url: 'http://127.0.0.1:${server.port}/model.gguf',
          sha256: _sha256Hex(promised),
          bytes: promised.length,
        ),
        directory: () async => dir,
      );

      expect(await model.download(), isFalse);

      final File file = File('${dir.path}/$kOnDeviceModelFileName');
      expect(file.existsSync(), isFalse);
      expect(File('${file.path}.part').existsSync(), isFalse);
      expect(await model.isPresent(), isFalse);
    });

    test(
      'delete frees the model and any part, and is harmless when empty',
      () async {
        final device = _device();
        device.writeModel();
        File('${device.file.path}.part').writeAsBytesSync(<int>[9, 9]);

        expect(await device.model.delete(), 5);
        expect(device.file.existsSync(), isFalse);
        expect(File('${device.file.path}.part').existsSync(), isFalse);

        expect(await device.model.delete(), 0);
      },
    );

    test(
      'a directory the platform will not give up is "no model", not a crash',
      () async {
        final model = OnDeviceModel(
          directory: () async =>
              throw const FileSystemException('no documents'),
        );

        expect(await model.isPresent(), isFalse);
        expect(await model.sizeBytes(), 0);
      },
    );
  });

  group('streaming from this device', () {
    test('the model\'s tokens are handed over in order', () async {
      final device = _device();
      device.writeModel();
      device.runtime.chunks = <String>['A mesh ', 'is devices ', 'talking.'];

      expect(
        await device.service().generateResponseStream('what is a mesh?').toList(),
        <String>['A mesh ', 'is devices ', 'talking.'],
      );
      expect(device.runtime.prompts.single.last.content, 'what is a mesh?');
    });

    test('a missing model throws before the first token', () async {
      final device = _device();

      await expectLater(
        device.service().generateResponseStream('hello').toList(),
        throwsA(isA<ModelNotFoundException>()),
      );
      expect(device.runtime.loads, 0);
    });

    test('a model that stops mid-answer throws a sentence about the answer',
        () async {
      final device = _device();
      device.writeModel();
      device.runtime.chunks = <String>['A mesh is ', 'devices'];
      device.runtime.failMidStream = true;

      final pieces = <String>[];
      await expectLater(
        device
            .service()
            .generateResponseStream('hello')
            .listen(pieces.add)
            .asFuture<void>(),
        throwsA(
          isA<OnDeviceAiException>().having(
            (e) => e.message,
            'message',
            kOnDeviceStreamFailureText,
          ),
        ),
      );
      expect(
        pieces,
        <String>['A mesh is '],
        reason: 'the words that did arrive are the caller\'s to keep showing',
      );
    });

    test('a model that cannot come up says which silence it is', () async {
      final device = _device(failToLoad: true);
      device.writeModel();

      await expectLater(
        device.service().generateResponseStream('hello').toList(),
        throwsA(
          isA<OnDeviceAiException>().having(
            (e) => e.message,
            'message',
            contains('could not be loaded'),
          ),
        ),
      );
    });
  });

  group('streaming through the chain', () {
    test('no model: the PC streams the answer', () async {
      final device = _device();
      final pc = _FakeBrain(pieces: <String>['From ', 'the ', 'PC.']);
      final brain = FallbackAiService(onDevice: device.service(), pc: pc);

      expect(
        await brain.generateResponseStream('hello').toList(),
        <String>['From ', 'the ', 'PC.'],
      );
      expect(pc.prompts, <String>['hello']);
    });

    test('words already on screen are never re-answered by the PC', () async {
      final device = _device();
      device.writeModel();
      device.runtime.chunks = <String>['Half an answer, '];
      device.runtime.failMidStream = true;
      final pc = _FakeBrain();
      final brain = FallbackAiService(onDevice: device.service(), pc: pc);

      final pieces = <String>[];
      await expectLater(
        brain
            .generateResponseStream('hello')
            .listen(pieces.add)
            .asFuture<void>(),
        throwsA(isA<OnDeviceAiException>()),
      );
      expect(pieces, <String>['Half an answer, ']);
      expect(
        pc.prompts,
        isEmpty,
        reason: 'the user gets one answer, not two half sentences',
      );
    });

    test('the PC covers a device that fails before its first word', () async {
      final device = _device(failToLoad: true);
      device.writeModel();
      final pc = _FakeBrain(pieces: <String>['The PC ', 'picked it up.']);
      final brain = FallbackAiService(onDevice: device.service(), pc: pc);

      expect(
        await brain.generateResponseStream('hello').toList(),
        <String>['The PC ', 'picked it up.'],
      );
      expect(pc.prompts, <String>['hello']);
    });

    test('neither brain: the one sentence the shell shows as a notice',
        () async {
      final device = _device();
      final brain = FallbackAiService(
        onDevice: device.service(),
        pc: _FakeBrain(
          failure: const OllamaException(kNexusOllamaUnreachableText),
        ),
      );

      await expectLater(
        brain.generateResponseStream('hello').toList(),
        throwsA(
          isA<OllamaException>().having(
            (e) => e.message,
            'message',
            kNexusOllamaUnreachableText,
          ),
        ),
      );
    });
  });

  group('where the answers come from', () {
    /// A PC that throws if it is asked: the probe must not need a socket to
    /// answer "this device has the model".
    OllamaService uninterruptiblePc() => OllamaService(
      client: MockClient(
        (request) async => throw const SocketException('not asked'),
      ),
    );

    test(
      'a model on this device is the answer, without probing the PC',
      () async {
        final device = _device();
        device.writeModel();

        final status = await AiStatus.detect(
          model: device.model,
          pc: uninterruptiblePc(),
        );

        expect(status.source, AiSource.onDevice);
        expect(status.label, 'On-Device (Loaded)');
      },
    );

    test('no model and no PC is No AI available', () async {
      final device = _device();

      final status = await AiStatus.detect(
        model: device.model,
        pc: OllamaService(
          client: MockClient(
            (request) async => throw const SocketException('refused'),
          ),
        ),
      );

      expect(status.source, AiSource.none);
      expect(status.label, 'No AI available');
    });

    test('no model, but the PC answers: PC (Ollama)', () async {
      final device = _device();

      final status = await AiStatus.detect(
        model: device.model,
        pc: OllamaService(
          client: MockClient((request) async {
            // The probe is the cheap call, never a generation.
            expect(request.url.path, '/api/tags');
            return http.Response('{"models":[]}', 200);
          }),
        ),
      );

      expect(status.source, AiSource.pc);
      expect(status.label, 'PC (Ollama)');
    });
  });
}
