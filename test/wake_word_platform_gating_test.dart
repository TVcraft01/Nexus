// The wake word is Android-only in this build. This file proves the gate that
// keeps it from starting anywhere else — at boot, and from the Settings switch
// — because both paths used to call `WakeWord.ensure().start()` unconditionally.
//
// The proof is deliberately not "the platform channel threw". A controller that
// is constructed has already built the ONNX engine, and on iOS the models are
// in the bundle, so "it failed at the channel" would still mean a microphone
// was reached for by code that had no business reaching. The gate returns
// before `ensure()`, so these tests assert that no controller was created at
// all — and that the gate still lets Android through.
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/services.dart' show EventChannel, MethodChannel;
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/mesh/wake_word.dart';

/// A controller whose two halves are fakes: no ONNX, no microphone, no
/// channel. It reports whether [start] was ever called.
class _RecordingController extends WakeWordController {
  _RecordingController()
    : super(engine: _NoEngine(), platform: _NoPlatform());

  int starts = 0;

  @override
  Future<bool> start() async {
    starts++;
    return true;
  }
}

class _NoEngine implements WakeWordEngine {
  @override
  Future<bool> init() async => true;

  @override
  void processAudio(Int16List chunk) {}

  @override
  bool get isActivated => false;

  @override
  void destroy() {}
}

class _NoPlatform extends WakeWordPlatform {
  _NoPlatform()
    : super(
        channel: const MethodChannel('wake_gate_test'),
        audio: const EventChannel('wake_gate_test_audio'),
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Runs [body] as [platform], restoring the platform inside the body: the
  /// framework asserts that no debug variable is left changed when it ends.
  Future<void> asPlatform(
    TargetPlatform platform,
    Future<void> Function() body,
  ) async {
    debugDefaultTargetPlatformOverride = platform;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  setUp(WakeWord.resetForTest);
  tearDown(WakeWord.resetForTest);

  test('iOS never starts the wake word, and never builds a controller', () async {
    await asPlatform(TargetPlatform.iOS, () async {
      expect(await WakeWord.startIfSupported(), isFalse);
      // The gate has to come before `ensure()`: an engine that was built and
      // then abandoned is still an engine loaded for a platform with no audio
      // loop behind the channel.
      expect(WakeWord.isCreated, isFalse);
    });
  });

  test('the boot path is gated, even with the setting stored as on', () async {
    // `assistant_view` binds its callbacks and starts the loop when
    // `store.wakeWord` is true. That value syncs between devices, so a phone
    // that never had the feature can still have it turned on. This is the
    // exact call that path makes.
    const bool storedWakeWord = true;
    await asPlatform(TargetPlatform.iOS, () async {
      if (storedWakeWord) {
        expect(await WakeWord.startIfSupported(), isFalse);
      }
      expect(WakeWord.isCreated, isFalse);
    });
  });

  test('Android still starts, so the gate is not simply "never"', () async {
    final recorder = _RecordingController();
    WakeWord.debugSetCurrent(recorder);

    await asPlatform(TargetPlatform.android, () async {
      expect(await WakeWord.startIfSupported(), isTrue);
      expect(recorder.starts, 1);
    });
  });

  test('a desktop with no wake word is gated too', () async {
    await asPlatform(TargetPlatform.linux, () async {
      expect(await WakeWord.startIfSupported(), isFalse);
      expect(WakeWord.isCreated, isFalse);
    });
  });
}
