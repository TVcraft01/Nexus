// The one interface between Nexus and whichever engine can see.
//
// Two things are pinned here, and they fail in different ways:
//
//   1. The method-channel contract. `dev.nexus.nexus/vision` is answered by
//      Kotlin on Android and Swift on iOS. What can go wrong is the wire shape:
//      a path sent under the wrong key, labels arriving as maps when Dart
//      expects strings, a platform that answers `null`. The mock handler below
//      is the only way to test that on a machine with neither phone.
//
//   2. The no-engine path. A desktop shell, or a `flutter test` run here, has no
//      handler at all and throws MissingPluginException. That must surface as
//      VisionUnavailable and leave the app saying "nothing found", never as a
//      crash in a bubble.
//
// The service-level formatting is already covered by ml_vision_service_test.dart
// through its reader seams; this file tests the layer beneath those seams.
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/ml_vision_service.dart';
import 'package:nexus/core/vision_engine.dart';

/// A stand-in engine: records what was asked, answers what the test says.
class _FakeEngine implements VisionEngine {
  _FakeEngine({this.text = '', this.labels = const <String>[]});

  final String text;
  final List<String> labels;
  final List<String> calls = <String>[];

  @override
  Future<String> recognizeText(String path) async {
    calls.add('recognizeText:$path');
    return text;
  }

  @override
  Future<List<String>> labelObjects(String path) async {
    calls.add('labelObjects:$path');
    return labels;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = PlatformVisionEngine.channel;

  void mockChannel(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    VisionEngine.override = null;
    debugDefaultTargetPlatformOverride = null;
  });

  group('the channel contract', () {
    test('the channel name is the one both platforms listen on', () {
      // Pinned literally: VisionBridge.kt and VisionBridge.swift both hard-code
      // this string, so a rename on one side has to fail here first.
      expect(kVisionChannelName, 'dev.nexus.nexus/vision');
      expect(channel.name, 'dev.nexus.nexus/vision');
    });

    test('recognizeText sends the path and returns the words', () async {
      final List<MethodCall> seen = <MethodCall>[];
      mockChannel((MethodCall call) async {
        seen.add(call);
        return 'STOP\nMain Street';
      });

      final String text = await const PlatformVisionEngine()
          .recognizeText('/tmp/photo.jpg');

      expect(text, 'STOP\nMain Street');
      expect(seen.single.method, 'recognizeText');
      expect(seen.single.arguments, <String, Object?>{'path': '/tmp/photo.jpg'});
    });

    test('labelObjects unpacks label maps, in the order the platform sent them',
        () async {
      mockChannel((MethodCall call) async {
        expect(call.method, 'labelObjects');
        expect(call.arguments, <String, Object?>{'path': '/tmp/dog.jpg'});
        return <Object?>[
          <String, Object?>{'label': 'Dog', 'confidence': 0.91},
          <String, Object?>{'label': 'Outdoor', 'confidence': 0.72},
        ];
      });

      final List<String> labels = await const PlatformVisionEngine()
          .labelObjects('/tmp/dog.jpg');

      expect(labels, <String>['Dog', 'Outdoor']);
    });

    test('bare strings are accepted too, so a simpler platform side works',
        () async {
      mockChannel((MethodCall call) async => <Object?>['Dog', '  Couch  ', '']);

      final List<String> labels = await const PlatformVisionEngine()
          .labelObjects('/tmp/dog.jpg');

      // Trimmed, and the empty entry dropped rather than joining into the
      // prompt as ", , Couch".
      expect(labels, <String>['Dog', 'Couch']);
    });

    test('a null or odd answer is an empty result, not a crash', () async {
      mockChannel((MethodCall call) async => null);
      expect(
        await const PlatformVisionEngine().labelObjects('/tmp/x.jpg'),
        isEmpty,
      );
      expect(await const PlatformVisionEngine().recognizeText('/tmp/x.jpg'), '');

      mockChannel((MethodCall call) async => <Object?>[42, null, 'Dog']);
      expect(
        await const PlatformVisionEngine().labelObjects('/tmp/x.jpg'),
        <String>['Dog'],
      );
    });
  });

  group('no engine on this platform', () {
    test('a missing handler is VisionUnavailable, not MissingPluginException',
        () async {
      // No mock installed: exactly what a Linux or Windows build does.
      await expectLater(
        const PlatformVisionEngine().recognizeText('/tmp/photo.jpg'),
        throwsA(isA<VisionUnavailable>()),
      );
      await expectLater(
        const PlatformVisionEngine().labelObjects('/tmp/photo.jpg'),
        throwsA(isA<VisionUnavailable>()),
      );
    });

    test('a PlatformException is VisionFailed, carrying the platform message',
        () async {
      mockChannel((MethodCall call) async {
        throw PlatformException(code: 'OCR_FAILED', message: 'Could not read');
      });

      await expectLater(
        const PlatformVisionEngine().recognizeText('/tmp/photo.jpg'),
        throwsA(
          isA<VisionFailed>().having(
            (VisionFailed error) => error.message,
            'message',
            'Could not read',
          ),
        ),
      );
    });

    // `flutter test` reports the *Android* platform unless told otherwise, so
    // the desktop case has to be stated rather than assumed — which is also the
    // reason a Windows or Linux build gets here with no engine at all.
    test('a desktop build has no engine and says so', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      expect(VisionEngine.isSupported, isFalse);
      expect(VisionEngine.current, isNull);
      // The bridge at the bottom of the stack: MlVisionService asks whether
      // there is an engine at all before offering to describe a picture.
      expect(MlVisionService().available, isFalse);
    });

    test('the two phone platforms have one, and desktop does not', () {
      for (final TargetPlatform platform in <TargetPlatform>[
        TargetPlatform.android,
        TargetPlatform.iOS,
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        expect(VisionEngine.isSupported, isTrue, reason: '$platform');
        expect(VisionEngine.current, isA<PlatformVisionEngine>(),
            reason: '$platform');
        expect(MlVisionService().available, isTrue, reason: '$platform');
      }

      for (final TargetPlatform platform in <TargetPlatform>[
        TargetPlatform.linux,
        TargetPlatform.windows,
        TargetPlatform.macOS,
        TargetPlatform.fuchsia,
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        expect(VisionEngine.isSupported, isFalse, reason: '$platform');
      }
    });

    test('an unreadable picture leaves the service owed a sentence, not a throw',
        () async {
      // No handlers, no engine: both passes fail and the turn still answers.
      final MlVisionService service = MlVisionService(
        answer: (String prompt) async => 'unused',
      );

      final String answer = await service.describe('/tmp/photo.jpg');

      // Empty findings mean the caller keeps its own placeholder — the point is
      // that this returns at all, and that it never invented a description.
      expect(answer.trim(), isNotEmpty);
      expect(answer, isNot(contains('unused')));
    });
  });

  group('the service uses whichever engine it is given', () {
    test('both passes go through the engine', () async {
      final _FakeEngine engine = _FakeEngine(
        text: 'EXIT 12',
        labels: <String>['Sign', 'Road'],
      );

      final String answer = await MlVisionService(
        engine: engine,
        answer: (String prompt) async => 'A sign on a road.',
      ).describe('/tmp/sign.jpg', question: '[User attached a photo]');

      expect(answer, 'A sign on a road.');
      expect(engine.calls, <String>[
        'recognizeText:/tmp/sign.jpg',
        'labelObjects:/tmp/sign.jpg',
      ]);
    });

    test('an injected engine overrides the platform one', () {
      VisionEngine.override = _FakeEngine();
      expect(VisionEngine.current, isA<_FakeEngine>());
      expect(VisionEngine.isSupported, isTrue);
      expect(MlVisionService().available, isTrue);
    });

    test('an engine that throws loses no more than its own half', () async {
      // OCR dies, labeling still answers: the picture is described from what
      // did work instead of from nothing.
      final MlVisionService service = MlVisionService(
        engine: _HalfBrokenEngine(),
        answer: (String prompt) async => 'A couch.',
      );

      final String answer = await service.describe('/tmp/room.jpg');

      expect(answer, 'A couch.');
    });
  });
}

/// Reads text by throwing, labels normally.
class _HalfBrokenEngine implements VisionEngine {
  @override
  Future<String> recognizeText(String path) async =>
      throw const VisionFailed('no OCR model');

  @override
  Future<List<String>> labelObjects(String path) async => <String>['Couch'];
}
