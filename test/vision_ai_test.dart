// The vision seam, before there is anything behind it.
//
// The brains this build runs are text models, so a picture must never be handed
// to one: asked "what is this?" with only `[User attached a photo]` to go on, a
// model invents a description, and the user cannot tell that from a sighting.
// These tests pin the honest answer and — just as important — the phrasings the
// shell does *not* claim, so an ordinary question is never answered with a
// notice about a camera.
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/vision_ai.dart';

void main() {
  group('the shipped service', () {
    test('has no eyes, and says so', () async {
      const VisionAiService service = MissingVisionAi();
      expect(service.available, isFalse);
      expect(
        await service.describe('/tmp/photo.png', question: 'what is this?'),
        kNexusVisionMissingText,
      );
    });

    test('the sentence names the photo and the missing module', () {
      expect(kNexusVisionMissingText, contains('photo'));
      expect(kNexusVisionMissingText, contains('vision module'));
      expect(kNexusVisionMissingText, contains('not installed'));
    });

    test(
      'the current service is the missing one when nothing is installed',
      () {
        addTearDown(() => VisionAiService.override = null);
        VisionAiService.override = null;
        expect(VisionAiService.current, isA<MissingVisionAi>());
        expect(VisionAiService.current.available, isFalse);
      },
    );
  });

  group('what counts as a question about the picture', () {
    test('this, that, and what you can see', () {
      for (final String said in <String>[
        'What is this?',
        "what's this",
        'what is that',
        'what is this photo',
        'What do you see?',
        'what can you see',
        'what do you see in this picture',
        'describe this',
        'describe the image',
        'look at this',
        'read this',
        'what is in this photo',
        'what is on the screenshot',
      ]) {
        expect(isVisionQuestion(said), isTrue, reason: said);
      }
    });

    test('a question about the app, or the world, is not one', () {
      for (final String said in <String>[
        'what is this app',
        'what is this for',
        'what is 2 + 2',
        'what is the weather',
        'what is a mesh network',
        'tell me a joke',
        'is this a good phone',
        '',
      ]) {
        expect(isVisionQuestion(said), isFalse, reason: said);
      }
    });
  });
}
