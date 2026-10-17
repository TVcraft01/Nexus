// The voice seams, unit-tested without hardware: availability is an honest
// per-platform answer, and a missing/broken speech engine fails gracefully
// instead of crashing the composer. Real audio capture and playback cannot
// run in this environment — these pin the contract the platform channels
// must keep on the user's device, including the three ways an utterance can
// be asked to end and the live words that arrive while it is still going.
import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/services.dart'
    show ByteData, MethodCall, MethodChannel, StandardMethodCodec;
import 'package:flutter_test/flutter_test.dart';

import 'package:nexus/core/speech.dart';

/// One interim result arriving from the platform, exactly as Android's
/// recognizer sends it: a `partial` call on the speech channel carrying
/// `{text}`. [text] of null stands for a call with no argument at all.
Future<void> interim(MethodChannel channel, String? text) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall(
            'partial',
            text == null ? null : <String, dynamic>{'text': text},
          ),
        ),
        (ByteData? _) {},
      );
}

/// One loudness reading arriving the way Android's `onRmsChanged` sends it: an
/// `rms` call carrying `{level}`. [level] of null, or of something that is not a
/// number, stands for a call the seam must not invent a reading from.
Future<void> loudness(MethodChannel channel, Object? level) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall(
            'rms',
            level == null ? null : <String, dynamic>{'level': level},
          ),
        ),
        (ByteData? _) {},
      );
}

void main() {
  // These are plain unit tests, so nothing has stood the binding up for them:
  // the platform side of the seam is reached through it.
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  /// Answers the seam's own calls — `listen`, `finish`, `stop` — recording
  /// them, so what the platform is actually asked for is provable.
  List<String> recordCalls(MethodChannel channel) {
    final List<String> calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call.method);
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    return calls;
  }

  test(
    'desktop: listening and speaking answer honestly that they are unset',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      expect(const SpeechInput().available, isFalse);
      expect(const SpeechOutput().available, isFalse);
      // Never a crash, never a pretend success — just false.
      expect(await const SpeechInput().listen(), isNull);
      expect(await const SpeechOutput().speak('hello'), isFalse);
    },
  );

  test('a live turn ends on the quiet after speech, not on a silent room', () {
    // The three numbers have one job: a room counts as quiet before it counts as
    // having a voice, so a turn cannot be ended by the noise floor it started
    // in — and Android's own silence (-2 dB) is quiet while a raised voice
    // (+10 dB) is a voice, on the scale the meter is drawn from.
    expect(kSpeechSilenceDb, lessThanOrEqualTo(kSpeechQuietDb));
    expect(kSpeechQuietDb, lessThan(kSpeechVoiceDb));
    expect(kSpeechLoudDb, greaterThanOrEqualTo(kSpeechVoiceDb));

    // The pause is a pause: long enough to sit through a breath, short enough
    // that the page does not look broken while it waits.
    expect(
      kSpeechTurnGap.inMilliseconds,
      inInclusiveRange(800, 2000),
    );
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

  test('a verb the recognizer glued to the filename is split back apart', () {
    // Measured on the phone (SM-A256E, 2026-10-11): a spoken "get report.pdf
    // from my pc" came back as "Getreport.pdf from my PC" — one token, no
    // space — and the file grammar needs its verb separated from the name,
    // so the sentence the user said could not be understood at all.
    expect(
      spokenToWritten('Getreport.pdf from my PC'),
      'Get report.pdf from my PC',
    );
    // The same, with the filename still spelled out as words.
    expect(
      spokenToWritten('getreport dot pdf from my pc'),
      'get report.pdf from my pc',
    );
    // Any of the grammar's verbs — including the two-word one, which is
    // written back as two words rather than as the runt it was heard as.
    expect(
      spokenToWritten('fetchnotes.txt from my laptop'),
      'fetch notes.txt from my laptop',
    );
    expect(
      spokenToWritten('sendme budget.xlsx from my desktop'),
      'send me budget.xlsx from my desktop',
    );
    // Nothing else is touched: a verb with a space after it was never glued,
    // and a word that merely begins like a verb has no filename in it.
    expect(
      spokenToWritten('get report.pdf from my pc'),
      'get report.pdf from my pc',
    );
    expect(spokenToWritten('get the weather'), 'get the weather');
    expect(spokenToWritten('copy that'), 'copy that');
    expect(spokenToWritten('getweather report'), 'getweather report');
  });

  test('android without a speech engine fails gracefully', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(const SpeechInput().available, isTrue);
    expect(const SpeechOutput().available, isTrue);
    // No platform channel exists in tests: the invoke fails, both seams
    // answer false/null instead of throwing.
    expect(await const SpeechInput().listen(), isNull);
    expect(await const SpeechOutput().speak('hello'), isFalse);
    // Ending an utterance is never the caller's problem either, whichever way
    // it is asked for.
    await expectLater(const SpeechInput().finish(), completes);
    await expectLater(const SpeechInput().stop(), completes);
  });

  test('the live words an utterance is made of cross to Dart', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    const MethodChannel channel = MethodChannel('dev.nexus.nexus/speech');
    recordCalls(channel);

    final List<String> heard = <String>[];
    final StreamSubscription<String> watching = const SpeechInput().partials
        .listen(heard.add);
    addTearDown(watching.cancel);

    // Opening the microphone is what claims the channel the interim words come
    // back on, and the stream is a broadcast one: nothing is buffered, so a
    // subscriber that arrives late hears only what is said after it.
    expect(await const SpeechInput().listen(), isNull);

    await interim(channel, 'hello');
    await interim(channel, 'hello world');
    // And nothing at all for the shapes that carry no words: a blank partial,
    // and a call whose argument is not the map this seam documents.
    await interim(channel, '   ');
    await interim(channel, null);
    await pumpEventQueue();

    expect(heard, <String>['hello', 'hello world']);
  });

  test('the loudness the microphone hears crosses to Dart while it listens', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    const MethodChannel channel = MethodChannel('dev.nexus.nexus/speech');
    recordCalls(channel);

    final List<double> levels = <double>[];
    final StreamSubscription<double> watching = const SpeechInput().rms.listen(
      levels.add,
    );
    addTearDown(watching.cancel);

    // Opening the microphone is what claims the channel the readings come back
    // on — the meter on the receiving end is only ever fed inside a session.
    expect(await const SpeechInput().listen(), isNull);

    await loudness(channel, 4.5);
    // And nothing for the shapes that carry no reading: a call with no argument,
    // and one whose level is not a number.
    await loudness(channel, null);
    await loudness(channel, 'loud');
    await pumpEventQueue();

    expect(levels, <double>[4.5]);
  });

  test('a dB reading becomes the meter\'s 0..1, clamped at both ends', () {
    // Android's own scale, from `onRmsChanged`: -2 dB is a silent room and +10 a
    // raised voice. Those are the ends of the meter, and there is nothing to
    // draw outside them — a room louder than a shout is not a taller bar.
    expect(rmsToLevel(kSpeechSilenceDb), 0);
    expect(rmsToLevel(kSpeechLoudDb), 1);
    expect(rmsToLevel(-40), 0);
    expect(rmsToLevel(30), 1);
    // Halfway up the scale is halfway up the bars.
    expect(rmsToLevel(4), closeTo(0.5, 0.0001));
  });

  test(
    'a released finger asks for the transcript; a cancelled one does not',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      const MethodChannel channel = MethodChannel('dev.nexus.nexus/speech');
      final List<String> calls = recordCalls(channel);

      // Held: the recognizer is opened.
      await const SpeechInput().listen();
      // Released on the button: ended with its words kept.
      await const SpeechInput().finish();
      // The finger left the button, or the guard fired: ended and thrown away.
      await const SpeechInput().stop();

      expect(calls, <String>['listen', 'finish', 'stop']);
    },
  );

  test(
    'a desktop that cannot listen does not pretend to end utterances',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      const MethodChannel channel = MethodChannel('dev.nexus.nexus/speech');
      final List<String> calls = recordCalls(channel);

      await const SpeechInput().listen();
      await const SpeechInput().finish();
      await const SpeechInput().stop();

      // Not one call: there is no recognizer here to hold or to end.
      expect(calls, isEmpty);
    },
  );
}
