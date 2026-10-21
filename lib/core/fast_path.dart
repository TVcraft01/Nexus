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

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;

import 'agent_contract.dart' show AgentActions;
import 'command_interpreter.dart'
    show CommandInterpreter, InterpretOutcome, InterpretResult;
import 'system_actions.dart';

/// The interpreter the battery bridge reads with. Const and stateless, like the
/// one in system_actions.dart.
const CommandInterpreter _phrases = CommandInterpreter();

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

/// What Nexus says when it is asked about the weather.
///
/// Pinned word for word, because it is a promise rather than an apology: this
/// app is local-first, nothing here reaches a weather service, and a model
/// asked for tomorrow's forecast will invent a plausible one. A sentence that
/// names the limit is the only honest answer, and it is a fast path because the
/// user should not wait four seconds to be told so.
const String kNoWeatherText =
    'I need internet access to check the weather. I am a local AI.';

/// A weather question, anchored to the words that make one.
///
/// Narrow on purpose: "it's raining" is a remark and stays a conversation. A
/// question about the weather names the weather, a forecast, or the temperature
/// — and gets the one true sentence instead of a guess.
final RegExp _weather = RegExp(
  r'\b(weather|forecast|temperature outside|how (?:hot|cold) is it|'
  r'is it (?:going to )?(?:rain|snow)|will it (?:rain|snow)|'
  r'meteo|météo)\b',
  caseSensitive: false,
);

/// A question whose answer is a fixed sentence rather than the model's, or
/// null when the model is the right place to ask.
///
/// Only the weather lives here: the clock, the date and arithmetic are answered
/// by their own functions ([isClockQuestion], [nexusMathAnswer]) and the battery
/// is a device action, so none of them needs a canned sentence — they need a
/// fast path *to* the thing that really knows.
String? fastPathReply(String text) {
  final String said = text.trim();
  if (said.isEmpty) return null;
  return _weather.hasMatch(said) ? kNoWeatherText : null;
}

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
          RegExp(
            r'\s+on\s+(?:my|the)\s+(?:phone|mobile)$',
            caseSensitive: false,
          ),
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
  // "Battery" and "how much battery is left" are the phone's to answer, and
  // waiting on a model to translate a closed phrase is the four-second torch
  // problem again. The interpreter already recognises the whole family; this is
  // only the bridge from its action to the shell's vocab entry.
  if (said.toLowerCase().contains('battery')) {
    final InterpretResult battery = _phrases.interpret(said);
    if (battery.outcome == InterpretOutcome.matched &&
        battery.command?.action == AgentActions.batteryGet) {
      return const SystemActionCall('get_battery_level');
    }
  }
  return _here(actionFromPhrase(said));
}

/// The actions whose only implementation is the phone's own intents.
///
/// The shell runs on this PC too ([lib/main.dart] starts it everywhere), and
/// there the same sentences are not commands this file can run: the desktop
/// backend answers an `open_app` or a `screenshot` with a gap sentence, so
/// claiming them here would turn "open Spotify" from something the model could
/// answer into a refusal that names the wrong platform. On Android they are the
/// point — a closed list of intents the phone already had.
const Set<String> _phoneOnly = <String>{
  'open_app',
  'send_sms',
  'send_email',
  'navigate_to',
  'screenshot',
  'set_alarm',
  'cancel_alarms',
  'cancel_timers',
  'show_alarms',
  'next_song',
  'previous_song',
};

/// [call] when this device can actually run it, or null when it is the phone's.
SystemActionCall? _here(SystemActionCall? call) {
  if (call == null) return null;
  if (_phoneOnly.contains(call.action) &&
      defaultTargetPlatform != TargetPlatform.android) {
    return null;
  }
  return call;
}
