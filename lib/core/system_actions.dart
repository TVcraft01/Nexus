// The phone's own hands: the handful of things Nexus can *do* rather than say.
//
// Everything in this file exists because a conversation is not the only thing a
// user wants from an assistant. "It's dark in here" is not a question, and an
// answer of "you could turn on your flashlight" is a search result read aloud.
// So the model is given a small, closed vocabulary of actions it may *ask* for
// ([kSystemActionRules]), the shell recognises the one shape it may ask in
// ([SystemActionCall.tryParse]), and this device carries them out
// ([DeviceSystemActions]).
//
// Three rules shape the design, and each of them is a refusal:
//
//   * the model never acts. It emits a request; the shell decides to run it and
//     writes the line that says what happened. A model that says "I turned the
//     flashlight on" is lying, and the fix is to give it something true to say;
//   * an action that is not one of the closed set, or that arrives without the
//     arguments it needs, is **not** an action — it is text, shown as the
//     assistant's answer exactly as it was written. That is the whole of the
//     hallucination policy: a guess costs a sentence on screen, never a torch
//     in the dark or an alarm at 3am;
//   * the native side is the one Android already had. `agent_contract.dart`'s
//     actions are wired to `dev.nexus.nexus/device` (`torch`, `wifi`,
//     `bluetooth`, `volume`, `brightness`, `setAlarm`, `setTimer`, `openApp`,
//     `battery`), so this file adds a vocabulary and a sentence, not a second
//     channel to keep in step.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show immutable, visibleForTesting;

import 'agent_contract.dart';
import 'clock_context.dart' show nexusClockAnswer;
import 'command_interpreter.dart'
    show CommandInterpreter, InterpretOutcome, InterpretResult;
import 'device_actions.dart';

/// The interpreter the phrase bridge reads with. Const and stateless, so one
/// instance is the same as none.
const CommandInterpreter _phrases = CommandInterpreter();

/// A request the fixed vocabulary already understands, as the call a model
/// would have made for it — or null when the phrase is not one of them.
///
/// This exists because "the model usually emits the JSON" is not a contract. On
/// the A25, "set brightness to 60" came back as the sentence
/// *"Brightness set to 60%."* with nothing executed, twice, on both models —
/// while the very same channel executed "set volume to 30" one message
/// earlier. The translation from speech to [kSystemActionNames] is a closed
/// list, and [CommandInterpreter] already covers it exactly, so the shell asks
/// it first and leaves the model to the phrasings the list does not cover.
///
/// Only actions that name a state or a level are translated. A bare
/// "flashlight" is a **toggle**, and the model's vocabulary has no word for
/// one; guessing `on` here would turn a request to turn it off into a request
/// to turn it on, which is worse than letting the model answer.
SystemActionCall? actionFromPhrase(String text) {
  final String phrase = text.trim();
  if (phrase.isEmpty) return null;
  final InterpretResult result = _phrases.interpret(phrase);
  // `needsInfo` means the phrase was understood but incomplete ("set a timer"
  // with no length). The shell has nothing to ask with here, so it is the
  // model's to answer rather than a guess of ours.
  if (result.outcome != InterpretOutcome.matched) return null;
  final ParsedCommand? command = result.command;
  if (command == null) return null;

  final Object? state = command.arguments['state'];
  switch (command.action) {
    case AgentActions.wifiToggle:
      if (state != 'on' && state != 'off') return null;
      return SystemActionCall('set_wifi', <String, Object?>{'state': state});
    case AgentActions.bluetoothToggle:
      if (state != 'on' && state != 'off') return null;
      return SystemActionCall('set_bluetooth', <String, Object?>{
        'state': state,
      });
    case AgentActions.flashlightToggle:
      if (state != 'on' && state != 'off') return null;
      return SystemActionCall('set_flashlight', <String, Object?>{
        'state': state,
      });
    case AgentActions.timerSet:
      // The fast path exists for the sentences a user says expecting an
      // instant result, and a timer is one of them: waiting on a model to
      // translate "set a timer for five minutes" is the delay the path removes.
      final Object? seconds = command.arguments['seconds'];
      if (seconds is! int || seconds <= 0) return null;
      return SystemActionCall('set_timer', <String, Object?>{
        'seconds': seconds,
      });
    // "Play some music" is the one media phrase with a device action behind
    // it. Bare "play" and "resume" are deliberately not translated: those may
    // be about a preview or a track that is already loaded, and opening the
    // phone's player over it would be a different request. A named song is not
    // translated either — this app cannot make a named track appear, and the
    // honest answer is not a player opening to something else.
    case AgentActions.callPlace:
      // A video call is not a dial: it needs an app and a contact path the
      // system-actions vocabulary does not have, so it stays with the model and
      // the phone bridge. A plain call names one target and becomes the dialer.
      if (command.arguments['mode'] == 'video') return null;
      final Object? contact = command.arguments['contact'];
      if (contact is! String || contact.trim().isEmpty) return null;
      return SystemActionCall('call_number', <String, Object?>{
        'number': contact.trim(),
      });
    case AgentActions.mediaPlay:
      if (!RegExp(
        r'\b(music|musique)\b',
        caseSensitive: false,
      ).hasMatch(phrase)) {
        return null;
      }
      return const SystemActionCall('play_music');
    case AgentActions.volumeSet:
    case AgentActions.brightnessSet:
      // Up/down are relative steps the vocabulary cannot express, and a level
      // outside the range `SystemActionCall` accepts is not one either.
      if (command.arguments['mode'] != 'set') return null;
      final Object? level = command.arguments['level'];
      if (level is! int) return null;
      final bool brightness = command.action == AgentActions.brightnessSet;
      if (level < (brightness ? 1 : 0) || level > 100) return null;
      return SystemActionCall(
        brightness ? 'set_brightness' : 'set_volume',
        <String, Object?>{'level': level},
      );
  }
  return null;
}

/// The actions the model may ask for, by the names it is told to use.
///
/// A closed set, deliberately: every name here has a native method behind it
/// and a sentence in front of it, and anything else the model writes is prose.
///
/// The four settings actions are the ones a small model is most likely to get
/// subtly wrong, which is why their arguments are a word (`on`/`off`) and a
/// number in one fixed range rather than anything looser: `set_volume` with a
/// level the phone cannot read is not a volume, it is a sentence about one.
const Set<String> kSystemActionNames = <String>{
  'set_flashlight',
  'set_alarm',
  'set_timer',
  'open_app',
  'get_battery_level',
  'set_wifi',
  'set_bluetooth',
  'set_volume',
  'set_brightness',
  'get_time',
  'play_music',
  'call_number',
};

/// What a failed `play_music` says — the same sentence whether Android refused
/// the intent or there is no player installed.
///
/// The sentence is deliberately not "I played it": the model cannot choose a
/// song, and an action that only opens the music player must not be described
/// as though music is now coming out of the phone. A refusal is a fact, and it
/// is the one the user can act on — install a player, or open one themselves.
const String kMusicUnavailableText =
    "I couldn't do that. Your device blocked it or the app isn't installed.";

/// The rules the model is given: what it may ask for, in what shape, and what
/// to do when the user is just talking.
///
/// Written for a 0.5B model, which is why it is a list of exact literals rather
/// than a description of a protocol. The last two lines matter as much as the
/// JSON: a model told only "output JSON" starts answering "hello" with a
/// flashlight, and one told only "answer normally" never acts at all.
/// The one instruction that makes the thread's collapsible "Thinking…" bubble
/// possible. Kept beside the action rules rather than in either brain so the
/// phone's model and the PC's model are asked for the same shape, and phrased
/// so a JSON action still ends up alone after the closing tag.
const String kNexusReasoningRules =
    'Before answering, think step-by-step. Put reasoning inside <thought> and '
    '</thought> tags, then give the final answer outside them. '
    'When the answer is a phone action, put ONLY the JSON object after '
    '</thought>, with no sentence around it. Never mention the tags.';

const String kSystemActionRules =
    'You can ask this phone to do a few things. '
    'When the user asks for one of them, reply with ONLY one JSON object, '
    'with no sentence before it and none after it:\n'
    '  {"action":"set_flashlight","state":"on"}   (or "off")\n'
    '  {"action":"set_wifi","state":"on"}   (or "off")\n'
    '  {"action":"set_bluetooth","state":"on"}   (or "off")\n'
    '  {"action":"set_volume","level":40}   (0 to 100)\n'
    '  {"action":"set_brightness","level":70}   (1 to 100)\n'
    '  {"action":"set_alarm","hour":7,"minute":30}   (24-hour clock)\n'
    '  {"action":"set_timer","seconds":300}\n'
    '  {"action":"open_app","app_name":"Maps"}\n'
    '  {"action":"get_battery_level"}\n'
    '  {"action":"get_time"}   (use this for the date or time — never guess)\n'
    '  {"action":"play_music"}   (only opens the phone\'s music player)\n'
    '  {"action":"call_number","number":"555-1234"}   (opens the dialer)\n'
    'Those twelve are the only actions there are. '
    'ONLY set an alarm if the user explicitly asks you to in this message. '
    'Never set an alarm because a message is long, contains a time, or was '
    'pasted in — an alarm nobody asked for is worse than no answer. '
    // Measured on the A25: asked "what is 6 times 7", the model answered
    // `{"action":"set_timer","seconds":420}`. It read the numbers as a
    // length of time because it had no other way to use them, so the rule is
    // said in words a small model cannot mistake for a suggestion: arithmetic
    // is not what the actions are for, and "I don't know" is allowed.
    'You are an AI assistant. Do not use tools to do math. '
    'If you cannot answer, just say so. '
    'If the user is just talking, answer normally and do not write any JSON. '
    'Never say you did something yourself — the app does it and tells them. '
    // The hallucination this rule exists for: asked to play a song, a model
    // wrote `song: Yesterday, artist: The Beatles` — a claim about a player it
    // never opened — and the thread showed it as an answer. The shape is banned
    // as well as the claim, because a key-value pair reads like data and a small
    // model reaches for it whenever it has nothing true to say.
    'play_music only opens the music player. Never name a song or an artist as '
    'if you played it, and never invent what is playing. '
    'Do not output key-value pairs. If you cannot perform an action, speak in '
    'plain English.';

/// [system] with the action rules after it, one blank line between.
///
/// One definition, used by both brains, so the phone's model and the PC's model
/// are never offered different vocabularies.
String systemWithActions(String system) =>
    '$system\n\n$kNexusReasoningRules\n\n$kSystemActionRules';

/// One action the model asked for, already checked against
/// [kSystemActionNames] and carrying the arguments it needs.
@immutable
class SystemActionCall {
  const SystemActionCall(this.action, [this.args = const <String, Object?>{}]);

  /// The wire name — `set_flashlight`, not `device.flashlight`. This is the
  /// model's vocabulary; [DeviceSystemActions] is where it becomes the
  /// app's.
  final String action;

  /// The arguments, already of the right type and in range: a call that exists
  /// at all is a call that can run.
  final Map<String, Object?> args;

  /// The action [reply] asks for, or null when it asks for none.
  ///
  /// Null is the answer for every shape that is not a usable action: prose with
  /// no JSON in it, JSON that is not an object, an `"action"` the app does not
  /// have, a known action missing an argument or with one out of range, and
  /// JSON that does not parse at all. The caller does the same thing with all
  /// of them — shows the reply as the assistant wrote it — which is why they
  /// are one answer here rather than an error the caller has to sort out.
  ///
  /// The object may sit anywhere in the reply. Real models wrap it in a
  /// sentence ("Sure — here you go: {...}") even when told not to, and refusing
  /// that would mean the torch stays off because the model was chatty.
  static SystemActionCall? tryParse(String reply) {
    for (final String json in _jsonObjects(reply)) {
      final SystemActionCall? call = _decode(json);
      if (call != null) return call;
    }
    return null;
  }

  /// Every balanced `{…}` region in [text], outermost first.
  ///
  /// Brace counting rather than a JSON parser, because [tryParse] has to find
  /// the object inside prose that no JSON parser will accept as a whole. Quotes
  /// and escapes are tracked so a brace inside a string ("open_app" with a
  /// `}` in the name) does not end the object early.
  static Iterable<String> _jsonObjects(String text) sync* {
    int start = text.indexOf('{');
    while (start >= 0) {
      final int end = _closingBrace(text, start);
      if (end > start) {
        yield text.substring(start, end + 1);
        start = text.indexOf('{', end + 1);
      } else {
        // An unbalanced `{` — a truncated answer, or prose containing one. The
        // search continues one character later so a valid object after it is
        // still found.
        start = text.indexOf('{', start + 1);
      }
    }
  }

  /// The index of the `}` that closes the `{` at [start], or -1.
  static int _closingBrace(String text, int start) {
    int depth = 0;
    bool inString = false;
    bool escaped = false;
    for (int i = start; i < text.length; i++) {
      final String ch = text[i];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (ch == r'\') {
          escaped = true;
        } else if (ch == '"') {
          inString = false;
        }
        continue;
      }
      if (ch == '"') {
        inString = true;
      } else if (ch == '{') {
        depth++;
      } else if (ch == '}') {
        depth--;
        if (depth == 0) return i;
      }
    }
    return -1;
  }

  /// [raw] as a runnable call, or null. The one place the vocabulary and the
  /// argument ranges are written down.
  static SystemActionCall? _decode(String raw) {
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final Object? action = decoded['action'];
    if (action is! String) {
      // A model with no clock writes the time it cannot know. Measured on the
      // A25, twice: asked "what time is it" at 14:24 it answered
      // `{"time": "07:30"}` — not an action, so it used to reach the screen as
      // raw JSON stating a false time. A block whose subject is the clock is a
      // request for the clock, and the shell answers it with its own reading
      // rather than showing the guess.
      if (decoded.containsKey('time') || decoded.containsKey('date')) {
        return const SystemActionCall('get_time');
      }
      return null;
    }

    switch (action.trim()) {
      case 'set_flashlight':
      case 'set_wifi':
      case 'set_bluetooth':
        final String? state = _state(decoded['state']);
        if (state == null) return null;
        return SystemActionCall(action.trim(), <String, Object?>{
          'state': state,
        });
      case 'set_volume':
      case 'set_brightness':
        // One level, one range, and the same word for it in the prompt and in
        // the parser: a model that writes `percent` or `value` is understood,
        // because those are the near-misses a 0.5B produces, but a level that
        // is not a whole number in range is refused rather than clamped. Silent
        // clamping would turn "set the volume to 300" into a normal answer, and
        // the user would never learn the model had misunderstood them.
        final int? level = _int(decoded['level'] ?? decoded['percent']);
        if (level == null) return null;
        // Brightness floors at 1: 0 is a real volume and a screen the user
        // cannot see to undo.
        final bool brightness = action.trim() == 'set_brightness';
        if (level < (brightness ? 1 : 0) || level > 100) return null;
        return SystemActionCall(action.trim(), <String, Object?>{
          'level': level,
        });
      case 'set_alarm':
        final int? hour = _int(decoded['hour']);
        final int? minute = _int(decoded['minute']);
        // A 7 in the minute slot is a model that has confused the fields; an
        // alarm at 7:07 is not what anybody asked for, and 7:75 does not exist.
        if (hour == null || minute == null) return null;
        if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
        return SystemActionCall('set_alarm', <String, Object?>{
          'hour': hour,
          'minute': minute,
        });
      case 'set_timer':
        final int? seconds = _int(decoded['seconds']);
        // Android's own timer takes a length in seconds and is answered by the
        // clock app; zero is not a timer, and a negative one is a bug.
        if (seconds == null || seconds <= 0) return null;
        return SystemActionCall('set_timer', <String, Object?>{
          'seconds': seconds,
        });
      case 'open_app':
        // `app_name` is the documented field; `app` is the near-miss a small
        // model writes, and refusing it would cost the user their app for a
        // naming quibble. Either way the value is a non-empty name.
        final String? app = _string(decoded['app_name'] ?? decoded['app']);
        if (app == null) return null;
        return SystemActionCall('open_app', <String, Object?>{'app_name': app});
      case 'get_battery_level':
        return const SystemActionCall('get_battery_level');
      case 'play_music':
        // No arguments: the action opens the phone's player. A `song` or
        // `artist` field is not read here — the phone cannot make a named track
        // appear, and pretending the argument was the point is how the invented
        // `song: …` answer got made in the first place.
        return const SystemActionCall('play_music');
      case 'call_number':
        // One target: a number, or a contact name the phone can resolve. The
        // action is deliberately called `call_number` even when the value is a
        // name, because the vocabulary is the model's and the phone's dialer is
        // what it reaches.
        final String? target = _string(
          decoded['number'] ?? decoded['target'] ?? decoded['name'],
        );
        if (target == null) return null;
        return SystemActionCall('call_number', <String, Object?>{
          'number': target,
        });
      case 'get_time':
        // No arguments: the clock is the phone's, not the model's. Measured on
        // the A25: asked the time before this existed, the model asked for
        // `get_time` anyway (and was refused), or invented `{"time":"07:30"}`.
        return const SystemActionCall('get_time');
    }
    return null;
  }

  /// `on`/`off`, in any case, or null. Not a boolean: the model is told the
  /// literal words, and `true` here would be a different instruction than the
  /// one in [kSystemActionRules].
  static String? _state(Object? raw) {
    if (raw is! String) return null;
    final String value = raw.trim().toLowerCase();
    return value == 'on' || value == 'off' ? value : null;
  }

  /// A whole number from a JSON number, or from a string of digits (a model
  /// quoting its arguments). Null for anything else.
  static int? _int(Object? raw) {
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim());
    return null;
  }

  /// A trimmed non-empty string, or null.
  static String? _string(Object? raw) {
    if (raw is! String) return null;
    final String value = raw.trim();
    return value.isEmpty ? null : value;
  }

  /// For a log line, and for a test's failure message.
  @override
  String toString() => 'SystemActionCall($action, $args)';
}

/// What running one call produced: whether it happened, and the sentence the
/// thread shows.
@immutable
class SystemActionOutcome {
  const SystemActionOutcome({
    required this.ok,
    required this.message,
    required this.call,
  });

  /// True when the phone actually did it. A refusal — no flashlight on this
  /// device, an app that is not installed — is false, and keeps the phone's own
  /// sentence rather than a generic apology.
  final bool ok;

  /// One sentence, already fit to show: "Flashlight on.", "Battery at 84%."
  final String message;

  /// The request this answers, so the bubble knows which action it was.
  final SystemActionCall call;

  @override
  String toString() => 'SystemActionOutcome($ok, $message)';
}

/// Runs the model's action requests on this device.
///
/// An interface rather than a class with a channel in it for the reason the
/// rest of the shell has seams: a widget test asserts that a flashlight request
/// produced a bubble *without* turning on a real torch.
abstract class SystemActions {
  /// Test seam, in the same shape as [ChatLog.override]: a test states what
  /// "the phone" is. The app never sets it.
  @visibleForTesting
  static SystemActions Function()? override;

  static SystemActions get current =>
      override?.call() ?? const DeviceSystemActions();

  /// Runs [call] and reports what happened. Never throws: a failure with no
  /// sentence is a bubble that says nothing, so every path produces one.
  Future<SystemActionOutcome> execute(SystemActionCall call);
}

/// The real one: [DeviceActionBackend], which is the `dev.nexus.nexus/device`
/// channel on Android and an honest refusal everywhere else.
///
/// The mapping from the model's vocabulary to the app's is here and nowhere
/// else — [AgentActions] is what the native side already answers, and this is
/// the only translation between the two.
class DeviceSystemActions implements SystemActions {
  const DeviceSystemActions({this.backend, this.clock});

  /// Injected by tests; null means "the platform's", which is what the app
  /// gets. Not a field on the seam because a test that wants a recorder uses
  /// [SystemActions.override], exactly as it does for the brain.
  final DeviceActionBackend? backend;

  /// The clock `get_time` reads, or null for [DateTime.now]. A field so a test
  /// can pin the sentence instead of racing the second hand.
  final DateTime Function()? clock;

  @override
  Future<SystemActionOutcome> execute(SystemActionCall call) async {
    // The clock is the shell's own: no permission, no platform channel, and the
    // one thing it must be is *now*. Answered before [backend] is consulted so
    // a device with no channel can still tell the time.
    if (call.action == 'get_time') {
      return SystemActionOutcome(
        ok: true,
        message: nexusClockAnswer(now: clock?.call()),
        call: call,
      );
    }
    final (String action, Map<String, dynamic> args) = _plan(call);
    try {
      final ActionResult result = await (backend ?? deviceActionBackend()).run(
        action,
        args,
      );
      return SystemActionOutcome(
        ok: result.ok,
        // A success gets the shell's wording, because it is a fact the shell
        // knows — "Alarm set for 07:30" — while a failure keeps the phone's,
        // because only the phone knows why ("What app should I open?").
        //
        // Music is the exception: a refusal there is one of two facts the phone
        // has no better words for (blocked, or nothing installed), and the
        // sentence is fixed so the pill can never turn a refusal into a check
        // mark with an ambiguous line beside it.
        message: result.ok
            ? (_done(call) ?? result.message)
            : (call.action == 'play_music'
                  ? kMusicUnavailableText
                  : result.message),
        call: call,
      );
    } catch (_) {
      // The channel itself threw: a missing plugin, a denied permission, a
      // method a future Android removed. It names the action and where it does
      // work, and never a stack trace.
      return SystemActionOutcome(
        ok: false,
        message: notOnThisSystem(action),
        call: call,
      );
    }
  }

  /// [call] as the app's action and arguments.
  ///
  /// The argument names are the native side's, not the model's:
  /// `torch` reads `mode` (anything but `off` means on), `openApp` takes a
  /// `query`, and the alarm takes `hour`/`minute` in the same words. Keeping
  /// the translation in one function is what stops one of them drifting
  /// out of step with its native method.
  (String, Map<String, dynamic>) _plan(SystemActionCall call) {
    switch (call.action) {
      case 'set_flashlight':
        return (
          AgentActions.flashlightToggle,
          <String, dynamic>{'mode': call.args['state']},
        );
      case 'set_alarm':
        return (
          AgentActions.alarmSet,
          <String, dynamic>{
            'hour': call.args['hour'],
            'minute': call.args['minute'],
          },
        );
      case 'set_timer':
        return (
          AgentActions.timerSet,
          <String, dynamic>{'seconds': call.args['seconds']},
        );
      case 'open_app':
        return (
          AgentActions.appOpen,
          <String, dynamic>{'query': call.args['app_name']},
        );
      // The two radio switches. Both go to the native side as `mode`, the word
      // the torch already uses, and both are best-effort: Android 10 and 12
      // respectively stopped letting ordinary apps switch Wi-Fi and Bluetooth,
      // so the phone answers with what it could really do — see MainActivity's
      // `setWifi` / `setBluetooth`, which fall back to the system panel and say
      // so.
      case 'set_wifi':
        return (
          AgentActions.wifiToggle,
          <String, dynamic>{'mode': call.args['state']},
        );
      case 'set_bluetooth':
        return (
          AgentActions.bluetoothToggle,
          <String, dynamic>{'mode': call.args['state']},
        );
      case 'set_volume':
        return (
          AgentActions.volumeSet,
          <String, dynamic>{'mode': 'set', 'level': call.args['level']},
        );
      case 'set_brightness':
        return (
          AgentActions.brightnessSet,
          <String, dynamic>{'mode': 'set', 'level': call.args['level']},
        );
      case 'play_music':
        return (AgentActions.musicPlay, <String, dynamic>{});
      case 'call_number':
        return (
          AgentActions.callPlace,
          <String, dynamic>{'number': call.args['number']},
        );
      default:
        return (AgentActions.batteryGet, <String, dynamic>{});
    }
  }

  /// The shell's sentence for a success, or null when the phone's is better.
  ///
  /// Flashlight, alarm and timer are facts this side already knows completely,
  /// and the phone's wording for them is a summary ("Timer running for 5 min").
  /// Battery is a reading only the phone has. Opening an app is somewhere in
  /// between: the phone says which app it resolved, which is the part the user
  /// cannot see for themselves.
  ///
  /// The four settings actions are deliberately **not** in here. The shell
  /// knows what was asked for and not what happened: Android may have refused to
  /// switch the radio and opened the settings panel instead, or refused to write
  /// the brightness without "modify system settings" access. A sentence written
  /// here would say "Wi-Fi on." about a Wi-Fi that is still off, which is the
  /// one thing this file exists to prevent, so the phone's own sentence wins.
  String? _done(SystemActionCall call) {
    switch (call.action) {
      case 'set_flashlight':
        return call.args['state'] == 'off'
            ? 'Flashlight off.'
            : 'Flashlight on.';
      case 'set_alarm':
        final int hour = call.args['hour']! as int;
        final int minute = call.args['minute']! as int;
        final String hh = hour.toString().padLeft(2, '0');
        final String mm = minute.toString().padLeft(2, '0');
        return 'Alarm set for $hh:$mm.';
      case 'set_timer':
        return 'Timer set for ${_duration(call.args['seconds']! as int)}.';
      case 'play_music':
        // The shell knows what it asked the phone to do and not what came out
        // of it, so it says only that: the player was opened. The phone's own
        // sentence names the app when it can.
        return null;
      default:
        return null;
    }
  }

  /// A length of time in the words a person would use: "5 minutes", "90
  /// seconds", "1 hour 5 minutes".
  ///
  /// A timer is read back to the user, and "900 seconds" is a number they have
  /// to do arithmetic on.
  static String _duration(int seconds) {
    if (seconds < 60) return '$seconds ${seconds == 1 ? 'second' : 'seconds'}';
    final int minutes = seconds ~/ 60;
    final int rest = seconds % 60;
    if (rest != 0 && minutes < 60) {
      return '$minutes min $rest s';
    }
    if (minutes < 60) return '$minutes ${minutes == 1 ? 'minute' : 'minutes'}';
    final int hours = minutes ~/ 60;
    final int spare = minutes % 60;
    final String head = '$hours ${hours == 1 ? 'hour' : 'hours'}';
    if (spare == 0) return head;
    return '$head $spare min';
  }
}
