import 'agent_contract.dart';

/// How an input was understood.
enum InterpretOutcome {
  /// Recognized with every argument present — ready to dispatch.
  matched,

  /// Recognized but missing an argument (e.g. "play my playlist" needs a
  /// name). Ask which one, remember the answer.
  needsInfo,

  /// Nothing matched — a teaching opportunity. Ask the user what it should
  /// mean and remember it for next time.
  unknown,
}

/// Result of interpreting one natural-language input.
class InterpretResult {
  final InterpretOutcome outcome;
  final ParsedCommand? command;

  /// `needsInfo` only: which argument is missing, e.g. `media.play.playlist`.
  final String? missingArgKey;

  /// `needsInfo` only: the question to ask the user.
  final String? question;

  const InterpretResult._(this.outcome, {this.command, this.missingArgKey, this.question});

  factory InterpretResult.matched(ParsedCommand command) =>
      InterpretResult._(InterpretOutcome.matched, command: command);

  factory InterpretResult.needsInfo(
    String argKey,
    String question,
    ParsedCommand command,
  ) => InterpretResult._(
    InterpretOutcome.needsInfo,
    command: command,
    missingArgKey: argKey,
    question: question,
  );

  factory InterpretResult.unknown() =>
      const InterpretResult._(InterpretOutcome.unknown);
}

/// The human → AI translator. Unlike a rigid command parser, this maps many
/// natural phrasings onto one canonical intent, notices when an argument is
/// missing, and hands back unrecognized phrases as teaching opportunities.
///
/// The catalog below is deliberately broad — the Siri/Alexa-style vocabulary
/// ("set an alarm…", "call …", "what's the weather?") — so the assistant
/// *recognizes* everyday requests. Whether a recognized intent can actually
/// execute is the CommandService's job: time, math, clipboard, device list
/// and the ESP32 blink work today; the rest answer honestly that they aren't
/// wired up yet. Phrases like "bring me home" stay teachable: the user tells
/// us once what they should mean, and we remember.
///
/// A future model (SLM/LLM) can produce the same [ParsedCommand] shape — the
/// interpreter is just the offline, deterministic first pass.
class CommandInterpreter {
  const CommandInterpreter();

  InterpretResult interpret(String input) {
    final text = input.trim().toLowerCase();
    // "what's" / "whats" -> "what is" so one pattern covers every contraction.
    final norm = text
        .replaceAll("what's", 'what is')
        .replaceAll('whats', 'what is')
        .replaceAll("'s", ' is')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    if (_oneOf(norm, const ['hello', 'hi', 'hey', 'yo', 'hiya', 'good morning', 'good afternoon', 'good evening', 'good night', 'how are you'])) {
      return InterpretResult.matched(
        const ParsedCommand(action: AgentActions.greet, target: 'local'),
      );
    }

    // --- device.list: many phrasings, one intent.
    if (RegExp(r'^(show|list|what|which).*devices?').hasMatch(norm) ||
        norm == 'devices' ||
        norm == 'my devices') {
      return InterpretResult.matched(
        const ParsedCommand(action: AgentActions.deviceList, target: 'local'),
      );
    }

    // --- led.blink: keep the existing flexible form.
    final blink = RegExp(r'^(?:blink|flash) (?:the )?(.+)$').firstMatch(norm);
    if (blink != null) {
      return InterpretResult.matched(
        ParsedCommand(action: AgentActions.ledBlink, target: blink.group(1)!),
      );
    }

    // --- time & date (executable locally).
    if (_oneOf(norm, const [
      'what is the time', 'what time is it', 'current time', 'time now',
      'tell me the time', 'what time', 'time',
    ])) {
      return InterpretResult.matched(
        const ParsedCommand(action: AgentActions.timeGet, target: 'local', arguments: {'kind': 'time'}),
      );
    }
    if (_oneOf(norm, const [
      'what is the date', 'what is today', 'what date is it', 'what day is it',
      'today is date', 'todays date', 'date', 'day',
    ])) {
      return InterpretResult.matched(
        const ParsedCommand(action: AgentActions.timeGet, target: 'local', arguments: {'kind': 'date'}),
      );
    }

    // --- calendar (checked before "what is …" so it isn't read as a search).
    if (_oneOf(norm, const [
      'what is on my calendar', 'what do i have scheduled', 'my calendar',
      'what is my schedule', 'schedule', 'agenda',
    ]) || RegExp(r'^schedule ').hasMatch(norm)) {
      return InterpretResult.matched(
        const ParsedCommand(action: AgentActions.calendarGet, target: 'local'),
      );
    }

    // --- weather (also before "what is …").
    if (_oneOf(norm, const [
      'weather', 'what is the weather', 'what is the weather today',
      'is it going to rain', 'is it raining', 'is it going to snow',
      'what is the temperature', 'temperature', 'how hot is it', 'how cold is it',
    ])) {
      return InterpretResult.matched(
        const ParsedCommand(action: AgentActions.weatherGet, target: 'local'),
      );
    }

    // --- news (before "what is …" so "what is the news" isn't a search).
    if (_oneOf(norm, const ['news', 'what is the news', 'headlines', 'any news', 'what is happening'])) {
      return InterpretResult.matched(
        const ParsedCommand(action: AgentActions.newsGet, target: 'local'),
      );
    }

    // --- math: "what is 2 plus 2", "calculate 5 * 3", "how much is 10/2".
    // A "what is …" that is NOT arithmetic becomes a web-search intent.
    final what = RegExp(r'^(what is|how much is|calculate|compute|work out|solve) (.+)$').firstMatch(norm);
    if (what != null) {
      final expr = _toSymbols(what.group(2)!);
      if (RegExp(r'^[0-9+\-*/(). ]+$').hasMatch(expr) && RegExp(r'\d').hasMatch(expr)) {
        return InterpretResult.matched(
          ParsedCommand(
            action: AgentActions.mathCalc,
            target: 'local',
            arguments: {'expr': expr},
          ),
        );
      }
      return InterpretResult.matched(
        ParsedCommand(
          action: AgentActions.webSearch,
          target: 'local',
          arguments: {'query': what.group(2)!},
        ),
      );
    }
    // A bare arithmetic expression: "2 + 2".
    final bare = norm.trim();
    if (RegExp(r'^\d').hasMatch(bare) &&
        RegExp(r'^[0-9+\-*/(). ]+$').hasMatch(bare) &&
        RegExp(r'[+\-*/]').hasMatch(bare)) {
      return InterpretResult.matched(
        ParsedCommand(
          action: AgentActions.mathCalc,
          target: 'local',
          arguments: {'expr': bare},
        ),
      );
    }

    // --- definition -> folded into web search ("what does X mean").
    final define = RegExp(r'^what does (.+) mean$').firstMatch(norm);
    if (define != null) {
      return InterpretResult.matched(
        ParsedCommand(
          action: AgentActions.webSearch,
          target: 'local',
          arguments: {'query': 'define ${define.group(1)}'},
        ),
      );
    }

    // --- reminders, alarms, timers.
    if (RegExp(r'^remind me( to (.+))?$').hasMatch(norm) ||
        RegExp(r'^set (a |an |the )?reminder( to (.+))?$').hasMatch(norm)) {
      return InterpretResult.matched(
        const ParsedCommand(action: AgentActions.reminderSet, target: 'local'),
      );
    }
    if (RegExp(r'^set (an |the )?alarm').hasMatch(norm) ||
        RegExp(r'^wake me up').hasMatch(norm)) {
      return InterpretResult.matched(
        const ParsedCommand(action: AgentActions.alarmSet, target: 'local'),
      );
    }
    if (RegExp(r'^set (a |the )?timer').hasMatch(norm) ||
        RegExp(r'^(start|begin) (a |the )?timer').hasMatch(norm)) {
      return InterpretResult.matched(
        const ParsedCommand(action: AgentActions.timerSet, target: 'local'),
      );
    }

    // --- calls & messages.
    final call = RegExp(r'^call (.+)$').firstMatch(norm);
    if (call != null) {
      return InterpretResult.matched(
        ParsedCommand(
          action: AgentActions.callPlace,
          target: 'local',
          arguments: {'contact': call.group(1)!},
        ),
      );
    }
    // "text john", "message john" — the verb is also the channel.
    final directMessage = RegExp(r'^(text|message) (.+)$').firstMatch(norm);
    if (directMessage != null) {
      return InterpretResult.matched(
        ParsedCommand(
          action: AgentActions.messageSend,
          target: 'local',
          arguments: {'contact': directMessage.group(2)!},
        ),
      );
    }
    // "send a message [to john]".
    final sendMessage = RegExp(r'^send (a |an )?(message|text)( to )?(.+)?$').firstMatch(norm);
    if (sendMessage != null) {
      return InterpretResult.matched(
        ParsedCommand(
          action: AgentActions.messageSend,
          target: 'local',
          arguments: {
            if (sendMessage.group(4)?.isNotEmpty ?? false) 'contact': sendMessage.group(4)!,
          },
        ),
      );
    }

    // --- clipboard: "copy <text>", optionally "to my phone/pc/…".
    final copy = RegExp(r'^(copy|send) (.+)$').firstMatch(norm);
    if (copy != null) {
      // Strip a trailing recipient ("copy hello to my phone") or a bare one
      // ("copy to my phone") so only the real text is copied.
      var text = copy.group(2)!.trim();
      final recipient = RegExp(
        r'(?:^|\s)(to|on) (my |the )?(phone|pc|computer|laptop|tablet|devices|other devices|others)$',
      ).firstMatch(text);
      if (recipient != null) text = text.substring(0, recipient.start).trim();
      return InterpretResult.matched(
        ParsedCommand(
          action: AgentActions.clipboardWrite,
          target: 'local',
          arguments: {'text': text},
        ),
      );
    }

    // --- music control & play.
    if (_oneOf(norm, const ['pause', 'pause the music', 'stop the music', 'stop music', 'stop'])) {
      return InterpretResult.matched(
        const ParsedCommand(action: AgentActions.musicControl, target: 'local', arguments: {'mode': 'pause'}),
      );
    }
    if (_oneOf(norm, const ['next song', 'skip', 'skip this song', 'next track', 'next'])) {
      return InterpretResult.matched(
        const ParsedCommand(action: AgentActions.musicControl, target: 'local', arguments: {'mode': 'next'}),
      );
    }
    if (_oneOf(norm, const ['previous song', 'previous track', 'go back', 'last song', 'back'])) {
      return InterpretResult.matched(
        const ParsedCommand(action: AgentActions.musicControl, target: 'local', arguments: {'mode': 'previous'}),
      );
    }
    if (_oneOf(norm, const ['shuffle', 'shuffle my music', 'shuffle the music', 'shuffle my playlist'])) {
      return InterpretResult.matched(
        const ParsedCommand(action: AgentActions.musicControl, target: 'local', arguments: {'mode': 'shuffle'}),
      );
    }
    if (RegExp(r'^play\b').hasMatch(norm)) {
      final rest = norm.substring(4).trim();
      final generic = RegExp(r'^(my )?(playlist|music|songs|tunes|some music)$').firstMatch(rest);
      if (generic != null) {
        return InterpretResult.needsInfo(
          'media.play.playlist',
          'Which playlist?',
          const ParsedCommand(action: AgentActions.mediaPlay, target: 'local'),
        );
      }
      if (rest.isNotEmpty) {
        return InterpretResult.matched(
          ParsedCommand(
            action: AgentActions.mediaPlay,
            target: 'local',
            arguments: {'playlist': rest},
          ),
        );
      }
    }

    // --- smart home: turn on/off, lock/unlock, thermostat, lights.
    final switchDevice = RegExp(r'^(turn|switch) (on|off) (the )?(.+)$').firstMatch(norm);
    if (switchDevice != null) {
      return InterpretResult.matched(
        ParsedCommand(
          action: AgentActions.homeControl,
          target: 'local',
          arguments: {
            'state': switchDevice.group(2)!,
            'device': switchDevice.group(4)!,
          },
        ),
      );
    }
    if (RegExp(r'^(lock|unlock) (the )?(door|doors|front door)$').hasMatch(norm) ||
        RegExp(r'^set (the )?(thermostat|lights?|temperature)').hasMatch(norm) ||
        RegExp(r'^(dim|brighten) (the )?lights?').hasMatch(norm)) {
      return InterpretResult.matched(
        const ParsedCommand(action: AgentActions.homeControl, target: 'local'),
      );
    }

    // --- navigation. Explicit destinations are recognized; vague home-ish
    // phrases ("bring me home", "take me home") stay teachable.
    final nav = RegExp(r'^(navigate|get directions|give me directions|take me)( to )?(.+)$').firstMatch(norm);
    if (nav != null) {
      final place = nav.group(3)!.trim();
      if (place != 'home' && !place.startsWith('home ')) {
        return InterpretResult.matched(
          ParsedCommand(
            action: AgentActions.navigationRoute,
            target: 'local',
            arguments: {'place': place},
          ),
        );
      }
    }

    // --- notes.
    final note = RegExp(r'^(note|write down|make a note)( down)?( that)? (.+)$').firstMatch(norm) ??
        RegExp(r'^remember that (.+)$').firstMatch(norm);
    if (note != null) {
      return InterpretResult.matched(
        ParsedCommand(
          action: AgentActions.noteCreate,
          target: 'local',
          arguments: {'text': note.group(note.groupCount)!},
        ),
      );
    }

    // --- translation.
    final translate = RegExp(r'^translate (.+) (to|into) (.+)$').firstMatch(norm);
    if (translate != null) {
      return InterpretResult.matched(
        ParsedCommand(
          action: AgentActions.translateText,
          target: 'local',
          arguments: {'text': translate.group(1)!, 'language': translate.group(3)!},
        ),
      );
    }

    // --- explicit web search.
    final search = RegExp(r'^(search|google|look up|search the web)( for )?(.+)$').firstMatch(norm);
    if (search != null) {
      return InterpretResult.matched(
        ParsedCommand(
          action: AgentActions.webSearch,
          target: 'local',
          arguments: {'query': search.group(3)!},
        ),
      );
    }

    // Everything else — including context-dependent phrases like "bring me
    // home" — is a teaching opportunity. The user tells us what it should
    // mean once, and we remember it.
    return InterpretResult.unknown();
  }

  bool _oneOf(String norm, List<String> forms) => forms.contains(norm);

  /// "2 plus 2", "5 times 3", "10 divided by 2" -> "2+2", "5*3", "10/2".
  String _toSymbols(String expr) {
    return expr
        .replaceAll('divided by', '/')
        .replaceAll('multiplied by', '*')
        .replaceAll('times', '*')
        .replaceAll('plus', '+')
        .replaceAll('minus', '-')
        .replaceAll('over', '/')
        .replaceAll(RegExp(r'\s+'), '');
  }
}
