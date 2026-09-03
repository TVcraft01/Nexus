import 'agent_contract.dart';

/// How an input was understood.
enum InterpretOutcome { matched, needsInfo, unknown }

class InterpretResult {
  final InterpretOutcome outcome;
  final ParsedCommand? command;
  final String? missingArgKey;
  final String? question;

  const InterpretResult._(
    this.outcome, {
    this.command,
    this.missingArgKey,
    this.question,
  });

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

class CommandInterpreter {
  const CommandInterpreter();

  static String normalizePhrase(String input) {
    var t = input.trim().toLowerCase();
    const accents = {
      'à': 'a',
      'á': 'a',
      'â': 'a',
      'ä': 'a',
      'ã': 'a',
      'å': 'a',
      'è': 'e',
      'é': 'e',
      'ê': 'e',
      'ë': 'e',
      'ì': 'i',
      'í': 'i',
      'î': 'i',
      'ï': 'i',
      'ò': 'o',
      'ó': 'o',
      'ô': 'o',
      'ö': 'o',
      'õ': 'o',
      'ù': 'u',
      'ú': 'u',
      'û': 'u',
      'ü': 'u',
      'ç': 'c',
      'ñ': 'n',
      'ý': 'y',
      'ÿ': 'y',
    };
    t = t.replaceAllMapped(
      RegExp('[àáâäãåèéêëìíîïòóôöõùúûüçñýÿ]'),
      (m) => accents[m.group(0)]!,
    );
    return t
        .replaceAll("what's", 'what is')
        .replaceAll('whats', 'what is')
        .replaceAll("'s", ' is')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  InterpretResult interpret(String input) {
    final norm = normalizePhrase(input);

    // --- Greetings
    if (_oneOf(norm, const [
      'hello',
      'hi',
      'hey',
      'yo',
      'hiya',
      'good morning',
      'good afternoon',
      'good evening',
      'good night',
      'how are you',
    ])) {
      return InterpretResult.matched(
        const ParsedCommand(action: AgentActions.greet, target: 'local'),
      );
    }

    // --- Device list
    if (RegExp(r'^(show|list|what|which).*devices?').hasMatch(norm) ||
        norm == 'devices' ||
        norm == 'my devices') {
      return InterpretResult.matched(
        const ParsedCommand(action: AgentActions.deviceList, target: 'local'),
      );
    }

    // --- LED blink
    final blink = RegExp(r'^(?:blink|flash) (?:the )?(.+)$').firstMatch(norm);
    if (blink != null) {
      return InterpretResult.matched(
        ParsedCommand(action: AgentActions.ledBlink, target: blink.group(1)!),
      );
    }

    // --- Time & date
    if (_oneOf(norm, const [
      'what is the time',
      'what time is it',
      'current time',
      'time now',
      'tell me the time',
      'what time',
      'time',
      'now',
    ])) {
      return InterpretResult.matched(
        const ParsedCommand(
          action: AgentActions.timeGet,
          target: 'local',
          arguments: {'kind': 'time'},
        ),
      );
    }
    if (_oneOf(norm, const [
      'what is the date',
      'what is today',
      'what date is it',
      'what day is it',
      'today',
      'todays date',
      'date',
      'day',
    ])) {
      return InterpretResult.matched(
        const ParsedCommand(
          action: AgentActions.timeGet,
          target: 'local',
          arguments: {'kind': 'date'},
        ),
      );
    }

    // --- Math
    final what = RegExp(
      r'^(what is|how much is|calculate|compute|work out|solve) (.+)$',
    ).firstMatch(norm);
    if (what != null) {
      final expr = _toSymbols(what.group(2)!);
      if (RegExp(r'^[0-9+\-*/(). ]+$').hasMatch(expr) &&
          RegExp(r'\d').hasMatch(expr)) {
        return InterpretResult.matched(
          ParsedCommand(
            action: AgentActions.mathCalc,
            target: 'local',
            arguments: {'expr': expr},
          ),
        );
      }
      // Non-math "what is" -> web search
      return InterpretResult.matched(
        ParsedCommand(
          action: AgentActions.webSearch,
          target: 'local',
          arguments: {'query': what.group(2)},
        ),
      );
    }
    // Bare arithmetic: "2 + 2"
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

    // --- Definition -> web search
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

    // --- Clipboard: "copy <text>"
    final copy = RegExp(r'^(copy|send) (.+)$').firstMatch(norm);
    if (copy != null) {
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

    // --- Timer
    final timer = RegExp(
      r'^((?:set|start|begin) (?:a |the )?timer|(?:a )?timer)(?: for (.+))?$',
    ).firstMatch(norm);
    if (timer != null) {
      final length = timer.group(2)?.trim();
      final seconds = length == null ? null : parseDurationSeconds(length);
      if (seconds == null) {
        return InterpretResult.needsInfo(
          'timer.set.seconds',
          length == null
              ? 'How long should the timer run?'
              : 'How long is "$length"? Try "5 minutes" or "1 hour 30 minutes".',
          const ParsedCommand(action: AgentActions.timerSet, target: 'local'),
        );
      }
      return InterpretResult.matched(
        ParsedCommand(
          action: AgentActions.timerSet,
          target: 'local',
          arguments: {'seconds': seconds},
        ),
      );
    }

    // --- Web search: "search for X" / "google X"
    final search = RegExp(
      r'^(search|google|look up|search the web|find)( for )?(.+)$',
    ).firstMatch(norm);
    if (search != null) {
      return InterpretResult.matched(
        ParsedCommand(
          action: AgentActions.webSearch,
          target: 'local',
          arguments: {'query': search.group(3)},
        ),
      );
    }

    // --- Open URL / website
    final open = RegExp(r'^(open|go to|launch|start) (.+)$').firstMatch(norm);
    if (open != null) {
      final target = open.group(2)!.trim();
      // If it looks like a URL or domain, open it
      if (target.contains('.') || target.startsWith('http')) {
        return InterpretResult.matched(
          ParsedCommand(
            action: AgentActions.openUrl,
            target: 'local',
            arguments: {'url': target},
          ),
        );
      }
    }

    // --- Notes: "note that X" / "save X"
    final note =
        RegExp(r'^(note|write down|make a note)( down)?( that)? (.+)$')
            .firstMatch(norm) ??
        RegExp(r'^remember that (.+)$').firstMatch(norm) ??
        RegExp(r'^save (.+)$').firstMatch(norm);
    if (note != null) {
      return InterpretResult.matched(
        ParsedCommand(
          action: AgentActions.noteCreate,
          target: 'local',
          arguments: {'text': note.group(note.groupCount)},
        ),
      );
    }

    // --- System info
    if (_oneOf(norm, const [
      'system info',
      'systeminfo',
      'what are my specs',
      'my specs',
      'computer info',
      'pc info',
      'machine info',
    ])) {
      return InterpretResult.matched(
        const ParsedCommand(action: AgentActions.systemInfo, target: 'local'),
      );
    }

    // --- Volume
    final volume = RegExp(
      r'^(?:volume (up|down)|turn (?:the volume |it )(up|down)|(?:make it )?(louder|quieter|quiet)|mute)$',
    ).firstMatch(norm);
    if (volume != null) {
      final word =
          (volume.group(1) ?? volume.group(2) ?? volume.group(3) ?? 'mute')
              .toLowerCase();
      final mode = switch (word) {
        'up' || 'louder' => 'up',
        'down' || 'quieter' || 'quiet' => 'down',
        _ => 'mute',
      };
      return InterpretResult.matched(
        ParsedCommand(
          action: AgentActions.volumeSet,
          target: 'local',
          arguments: {'mode': mode},
        ),
      );
    }

    // --- Help
    if (_oneOf(norm, const [
      'help',
      'i need help',
      'what can you do',
      'what can i do',
      'commands',
      'what do you know',
      'abilities',
      'how do you work',
      'options',
    ])) {
      return InterpretResult.matched(
        const ParsedCommand(action: AgentActions.helpGet, target: 'local'),
      );
    }

    return InterpretResult.unknown();
  }

  static int? parseDurationSeconds(String raw) {
    final matches = RegExp(
      r'(\d+)\s*(hours?|hrs?|h|min(?:utes?)?|m|seconds?|secs?|s)\b',
    ).allMatches(raw.trim().toLowerCase()).toList();
    if (matches.isEmpty) return null;
    var total = 0;
    for (final m in matches) {
      final n = int.tryParse(m.group(1)!);
      if (n == null) return null;
      total += switch (m.group(2)![0]) {
        'h' => n * 3600,
        'm' => n * 60,
        _ => n,
      };
    }
    return total > 0 ? total : null;
  }

  bool _oneOf(String norm, List<String> forms) => forms.contains(norm);

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
