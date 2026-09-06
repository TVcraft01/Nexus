// The assistant's local answer catalog: what it says when a parsed command
// can be answered on this device, plus the pure helpers those answers use
// (fact matching, phone extraction, formatting, arithmetic). Routing —
// which device, which approval, which clarification — stays in
// CommandService; this module only decides the words and the few memory
// writes an answer performs.
import 'dart:math';

import 'agent_contract.dart';
import 'command_interpreter.dart';
import 'reminders.dart';

/// The window onto the assistant's state the catalog may touch while
/// answering. Kept deliberately small so the catalog is readable and
/// testable without a full [CommandService]:
///  - [facts] is the live fact list — answers may read it and memory
///    commands (remember/forget) mutate it in place.
///  - [devices] lists the mesh devices reachable right now (for honest
///    find/ring answers).
///  - [local] is this device's snapshot (for "is this a phone?" answers).
///  - [onMemoryChanged]/[onFactLearned] fire exactly as in the service so a
///    remembered fact persists and broadcasts through the same funnel.
class AnswerContext {
  AnswerContext({
    required this.facts,
    required this.devices,
    required this.local,
    this.onMemoryChanged,
    this.onFactLearned,
  });

  final List<String> facts;
  final List<AgentDeviceSnapshot> Function() devices;
  final AgentDeviceSnapshot? local;
  final void Function()? onMemoryChanged;
  final void Function(String fact)? onFactLearned;
}

/// Capability ids of a device snapshot, for the catalog cases that ask
/// "can this device act?" (airplane mode, contact actions).
List<String> _capabilitiesOf(AgentDeviceSnapshot? device) =>
    device?.capabilities.map((c) => c.id).toList() ?? const [];

/// Whether [action] can actually execute somewhere in the assistant's world
/// right now — on this device, or on a paired device the mesh can reach.
bool _somewhereRuns(AnswerContext ctx, String action) {
  if (_capabilitiesOf(ctx.local).contains(action)) return true;
  return ctx.devices().any((d) => d.capabilities.any((c) => c.id == action));
}

/// The honest answer when a contact action has no taught number and nothing
/// in the assistant's world can execute it: teach the number instead of
/// echoing an action that can only fail here. (A paired phone would have its
/// own address book — the prompt only fires when no executor is reachable.)
AgentDispatchResult _unknownContactAnswer(String contact, String verb) =>
    AgentDispatchResult(
      status: AgentResultStatus.succeeded,
      dispatch: AgentMessage(
        'I don\'t have a number for "$contact" yet. Teach me with '
        '"remember that $contact is 0612345678" — then your Nexus phone '
        'can $verb them with the number.',
      ),
    );

/// Words worth matching on — lowercase, alphanumeric runs of 3+ chars,
/// minus a few stopwords so "the" in a topic doesn't match "the" in every
/// fact ("what is the capital of france" must not hit a bike fact).
const _stopWords = {
  'the',
  'and',
  'for',
  'with',
  'that',
  'this',
  'from',
  'was',
  'are',
  'has',
  'had',
  'not',
  'but',
  'all',
  'out',
  'get',
  'got',
};

/// Cross-wording: how people actually ask vs how they said it. Seeded
/// only with observed pairs ("what do you know about internet" for a
/// wifi fact); grows from the assistant log, never by hand-guessing.
const _synonyms = {
  'internet': ['wifi', 'network'],
  'family': ['mom', 'mum', 'mama', 'dad', 'papa', 'brother', 'sister'],
};

Set<String> _topicWords(String text) => text
    .toLowerCase()
    .split(RegExp(r'[^a-z0-9]+'))
    .where((w) => w.length >= 3 && !_stopWords.contains(w))
    .toSet();

/// Topic words plus their synonyms, so "about internet" reaches a wifi
/// fact without any model.
Set<String> _topicWordsExpanded(String text) {
  final words = _topicWords(text);
  return {...words, for (final w in words) ...?_synonyms[w]};
}

/// Facts loosely matching a spoken topic, best first. Substring matching
/// alone misses real wording: a bike-code fact is "about bike" but not
/// "about bicycle". A fact matches when any of its words loosely matches
/// any topic word — same word, a prefix, or small edit distance for
/// typos. Synonyms ("internet" ↔ "wifi") are deliberately out of scope.
List<String> _factsAbout(List<String> facts, String topic) {
  final topicWords = _topicWordsExpanded(topic);
  if (topicWords.isEmpty) return const [];
  bool loose(String factWord, String topicWord) {
    if (factWord == topicWord) return true;
    if (factWord.length >= 3 &&
        (factWord.startsWith(topicWord) || topicWord.startsWith(factWord))) {
      return true;
    }
    return topicWord.length >= 4 &&
        factWord.length >= 4 &&
        CommandInterpreter.phraseSimilarity(factWord, topicWord) >= 0.75;
  }

  bool factMatches(String fact) {
    final words = _topicWords(fact);
    return words.any((fw) => topicWords.any((tw) => loose(fw, tw)));
  }

  final hits = facts.where(factMatches).toList();
  hits.sort(
    (a, b) => _factScore(b, topicWords).compareTo(_factScore(a, topicWords)),
  );
  return hits;
}

/// How strongly a fact matches a set of topic words — used only to order
/// multiple hits, never to admit them.
int _factScore(String fact, Set<String> topicWords) =>
    _topicWords(fact).intersection(topicWords).length;

/// A phone-looking token in [fact], normalized to digits, or null. Requires
/// 9..15 digits (E.164 max) so street numbers, years, and card or order
/// numbers never resolve as contacts.
String? _phoneIn(String fact) {
  final run = RegExp(r'\+?[\d\s.\-()]{9,}').firstMatch(fact);
  if (run == null) return null;
  final digits = run.group(0)!.replaceAll(RegExp(r'[^\d+]'), '');
  return digits.length >= 9 && digits.length <= 15 ? digits : null;
}

/// The phone number nexus has been taught for a contact name, or null when
/// no matching fact carries one — the device then falls back to its own
/// address book. Best-scoring fact wins, like question recall.
String? _contactNumber(List<String> facts, String name) {
  if (name.isEmpty) return null;
  for (final fact in _factsAbout(facts, name)) {
    final number = _phoneIn(fact);
    if (number != null) return number;
  }
  return null;
}

/// Locally executable intents that need no device: greeting, time, math.
AgentDispatchResult localAnswer(ParsedCommand command, AnswerContext ctx) {
  switch (command.action) {
    case AgentActions.helpGet:
      return const AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Here is what I can do:\n'
          '\n'
          'Time & Math:\n'
          '  \"what time is it\" / \"what is the date\"\n'
          '  \"what is 12 times 8\" / \"2 + 3\"\n'
          '\n'
          'System:\n'
          '  \"open youtube\" — launch any app\n'
          '  \"battery\" / \"screenshot\"\n'
          '  \"flashlight on\" / \"brightness 50\"\n'
          '  \"volume up\" / \"volume down\" / \"mute\"\n'
          '  \"wifi on\" / \"bluetooth off\"\n'
          '  \"lock screen\"\n'
          '\n'
          'Communication:\n'
          '  \"call mom\" — open dialer\n'
          '  \"text dad saying hello\" — send SMS\n'
          '\n'
          'Media:\n'
          '  \"play\" / \"pause\" / \"next\" / \"previous\"\n'
          '  \"shuffle\" / \"repeat\"\n'
          '\n'
          'Productivity:\n'
          '  \"alarm for 7am\" / \"remind me to buy milk\"\n'
          '  \"define serendipity\" / \"translate hello to French\"\n'
          '  "convert 5 miles to km" / "convert 100 usd to eur"\n'
          '  "what is 15% of 80" — math with percents\n'
          '\n'
          'Weather & Getting Around:\n'
          '  "what is the weather in paris" — live forecast\n'
          '  "take me home" / "navigate to the office" — maps\n'
          '\n'
          'Email:\n'
          '  "email mom saying hello" — opens your mail app\n'
          '  "set volume to 50" — volume to a level\n'
          '\n'
          'Fun:\n'
          '  \"roll a dice\" / \"flip a coin\" / \"random 1 to 100\"\n'
          '  \"tell me a joke\"\n'
          '\n'
          'Clipboard & Devices:\n'
          '  \"copy hello to my devices\"\n'
          '  \"show my devices\" / \"blink the ESP32\"\n'
          '\n'
          'Web:\n'
          '  \"search for flutter\" / \"open github.com\"\n'
          '  \"note that buy milk\"\n'
          '\n'
          'Memory:\n'
          '  "remember that my bike code is 4321"\n'
          '  "what is my wifi password" — I answer from memory\n'
          '  "what do you know about me" / "forget my bike code"\n'
          '  "remember that mom is 0612345678" — then "call mom" / "text mom" use it\n'
          '\n'
          'If I misunderstand, just teach me once — I remember.',
        ),
      );
    case AgentActions.greet:
      return const AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Hello! I can tell you the time, do math, search the web, save notes, show your PC specs, and copy text between your devices. Ask me anything — and if I don\'t understand, I\'ll ask you to teach me.',
        ),
      );
    case AgentActions.timeGet:
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          _formatTime(command.arguments['kind']),
          // The clock keeps ticking instead of freezing at the answer.
          live: command.arguments['kind'] != 'date',
        ),
      );
    case AgentActions.mathCalc:
      final result = evaluateMath(command.arguments['expr'] as String? ?? '');
      if (result == null) {
        return const AgentDispatchResult(
          status: AgentResultStatus.unavailable,
          message: 'I couldn\'t work that out — try something like "what is 2 plus 2".',
        );
      }
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          '${command.arguments['expr']} = ${_formatNumber(result)}',
        ),
      );
    case AgentActions.webSearch:
      final query = command.arguments['query'] as String? ?? '';
      if (query.isEmpty) {
        return const AgentDispatchResult(
          status: AgentResultStatus.unavailable,
          message: 'What should I search for?',
        );
      }
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Opening search for "$query"…',
          action: AgentActions.webSearch,
          arguments: {'query': query},
        ),
      );
    case AgentActions.weatherGet:
      final place = command.arguments['place'] as String? ?? '';
      if (place.isEmpty) {
        return const AgentDispatchResult(
          status: AgentResultStatus.unavailable,
          message: 'Which city? Try "weather in Paris".',
        );
      }
      final kind = command.arguments['kind'] as String? ?? 'now';
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Checking the weather in $place…',
          action: AgentActions.weatherGet,
          arguments: {'place': place, 'kind': kind},
        ),
      );
    case AgentActions.navOpen:
      final query = command.arguments['query'] as String? ?? '';
      if (query.isEmpty) {
        return const AgentDispatchResult(
          status: AgentResultStatus.unavailable,
          message: 'Where should I take you?',
        );
      }
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Opening maps for "$query"…',
          action: AgentActions.navOpen,
          arguments: {'query': query},
        ),
      );
    case AgentActions.noteCreate:
      final text = command.arguments['text'] as String? ?? '';
      if (text.isEmpty) {
        return const AgentDispatchResult(
          status: AgentResultStatus.unavailable,
          message: 'What should I note down?',
        );
      }
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Noted: "$text"',
          action: AgentActions.noteCreate,
          arguments: {'text': text},
        ),
      );
    case AgentActions.timerSet:
      // Accept the remembered default in either shape: an int (typed
      // "300") or the plain answer to the question ("5 minutes").
      final raw = command.arguments['seconds'];
      final seconds = raw is int
          ? raw
          : CommandInterpreter.parseDurationSeconds(raw?.toString() ?? '');
      if (seconds == null || seconds <= 0) {
        return const AgentDispatchResult(
          status: AgentResultStatus.unavailable,
          message: 'How long should the timer run?',
        );
      }
      final minutes = seconds ~/ 60;
      final secs = seconds % 60;
      final label = minutes > 0 ? '${minutes}m ${secs}s' : '${secs}s';
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Timer set for $label.',
          action: AgentActions.timerSet,
          arguments: {'seconds': seconds},
        ),
      );
    case AgentActions.openUrl:
      final url = command.arguments['url'] as String? ?? '';
      if (url.isEmpty) {
        return const AgentDispatchResult(
          status: AgentResultStatus.unavailable,
          message: 'What should I open?',
        );
      }
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Opening $url…',
          action: AgentActions.openUrl,
          arguments: {'url': url},
        ),
      );
    case AgentActions.systemInfo:
      return const AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Checking system info…',
          action: AgentActions.systemInfo,
        ),
      );
    case AgentActions.volumeSet:
      final mode = command.arguments['mode'] as String? ?? 'mute';
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Volume $mode.',
          action: AgentActions.volumeSet,
          arguments: {'mode': mode},
        ),
      );
    // --- System ---
    case AgentActions.appOpen:
      final query = command.arguments['query'] as String? ?? '';
      if (query.isEmpty) {
        return const AgentDispatchResult(
          status: AgentResultStatus.unavailable,
          message: 'What app should I open?',
        );
      }
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Opening $query...',
          action: AgentActions.appOpen,
          arguments: {'query': query},
        ),
      );
    case AgentActions.appClose:
      final query = command.arguments['query'] as String? ?? '';
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Closing $query...',
          action: AgentActions.appClose,
          arguments: {'query': query},
        ),
      );
    case AgentActions.screenshot:
      return const AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Taking screenshot...',
          action: AgentActions.screenshot,
        ),
      );
    case AgentActions.batteryGet:
      return const AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Checking battery...',
          action: AgentActions.batteryGet,
        ),
      );
    case AgentActions.brightnessSet:
      final mode = command.arguments['mode'] as String? ?? 'up';
      final level = command.arguments['level'];
      final label = level != null ? 'to $level%' : mode;
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Brightness $label.',
          action: AgentActions.brightnessSet,
          arguments: {'mode': mode, if (level != null) 'level': level},
        ),
      );
    case AgentActions.flashlightToggle:
      final state = command.arguments['state'] as String?;
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          state != null ? 'Flashlight $state.' : 'Toggling flashlight.',
          action: AgentActions.flashlightToggle,
          arguments: {if (state != null) 'state': state},
        ),
      );
    case AgentActions.wifiToggle:
      final state = command.arguments['state'] as String?;
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          state != null ? 'WiFi $state.' : 'Toggling WiFi.',
          action: AgentActions.wifiToggle,
          arguments: {if (state != null) 'state': state},
        ),
      );
    case AgentActions.bluetoothToggle:
      final state = command.arguments['state'] as String?;
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          state != null ? 'Bluetooth $state.' : 'Toggling Bluetooth.',
          action: AgentActions.bluetoothToggle,
          arguments: {if (state != null) 'state': state},
        ),
      );
    case AgentActions.lockScreen:
      return const AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Locking screen.',
          action: AgentActions.lockScreen,
        ),
      );
    // --- Communication ---
    case AgentActions.callPlace:
      final contact = command.arguments['contact'] as String? ?? '';
      if (contact.isEmpty) {
        return const AgentDispatchResult(
          status: AgentResultStatus.unavailable,
          message: 'Who should I call?',
        );
      }
      final isVideo = command.arguments['mode'] == 'video';
      final app = command.arguments['app'] as String?;
      // Video calls open a named app (WhatsApp/Telegram) by contact, not by
      // number — resolution only applies to plain calls.
      if (!isVideo) {
        final number = _contactNumber(ctx.facts, contact);
        if (number == null && !_somewhereRuns(ctx, AgentActions.callPlace)) {
          return _unknownContactAnswer(contact, 'call');
        }
        final who = number != null ? '$contact at $number' : contact;
        return AgentDispatchResult(
          status: AgentResultStatus.succeeded,
          dispatch: AgentMessage(
            'Calling $who...',
            action: AgentActions.callPlace,
            arguments: {'contact': contact, 'number': ?number},
          ),
        );
      }
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          app == null
              ? 'Which app should I video call $contact on?'
              : 'Video calling $contact on $app...',
          action: AgentActions.callPlace,
          arguments: {
            'contact': contact,
            'mode': 'video',
            if (app != null) 'app': app,
          },
        ),
      );
    case AgentActions.messageSend:
      final contact = command.arguments['contact'] as String? ?? '';
      if (contact.isEmpty) {
        return const AgentDispatchResult(
          status: AgentResultStatus.unavailable,
          message: 'Who should I text?',
        );
      }
      final body = command.arguments['body'] as String?;
      final number = _contactNumber(ctx.facts, contact);
      if (number == null && !_somewhereRuns(ctx, AgentActions.messageSend)) {
        return _unknownContactAnswer(contact, 'text');
      }
      final who = number != null ? '$contact at $number' : contact;
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          body != null ? 'Texting $who: "$body"' : 'Opening text to $who...',
          action: AgentActions.messageSend,
          arguments: {'contact': contact, 'number': ?number, 'body': ?body},
        ),
      );
    case AgentActions.emailSend:
      final contact = command.arguments['contact'] as String? ?? '';
      if (contact.isEmpty) {
        return const AgentDispatchResult(
          status: AgentResultStatus.unavailable,
          message: 'Who should I email?',
        );
      }
      final body = command.arguments['body'] as String?;
      // The device's own address book resolves the address (like texts do
      // with numbers); no taught-address concept exists yet, so email stays
      // a device action unless nothing anywhere can run it.
      if (!_somewhereRuns(ctx, AgentActions.emailSend)) {
        return AgentDispatchResult(
          status: AgentResultStatus.succeeded,
          dispatch: AgentMessage(
            'I can\'t open email on this device — try on a device with a mail app.',
          ),
        );
      }
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          body != null
              ? 'Emailing $contact: "$body"'
              : 'Opening email to $contact...',
          action: AgentActions.emailSend,
          arguments: {'contact': contact, 'body': ?body},
        ),
      );
    // --- Media ---
    case AgentActions.mediaPlay:
      final query = command.arguments['query'] as String?;
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          query != null ? 'Playing "$query"…' : 'Playing.',
          action: AgentActions.mediaPlay,
          arguments: {if (query != null) 'query': query},
        ),
      );
    case AgentActions.mediaPause:
      return const AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage('Paused.', action: AgentActions.mediaPause),
      );
    case AgentActions.mediaNext:
      return const AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage('Next track.', action: AgentActions.mediaNext),
      );
    case AgentActions.mediaPrev:
      return const AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Previous track.',
          action: AgentActions.mediaPrev,
        ),
      );
    case AgentActions.mediaShuffle:
      return const AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Shuffle toggled.',
          action: AgentActions.mediaShuffle,
        ),
      );
    case AgentActions.mediaRepeat:
      return const AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Repeat toggled.',
          action: AgentActions.mediaRepeat,
        ),
      );
    // --- Productivity ---
    case AgentActions.alarmSet:
      final hour = command.arguments['hour'] as int? ?? 0;
      final minute = command.arguments['minute'] as int? ?? 0;
      final hh = hour.toString().padLeft(2, '0');
      final mm = minute.toString().padLeft(2, '0');
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Alarm set for $hh:$mm.',
          action: AgentActions.alarmSet,
          arguments: {'hour': hour, 'minute': minute},
        ),
      );
    case AgentActions.reminderSet:
      final raw = command.arguments['text'] as String? ?? '';
      final split = const Reminders().splitTime(raw, Reminders.now());
      if (split == null) {
        // No time in the request — never pretend a reminder was set.
        return const AgentDispatchResult(
          status: AgentResultStatus.succeeded,
          dispatch: AgentMessage(
            'I\'ll remind you — but when? Try "remind me to buy milk at 6pm" '
            'or "remind me to stretch in 20 minutes".',
          ),
        );
      }
      final (text, dueAt) = split;
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Reminder set for ${_clockLabel(dueAt)} — I\'ll tell you then.',
          action: AgentActions.reminderSet,
          arguments: {'text': text, 'dueAt': dueAt.toIso8601String()},
        ),
      );
    case AgentActions.defineWord:
      final word = command.arguments['word'] as String? ?? '';
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Looking up "$word"...',
          action: AgentActions.defineWord,
          arguments: {'query': 'define $word'},
        ),
      );
    case AgentActions.translateText:
      final text = command.arguments['text'] as String? ?? '';
      final lang = command.arguments['language'] as String?;
      final target = lang != null ? ' to $lang' : '';
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Translating "$text"$target...',
          action: AgentActions.webSearch,
          arguments: {'query': 'translate $text$target'},
        ),
      );
    case AgentActions.unitConvert:
      final value = command.arguments['value'] ?? 0;
      final from = command.arguments['from'] as String? ?? '';
      final to = command.arguments['to'] as String? ?? '';
      // Currency needs live rates the app has no source for — a plain unit
      // conversion (miles->km) is computed inline; currency goes to the web.
      const currencies = {
        'usd', 'eur', 'gbp', 'chf', 'jpy', 'cad', 'aud', 'cny', 'inr', 'btc',
      };
      if (currencies.contains(from.toLowerCase()) ||
          currencies.contains(to.toLowerCase())) {
        return AgentDispatchResult(
          status: AgentResultStatus.succeeded,
          dispatch: AgentMessage(
            'I don\'t have live exchange rates — searching instead…',
            action: AgentActions.webSearch,
            arguments: {'query': 'convert $value $from to $to'},
          ),
        );
      }
      final converted = _convertUnit(value, from, to);
      if (converted != null) {
        return AgentDispatchResult(
          status: AgentResultStatus.succeeded,
          dispatch: AgentMessage(
            '$value $from = ${_formatNumber(converted)} $to.',
          ),
        );
      }
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Converting $value $from to $to...',
          action: AgentActions.webSearch,
          arguments: {'query': 'convert $value $from to $to'},
        ),
      );
    // --- Alarm dismiss / timer status & cancel: system apps own alarms and
    // timers — apps can set them but cannot read or stop them. Say so
    // instead of faking a win.
    case AgentActions.alarmDismiss:
      return const AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'I can set alarms, but I can\'t turn them off from inside the app — open the Clock app to dismiss it.',
        ),
      );
    case AgentActions.timerStatus:
      return const AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Timers live in your system Clock app, so I can\'t see the time left from here — open the Clock app to check.',
        ),
      );
    case AgentActions.timerCancel:
      return const AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'I can start timers, but I can\'t stop one from inside the app — open the Clock app to cancel it.',
        ),
      );
    case AgentActions.darkModeSet:
      return const AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'Dark mode is a system setting — I can\'t switch it from inside the app. Open your display settings to change it.',
        ),
      );
    // --- Fun ---
    case AgentActions.randomDice:
      final result = Random().nextInt(6) + 1;
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage('Rolled a $result!'),
      );
    case AgentActions.randomCoin:
      final result = Random().nextBool() ? 'Heads' : 'Tails';
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage('$result!'),
      );
    case AgentActions.randomNumber:
      final min = command.arguments['min'] as int? ?? 1;
      final max = command.arguments['max'] as int? ?? 100;
      final result = min + Random().nextInt(max - min + 1);
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage('$result'),
      );
    case AgentActions.tellJoke:
      const jokes = [
        'Why do programmers prefer dark mode? Because light attracts bugs!',
        'There are 10 types of people in the world: those who understand binary and those who don\'t.',
        'A SQL query walks into a bar, sees two tables and asks... "Can I join you?"',
        'Why was the JavaScript developer sad? Because he didn\'t Node how to Express himself.',
        'What\'s a programmer\'s favorite hangout place? Foo Bar.',
        'Why do Java developers wear glasses? Because they can\'t C#.',
        'How many programmers does it take to change a light bulb? None, that\'s a hardware problem.',
        'What do you call a group of 8 hobbits? A hobbyte.',
        'Why did the developer go broke? Because he used up all his cache.',
        'What do you call a computer that sings? A-Dell.',
      ];
      final joke = jokes[Random().nextInt(jokes.length)];
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(joke),
      );
    // --- Find/ring a paired device. There is no ring/find executor in
    // this release, so the honest answer depends on whether the target
    // is actually on the mesh right now — never a silent dead-end.
    case AgentActions.findDevice:
    case AgentActions.ringDevice:
      final who = command.target;
      final reachable = ctx.devices().any(
        (d) =>
            d.online &&
            (d.name.toLowerCase().contains(who.toLowerCase()) ||
                d.id.toLowerCase() == who.toLowerCase()),
      );
      final verb = command.action == AgentActions.ringDevice
          ? 'make it ring'
          : 'find it';
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          reachable
              ? '"$who" is online on your mesh, but I can\'t $verb from the assistant in this release yet.'
              : 'I don\'t see "$who" online right now. $verb needs the other device connected to your mesh — open the Devices tab to check.',
        ),
      );
    // --- Airplane mode: needs a system permission, or doesn't exist on a
    // PC. Say which instead of pretending to toggle radios.
    case AgentActions.airplaneModeSet:
      final isPhone = _capabilitiesOf(ctx.local)
          .contains(AgentActions.callPlace);
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          isPhone
              ? 'Airplane mode needs a system-level permission Nexus doesn\'t take — swipe down from the top of the screen and tap the airplane toggle.'
              : 'Airplane mode is a phone feature — this device has no radios to switch.',
        ),
      );
    case AgentActions.deviceRestart:
      return const AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          'I won\'t restart the device from inside the app — use the power menu.',
        ),
      );
    // --- Memory: facts the user told us about their world. All three
    // answer locally with plain messages — the store is the memory.
    case AgentActions.memoryRemember:
      final text = (command.arguments['text'] as String? ?? '').trim();
      // A bare framing phrase ("remember that") makes the interpreter's
      // regex backtrack into capturing the framing word itself — answer
      // exactly as if nothing was said, never store it.
      if (text.isEmpty ||
          text.toLowerCase() == 'that' ||
          text.toLowerCase() == 'this') {
        return const AgentDispatchResult(
          status: AgentResultStatus.unavailable,
          message: 'What should I remember? Try "remember that my wifi password is nexus".',
        );
      }
      if (ctx.facts.any((f) => f.toLowerCase() == text.toLowerCase())) {
        return AgentDispatchResult(
          status: AgentResultStatus.succeeded,
          dispatch: AgentMessage('I already know that.'),
        );
      }
      ctx.facts.add(text);
      ctx.onMemoryChanged?.call();
      ctx.onFactLearned?.call(text);
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage('Remembered: "$text".'),
      );
    case AgentActions.memoryRecall:
      final topic = (command.arguments['topic'] as String? ?? '').trim();
      if (ctx.facts.isEmpty) {
        return const AgentDispatchResult(
          status: AgentResultStatus.succeeded,
          dispatch: AgentMessage(
            'I don\'t remember anything about you yet. Tell me with "remember that …".',
          ),
        );
      }
      final matches = topic.isEmpty
          ? ctx.facts.toList()
          : _factsAbout(ctx.facts, topic);
      if (matches.isEmpty) {
        return AgentDispatchResult(
          status: AgentResultStatus.succeeded,
          dispatch: AgentMessage(
            'I don\'t remember anything about "$topic" yet. Tell me with "remember that …".',
          ),
        );
      }
      final heading = topic.isEmpty
          ? 'Here is what I know:'
          : 'About "$topic":';
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          '$heading\n${matches.map((f) => '  • $f').join('\n')}',
        ),
      );
    case AgentActions.memoryQuestion:
      // The payoff of memory: a personal question answered from what the
      // user actually said. Nothing stored? Fall back to the web honestly.
      final qTopic = (command.arguments['topic'] as String? ?? '').trim();
      if (qTopic.isEmpty) {
        return const AgentDispatchResult(
          status: AgentResultStatus.unavailable,
          message: 'What do you want to know? Try "what is my wifi password".',
        );
      }
      final hits = _factsAbout(ctx.facts, qTopic);
      if (hits.isEmpty) {
        return AgentDispatchResult(
          status: AgentResultStatus.succeeded,
          dispatch: AgentMessage(
            'I don\'t know that yet — nothing you told me matches "$qTopic". Searching the web instead…',
            action: AgentActions.webSearch,
            arguments: {'query': qTopic},
          ),
        );
      }
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          hits.length == 1
              ? hits.single
              : '${hits.length} things you told me match "$qTopic":\n'
                    '${hits.map((f) => '  • $f').join('\n')}',
        ),
      );
    case AgentActions.memoryForget:
      final query = (command.arguments['text'] as String? ?? '').trim();
      // Same backtrack guard as remember: "forget that" must ask what to
      // forget, never delete every fact containing the word "that".
      if (query.isEmpty || query.toLowerCase() == 'that') {
        return const AgentDispatchResult(
          status: AgentResultStatus.unavailable,
          message: 'What should I forget? Try "forget my wifi password".',
        );
      }
      final gone = ctx.facts
          .where((f) => f.toLowerCase().contains(query.toLowerCase()))
          .toList();
      if (gone.isEmpty) {
        return AgentDispatchResult(
          status: AgentResultStatus.succeeded,
          dispatch: AgentMessage('I don\'t remember anything like "$query".'),
        );
      }
      ctx.facts.removeWhere(
        (f) => f.toLowerCase().contains(query.toLowerCase()),
      );
      ctx.onMemoryChanged?.call();
      return AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          gone.length == 1
              ? 'Forgotten: "${gone.single}".'
              : 'Forgotten ${gone.length} things.',
        ),
      );
    default:
      return const AgentDispatchResult(
        status: AgentResultStatus.unavailable,
        message: 'This command is not available yet.',
      );
  }
}

String _formatTime(Object? kind) {
  final now = DateTime.now();
  if (kind == 'date') {
    const weekdays = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    return 'It\'s ${weekdays[now.weekday - 1]}, ${months[now.month - 1]} ${now.day}, ${now.year}.';
  }
  final hh = now.hour.toString().padLeft(2, '0');
  final mm = now.minute.toString().padLeft(2, '0');
  return 'It\'s $hh:$mm.';
}

String _formatNumber(double value) => value == value.roundToDouble()
    ? value.toInt().toString()
    : value.toString();

/// Inline unit conversion for the units Siri converts without the web:
/// lengths, weights, temperatures, speeds. Returns null when the pair is
/// not known — the caller falls back to a web search, never a fake number.
double? _convertUnit(double value, String from, String to) {
  final f = from.trim().toLowerCase();
  final t = to.trim().toLowerCase();
  double? toBase(String unit) {
    // Length → meters
    switch (unit) {
      case 'km' || 'kilometer' || 'kilometers':
        return value * 1000;
      case 'm' || 'meter' || 'meters':
        return value;
      case 'cm' || 'centimeter' || 'centimeters':
        return value / 100;
      case 'mm' || 'millimeter' || 'millimeters':
        return value / 1000;
      case 'mile' || 'miles' || 'mi':
        return value * 1609.344;
      case 'yard' || 'yards' || 'yd':
        return value * 0.9144;
      case 'foot' || 'feet' || 'ft':
        return value * 0.3048;
      case 'inch' || 'inches' || 'in':
        return value * 0.0254;
      // Weight → kilograms
      case 'kg' || 'kilogram' || 'kilograms':
        return value;
      case 'g' || 'gram' || 'grams':
        return value / 1000;
      case 'mg' || 'milligram' || 'milligrams':
        return value / 1e6;
      case 'lb' || 'lbs' || 'pound' || 'pounds':
        return value * 0.45359237;
      case 'ounce' || 'ounces' || 'oz':
        return value * 0.028349523;
      case 'stone' || 'stones':
        return value * 6.35029318;
      // Temperature → celsius
      case 'c' || 'celsius':
        return value;
      case 'f' || 'fahrenheit':
        return (value - 32) * 5 / 9;
      case 'k' || 'kelvin':
        return value - 273.15;
      // Speed → km/h
      case 'kmh' || 'kph' || 'km/h':
        return value;
      case 'mph':
        return value * 1.609344;
      default:
        return null;
    }
  }

  double? fromBase(double v, String unit) {
    switch (unit) {
      case 'km' || 'kilometer' || 'kilometers':
        return v / 1000;
      case 'm' || 'meter' || 'meters':
        return v;
      case 'cm' || 'centimeter' || 'centimeters':
        return v * 100;
      case 'mm' || 'millimeter' || 'millimeters':
        return v * 1000;
      case 'mile' || 'miles' || 'mi':
        return v / 1609.344;
      case 'yard' || 'yards' || 'yd':
        return v / 0.9144;
      case 'foot' || 'feet' || 'ft':
        return v / 0.3048;
      case 'inch' || 'inches' || 'in':
        return v / 0.0254;
      case 'kg' || 'kilogram' || 'kilograms':
        return v;
      case 'g' || 'gram' || 'grams':
        return v * 1000;
      case 'mg' || 'milligram' || 'milligrams':
        return v * 1e6;
      case 'lb' || 'lbs' || 'pound' || 'pounds':
        return v / 0.45359237;
      case 'ounce' || 'ounces' || 'oz':
        return v / 0.028349523;
      case 'stone' || 'stones':
        return v / 6.35029318;
      case 'c' || 'celsius':
        return v;
      case 'f' || 'fahrenheit':
        return v * 9 / 5 + 32;
      case 'k' || 'kelvin':
        return v + 273.15;
      case 'kmh' || 'kph' || 'km/h':
        return v;
      case 'mph':
        return v / 1.609344;
      default:
        return null;
    }
  }

  final base = toBase(f);
  if (base == null) return null;
  final out = fromBase(base, t);
  if (out == null) return null;
  // Rounding to 4 significant decimals keeps answers clean and honest.
  return double.parse(out.toStringAsPrecision(6));
}

/// "8:00pm" / "6:05am" — how the reminder echo says when it fires.
String _clockLabel(DateTime t) {
  final hh = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final mm = t.minute.toString().padLeft(2, '0');
  final meridiem = t.hour < 12 ? 'am' : 'pm';
  return '$hh:$mm$meridiem';
}

/// Safely evaluates a small arithmetic expression: numbers, `+ - * /` and
/// parentheses. Returns null for anything invalid (empty, bad tokens, or
/// division by zero). No dynamic code is ever executed.
double? evaluateMath(String expr) {
  final clean = expr.trim();
  if (clean.isEmpty || RegExp(r'[^0-9+\-*/(). ]').hasMatch(clean)) return null;
  final tokens = RegExp(r'\d+(\.\d+)?|[()+\-*/]')
      .allMatches(clean)
      .map((m) => m.group(0)!)
      .toList();
  final values = <double>[];
  final ops = <String>[];

  int precedence(String op) => op == '+' || op == '-' ? 1 : 2;

  bool apply() {
    if (values.length < 2 || ops.isEmpty) return false;
    final b = values.removeLast();
    final a = values.removeLast();
    final op = ops.removeLast();
    switch (op) {
      case '+':
        values.add(a + b);
      case '-':
        values.add(a - b);
      case '*':
        values.add(a * b);
      case '/':
        if (b == 0) return false;
        values.add(a / b);
    }
    return true;
  }

  for (final token in tokens) {
    if (RegExp(r'^\d').hasMatch(token)) {
      values.add(double.parse(token));
      continue;
    }
    if (token == '(') {
      ops.add(token);
      continue;
    }
    if (token == ')') {
      while (ops.isNotEmpty && ops.last != '(') {
        if (!apply()) return null;
      }
      if (ops.isEmpty) return null;
      ops.removeLast();
      continue;
    }
    while (ops.isNotEmpty &&
        ops.last != '(' &&
        precedence(ops.last) >= precedence(token)) {
      if (!apply()) return null;
    }
    ops.add(token);
  }
  while (ops.isNotEmpty) {
    if (!apply()) return null;
  }
  return values.length == 1 && ops.isEmpty ? values.single : null;
}
