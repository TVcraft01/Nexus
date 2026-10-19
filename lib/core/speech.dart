// Voice input for the assistant: one seam the composer taps, with the
// Android real implementation behind the `dev.nexus.nexus/speech` channel
// and an honest "not on this device" everywhere else — the same thin
// platform split the phone and clipboard backends use. The recognized text
// is just an ask: it runs through the exact same pipeline as typing.
//
// Four things cross this seam, and they are four because they answer four
// different questions. [SpeechInput.listen] is the final transcript — what was
// said. [SpeechInput.partials] is what the recognizer *thinks* was said while it
// is still listening, so a composer can show the sentence forming. [SpeechInput.rms]
// is how *loud* the room is this instant, which is what a level meter is drawn
// from: the words say what was said, and the level says a voice is being heard at
// all. [SpeechInput.finish]/[SpeechInput.stop] end the utterance, and the
// difference between them is the whole point of a voice note: finish keeps the
// words, stop throws them away.
import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, visibleForTesting;
import 'package:flutter/services.dart' show MethodCall, MethodChannel;

/// What a recognizer hands back is what it *heard*, not what was meant:
/// "report.pdf" comes back as "report dot pdf", and the file-fetch grammar
/// needs the extension to see a file at all. So the spoken seam writes the
/// spoken dot back as the character it stands for.
///
/// Deliberately narrow, so it can only ever help: the dot is written back
/// only where a *filename* is ending — one to eight word characters after the
/// spoken dot, and then either the end of the sentence or the
/// `from`/`to <device>` that names where the file is going. A sentence that
/// merely contains the word "dot" ("that is the dot in the middle") is left
/// exactly as it was heard, and typed text never passes through here at all.
///
/// The second repair is the other half of the same problem: a recognizer runs
/// words together as readily as it writes them out. Measured on the phone,
/// "get report.pdf from my pc" came back as **"Getreport.pdf from my PC"** —
/// one token, no space — and the file-fetch grammar needs its verb separated
/// from the name (`^(get|fetch|send me|copy) …`), so the sentence the user
/// said could not be understood at all. [gluedVerbSplit] puts the space back.
String spokenToWritten(String heard) => gluedVerbSplit(
  heard.replaceAllMapped(
    RegExp(
      r'\s*\b(?:dot|period)\s+([A-Za-z0-9]{1,8})\b'
      r'(?=\s+(?:from|to|onto|into)\b|$)',
      caseSensitive: false,
    ),
    // Extensions are written lower-case on disk, and a recognizer capitalises
    // whatever it likes ("Report Dot PDF"); the name it heard is left alone.
    (match) => '.${match[1]!.toLowerCase()}',
  ),
);

/// What a glued verb has to be written as for the file grammar to read it:
/// the verbs are the grammar's own (`get|fetch|send me|copy`), longest first
/// so a longer verb is never mistaken for a shorter one plus its leftovers.
const _gluedVerbs = <String, String>{
  'sendme': 'send me',
  'fetch': 'fetch',
  'copy': 'copy',
  'get': 'get',
};

/// Collapses the double space a glue repair can leave behind.
final _extraSpace = RegExp(r' {2,}');

/// Looks like the start of a filename: something with an extension on it, so
/// `report.pdf` yes, `weather report` no.
final _filenameStart = RegExp(r'^[A-Za-z0-9][\w .\-]*\.[A-Za-z0-9]{1,8}\b');

/// Splits a verb a recognizer glued to the next word: `Getreport.pdf …` comes
/// back as `Get report.pdf …`, `sendme notes.txt …` as `send me notes.txt …`.
///
/// Only the first word is examined, only after a verb the file grammar itself
/// accepts, and only when what follows really does look like a filename — so
/// ordinary speech is left alone: `get weather` (no verb glued), `copy that`
/// and `fetch` (nothing to separate) all come back exactly as heard, and a
/// name the user happens to own that begins with a verb (`getreport.pdf` as a
/// literal filename) is read as verb + name. That last case is the price of
/// understanding the sentence a real recognizer produced, and it is paid only
/// here — typed text never passes through this seam at all.
String gluedVerbSplit(String heard) {
  final space = heard.indexOf(' ');
  final head = space < 0 ? heard : heard.substring(0, space);
  final tail = space < 0 ? '' : heard.substring(space);
  final lower = head.toLowerCase();
  for (final entry in _gluedVerbs.entries) {
    final glued = entry.key;
    // Nothing glued: the word IS the verb the grammar wants ("get the
    // weather", "copy that"). Compared against the *written* form, because
    // "sendme" is itself the glue — the missing space is inside it.
    if (!lower.startsWith(glued) || lower == entry.value) continue;
    final rest = head.substring(glued.length);
    if (!_filenameStart.hasMatch('$rest$tail'.trim())) continue;
    // Only the missing space is added: the words keep the case they were
    // heard in ("Sendme" is written "Send me", not "Send Me" or "send me").
    final written = entry.value.split(' ');
    final verb = [
      head.substring(0, written.first.length),
      ...written.skip(1),
    ].join(' ');
    return '$verb $rest$tail'.replaceAll(_extraSpace, ' ');
  }
  return heard;
}

class SpeechInput {
  const SpeechInput();

  /// Test seam: a fake recognizer for widget tests (like
  /// [QueryLog.readAllOverride]).
  @visibleForTesting
  static SpeechInput Function()? override;

  static SpeechInput get current => override?.call() ?? const SpeechInput();

  /// Whether this device can listen at all. Android can; desktops answer
  /// honestly that voice input isn't set up here.
  bool get available => defaultTargetPlatform == TargetPlatform.android;

  /// The words the recognizer is still working on, as it revises them.
  ///
  /// A broadcast stream, because the shell subscribes for the length of one
  /// session and a session is not the only thing that could ever want these.
  /// It carries what the recognizer *guesses* — the guesses are cumulative
  /// ("hello", then "hello world") and each one replaces the last, so a
  /// subscriber that shows them is showing the sentence form, not a log.
  /// Nothing is buffered: words said while nobody is listening are gone.
  Stream<String> get partials => _partials.stream;

  /// How loud the microphone is hearing right now, in the platform's own units —
  /// Android's `onRmsChanged` reading in dB, where [kSpeechSilenceDb] is a silent
  /// room and [kSpeechLoudDb] a raised voice ([rmsToLevel] is the mapping a meter
  /// uses).
  ///
  /// Broadcast for the same reason [partials] is, and fed only while a session
  /// is live: the platform sends a reading from inside [listen]'s session and
  /// stops with it, so nothing is buffered and a subscriber that arrives late
  /// hears nothing rather than the last thing the room said.
  Stream<double> get rms => _rms.stream;

  /// Listens for one utterance and returns the recognized text, or null
  /// when nothing was heard, the user cancelled, or voice isn't available.
  Future<String?> listen() async {
    if (!available) return null;
    _wireChannel();
    try {
      return await _channel.invokeMethod<String>('listen');
    } catch (_) {
      return null; // never crash the composer for a mic failure
    }
  }

  /// Ends the utterance *and keeps its words*: the recognizer is asked to hand
  /// over its best transcript now, instead of being cancelled. The pending
  /// [listen] resolves with it.
  ///
  /// This is what a released hold-to-talk finger means — the sentence the user
  /// said is the sentence they want — where [stop] is what abandoning the
  /// gesture means. Never throws and never blocks: a seam that fails here just
  /// leaves the recognizer to end the utterance on its own.
  Future<void> finish() async {
    if (!available) return;
    try {
      await _channel.invokeMethod<void>('finish');
    } catch (_) {
      // Nothing to do: the recognizer's own end-of-speech still answers.
    }
  }

  /// Stops the utterance in flight: the finger left the button, or the screen
  /// went away. Answers like hearing nothing, so the caller has one idle path
  /// (a pending [listen] resolves null). Never throws, never blocks on the
  /// recognizer acknowledging — the microphone is released on the platform
  /// side either way.
  Future<void> stop() async {
    if (!available) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {
      // A mic that cannot be stopped is not something the composer can fix.
    }
  }

  /// Sets the recognizer's language for the next utterance.
  ///
  /// A BCP-47 tag (`en-US`, `fr-FR`). The platform owns the actual model; a
  /// language it does not have installed falls back to the device's own, which
  /// is the honest outcome and not something this seam can promise around.
  /// Never throws: a missing channel leaves the recognizer on its own default.
  Future<void> setLanguage(String locale) async {
    if (!available) return;
    try {
      await _channel.invokeMethod<void>('setLanguage', <String, Object?>{
        'locale': locale,
      });
    } catch (_) {
      // No channel: the platform's own locale is still a working answer.
    }
  }

  /// One controller for every [partials] subscriber, one for every [rms]
  /// subscriber, and one handler for the platform's calls. Installed on the
  /// first [listen] rather than at import time, so a build that never opens the
  /// microphone never claims the channel.
  static final StreamController<String> _partials =
      StreamController<String>.broadcast();

  static final StreamController<double> _rms =
      StreamController<double>.broadcast();

  static bool _wired = false;

  static void _wireChannel() {
    if (_wired) return;
    _wired = true;
    _channel.setMethodCallHandler((MethodCall call) async {
      final args = call.arguments;
      // Two things arrive on this channel while an utterance is in flight, and
      // they are shaped differently on purpose: `partial` carries words, `rms`
      // carries one number. Anything else on this channel is not ours to guess
      // at, and an empty one of either is not worth forwarding.
      if (call.method == 'rms') {
        final level = args is Map ? args['level'] : null;
        if (level is num) _rms.add(level.toDouble());
        return null;
      }
      if (call.method != 'partial') return null;
      final text = args is Map ? args['text'] : null;
      if (text is String && text.trim().isNotEmpty) _partials.add(text);
      return null;
    });
  }

  static const _channel = MethodChannel('dev.nexus.nexus/speech');
}

/// Where the platform's own loudness reading stops meaning "a silent room" and
/// starts meaning "a raised voice".
///
/// Android's scale, from the documentation for
/// `RecognitionListener.onRmsChanged`: the value is in dB and "typically ranges
/// from -2.0 to 10.0", with 0 as the reference. Those two numbers are therefore
/// the ends of the meter, and they live here rather than in the widget so the
/// mapping is testable without a screen.
const double kSpeechSilenceDb = -2;
const double kSpeechLoudDb = 10;

/// Maps a reading from [SpeechInput.rms] onto 0..1 for a level meter: 0 at
/// [kSpeechSilenceDb] and below, 1 at [kSpeechLoudDb] and above.
///
/// Deliberately linear and deliberately clamped. A meter that exaggerated
/// quiet speech would look alive on a phone that was hearing nothing, which is
/// the one thing this reading exists to rule out.
double rmsToLevel(double rmsDb) =>
    ((rmsDb - kSpeechSilenceDb) / (kSpeechLoudDb - kSpeechSilenceDb)).clamp(
      0.0,
      1.0,
    );

/// Where a live turn decides that the user has started speaking.
///
/// Live conversation has no finger to end it: the page opens the microphone and
/// waits for the recognizer to say the sentence is over. That is a promise the
/// platform does not keep on every ROM — an on-device recognizer that reports
/// interim words will happily sit on the microphone until it is told to stop —
/// so the shell decides for itself, from the loudness readings it already gets
/// for the meter. Above this the room has a voice in it; below [kSpeechQuietDb]
/// it has gone quiet again. In between is neither, which is the hysteresis that
/// keeps a fan from ending a sentence.
const double kSpeechVoiceDb = 2;

/// Where a room counts as quiet enough for a live turn to be over — see
/// [kSpeechVoiceDb]. Above Android's own reference level (0 dB) on purpose: a
/// phone on a desk hums above silence, and a threshold at silence would never
/// let a turn end.
const double kSpeechQuietDb = 0.5;

/// How long the room has to stay quiet after speech before a live turn asks the
/// recognizer for its transcript.
///
/// A pause rather than a stopwatch: it restarts on every word (an interim
/// result) and every loud reading, so it only ever fires on a speaker who has
/// actually stopped.
///
/// Two seconds, raised from 1.2s on the strength of using it: the shorter window
/// ended turns while the speaker was still thinking — mid-sentence, at the pause
/// before the point — and the user watched their own turn close under them. The
/// cost is the other side of the same coin: a sentence that is over waits two
/// seconds before it is answered, which is a pause a listener takes too.
const Duration kSpeechTurnGap = Duration(milliseconds: 2000);

/// How long live conversation waits after the assistant's voice stops before it
/// opens the microphone again.
///
/// A beat rather than an instant: the answer has to land, and the user has to
/// have a moment to say "stop" before the room starts listening to itself. Live
/// mode is a conversation, so the default is to hand the turn back — the page
/// still stops for good when the user taps Stop speaking or closes it.
const Duration kLiveAutoListenDelay = Duration(milliseconds: 1500);

/// Speaking for the assistant: reads a reply out loud on devices that can.
/// Android speaks through the system text-to-speech engine (fully on-device,
/// no network — the same zero-cloud rule as the mic); everywhere else this
/// answers honestly that spoken replies aren't set up here, and the
/// assistant simply stays a text companion.
class SpeechOutput {
  const SpeechOutput();

  /// Test seam, like [SpeechInput.override]: a fake speaker for widget
  /// tests, so "the assistant said X" is provable without hardware.
  @visibleForTesting
  static SpeechOutput Function()? override;

  static SpeechOutput get current => override?.call() ?? const SpeechOutput();

  /// Whether this device can read replies out loud at all.
  bool get available => defaultTargetPlatform == TargetPlatform.android;

  /// Fires once for every utterance that finishes — spoken to its end, cut off
  /// by a newer reply, or stopped by the user. Live conversation waits for this
  /// before it reopens the microphone: listening while the phone is still
  /// talking would feed the assistant its own voice.
  ///
  /// A broadcast stream, and empty when the platform has no engine: a caller
  /// that only schedules work here simply never hears anything.
  Stream<void> get spoken => _spoken.stream;

  /// Says [text] out loud. Returns true when the utterance was handed to
  /// the speech engine. Never throws — a device that can't speak (or a
  /// speech engine that fails) just means the text stays on the card.
  Future<bool> speak(String text) async {
    if (!available) return false;
    _wireChannel();
    try {
      return await _channel.invokeMethod<bool>('speak', {'text': text}) ??
          false;
    } catch (_) {
      return false; // never crash the assistant for a speech failure
    }
  }

  /// Creates the platform's speech engine before the first reply needs it.
  ///
  /// Text-to-speech is constructed asynchronously, and a first sentence that
  /// arrives while it is still initialising is the one that feels slow. Asking
  /// at startup moves that cost to the launch screen, where nobody is waiting
  /// on a voice. Never throws and never blocks a frame.
  Future<bool> warmUp() async {
    if (!available) return false;
    _wireChannel();
    try {
      return await _channel.invokeMethod<bool>('warmUp') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Sets the spoken language for every later utterance.
  ///
  /// Same tag as [SpeechInput.setLanguage]; the two are set together by
  /// `VoiceSettings` so a user who chooses French does not get an English
  /// voice reading French words.
  Future<void> setLanguage(String locale) async {
    if (!available) return;
    _wireChannel();
    try {
      await _channel.invokeMethod<void>('setLanguage', <String, Object?>{
        'locale': locale,
      });
    } catch (_) {
      // A speaker that refuses a language still speaks in its own.
    }
  }

  /// Cuts the utterance off now. The one control over a phone that has started
  /// talking: a user who has heard enough should not have to wait it out.
  ///
  /// Never throws, and answers as soon as the stop is asked for rather than
  /// when the engine confirms it.
  Future<void> stop() async {
    if (!available) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {
      // A speaker that cannot be stopped is not something the caller can fix.
    } finally {
      _spoken.add(null);
    }
  }

  static final StreamController<void> _spoken =
      StreamController<void>.broadcast();

  static bool _wired = false;

  /// Listens for the platform's `done` call. Installed on the first [speak], so
  /// a build that never reads anything aloud never claims the channel.
  static void _wireChannel() {
    if (_wired) return;
    _wired = true;
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'done') _spoken.add(null);
      return null;
    });
  }

  static const _channel = MethodChannel('dev.nexus.nexus/speech_out');
}
