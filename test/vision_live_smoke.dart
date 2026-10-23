// Live vision, the whole way: the product's own [VisionModelFiles] fetching
// SmolVLM 500M and its projector from the pinned URLs, verifying both sha256s,
// loading them through the native llama.cpp runtime with `mtmd`, and answering
// a question about a real picture. No mocks anywhere.
//
// Not part of the suite: no `_test` suffix, so the default test glob skips it
// (the same rule as test/llm_live_smoke.dart). It downloads ~545 MB on a first
// run and needs minutes of CPU, neither of which a unit-test run may assume.
// Run it explicitly:
//
//   flutter test test/vision_live_smoke.dart
//
// NEXUS_VISION_DIR is where the two files live (default
// /tmp/nexus_vision_models).
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/vision_ai_service.dart';

/// A 1024 × 768 drawing with things a person would name: sky, sun, grass, a
/// tree. Bigger than [kVisionImageEdge] on purpose, so the downscale in front
/// of the model runs too.
Future<File> drawScene(Directory dir) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  const double w = 1024;
  const double h = 768;
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, w, h),
    Paint()..color = const Color(0xFF8EC5EB),
  );
  canvas.drawRect(
    const Rect.fromLTWH(0, h * 0.62, w, h * 0.38),
    Paint()..color = const Color(0xFF4E9A3A),
  );
  canvas.drawCircle(
    const Offset(w * 0.8, h * 0.18),
    70,
    Paint()..color = const Color(0xFFFFD93D),
  );
  canvas.drawRect(
    const Rect.fromLTWH(w * 0.28, h * 0.42, 34, h * 0.34),
    Paint()..color = const Color(0xFF6B4423),
  );
  canvas.drawCircle(
    Offset(w * 0.295, h * 0.36),
    105,
    Paint()..color = const Color(0xFF2E6B2A),
  );
  final ui.Image image = await recorder.endRecording().toImage(
    w.toInt(),
    h.toInt(),
  );
  final ByteData? png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  final File file = File('${dir.path}/scene.png');
  await file.writeAsBytes(png!.buffer.asUint8List());
  return file;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // flutter_test installs an HttpClient that answers 400 to every request, so
  // the fetch below — a real socket against the pinned URLs — would never see
  // the model. The mock goes for this process.
  HttpOverrides.global = null;

  test('live: SmolVLM sees a picture and answers in a sentence', () async {
    final Directory dir = Directory(
      Platform.environment['NEXUS_VISION_DIR'] ?? '/tmp/nexus_vision_models',
    )..createSync(recursive: true);
    final VisionModelFiles files = VisionModelFiles(
      kVisionSmall,
      directory: () async => dir,
    );

    if (!await files.isPresent()) {
      // ignore: avoid_print
      print(
        'FETCHING ${kVisionSmall.weights.url} + '
        '${kVisionSmall.projector.url}',
      );
      final DateTime started = DateTime.now();
      int last = -1;
      final bool fetched = await files.download(
        onProgress: (double progress) {
          final int percent = (progress * 100).round();
          if (percent ~/ 10 != last ~/ 10) {
            last = percent;
            // ignore: avoid_print
            print('  $percent%');
          }
        },
      );
      expect(fetched, isTrue, reason: 'both verified files must arrive');
      // ignore: avoid_print
      print(
        'FETCHED ${await files.sizeBytes()} bytes in '
        '${DateTime.now().difference(started).inSeconds}s',
      );
    }
    expect(await files.isPresent(), isTrue);

    final Directory pictures = Directory.systemTemp.createTempSync('vlm_shot');
    addTearDown(() {
      if (pictures.existsSync()) pictures.deleteSync(recursive: true);
    });
    final File picture = await drawScene(pictures);

    final LlamadartVisionInference eyes = LlamadartVisionInference();
    addTearDown(eyes.unload);
    final DateTime loading = DateTime.now();
    await eyes.load(
      weightsPath: (await files.weightsFile()).path,
      projectorPath: (await files.projectorFile()).path,
      threads: 4,
    );
    // ignore: avoid_print
    print('LOADED in ${DateTime.now().difference(loading).inMilliseconds}ms');

    final DateTime asked = DateTime.now();
    final String answer = await eyes.describe(
      imagePath: picture.path,
      prompt: kVisionSmall.prompt('What is in this picture?'),
    );
    // ignore: avoid_print
    print(
      'ANSWER "$answer" in '
      '${DateTime.now().difference(asked).inMilliseconds}ms',
    );

    expect(answer.trim(), isNotEmpty, reason: 'a sighted model must answer');
    expect(
      answer.trim().toLowerCase(),
      isNot(contains('uploaded')),
      reason: 'the model was asked about a picture, not an upload',
    );
  }, timeout: const Timeout(Duration(minutes: 12)));
}
