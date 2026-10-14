import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/mesh/wake_word.dart';

/// Fake engine: no ONNX, no microphone. Each chunk either trips the latch
/// ([fireOnChunk]) or clears it, mirroring isActivated's latch-then-clear
/// read.
class FakeEngine implements WakeWordEngine {
  bool initResult = true;
  bool fireOnChunk = false;
  bool _activated = false;
  bool destroyed = false;

  @override
  Future<bool> init() async => initResult;

  @override
  void processAudio(Int16List chunk) {
    _activated = fireOnChunk;
  }

  @override
  bool get isActivated => _activated;

  @override
  void destroy() {
    destroyed = true;
    _activated = false;
  }
}

/// Fake platform: no MethodChannel, no EventChannel — calls are counted and
/// audio is a test-owned broadcast stream.
class FakePlatform extends WakeWordPlatform {
  FakePlatform()
    : super(
        channel: const MethodChannel('wake_word_test'),
        audio: const EventChannel('wake_word_test_audio'),
      );

  final StreamController<dynamic> incoming =
      StreamController<dynamic>.broadcast();
  int startCalls = 0;
  int stopCalls = 0;
  bool startResult = true;

  @override
  Future<bool> start() async {
    startCalls++;
    return startResult;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  Stream<dynamic> audioStream() => incoming.stream;
}

/// 80 ms of silence at 16 kHz mono — shape is what matters, not content.
Uint8List silentChunk() => Uint8List(1280 * 2);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('toggle off: the native loop is never started', () async {
    final engine = FakeEngine();
    final platform = FakePlatform();
    final controller = WakeWordController(
      engine: engine,
      platform: platform,
    );
    addTearDown(() async {
      await controller.stop();
      await platform.incoming.close();
    });

    // Never started: stopping is a no-op that touches nothing native.
    await controller.stop();
    expect(controller.running, isFalse);
    expect(platform.startCalls, 0);
    expect(platform.stopCalls, 0);
    expect(engine.destroyed, isFalse);
  });

  test('toggle on: engine init then the native loop, running', () async {
    final engine = FakeEngine();
    final platform = FakePlatform();
    final controller = WakeWordController(
      engine: engine,
      platform: platform,
    );
    addTearDown(() async {
      await controller.stop();
      await platform.incoming.close();
    });

    expect(await controller.start(), isTrue);
    expect(controller.running, isTrue);
    expect(platform.startCalls, 1);

    // A refused engine never reaches the microphone.
    final deadEngine = FakeEngine()..initResult = false;
    final deadPlatform = FakePlatform();
    final dead = WakeWordController(
      engine: deadEngine,
      platform: deadPlatform,
    );
    addTearDown(() async {
      await dead.stop();
      await deadPlatform.incoming.close();
    });
    expect(await dead.start(), isFalse);
    expect(deadPlatform.startCalls, 0);
  });

  test('detection: one wake arms listening, cooldown eats the echo', () async {
    final engine = FakeEngine()..fireOnChunk = true;
    final platform = FakePlatform();
    final controller = WakeWordController(
      engine: engine,
      platform: platform,
    );
    var wakes = 0;
    controller.onWake = () => wakes++;
    addTearDown(() async {
      await controller.stop();
      await platform.incoming.close();
    });

    expect(await controller.start(), isTrue);
    platform.incoming.add(silentChunk());
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(wakes, 1);

    // Same utterance still scoring: the cooldown suppresses the re-fire.
    platform.incoming.add(silentChunk());
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(wakes, 1);
  });

  test('silence: an unanswered wake goes idle, speech cancels it', () async {
    final engine = FakeEngine();
    final platform = FakePlatform();
    final controller = WakeWordController(
      engine: engine,
      platform: platform,
      listenWindow: const Duration(milliseconds: 50),
    );
    var timeouts = 0;
    controller.onSilenceTimeout = () => timeouts++;
    addTearDown(() async {
      await controller.stop();
      await platform.incoming.close();
    });

    // Nobody answers the armed mic: the window expires silently.
    controller.beginUtteranceWindow();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(timeouts, 1);

    // Speech arrived this time: the window is cancelled, no second timeout.
    controller.beginUtteranceWindow();
    controller.heardSpeech();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(timeouts, 1);
  });
}
