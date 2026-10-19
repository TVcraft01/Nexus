// The ML Kit vision layer, without ML Kit.
//
// The real OCR and labeler are platform channels this machine does not have, so
// the two readers are constructor seams. What is pinned here is everything the
// phone actually gets wrong if it is wrong: the exact sentence handed to the
// local brain, the top-five cut, the no-findings fallback, and failures arriving
// as a sentence rather than an exception in a bubble.
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/attachments.dart';
import 'package:nexus/core/ml_vision_service.dart';
import 'package:nexus/core/ollama_service.dart' show OllamaException;
import 'package:nexus/core/vision_ai.dart';

void main() {
  test('formats OCR and the top five labels into the brain prompt', () async {
    final List<String> prompts = <String>[];
    final MlVisionService service = MlVisionService(
      readText: (_) async => 'STOP\nMain Street',
      readLabels: (_) async => const <String>[
        'Dog',
        'Outdoor',
        'Car',
        'Grass',
        'Sky',
        'Tree',
      ],
      answer: (String prompt) async {
        prompts.add(prompt);
        return 'A dog beside a road.';
      },
    );

    final String answer = await service.describe(
      '/tmp/photo.jpg',
      question: kPhotoPrompt,
    );

    expect(answer, 'A dog beside a road.');
    expect(
      prompts.single,
      '[User attached an image. OCR Text: "STOP\nMain Street", '
      'Objects in image: Dog, Outdoor, Car, Grass, Sky. '
      'User asked: "[User attached a photo]"]',
    );
  });

  test(
    'a picture with no words and no objects keeps the placeholder',
    () async {
      var asked = false;
      final MlVisionService service = MlVisionService(
        readText: (_) async => '   ',
        readLabels: (_) async => const <String>[],
        answer: (_) async {
          asked = true;
          return 'invented';
        },
      );

      expect(
        await service.describe('/tmp/photo.jpg', question: kPhotoPrompt),
        kPhotoPrompt,
      );
      expect(
        asked,
        isFalse,
        reason: 'a blind prompt is not sent to a text brain',
      );
    },
  );

  test('an empty label list makes the OCR-only prompt explicit', () async {
    final List<String> prompts = <String>[];
    final MlVisionService service = MlVisionService(
      readText: (_) async => 'Platform 9',
      readLabels: (_) async => const <String>[],
      answer: (String prompt) async {
        prompts.add(prompt);
        return 'The sign says Platform 9.';
      },
    );

    await service.describe('/tmp/photo.jpg', question: 'what does it say?');

    expect(prompts.single, contains('OCR Text: "Platform 9"'));
    expect(prompts.single, contains('Objects in image: none'));
    expect(prompts.single, contains('User asked: "what does it say?"'));
  });

  test('an action object from the chat brain becomes the evidence', () async {
    final MlVisionService service = MlVisionService(
      readText: (_) async => 'STOP',
      readLabels: (_) async => const <String>['Dog', 'Outdoor'],
      answer: (_) async => '{"action":"get_time"}',
    );

    expect(
      await service.describe('/tmp/photo.jpg', question: kPhotoPrompt),
      'In the image I can see Dog, Outdoor. The text reads "STOP".',
    );
  });

  test('a JSON answer field is unwrapped', () async {
    final MlVisionService service = MlVisionService(
      readText: (_) async => '',
      readLabels: (_) async => const <String>['Dog'],
      answer: (_) async => '{"result":"A dog outside."}',
    );

    expect(
      await service.describe('/tmp/photo.jpg', question: kPhotoPrompt),
      'A dog outside.',
    );
  });

  test('a brain failure is a sentence, not a throw', () async {
    final MlVisionService service = MlVisionService(
      readText: (_) async => 'hello',
      readLabels: (_) async => const <String>['Text'],
      answer: (_) async => throw const OllamaException('No PC found.'),
    );

    expect(
      await service.describe('/tmp/photo.jpg', question: kPhotoPrompt),
      'No PC found.',
    );
  });

  test('a reader failure does not throw away the other reader', () async {
    final List<String> prompts = <String>[];
    final MlVisionService service = MlVisionService(
      readText: (_) async => throw StateError('no OCR model'),
      readLabels: (_) async => const <String>['Dog', 'Outdoor'],
      answer: (String prompt) async {
        prompts.add(prompt);
        return 'A dog outside.';
      },
    );

    expect(
      await service.describe('/tmp/photo.jpg', question: kPhotoPrompt),
      'A dog outside.',
    );
    expect(prompts.single, contains('OCR Text: "none"'));
    expect(prompts.single, contains('Objects in image: Dog, Outdoor'));
  });

  test('is available when a reader is installed', () {
    final MlVisionService service = MlVisionService(readText: (_) async => '');

    expect(service, isA<VisionAiService>());
    expect(service.available, isTrue);
  });
}
