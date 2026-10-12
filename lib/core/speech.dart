// Voice input for the assistant: one seam the composer taps, with the
// Android real implementation behind the `dev.nexus.nexus/speech` channel
// and an honest "not on this device" everywhere else — the same thin
// platform split the phone and clipboard backends use. The recognized text
// is just an ask: it runs through the exact same pipeline as typing.
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, visibleForTesting;
import 'package:flutter/services.dart' show MethodChannel;

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

  /// Listens for one utterance and returns the recognized text, or null
  /// when nothing was heard, the user cancelled, or voice isn't available.
  Future<String?> listen() async {
    if (!available) return null;
    try {
      return await _channel.invokeMethod<String>('listen');
    } catch (_) {
      return null; // never crash the composer for a mic failure
    }
  }

  /// Stops the utterance in flight: the second tap on the mic, or the screen
  /// going away. Answers like hearing nothing, so the caller has one idle path
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

  static const _channel = MethodChannel('dev.nexus.nexus/speech');
}

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

  /// Says [text] out loud. Returns true when the utterance was handed to
  /// the speech engine. Never throws — a device that can't speak (or a
  /// speech engine that fails) just means the text stays on the card.
  Future<bool> speak(String text) async {
    if (!available) return false;
    try {
      return await _channel.invokeMethod<bool>('speak', {'text': text}) ??
          false;
    } catch (_) {
      return false; // never crash the assistant for a speech failure
    }
  }

  static const _channel = MethodChannel('dev.nexus.nexus/speech_out');
}