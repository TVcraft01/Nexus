// The eyes, without a download and without a phone.
//
// Everything here is a seam the service already has: the files are a temp
// directory, the models are fakes a test can make fail, and the fallback is a
// service that records what it was asked. What that makes provable is the whole
// decision the app makes around a photo — which pair of eyes answered, why, and
// what happens when the big one does not fit or will not load.

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/llm.dart';
import 'package:nexus/core/on_device_ai_service.dart' show OnDeviceAiService;
import 'package:nexus/core/vision_ai.dart';
import 'package:nexus/core/vision_ai_service.dart';

/// A model whose load and answer are the test's to decide.
class _FakeVisionInference implements VisionInference {
  int loads = 0;
  int unloads = 0;
  final List<(String image, String prompt)> asked = <(String, String)>[];

  String answer = 'A wooden table under a window.';
  Object? failLoad;
  Object? failAnswer;

  @override
  Future<void> load({
    required String weightsPath,
    required String projectorPath,
    required int threads,
  }) async {
    loads++;
    final Object? failure = failLoad;
    if (failure != null) throw failure;
  }

  @override
  Future<String> describe({
    required String imagePath,
    required String prompt,
  }) async {
    asked.add((imagePath, prompt));
    final Object? failure = failAnswer;
    if (failure != null) throw failure;
    return answer;
  }

  @override
  Future<void> unload() async => unloads++;
}

/// ML Kit, replaced by one sentence the test can recognise.
class _FakeFallback extends VisionAiService {
  final List<String> questions = <String>[];
  final List<VisionEvidence> evidence = <VisionEvidence>[];

  @override
  bool get available => true;

  @override
  Future<String> describe(
    String imagePath, {
    String question = '',
    VisionEvidenceCallback? onEvidence,
  }) async {
    questions.add(question);
    const VisionEvidence seen = VisionEvidence(
      text: 'OPEN',
      labels: <String>['Door'],
    );
    evidence.add(seen);
    onEvidence?.call(seen);
    return 'ML Kit: $question';
  }
}

/// A real PNG of [width] × [height], because [prepareVisionImage] decodes with
/// `dart:ui` and a fake byte string would prove nothing about resizing.
Future<File> writePng(Directory dir, int width, int height) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = const Color(0xFF336699),
  );
  final ui.Image image = await recorder.endRecording().toImage(width, height);
  final ByteData? png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  final File file = File('${dir.path}/source.png');
  await file.writeAsBytes(png!.buffer.asUint8List());
  return file;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nexus_vision');
    // A roomy phone unless a test says otherwise: the real reading is the
    // host's, and the host running these tests is usually the one under load.
    OnDeviceAiService.availableMemoryOverride = () async =>
        3 * 1024 * 1024 * 1024;
  });

  tearDown(() {
    OnDeviceAiService.availableMemoryOverride = null;
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  void install(VisionModelPair pair, {int bytes = 8}) {
    File('${dir.path}/${pair.weightsFileName}')
        .writeAsBytesSync(List<int>.filled(bytes, 1));
    File('${dir.path}/${pair.projectorFileName}')
        .writeAsBytesSync(List<int>.filled(bytes, 2));
  }

  VlmVisionService serviceWith(
    _FakeVisionInference model,
    _FakeFallback fallback, {
    VisionFileFetcher? fetch,
  }) => VlmVisionService.test(
    filesFor: (VisionModelPair pair) =>
        VisionModelFiles(pair, directory: () async => dir, fetch: fetch),
    inference: () => model,
    fallback: () => fallback,
  );

  test('without any model, ML Kit answers and nothing is loaded', () async {
    final _FakeVisionInference model = _FakeVisionInference();
    final _FakeFallback fallback = _FakeFallback();
    final VlmVisionService service = serviceWith(model, fallback);

    final String answer = await service.describe(
      '/photos/room.jpg',
      question: 'What is this?',
    );

    expect(answer, 'ML Kit: What is this?');
    expect(model.loads, 0, reason: '1.8 GB is not loaded for a missing file');
    expect(fallback.questions, <String>['What is this?']);
    expect(service.available, isTrue, reason: 'ML Kit is still the eyes');
  });

  test('the small model answers with its own prompt shape', () async {
    install(kVisionSmall);
    final _FakeVisionInference model = _FakeVisionInference();
    final _FakeFallback fallback = _FakeFallback();
    final VlmVisionService service = serviceWith(model, fallback);

    final String answer = await service.describe(
      '/photos/room.jpg',
      question: 'What is in this picture?',
    );

    expect(answer, model.answer);
    expect(model.loads, 1);
    expect(model.asked, hasLength(1));
    expect(model.asked.single.$1, '/photos/room.jpg');
    expect(
      model.asked.single.$2,
      startsWith('<|im_start|>User:<image>'),
      reason: 'SmolVLM is asked in its own chat template',
    );
    expect(
      model.asked.single.$2,
      contains('What is in this picture?<end_of_utterance>'),
    );
    expect(fallback.questions, isEmpty);
  });

  test('the big model wins when there is room for it', () async {
    install(kVisionSmall);
    install(kVisionLarge);
    final _FakeVisionInference model = _FakeVisionInference();
    final _FakeFallback fallback = _FakeFallback();
    final VlmVisionService service = serviceWith(model, fallback);

    expect(await service.describe('/a.jpg'), model.answer);
    expect(
      model.asked.single.$2,
      startsWith('\n\nQuestion:'),
      reason: 'Moondream2 answers a bare Question: line',
    );
  });

  test('the small model is used when the big one does not fit', () async {
    install(kVisionSmall);
    install(kVisionLarge);
    // The A25's measured state: Moondream2 loaded at 1.86 GB free, then the
    // low-memory killer reaped the app mid-generation.
    OnDeviceAiService.availableMemoryOverride = () async => 1862 * 1024 * 1024;
    final _FakeVisionInference model = _FakeVisionInference();
    final _FakeFallback fallback = _FakeFallback();
    final VlmVisionService service = serviceWith(model, fallback);

    expect(await service.describe('/a.jpg'), model.answer);
    expect(model.loads, 1);
    expect(
      model.asked.single.$2,
      startsWith('<|im_start|>User:<image>'),
      reason: 'the phone-sized model answered, not the one that got killed',
    );
  });

  test('when no downloaded model fits, ML Kit answers', () async {
    install(kVisionLarge);
    OnDeviceAiService.availableMemoryOverride = () async => 1862 * 1024 * 1024;
    final _FakeVisionInference model = _FakeVisionInference();
    final _FakeFallback fallback = _FakeFallback();
    final VlmVisionService service = serviceWith(model, fallback);

    final String answer = await service.describe('/a.jpg');

    expect(answer, startsWith('ML Kit'));
    expect(model.loads, 0, reason: 'a load that kills the app is not a load');
  });

  test('a projector without its weights is not a model', () async {
    File('${dir.path}/${kVisionSmall.weightsFileName}')
        .writeAsBytesSync(List<int>.filled(8, 1));
    final _FakeVisionInference model = _FakeVisionInference();
    final _FakeFallback fallback = _FakeFallback();
    final VlmVisionService service = serviceWith(model, fallback);

    expect(await service.describe('/a.jpg'), startsWith('ML Kit'));
    expect(model.loads, 0);
  });

  test('a model that will not load falls back, once per session', () async {
    install(kVisionSmall);
    final _FakeVisionInference model = _FakeVisionInference()
      ..failLoad = StateError('not enough room');
    final _FakeFallback fallback = _FakeFallback();
    final VlmVisionService service = serviceWith(model, fallback);

    expect(await service.describe('/a.jpg'), startsWith('ML Kit'));
    expect(await service.describe('/b.jpg'), startsWith('ML Kit'));

    expect(model.loads, 1, reason: 'the failure must not be paid for twice');
    expect(fallback.questions.length, 2);
  });

  test('a model that fails mid-answer unloads and hands over', () async {
    install(kVisionSmall);
    final _FakeVisionInference model = _FakeVisionInference()
      ..failAnswer = StateError('the runtime gave up');
    final _FakeFallback fallback = _FakeFallback();
    final VlmVisionService service = serviceWith(model, fallback);

    final String answer = await service.describe('/a.jpg', question: 'what?');

    expect(answer, 'ML Kit: what?');
    expect(model.unloads, greaterThanOrEqualTo(1), reason: 'no idle weights');
  });

  test(
    'the fallback still reports evidence, so the bubble can draw it',
    () async {
      final _FakeVisionInference model = _FakeVisionInference();
      final _FakeFallback fallback = _FakeFallback();
      final VlmVisionService service = serviceWith(model, fallback);

      VisionEvidence? drawn;
      await service.describe(
        '/a.jpg',
        onEvidence: (VisionEvidence evidence) => drawn = evidence,
      );

      expect(drawn?.text, 'OPEN');
      expect(drawn?.labels, <String>['Door']);
      expect(fallback.evidence.single.text, 'OPEN');
    },
  );

  test(
    'describeMany asks once per picture and keeps the first answer',
    () async {
      install(kVisionSmall);
      final _FakeVisionInference model = _FakeVisionInference();
      final _FakeFallback fallback = _FakeFallback();
      final VlmVisionService service = serviceWith(model, fallback);

      final String answer = await service.describeMany(<String>[
        '/a.jpg',
        '/b.jpg',
      ], question: 'What is this?');

      expect(answer, model.answer);
      expect(model.asked.length, 2);
      expect(fallback.questions, isEmpty);
    },
  );

  test('downloading fetches both files and reports the whole pair', () async {
    final List<double> progress = <double>[];
    final VisionModelFiles files = VisionModelFiles(
      kVisionSmall,
      directory: () async => dir,
      fetch: (LlmModel model, {void Function(double)? onProgress}) async {
        onProgress?.call(0.5);
        File('${dir.path}/${model.name}.gguf')
            .writeAsBytesSync(List<int>.filled(8, 3));
        return true;
      },
    );

    expect(await files.isPresent(), isFalse);
    expect(await files.download(onProgress: progress.add), isTrue);

    expect(await files.isPresent(), isTrue);
    expect(await files.sizeBytes(), 16);
    expect(progress, isNotEmpty);
    expect(progress.last, 1.0);
  });

  test('a failure on the second file leaves no model behind', () async {
    int calls = 0;
    final VisionModelFiles files = VisionModelFiles(
      kVisionSmall,
      directory: () async => dir,
      fetch: (LlmModel model, {void Function(double)? onProgress}) async {
        calls++;
        if (calls == 2) return false;
        File('${dir.path}/${model.name}.gguf')
            .writeAsBytesSync(List<int>.filled(8, 3));
        return true;
      },
    );

    expect(await files.download(), isFalse);
    expect(calls, 2);
    expect(await files.isPresent(), isFalse);
    expect(
      File('${dir.path}/${kVisionSmall.weightsFileName}').existsSync(),
      isTrue,
    );
  });

  test('delete frees both files and the .part a kill left behind', () async {
    install(kVisionSmall, bytes: 10);
    File('${dir.path}/${kVisionSmall.projectorFileName}.part')
        .writeAsBytesSync(List<int>.filled(4, 9));
    final VisionModelFiles files = VisionModelFiles(
      kVisionSmall,
      directory: () async => dir,
    );

    expect(await files.delete(), 24);
    expect(await files.isPresent(), isFalse);
    expect(Directory(dir.path).listSync(), isEmpty);
  });

  test('a model that arrives later is picked up by refresh', () async {
    final _FakeVisionInference model = _FakeVisionInference();
    final _FakeFallback fallback = _FakeFallback();
    final VlmVisionService service = serviceWith(model, fallback);

    expect(await service.describe('/a.jpg'), startsWith('ML Kit'));
    install(kVisionSmall);
    await service.refresh();
    expect(service.available, isTrue);
    expect(await service.describe('/a.jpg'), model.answer);
  });

  test(
    'a large photo is prepared at the model edge, keeping its shape',
    () async {
      final File source = await writePng(dir, 1600, 900);
      final File? prepared = await prepareVisionImage(source.path);

      expect(prepared, isNotNull);
      addTearDown(() {
        if (prepared!.parent.existsSync()) {
          prepared.parent.deleteSync(recursive: true);
        }
      });
      final ui.Codec codec = await ui.instantiateImageCodec(
        await prepared!.readAsBytes(),
      );
      final ui.Image scaled = (await codec.getNextFrame()).image;
      expect(scaled.width, kVisionImageEdge);
      expect(scaled.height, closeTo(kVisionImageEdge * 900 / 1600, 1));
    },
  );

  test('a picture already inside the budget is passed through', () async {
    final File source = await writePng(dir, 200, 100);
    expect(await prepareVisionImage(source.path), isNull);
  });

  test('an unreadable file is passed through rather than thrown', () async {
    final File source = File('${dir.path}/notes.txt')
      ..writeAsStringSync('not a photo');
    expect(await prepareVisionImage(source.path), isNull);
  });

  test('both pinned models have real URLs, sizes and hashes', () {
    for (final VisionModelPair pair in kVisionPairs) {
      expect(pair.weights.url, startsWith('https://huggingface.co/'));
      expect(pair.projector.url, startsWith('https://huggingface.co/'));
      expect(pair.weights.sha256, hasLength(64));
      expect(pair.projector.sha256, hasLength(64));
      expect(pair.weights.bytes, greaterThan(100 * 1024 * 1024));
      expect(pair.projector.bytes, greaterThan(50 * 1024 * 1024));
    }
    expect(kVisionSmall.label, 'SmolVLM 500M');
    expect(kVisionSmall.megabytes, 521);
    expect(
      kVisionSmall.workingSetBytes,
      lessThan(kVisionLarge.workingSetBytes),
    );
    expect(kVisionLarge.label, 'Moondream2 1.8B');
    expect(kVisionLarge.megabytes, 1745);
  });

  test('the test factory keeps its own files, not the app singleton\'s', () {
    // The app installs [VlmVisionService.new], which is one instance holding
    // the engine. A test states its own, or this file would hold weights.
    final VlmVisionService service = serviceWith(
      _FakeVisionInference(),
      _FakeFallback(),
    );
    expect(service.filesFor(kVisionSmall).pair, same(kVisionSmall));
  });
}
