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

  test('spoken filenames are written back as files', () {
    // What the microphone actually returns for "get report.pdf from my pc"
    // — measured on the phone, the recognizer writes the filename as words.
    expect(
      spokenToWritten('get report dot pdf from my pc'),
      'get report.pdf from my pc',
    );
    expect(
      spokenToWritten('Get Report Dot PDF From My PC'),
      'Get Report.pdf From My PC',
    );
    // A file named with no destination: the spoken dot ends the sentence.
    expect(spokenToWritten('open notes period txt'), 'open notes.txt');
    expect(
      spokenToWritten('get todo dot txt to my phone'),
      'get todo.txt to my phone',
    );
    // Nothing else is touched: ordinary speech, and a dot that is not
    // ending a filename, come back exactly as they were heard.
    expect(spokenToWritten('what time is it'), 'what time is it');
    expect(
      spokenToWritten('that is the dot in the middle'),
      'that is the dot in the middle',
    );
    expect(spokenToWritten(''), '');
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