// The voice seams, unit-tested without hardware: availability is an honest
// per-platform answer, and a missing/broken speech engine fails gracefully
// instead of crashing the composer. Real audio capture and playback cannot
// run in this environment — these pin the contract the platform channels
// must keep on the user's device.
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter_test/flutter_test.dart';

import 'package:nexus/core/speech.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('desktop: listening and speaking answer honestly that they are unset', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    expect(const SpeechInput().available, isFalse);
    expect(const SpeechOutput().available, isFalse);
    // Never a crash, never a pretend success — just false.
    expect(await const SpeechInput().listen(), isNull);
    expect(await const SpeechOutput().speak('hello'), isFalse);
  });

  test('android without a speech engine fails gracefully', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(const SpeechInput().available, isTrue);
    expect(const SpeechOutput().available, isTrue);
    // No platform channel exists in tests: the invoke fails, both seams
    // answer false/null instead of throwing.
    expect(await const SpeechInput().listen(), isNull);
    expect(await const SpeechOutput().speak('hello'), isFalse);
  });

}