// The handful of sentences that must never wait for a model.
//
// A phone assistant that thinks for four seconds before turning on a torch is
// not an assistant. The vocabulary in [SystemActionCall] is closed and the
// interpreter already knows most of it, so a strict command can be recognised
// here — before a single token is generated — and executed directly.
//
// The rule for adding a phrase is the same one the interpreter uses: it has to
// name an action and every argument it needs. "It's dark in here" is a
// reasonable request for a flashlight, but it is not a *command*, and guessing
// at it here would make the fast path a place where a conversation can turn
// into an action. That is the model's job. This file is only for the Siri-shaped
// sentences a user says when they expect an instant result.
//
// "Call …" is the one phrase the interpreter already understands but the chat
// shell did not act on. It becomes [call_number] here so the phone dials through
// its own dialer rather than asking a 0.5B model to write JSON about it.
library;

import 'system_actions.dart';

/// The call phrase, anchored to the whole sentence. Deliberately narrower than
/// the interpreter's: "ring the changes" is a conversation, and "call it a day"
/// is an idiom. A target is required, and "call me maybe" is a song title, not a
/// request to dial the user.
final RegExp _call = RegExp(
  r'^(?:call|dial)\s+(?:up\s+)?(.+?)[.!?]*$',
  caseSensitive: false,
);

/// Words that make a "call …" sentence something other than a dial request.
const Set<String> _callNotActions = <String>{
  'me',
  'maybe',
  'it',
  'this',
  'that',
  'a',
  'the',
  'back',
  'off',
  'out',
};

/// A strict command in [text], or null when it is a conversation.
///
/// Timer and flashlight go through [actionFromPhrase], which is the same
/// interpreter the composer already consults; call is parsed here because the
/// model's vocabulary now has a dial action and the phrase should reach it
/// without the model. The result is a [SystemActionCall], so the caller runs it
/// through exactly the same executor and bubble as any other action.
SystemActionCall? fastPathAction(String text) {
  final String said = text.trim();
  if (said.isEmpty) return null;
  final RegExpMatch? call = _call.firstMatch(said);
  if (call != null) {
    final String target = call
        .group(1)!
        .trim()
        .replaceFirst(RegExp(r'^(?:the|my)\s+', caseSensitive: false), '')
        .trim();
    final String key = target.toLowerCase();
    final String first = key.split(RegExp(r'\s+')).first;
    if (target.isEmpty ||
        _callNotActions.contains(key) ||
        _callNotActions.contains(first)) {
      return null;
    }
    // Hand the cleaned target back to the interpreter rather than building
    // the call here: it already knows a trailing "on my phone" is a device
    // marker and "on facetime" is a video call the model owns.
    final SystemActionCall? parsed = actionFromPhrase('call $target');
    if (parsed == null || parsed.action != 'call_number') return parsed;
    // The interpreter normalises the whole phrase to lower case, which is
    // right for matching and wrong for the words the user typed: the phone's
    // confirmation said `tvcraft01` for "TVcraft01". When the target came back
    // unchanged, restore the spelling that was spoken — contacts and numbers
    // that were read from it (a device marker removed, video routed away)
    // never enter this branch.
    final Object? resolved = parsed.args['number'];
    final String spokenTarget = target
        .replaceFirst(
          RegExp(r'\s+on\s+(?:my|the)\s+(?:phone|mobile)$', caseSensitive: false),
          '',
        )
        .trim();
    if (resolved is String &&
        spokenTarget.isNotEmpty &&
        resolved.toLowerCase() == spokenTarget.toLowerCase()) {
      return SystemActionCall('call_number', <String, Object?>{
        'number': spokenTarget,
      });
    }
    return parsed;
  }
  return actionFromPhrase(said);
}
