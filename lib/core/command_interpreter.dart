import 'dart:math' as math;

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

  /// One canonical, fully-understood phrase per intent — the vocabulary used
  /// for "did you mean …?" when an input nearly matches something known.
  /// Every entry must parse (interpret() must match it) because a suggestion
  /// the user confirms becomes the command that runs.
  static const List<String> suggestionCatalog = [
    // Time & system
    'what time is it',
    'what is the date',
    'show my devices',
    'system info',
    // Actions on this device
    'call mom',
    'text mom saying hi',
    'make my phone ring',
    'find my phone',
    'open youtube',
    'open github.com',
    'close chrome',
    'search for cats',
    'note that buy milk',
    'blink the esp32',
    'copy hello to my devices',
    // Media
    'play music',
    'pause music',
    'next track',
    'previous track',
    'shuffle',
    'repeat',
    // System toggles & display
    'volume up',
    'volume down',
    'mute',
    'brightness up',
    'brightness 50',
    'flashlight on',
    'wifi on',
    'bluetooth off',
    'lock screen',
    'airplane mode on',
    'battery',
    'screenshot',
    'restart',
    // Productivity
    'set a timer for 5 minutes',
    'set an alarm for 7am',
    'remind me to buy milk',
    'define serendipity',
    'translate hello to french',
    'convert 5 miles to km',
    // Fun
    'roll a dice',
    'flip a coin',
    'random 1 to 100',
    'tell me a joke',
    // Help & French
    'help',
    'quelle heure est il',
  ];

  /// How close two normalized phrases are, 0..1. Combines a character-level
  /// edit-distance score (catches typos) with word-overlap (catches added or
  /// reworded words). 1.0 means identical.
  static double phraseSimilarity(String a, String b) {
    if (a == b) return 1.0;
    if (a.isEmpty || b.isEmpty) return 0.0;
    final dist = _levenshtein(a, b);
    final lengthScore = 1 - dist / math.max(a.length, b.length);
    final tokensA = a.split(' ');
    final tokensB = b.split(' ');
    final common = tokensA.toSet().intersection(tokensB.toSet()).length;
    final tokenScore = 2 * common / (tokensA.length + tokensB.length);
    return lengthScore * 0.55 + tokenScore * 0.45;
  }

  /// Finds the closest known phrase for an unrecognized input. Returns the
  /// meaning that phrase maps to plus its score, or null when nothing is
  /// close enough to risk guessing. Guessing is deliberately conservative:
  /// the caller only ever offers it — the user confirms before anything runs.
  static (String meaning, double score)? closestMeaning(
    String normalizedInput,
    Map<String, String> candidates,
  ) {
    if (normalizedInput.length < 6) return null;
    String? bestMeaning;
    var bestScore = 0.0;
    for (final entry in candidates.entries) {
      final score = phraseSimilarity(
        normalizedInput,
        normalizePhrase(entry.key),
      );
      if (score > bestScore) {
        bestScore = score;
        bestMeaning = entry.value;
      }
    }
    if (bestMeaning == null || bestScore < 0.68) return null;
    return (bestMeaning, bestScore);
  }

  /// Classic Levenshtein edit distance, two rolling rows so it stays cheap
  /// even if the catalog grows.
  static int _levenshtein(String a, String b) {
    if (a == b) return 0;
    var prev = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 1; i <= a.length; i++) {
      final curr = List<int>.filled(b.length + 1, 0)..[0] = i;
      for (var j = 1; j <= b.length; j++) {
        curr[j] = math.min(
          math.min(
            curr[j - 1] + 1, // deletion
            prev[j] + 1, // insertion
          ),
          prev[j - 1] + (a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1),
        );
      }
      prev = curr;
    }
    return prev[b.length];
  }

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
    // Strip conversational prefixes that friends naturally type
    t = t
        .replaceAll(
          RegExp(
            r'^(?:can you|could you|would you|will you|please|hey|yo|uh|um|so|okay|ok|alright|right)\s+',
          ),
          '',
        )
        .replaceAll(
          RegExp(
            "^(?:i want to|i would like to|i'd like to|i need to|i need you to|help me|go ahead and|just|try to)\\s+",
          ),
          '',
        )
        .replaceAll(RegExp(r'^(?:can you|could you|would you)\s+'), '');
    // Strip trailing filler
    t = t
        .replaceAll(RegExp(r'\s+(?:please|thanks|thank you|pls|thx|ty)$'), '')
        .replaceAll(RegExp(r'\s+for me$'), '')
        .replaceAll(RegExp(r'\s+for me\s*$'), '');
    // Keep stripping repeated leading filler so "hey please call mom"
    // and "can you please open youtube" both reach their patterns.
    var previous = '';
    while (t != previous) {
      previous = t;
      t = t.replaceAll(
        RegExp(
          r'^(?:can you|could you|would you|will you|please|hey|yo|uh|um|so|okay|ok|alright|right|just|try to|help me|go ahead and)\s+',
        ),
        '',
      );
    }
    return t
        .replaceAll("what's", 'what is')
        // "whats up" becomes "what is up", but "whatsapp" must survive
        // untouched — it is an app name, not a question.
        .replaceAll(RegExp(r"whats(?!app)"), 'what is')
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
      'sup',
      'salut',
      'bonjour',
      'coucou',
      'bonsoir',
      'what\'s up',
      'whats up',
      // normalizePhrase turns both "what's up" and "whats up" into this.
      'what is up',
      'good morning',
      'good afternoon',
      'good evening',
      'good night',
      'how are you',
      'how\'s it going',
      'how are you doing',
      'what\'s good',
      'how do you do',
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
      'tell me the time please',
      'what time',
      'time',
      'now',
      'what is it now',
      'what time do you have',
      'do you have the time',
      'got the time',
      'check the time',
      'what time is it right now',
      'what time is it currently',
      'quelle heure est il',
      'il est quelle heure',
      'quelle heure',
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
      'what day is today',
      'what is today date',
      'check the date',
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
      return InterpretResult.matched(
        ParsedCommand(
          action: AgentActions.webSearch,
          target: 'local',
          arguments: {'query': what.group(2)!.trim()},
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

    // --- Find/ring my device (before web-search & call: "find my phone"
    // must not become a web search, "ring my phone" must not dial a
    // contact named "my phone"). "ring mom" still falls through to call.
    final devicesNoun =
        r'(phone|cellphone|cell|mobile|tablet|ipad|pc|laptop|computer|desktop|device|watch)';
    final findDev = RegExp(
      r'^(?:find|where is|locate) (?:my |the )?' + devicesNoun + r'$',
    ).firstMatch(norm);
    if (findDev != null) {
      return InterpretResult.matched(
        ParsedCommand(
          action: AgentActions.findDevice,
          target: findDev.group(1)!,
        ),
      );
    }
    final ringDev =
        RegExp(r'^(?:ring|beep) (?:my |the )?' + devicesNoun + r'$')
            .firstMatch(norm) ??
        RegExp(r'^make (?:my |the )?' + devicesNoun + r' ring$')
            .firstMatch(norm) ??
        RegExp(r'^play (?:a )?sound on (?:my |the )?' + devicesNoun + r'$')
            .firstMatch(norm) ??
        RegExp(r'^make noise on (?:my |the )?' + devicesNoun + r'$')
            .firstMatch(norm);
    if (ringDev != null) {
      return InterpretResult.matched(
        ParsedCommand(
          action: AgentActions.ringDevice,
          target: ringDev.group(1)!,
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
          arguments: {'query': 'define ${define.group(1)!.trim()}'},
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
          arguments: {'query': search.group(3)!.trim()},
        ),
      );
    }

    // --- Open URL / website
    final open = RegExp(r'^(open|go to|launch|start|ouvre) (.+)$')
        .firstMatch(norm);
    if (open != null) {
      final target = open.group(2)!.trim();
      if (target.contains('.') || target.startsWith('http')) {
        return InterpretResult.matched(
          ParsedCommand(
            action: AgentActions.openUrl,
            target: 'local',
            arguments: {'url': target},
          ),
        );
      }
      // "open calculator" / "open youtube" -> app open
      return InterpretResult.matched(
        ParsedCommand(
          action: AgentActions.appOpen,
          target: 'local',
          arguments: {'query': target},
        ),
      );
    }

    // --- Close/kill app
    final close = RegExp(r'^(?:close|kill|stop|quit) (.+)$').firstMatch(norm);
    if (close != null) {
      return InterpretResult.matched(
        ParsedCommand(
          action: AgentActions.appClose,
          target: 'local',
          arguments: {'query': close.group(1)!.trim()},
        ),
      );
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

    // --- Battery
    if (_oneOf(norm, const [
      'battery',
      'battery level',
      'how much battery',
      'how much charge',
      'power left',
      'battery percentage',
      'charge level',
      'battery status',
      'what is my battery',
      'how charged is my phone',
      'how charged is my battery',
      'how full is the battery',
      'am i running low',
      'battery life',
      'what is my battery level',
      'check battery',
      'battery check',
      'batterie',
      'niveau de batterie',
    ])) {
      return InterpretResult.matched(
        const ParsedCommand(action: AgentActions.batteryGet, target: 'local'),
      );
    }

    // --- Screenshot
    if (_oneOf(norm, const [
      'take a screenshot',
      'screenshot',
      'capture screen',
      'screen capture',
      'take screenshot',
      'grab screen',
      'snap',
    ])) {
      return InterpretResult.matched(
        const ParsedCommand(action: AgentActions.screenshot, target: 'local'),
      );
    }

    // --- Flashlight
    if (_oneOf(norm, const [
      'flashlight on',
      'torch on',
      'turn on flashlight',
      'turn on torch',
      'enable flashlight',
      'enable torch',
      'light on',
    ])) {
      return InterpretResult.matched(
        const ParsedCommand(
          action: AgentActions.flashlightToggle,
          target: 'local',
          arguments: {'state': 'on'},
        ),
      );
    }
    if (_oneOf(norm, const [
      'flashlight off',
      'torch off',
      'turn off flashlight',
      'turn off torch',
      'disable flashlight',
      'disable torch',
      'light off',
    ])) {
      return InterpretResult.matched(
        const ParsedCommand(
          action: AgentActions.flashlightToggle,
          target: 'local',
          arguments: {'state': 'off'},
        ),
      );
    }
    if (_oneOf(norm, const [
      'flashlight',
      'torch',
      'toggle flashlight',
      'toggle torch',
      'flip flashlight',
    ])) {
      return InterpretResult.matched(
        const ParsedCommand(
          action: AgentActions.flashlightToggle,
          target: 'local',
        ),
      );
    }

    // --- Brightness
    final brightUp = RegExp(
      r'^(?:brightness (?:up|higher|increase)|brighter|(?:make it )?(?:more )?bright)$',
    ).firstMatch(norm);
    if (brightUp != null) {
      return InterpretResult.matched(
        const ParsedCommand(
          action: AgentActions.brightnessSet,
          target: 'local',
          arguments: {'mode': 'up'},
        ),
      );
    }
    final brightDown = RegExp(
      r'^(?:brightness (?:down|lower|decrease)|dimmer|darker|(?:make it )?(?:more )?dim|(?:make it )?(?:more )?dark)$',
    ).firstMatch(norm);
    if (brightDown != null) {
      return InterpretResult.matched(
        const ParsedCommand(
          action: AgentActions.brightnessSet,
          target: 'local',
          arguments: {'mode': 'down'},
        ),
      );
    }
    final brightNum = RegExp(r'^brightness (?:to )?(\d{1,3})(?:\s*%?)?$')
        .firstMatch(norm);
    if (brightNum != null) {
      final level = int.tryParse(brightNum.group(1)!);
      if (level != null && level >= 0 && level <= 100) {
        return InterpretResult.matched(
          ParsedCommand(
            action: AgentActions.brightnessSet,
            target: 'local',
            arguments: {'mode': 'set', 'level': level},
          ),
        );
      }
    }

    // --- Volume. Every alternative is captured so "mute", "unmute",
    // "volume up and down" and "toggle volume" each map to the mode they
    // mean — never silently all the way to mute.
    final volume = RegExp(
      r'^(?:volume (up|down|up and down|toggle)|(toggle volume)|turn (?:the volume |it )(up|down)|(?:make it )?(louder|quieter|quiet)|(mute|unmute))$',
    ).firstMatch(norm);
    if (volume != null) {
      final word =
          (volume.group(1) ??
                  volume.group(2) ??
                  volume.group(3) ??
                  volume.group(4) ??
                  volume.group(5) ??
                  'mute')
              .toLowerCase();
      final mode = switch (word) {
        'up' || 'louder' => 'up',
        'down' || 'quieter' || 'quiet' => 'down',
        'up and down' || 'toggle' || 'unmute' || 'toggle volume' => 'toggle',
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

    // --- WiFi
    if (_oneOf(norm, const [
      'wifi on',
      'turn on wifi',
      'enable wifi',
      'turn on the wifi',
    ])) {
      return InterpretResult.matched(
        const ParsedCommand(
          action: AgentActions.wifiToggle,
          target: 'local',
          arguments: {'state': 'on'},
        ),
      );
    }
    if (_oneOf(norm, const [
      'wifi off',
      'turn off wifi',
      'disable wifi',
      'turn off the wifi',
    ])) {
      return InterpretResult.matched(
        const ParsedCommand(
          action: AgentActions.wifiToggle,
          target: 'local',
          arguments: {'state': 'off'},
        ),
      );
    }
    if (_oneOf(norm, const ['toggle wifi', 'wifi', 'switch wifi'])) {
      return InterpretResult.matched(
        const ParsedCommand(action: AgentActions.wifiToggle, target: 'local'),
      );
    }

    // --- Bluetooth
    if (_oneOf(norm, const [
      'bluetooth on',
      'turn on bluetooth',
      'enable bluetooth',
    ])) {
      return InterpretResult.matched(
        const ParsedCommand(
          action: AgentActions.bluetoothToggle,
          target: 'local',
          arguments: {'state': 'on'},
        ),
      );
    }
    if (_oneOf(norm, const [
      'bluetooth off',
      'turn off bluetooth',
      'disable bluetooth',
    ])) {
      return InterpretResult.matched(
        const ParsedCommand(
          action: AgentActions.bluetoothToggle,
          target: 'local',
          arguments: {'state': 'off'},
        ),
      );
    }
    if (_oneOf(norm, const [
      'bluetooth',
      'toggle bluetooth',
      'switch bluetooth',
    ])) {
      return InterpretResult.matched(
        const ParsedCommand(
          action: AgentActions.bluetoothToggle,
          target: 'local',
        ),
      );
    }

    // --- Lock screen
    if (_oneOf(norm, const [
      'lock screen',
      'lock my phone',
      'lock the phone',
      'lock this device',
      'lock the device',
      'lock my device',
    ])) {
      return InterpretResult.matched(
        const ParsedCommand(action: AgentActions.lockScreen, target: 'local'),
      );
    }

    // --- Airplane mode (honest answer in the service layer — an app
    // cannot toggle the radios by itself).
    if (_oneOf(norm, const [
      'airplane mode on',
      'turn on airplane mode',
      'enable airplane mode',
    ])) {
      return InterpretResult.matched(
        const ParsedCommand(
          action: AgentActions.airplaneModeSet,
          target: 'local',
          arguments: {'state': 'on'},
        ),
      );
    }
    if (_oneOf(norm, const [
      'airplane mode off',
      'turn off airplane mode',
      'disable airplane mode',
    ])) {
      return InterpretResult.matched(
        const ParsedCommand(
          action: AgentActions.airplaneModeSet,
          target: 'local',
          arguments: {'state': 'off'},
        ),
      );
    }
    if (_oneOf(norm, const ['airplane mode', 'toggle airplane mode'])) {
      return InterpretResult.matched(
        const ParsedCommand(
          action: AgentActions.airplaneModeSet,
          target: 'local',
        ),
      );
    }

    // --- Restart (honest: no app restarts the machine it runs on).
    if (RegExp(
      r'^(?:restart|reboot)(?: (?:this|the|my) )?(?:device|phone|pc|laptop|computer|tablet)?$',
    ).hasMatch(norm)) {
      return InterpretResult.matched(
        const ParsedCommand(
          action: AgentActions.deviceRestart,
          target: 'local',
        ),
      );
    }

    // --- Video call: only ever starts in an app the user names. A bare
    // "video call mom" is answered honestly (which app?) — never silently
    // becomes a phone call or picks a default app for them.
    final video = RegExp(
      r'^(?:video call|videocall|video chat|face time|facetime) '
      r'(.+?)(?:\s+(?:on|via|using|through)\s+(.+))?$',
    ).firstMatch(norm);
    if (video != null) {
      var app = video.group(2)?.trim().toLowerCase();
      // "video call mom on my phone" names no app — drop the device suffix.
      if (app != null &&
          RegExp(r'^(?:my\s+)?(?:phone|device|cell)$').hasMatch(app)) {
        app = null;
      }
      final isFacetime =
          norm.startsWith('facetime') || norm.startsWith('face time');
      final resolvedApp = app ?? (isFacetime ? 'facetime' : null);
      return InterpretResult.matched(
        ParsedCommand(
          action: AgentActions.callPlace,
          target: 'local',
          arguments: {
            'contact': video.group(1)!.trim(),
            'mode': 'video',
            if (resolvedApp != null) 'app': resolvedApp,
          },
        ),
      );
    }

    // "whatsapp video call mom" — app first, contact last.
    final appVideo = RegExp(
      r'^(whatsapp|telegram|skype)\s+(?:video\s+)?call\s+(.+)$',
    ).firstMatch(norm);
    if (appVideo != null) {
      var who = appVideo.group(2)!.trim();
      who = who.replaceAll(
        RegExp(r'\s+(?:on|from)\s+(?:my\s+)?(?:phone|device|cell)$'),
        '',
      );
      return InterpretResult.matched(
        ParsedCommand(
          action: AgentActions.callPlace,
          target: 'local',
          arguments: {
            'contact': who,
            'mode': 'video',
            'app': appVideo.group(1)!.trim().toLowerCase(),
          },
        ),
      );
    }

    // --- Call
    final call = RegExp(r'^(?:call|dial|phone|ring|appelle|appeler) (.+)$')
        .firstMatch(norm);
    if (call != null) {
      final who = call.group(1)!.trim();
      // Strip trailing "on my phone" etc.
      final cleaned = who.replaceAll(
        RegExp(r'\s+(?:on|from)\s+(?:my\s+)?(?:phone|device|cell)$'),
        '',
      );
      return InterpretResult.matched(
        ParsedCommand(
          action: AgentActions.callPlace,
          target: 'local',
          arguments: {'contact': cleaned},
        ),
      );
    }
    // "give mom a call" word order
    final callGive = RegExp(r'^give (.+) (?:a|the) call$').firstMatch(norm);
    if (callGive != null) {
      return InterpretResult.matched(
        ParsedCommand(
          action: AgentActions.callPlace,
          target: 'local',
          arguments: {'contact': callGive.group(1)!.trim()},
        ),
      );
    }

    // --- Send text / SMS — every phrasing friends actually type, English
    // and French. A bare trailing message ("text mom love you") stays part
    // of the contact; the native side drops trailing words until the
    // contact resolves and treats the rest as the body. A trailing "on my
    // phone" is always a device marker, never part of the contact or the
    // draft.
    final textMsg = RegExp(
      r'^(?:text|sms|message|msg|texte|texto) '
      r'(.+?)(?:\s+(?:saying|disant|en disant)\s+(.+))?$',
    ).firstMatch(norm);
    if (textMsg != null) {
      final contact = _stripDeviceSuffix(textMsg.group(1)!);
      final body = _stripDeviceSuffix(textMsg.group(2) ?? '');
      return InterpretResult.matched(
        ParsedCommand(
          action: AgentActions.messageSend,
          target: 'local',
          arguments: {'contact': contact, if (body.isNotEmpty) 'body': body},
        ),
      );
    }

    // "send a text to mom saying hi" / "send an sms to mom". A bare
    // trailing body ("send a text to mom love you") stays in the contact
    // so the native side can split it — multi-word contacts ("varlet
    // florence") are never broken apart here.
    final sendTextTo = RegExp(
      r'^send (?:a |an )?(?:text|text message|texto|sms|message) to '
      r'(.+?)(?:\s+(?:saying|disant|en disant)\s+(.+))?'
      r'(?:\s+(.+))?$',
    ).firstMatch(norm);
    if (sendTextTo != null) {
      final contact = _stripDeviceSuffix(
        '${sendTextTo.group(1)!.trim()} ${sendTextTo.group(3) ?? ''}'.trim(),
      );
      final body = _stripDeviceSuffix(sendTextTo.group(2) ?? '');
      return InterpretResult.matched(
        ParsedCommand(
          action: AgentActions.messageSend,
          target: 'local',
          arguments: {'contact': contact, if (body.isNotEmpty) 'body': body},
        ),
      );
    }

    // "send mom a text saying hi" / "send mom a text love you" (bare body
    // stays in the contact; native side splits it)
    final sendObj = RegExp(
      r'^send (.+?) (?:a text|a texto|an? sms|a message|un message)'
      r'(?:\s+(?:saying|disant|en disant)\s+(.+))?'
      r'(?:\s+(.+))?$',
    ).firstMatch(norm);
    if (sendObj != null) {
      final contact = _stripDeviceSuffix(
        '${sendObj.group(1)!.trim()} ${sendObj.group(3) ?? ''}'.trim(),
      );
      final body = _stripDeviceSuffix(sendObj.group(2) ?? '');
      return InterpretResult.matched(
        ParsedCommand(
          action: AgentActions.messageSend,
          target: 'local',
          arguments: {'contact': contact, if (body.isNotEmpty) 'body': body},
        ),
      );
    }

    // French: "envoie un message a mom disant salut" (accents are folded
    // by normalizePhrase, so "à" arrives as "a").
    final frSend = RegExp(
      r'^envoie (?:un |une )?(?:message|texto|sms) a '
      r'(.+?)(?:\s+(?:disant|en disant|saying)\s+(.+))?$',
    ).firstMatch(norm);
    if (frSend != null) {
      final contact = _stripDeviceSuffix(frSend.group(1)!);
      final body = _stripDeviceSuffix(frSend.group(2) ?? '');
      return InterpretResult.matched(
        ParsedCommand(
          action: AgentActions.messageSend,
          target: 'local',
          arguments: {'contact': contact, if (body.isNotEmpty) 'body': body},
        ),
      );
    }

    // --- Clipboard: "copy <text>" or "send <text> to <device>". Only the
    // "copy" verb and device-targeted sends land here — a bare "send papi
    // salut" is a message to a person, never a clipboard write.
    final copy = RegExp(r'^copy (.+)$').firstMatch(norm);
    if (copy != null) {
      var text = copy.group(1)!.trim();
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
    final sendClip = RegExp(
      r'^send (.+) (?:to|onto|on) (?:my |the )?'
      r'(?:phone|pc|computer|laptop|tablet|devices|other devices|others)$',
    ).firstMatch(norm);
    if (sendClip != null) {
      return InterpretResult.matched(
        ParsedCommand(
          action: AgentActions.clipboardWrite,
          target: 'local',
          arguments: {'text': sendClip.group(1)!.trim()},
        ),
      );
    }

    // Bare "send X": someone-directed, not clipboard (device-targeted
    // sends were caught above).
    final bareSend = RegExp(r'^send (.+)$').firstMatch(norm);
    if (bareSend != null) {
      return InterpretResult.matched(
        ParsedCommand(
          action: AgentActions.messageSend,
          target: 'local',
          arguments: {'contact': bareSend.group(1)!.trim()},
        ),
      );
    }

    // --- Media controls
    if (_oneOf(norm, const [
      'play',
      'play music',
      'play the music',
      'resume',
      'resume music',
      'start playing',
      'unpause',
      'continue playing',
    ])) {
      return InterpretResult.matched(
        const ParsedCommand(action: AgentActions.mediaPlay, target: 'local'),
      );
    }
    if (_oneOf(norm, const [
      'pause',
      'pause music',
      'pause the music',
      'stop music',
      'stop playing',
      'pause playing',
    ])) {
      return InterpretResult.matched(
        const ParsedCommand(action: AgentActions.mediaPause, target: 'local'),
      );
    }
    if (_oneOf(norm, const [
      'next',
      'next track',
      'next song',
      'skip',
      'skip track',
      'skip song',
    ])) {
      return InterpretResult.matched(
        const ParsedCommand(action: AgentActions.mediaNext, target: 'local'),
      );
    }
    if (_oneOf(norm, const [
      'previous',
      'previous track',
      'previous song',
      'go back',
      'last track',
      'last song',
      'back a track',
    ])) {
      return InterpretResult.matched(
        const ParsedCommand(action: AgentActions.mediaPrev, target: 'local'),
      );
    }
    if (_oneOf(norm, const [
      'shuffle',
      'toggle shuffle',
      'randomize',
      'shuffle songs',
    ])) {
      return InterpretResult.matched(
        const ParsedCommand(action: AgentActions.mediaShuffle, target: 'local'),
      );
    }
    if (_oneOf(norm, const [
      'repeat',
      'toggle repeat',
      'repeat song',
      'repeat track',
      'loop',
      'loop song',
    ])) {
      return InterpretResult.matched(
        const ParsedCommand(action: AgentActions.mediaRepeat, target: 'local'),
      );
    }

    // --- Alarm
    final alarm = RegExp(r'^(?:set )?(?:an? )?alarm (?:for )?(.+)$')
        .firstMatch(norm);
    if (alarm != null) {
      final timeStr = alarm.group(1)!.trim();
      final parsed = parseClockTime(timeStr);
      if (parsed != null) {
        return InterpretResult.matched(
          ParsedCommand(
            action: AgentActions.alarmSet,
            target: 'local',
            arguments: {'hour': parsed.$1, 'minute': parsed.$2},
          ),
        );
      }
      return InterpretResult.needsInfo(
        'alarm.set.time',
        'What time should the alarm be? Try "7am" or "14:30".',
        const ParsedCommand(action: AgentActions.alarmSet, target: 'local'),
      );
    }

    // --- Reminder
    final remind = RegExp(
      r'^(?:remind me|set a reminder|remember to|reminder)(?: to| at| for)? (.+)$',
    ).firstMatch(norm);
    if (remind != null) {
      return InterpretResult.matched(
        ParsedCommand(
          action: AgentActions.reminderSet,
          target: 'local',
          arguments: {'text': remind.group(1)!.trim()},
        ),
      );
    }

    // --- Define word
    final defWord = RegExp(
      r'^(?:what does|define|definition of|meaning of|look up) (.+?)(?:\s+mean)?$',
    ).firstMatch(norm);
    if (defWord != null) {
      final word = defWord.group(1)!.trim();
      return InterpretResult.matched(
        ParsedCommand(
          action: AgentActions.defineWord,
          target: 'local',
          arguments: {'word': word},
        ),
      );
    }

    // --- Translate
    final trans = RegExp(
      r'^(?:translate|how do you say) (.+?)(?:\s+(?:to|into|in) (.+))?$',
    ).firstMatch(norm);
    if (trans != null) {
      final text = trans.group(1)!.trim();
      final lang = trans.group(2)?.trim();
      return InterpretResult.matched(
        ParsedCommand(
          action: AgentActions.translateText,
          target: 'local',
          arguments: {'text': text, if (lang != null) 'language': lang},
        ),
      );
    }

    // --- Unit conversion
    final convert = RegExp(
      r'^(?:convert|how (?:many|much)|what is) (\d+(?:\.\d+)?)\s*(\w+)\s+(?:to|in|into) (\w+)$',
    ).firstMatch(norm);
    if (convert != null) {
      return InterpretResult.matched(
        ParsedCommand(
          action: AgentActions.unitConvert,
          target: 'local',
          arguments: {
            'value': double.tryParse(convert.group(1)!) ?? 0,
            'from': convert.group(2)!,
            'to': convert.group(3)!,
          },
        ),
      );
    }

    // --- Roll dice
    if (_oneOf(norm, const [
      'roll a dice',
      'roll dice',
      'roll the dice',
      'roll a die',
      'dice',
    ])) {
      return InterpretResult.matched(
        const ParsedCommand(action: AgentActions.randomDice, target: 'local'),
      );
    }

    // --- Flip coin
    if (_oneOf(norm, const [
      'flip a coin',
      'flip coin',
      'flip the coin',
      'coin flip',
      'coin',
      'heads or tails',
    ])) {
      return InterpretResult.matched(
        const ParsedCommand(action: AgentActions.randomCoin, target: 'local'),
      );
    }

    // --- Random number
    final randNum = RegExp(
      r'^(?:random|pick a number|give me a number|number between) (?:number )?(?:between )?(\d+)\s*(?:and|to|-)\s*(\d+)$',
    ).firstMatch(norm);
    if (randNum != null) {
      final a = int.tryParse(randNum.group(1)!) ?? 1;
      final b = int.tryParse(randNum.group(2)!) ?? 100;
      return InterpretResult.matched(
        ParsedCommand(
          action: AgentActions.randomNumber,
          target: 'local',
          arguments: {'min': a < b ? a : b, 'max': a < b ? b : a},
        ),
      );
    }

    // --- Tell me a joke
    if (_oneOf(norm, const [
      'tell me a joke',
      'tell a joke',
      'joke',
      'say something funny',
      'make me laugh',
      'funny',
    ])) {
      return InterpretResult.matched(
        const ParsedCommand(action: AgentActions.tellJoke, target: 'local'),
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
      'what are your commands',
      'aide',
      'aide moi',
      'que peux tu faire',
      'que sais tu faire',
    ])) {
      return InterpretResult.matched(
        const ParsedCommand(action: AgentActions.helpGet, target: 'local'),
      );
    }

    return InterpretResult.unknown();
  }

  static (int, int)? parseClockTime(String raw) {
    final t = raw.trim().toLowerCase().replaceAll('.', '');
    if (t == 'noon') return (12, 0);
    if (t == 'midnight') return (0, 0);
    final m = RegExp(r'^(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$').firstMatch(t);
    if (m == null) return null;
    var hour = int.tryParse(m.group(1)!);
    final minute = m.group(2) == null ? 0 : (int.tryParse(m.group(2)!) ?? 0);
    final suffix = m.group(3);
    if (hour == null || minute > 59) return null;
    if (suffix != null) {
      if (hour < 1 || hour > 12) return null;
      if (suffix == 'pm' && hour != 12) hour += 12;
      if (suffix == 'am' && hour == 12) hour = 0;
    } else if (hour > 23) {
      return null;
    }
    return (hour, minute);
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

  /// Removes a trailing device marker ("on my phone") so it never becomes
  /// part of a contact name or a message draft.
  String _stripDeviceSuffix(String s) => s
      .replaceAll(
        RegExp(r'\s+(?:on|from)\s+(?:my\s+)?(?:phone|device|cell)$'),
        '',
      )
      .trim();

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
