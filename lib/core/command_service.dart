import 'dart:math';

import 'agent_contract.dart';
import 'command_interpreter.dart';

/// What the assistant remembers between sessions:
///  - [learned]: a phrase the user taught, mapped to the command it means
///    (e.g. "bring me home" -> "show my devices").
///  - [defaults]: an answer to a previous "which …?" question, keyed by the
///    argument (e.g. `media.play.playlist` -> "Chill Mix").
///  - [facts]: things the user told us about their world ("my wifi password
///    is nexus"), kept as plain text so recall can search them by keyword.
class AgentMemory {
  final Map<String, String> learned;
  final Map<String, dynamic> defaults;
  final List<String> facts;

  const AgentMemory({
    this.learned = const {},
    this.defaults = const {},
    this.facts = const [],
  });
}

class CommandService {
  final List<AgentDeviceSnapshot> Function() devices;
  final CommandInterpreter _interpreter;
  final Map<String, String> _learned;
  final Map<String, dynamic> _defaults;
  final List<String> _facts;
  final void Function()? onMemoryChanged;

  /// Fired when the user teaches a phrase on THIS device, so the view can
  /// broadcast it to paired devices. Never fired for phrases adopted from a
  /// peer (that would re-broadcast and loop the mesh).
  final void Function(String phrase, String meaning)? onPhraseLearned;

  /// The device the assistant is running on (with its capabilities). Used to
  /// decide whether an action can run here or should be offered to another
  /// device ("Do it on My Phone?").
  final AgentDeviceSnapshot? local;

  /// Actions this very device can truly execute end-to-end (calls on
  /// Android). When such an action routes here, the plan targets this device
  /// so the UI runs it in place; everything else keeps the honest unwired
  /// answer.
  final Set<String> locallyExecutable;

  /// Fired when the user tells the assistant a fact on THIS device, so the
  /// view can broadcast it to paired devices. Never fired for facts adopted
  /// from a peer (that would re-broadcast and loop the mesh).
  final void Function(String fact)? onFactLearned;

  /// The last input behind each open clarification, keyed by the
  /// [AgentClarification.key] handed to the UI.
  final Map<String, String> _pendingContext = {};

  /// The device pinned for an action ("call mom" -> My Phone), keyed by the
  /// action. Sticky on purpose: the approval re-run of the original command
  /// must not forget it, and "I'll remember which one" is the promise.
  final Map<String, String> _pendingDeviceChoice = {};

  CommandService({
    required this.devices,
    AgentMemory memory = const AgentMemory(),
    this.onMemoryChanged,
    this.onPhraseLearned,
    this.onFactLearned,
    this.local,
    this.locallyExecutable = const {},
    this._interpreter = const CommandInterpreter(),
  }) : _learned = Map.of(memory.learned),
       _defaults = Map.of(memory.defaults),
       _facts = List.of(memory.facts);

  /// Snapshot of the taught phrases, for persisting to the store.
  Map<String, String> get learnedSnapshot => Map.unmodifiable(_learned);

  /// Snapshot of the remembered argument defaults, for persisting.
  Map<String, dynamic> get defaultsSnapshot => Map.unmodifiable(_defaults);

  /// Snapshot of the facts the user told us, for persisting.
  List<String> get factsSnapshot => List.unmodifiable(_facts);

  /// Adopts a fact told to a paired device and synced over the mesh.
  /// Persists like a local remember, but never fires [onFactLearned] — the
  /// fact came FROM the mesh, broadcasting it back would loop forever.
  void adoptFact(String fact) {
    final clean = fact.trim();
    if (clean.isEmpty) return;
    if (_facts.any((f) => f.toLowerCase() == clean.toLowerCase())) return;
    _facts.add(clean);
    onMemoryChanged?.call();
  }

  AgentDispatchResult execute(
    String input, {
    AgentApproval approval = AgentApproval.required,
    String requestId = 'local-command',
    String? answerTo,
  }) {
    final text = input.trim();
    if (text.isEmpty) {
      return const AgentDispatchResult(status: AgentResultStatus.unavailable);
    }

    // An answer to a pending question (which playlist? / teach me a phrase).
    if (answerTo != null) {
      final original = _pendingContext[answerTo];
      if (original != null) {
        final answered = _applyAnswer(answerTo, text, approval, requestId);
        if (answered != null) return answered;
      }
    }

    final normalized = CommandInterpreter.normalizePhrase(text);

    // 1. A taught phrase wins: the user already told us what this means.
    final taught = _learned[normalized];
    if (taught != null) {
      return _dispatchInput(taught, approval, requestId);
    }

    // 2. Otherwise let the interpreter understand it.
    final interpreted = _interpreter.interpret(normalized);
    switch (interpreted.outcome) {
      case InterpretOutcome.matched:
        return _dispatchParsed(
          interpreted.command!,
          approval,
          requestId,
          rawInput: text,
        );

      case InterpretOutcome.needsInfo:
        final key = interpreted.missingArgKey!;
        // Remembered default? Then no question is needed anymore.
        final remembered = _defaults[key];
        if (remembered != null) {
          return _dispatchParsed(
            _withArgument(interpreted.command!, key, remembered),
            approval,
            requestId,
          );
        }
        _pendingContext['arg:$key'] = normalized;
        return AgentDispatchResult(
          status: AgentResultStatus.needsInfo,
          dispatch: AgentClarification(
            question: interpreted.question!,
            key: 'arg:$key',
            hint: 'I\'ll remember your answer, so you won\'t have to tell me again.',
          ),
        );

      case InterpretOutcome.unknown:
        // A near-miss of something already known ("tex mom saying hi",
        // "what time is is")? Offer it. The user confirms with "yes" before
        // anything runs, so a wrong guess is only ever a question — never
        // an action.
        final near = CommandInterpreter.closestMeaning(normalized, {
          for (final phrase in CommandInterpreter.suggestionCatalog)
            phrase: phrase,
          ..._learned,
        });
        if (near != null) {
          final meaning = near.$1;
          _pendingContext['near:$normalized'] = meaning;
          return AgentDispatchResult(
            status: AgentResultStatus.needsInfo,
            dispatch: AgentClarification(
              question: 'I don\'t understand "$text". Did you mean "$meaning"?',
              key: 'near:$normalized',
              hint: 'Answer "yes" to run it — or type the command it should mean. I remember either way.',
            ),
          );
        }
        _pendingContext['teach:$normalized'] = normalized;
        // When the phrase smells like a call or text but missed the exact
        // patterns, say the shape instead of sending them into the generic
        // teach loop — friends phrase these a hundred different ways.
        final commLike = RegExp(
          r'\b(appelle|appeler|texte|texto|sms|message|msg|call|text|dial|phone|ring|send)\b',
        ).hasMatch(normalized);
        final hint = commLike
            ? 'It sounds like a call or text — try "call <name>" or "text <name> saying <message>".'
            : 'Teach me what it should mean — or tap "what can you do" below to see everything I know.';
        return AgentDispatchResult(
          status: AgentResultStatus.needsInfo,
          dispatch: AgentClarification(
            question: 'I don\'t understand "$text" yet.',
            key: 'teach:$normalized',
            hint: hint,
          ),
        );
    }
  }

  /// Resolves the answer to a pending [AgentClarification]. Returns the
  /// dispatch result, or null when the key is unknown (already answered).
  AgentDispatchResult? _applyAnswer(
    String key,
    String answer,
    AgentApproval approval,
    String requestId,
  ) {
    if (key.startsWith('teach:')) {
      final phrase = key.substring('teach:'.length);
      _pendingContext[key] = phrase; // still waiting for a good answer
      return _applyTeachAnswer(key, phrase, answer, approval, requestId);
    }
    if (key.startsWith('near:')) {
      // The user is answering a "did you mean …?" question. "yes" runs the
      // suggested meaning (and learns the phrase so the typo never asks
      // again); anything else falls into the normal teach loop.
      final phrase = key.substring('near:'.length);
      final suggested = _pendingContext.remove(key);
      if (suggested == null) return null;
      if (_isYes(answer)) {
        _learned[phrase] = suggested;
        onMemoryChanged?.call();
        onPhraseLearned?.call(phrase, suggested);
        return _dispatchInput(suggested, approval, requestId);
      }
      // The re-ask must keep the suggested meaning stored — if the next
      // answer is a plain "yes" it has to run the suggestion, not the
      // original phrase (which would dead-end as unavailable).
      _pendingContext[key] = suggested;
      return _applyTeachAnswer(
        key,
        phrase,
        answer,
        approval,
        requestId,
        retryValue: suggested,
      );
    }
    if (key.startsWith('arg:')) {
      // Capture the original input before clearing the pending state, so we
      // can re-run it now that the default is remembered.
      final original = _pendingContext.remove(key);
      final argKey = key.substring('arg:'.length);
      // Shaped answers (durations) are validated before being remembered — a
      // bad default would otherwise wedge the command into a permanent dead
      // answer. Re-ask, exactly like the teach flow does for bad meanings.
      if (argKey == 'timer.set.seconds' &&
          CommandInterpreter.parseDurationSeconds(answer) == null) {
        _pendingContext[key] = original ?? answer;
        return AgentDispatchResult(
          status: AgentResultStatus.needsInfo,
          dispatch: AgentClarification(
            question: 'I still don\'t understand how long — try "5 minutes" or "1 hour 30 seconds".',
            key: key,
            hint: 'I\'ll remember your answer, so you won\'t have to tell me again.',
          ),
        );
      }
      _defaults[argKey] = answer;
      onMemoryChanged?.call();
      return original != null
          ? execute(original, approval: approval, requestId: requestId)
          : null;
    }
    if (key.startsWith('device:')) {
      // "Do it on My Phone?" — the answer names a device (or just "yes" for
      // the single candidate). Validate it, then re-run the original command
      // with that device pinned.
      final action = key.substring('device:'.length);
      final stored = _pendingContext.remove(key);
      if (stored == null) return null;
      final parts = stored.split('\u0001');
      final original = parts.first;
      final candidate = parts.length == 2 ? parts[1] : '';
      final resolved = _isYes(answer)
          ? (candidate.isEmpty ? null : _resolve(candidate, _allDevices()))
          : _resolve(answer, _allDevices());
      if (resolved == null) {
        _pendingContext[key] = stored; // still waiting for a good answer
        return AgentDispatchResult(
          status: AgentResultStatus.needsInfo,
          dispatch: AgentClarification(
            question: 'I don\'t see a device named "$answer".',
            key: key,
            hint: 'Try naming one of your devices, e.g. "My Phone".',
          ),
        );
      }
      _pendingDeviceChoice[action] = resolved.id;
      return execute(original, approval: approval, requestId: requestId);
    }
    return null;
  }

  /// Shared heart of the teach loop, used by both a plain "teach me"
  /// question and a rejected "did you mean …?" suggestion: parse the
  /// answer; if it is a command we know, remember it for [phrase] and run
  /// it; otherwise re-ask.
  AgentDispatchResult _applyTeachAnswer(
    String key,
    String phrase,
    String answer,
    AgentApproval approval,
    String requestId, {
    // What the pending value should hold while the question stays open.
    // The teach loop stores the phrase itself; the "did you mean" loop must
    // keep the suggested meaning, or a later plain "yes" would run the
    // original phrase instead of the suggestion.
    String? retryValue,
  }) {
    final interpreted = _interpreter.interpret(answer);
    if (interpreted.outcome != InterpretOutcome.matched) {
      _pendingContext[key] = retryValue ?? phrase; // still waiting
      return AgentDispatchResult(
        status: AgentResultStatus.needsInfo,
        dispatch: AgentClarification(
          question: 'I still don\'t understand what "$phrase" should mean.',
          key: key,
          hint: 'Type a command I already know, e.g. "show my devices" or "blink the ESP32".',
        ),
      );
    }
    _learned[CommandInterpreter.normalizePhrase(phrase)] = answer;
    onMemoryChanged?.call();
    onPhraseLearned?.call(CommandInterpreter.normalizePhrase(phrase), answer);
    return _dispatchParsed(interpreted.command!, approval, requestId);
  }

  AgentDispatchResult _dispatchInput(
    String input,
    AgentApproval approval,
    String requestId,
  ) {
    final interpreted = _interpreter.interpret(input.toLowerCase());
    if (interpreted.outcome != InterpretOutcome.matched) {
      return const AgentDispatchResult(status: AgentResultStatus.unavailable);
    }
    return _dispatchParsed(
      interpreted.command!,
      approval,
      requestId,
      rawInput: input,
    );
  }

  /// Routes a recognized command: local intents run here, blink and clipboard
  /// go through the existing contract, and catalog intents that need a
  /// capability this device lacks are offered to a device that has it.
  AgentDispatchResult _dispatchParsed(
    ParsedCommand command,
    AgentApproval approval,
    String requestId, {
    String? rawInput,
  }) {
    final action = command.action;
    if (action == AgentActions.deviceList) {
      return dispatchCommand(
        command: command,
        devices: devices(),
        requestId: requestId,
      );
    }
    if (action == AgentActions.ledBlink) {
      final snapshot = devices();
      final target = _resolve(command.target, snapshot);
      if (target == null) {
        return dispatchCommand(
          command: command,
          approval: approval,
          requestId: requestId,
        );
      }
      return dispatchCommand(
        command: ParsedCommand(
          action: command.action,
          target: target.id,
          arguments: command.arguments,
        ),
        targetDevice: DeviceCapabilities(
          deviceId: target.id,
          capabilities: target.capabilities,
        ),
        approval: approval,
        requestId: requestId,
      );
    }
    if (action == AgentActions.clipboardWrite) {
      return dispatchCommand(
        command: command,
        approval: approval,
        requestId: requestId,
      );
    }
    if (action == AgentActions.greet ||
        action == AgentActions.timeGet ||
        action == AgentActions.mathCalc ||
        action == AgentActions.helpGet ||
        action == AgentActions.webSearch ||
        action == AgentActions.noteCreate ||
        action == AgentActions.timerSet ||
        action == AgentActions.openUrl ||
        action == AgentActions.systemInfo ||
        action == AgentActions.volumeSet ||
        action == AgentActions.appOpen ||
        action == AgentActions.appClose ||
        action == AgentActions.screenshot ||
        action == AgentActions.batteryGet ||
        action == AgentActions.brightnessSet ||
        action == AgentActions.flashlightToggle ||
        action == AgentActions.wifiToggle ||
        action == AgentActions.bluetoothToggle ||
        action == AgentActions.lockScreen ||
        action == AgentActions.callPlace ||
        action == AgentActions.messageSend ||
        action == AgentActions.mediaPlay ||
        action == AgentActions.mediaPause ||
        action == AgentActions.mediaNext ||
        action == AgentActions.mediaPrev ||
        action == AgentActions.mediaShuffle ||
        action == AgentActions.mediaRepeat ||
        action == AgentActions.alarmSet ||
        action == AgentActions.reminderSet ||
        action == AgentActions.defineWord ||
        action == AgentActions.translateText ||
        action == AgentActions.unitConvert ||
        action == AgentActions.randomDice ||
        action == AgentActions.randomCoin ||
        action == AgentActions.randomNumber ||
        action == AgentActions.tellJoke ||
        action == AgentActions.findDevice ||
        action == AgentActions.ringDevice ||
        action == AgentActions.airplaneModeSet ||
        action == AgentActions.deviceRestart ||
        action == AgentActions.memoryRemember ||
        action == AgentActions.memoryRecall ||
        action == AgentActions.memoryForget ||
        action == AgentActions.memoryQuestion) {
      return _localAnswer(command);
    }
    if (_routableActions.contains(action)) {
      return _routeDeviceAction(command, approval, requestId, rawInput);
    }
    return _unwired(command);
  }

  AgentDispatchResult _unwired(ParsedCommand command) {
    return const AgentDispatchResult(
      status: AgentResultStatus.unavailable,
      message: 'This command is not available yet.',
    );
  }

  static const _routableActions = <String>{};

  /// Finds the device an action should run on, or asks the user to pick one.
  /// Naming a device ("call mom on my phone") pins the target and skips the
  /// search; otherwise the local device runs it if it can, a single capable
  /// device is offered, and several produce a "which one?" question.
  AgentDispatchResult _routeDeviceAction(
    ParsedCommand command,
    AgentApproval approval,
    String requestId,
    String? rawInput,
  ) {
    final args = Map<String, dynamic>.of(command.arguments);
    String? hint;
    // A device named in the command wins; otherwise fall back to the one
    // remembered for this action, then any "on my phone" suffix.
    hint ??= _pendingDeviceChoice[command.action];
    // The choice survives restarts: asked once, remembered forever.
    hint ??= _defaults['device:${command.action}'] as String?;
    hint ??= rawInput == null ? null : _deviceSuffix(rawInput)?.$2;
    if (hint != null && hint.isNotEmpty) {
      final target = _resolve(hint, _allDevices());
      if (target == null) {
        return AgentDispatchResult(
          status: AgentResultStatus.unavailable,
          message: 'I don\'t see a device named "$hint".',
        );
      }
      if (!_supports(target, command.action)) {
        return AgentDispatchResult(
          status: AgentResultStatus.unavailable,
          message: '${target.name} can\'t do that.',
        );
      }
      // Remember the choice so future commands of the same kind go straight
      // there — in this session AND after a restart (via [defaults]).
      _pendingDeviceChoice[command.action] = target.id;
      if (_defaults['device:${command.action}'] != target.id) {
        _defaults['device:${command.action}'] = target.id;
        onMemoryChanged?.call();
      }
      return _devicePlan(
        command: ParsedCommand(
          action: command.action,
          target: target.id,
          arguments: args,
        ),
        approval: approval,
        requestId: requestId,
      );
    }
    // No device named: can this device do it?
    final local = this.local;
    if (local != null && _supports(local, command.action)) {
      // Only genuinely wired-up actions get a plan targeting this device;
      // the rest stay honestly unwired.
      if (locallyExecutable.contains(command.action)) {
        return _devicePlan(
          command: ParsedCommand(
            action: command.action,
            target: local.id,
            arguments: args,
          ),
          approval: approval,
          requestId: requestId,
        );
      }
      return _unwired(command);
    }
    final candidates = _allDevices()
        .where((d) => d.online && _supports(d, command.action))
        .toList();
    if (candidates.isEmpty) return _unwired(command);
    final question = candidates.length == 1
        ? 'I can\'t do that here — do it on ${candidates.single.name}?'
        : 'Which device should do this?';
    final hintText = candidates.length == 1
        ? 'Answer "yes" or name another device. I\'ll remember which one for next time.'
        : 'Name one: ${candidates.map((d) => d.name).join(', ')}.';
    // A single candidate is remembered inside the pending value so a plain
    // "yes" answer can resolve to it.
    _pendingContext['device:${command.action}'] = candidates.length == 1
        ? '${rawInput ?? ''}\u0001${candidates.single.id}'
        : (rawInput ?? '');
    return AgentDispatchResult(
      status: AgentResultStatus.needsInfo,
      dispatch: AgentClarification(
        question: question,
        key: 'device:${command.action}',
        hint: hintText,
      ),
    );
  }

  AgentDispatchResult _devicePlan({
    required ParsedCommand command,
    required AgentApproval approval,
    required String requestId,
  }) {
    // Locally-executable actions (calls on Android) run immediately from
    // typed input — no Approve/Deny prompt. Remote requests keep their own
    // gate in handleRemoteRequest.
    final autoRun = locallyExecutable.contains(command.action);
    if (approval == AgentApproval.required && !autoRun) {
      return const AgentDispatchResult(
        status: AgentResultStatus.required,
        message: 'Local approval is required.',
      );
    }
    if (approval == AgentApproval.denied) {
      return const AgentDispatchResult(
        status: AgentResultStatus.denied,
        message: 'The action was denied locally.',
      );
    }
    return AgentDispatchResult(
      status: AgentResultStatus.succeeded,
      dispatch: AgentActionPlan(
        command.toRequest(
          requestId: requestId,
          approval: AgentApproval.approved,
        ),
      ),
    );
  }

  /// Executes an [AgentRequest] that arrived from another device over the
  /// mesh. The receiver gates it AGAIN locally — the remote's approval value
  /// is never trusted — so [approval] must come from this device's own UI.
  /// Catalog actions nothing can execute yet answer honestly; the reply
  /// travels back to the requester via [AgentResult].
  AgentDispatchResult handleRemoteRequest(
    AgentRequest request, {
    AgentApproval approval = AgentApproval.required,
  }) {
    if (approval == AgentApproval.denied) {
      return const AgentDispatchResult(
        status: AgentResultStatus.denied,
        message: 'The action was denied on this device.',
      );
    }
    if (approval == AgentApproval.required) {
      return const AgentDispatchResult(
        status: AgentResultStatus.required,
        message: 'This device has not approved the action yet.',
      );
    }
    final command = ParsedCommand(
      action: request.action,
      target: request.target,
      arguments: request.arguments,
    );
    switch (request.action) {
      case AgentActions.deviceList:
        return dispatchCommand(
          command: command,
          devices: devices(),
          requestId: request.requestId,
        );
      case AgentActions.ledBlink:
        final target = _resolve(request.target, devices());
        if (target == null) {
          return const AgentDispatchResult(
            status: AgentResultStatus.unavailable,
            message: 'The requested device is not connected here.',
          );
        }
        return dispatchCommand(
          command: command,
          targetDevice: DeviceCapabilities(
            deviceId: target.id,
            capabilities: target.capabilities,
          ),
          approval: AgentApproval.approved,
          requestId: request.requestId,
        );
      case AgentActions.clipboardWrite:
        return dispatchCommand(
          command: command,
          approval: AgentApproval.approved,
          requestId: request.requestId,
        );
      case AgentActions.greet:
      case AgentActions.timeGet:
      case AgentActions.mathCalc:
      case AgentActions.helpGet:
      case AgentActions.batteryGet:
      case AgentActions.screenshot:
      case AgentActions.randomDice:
      case AgentActions.randomCoin:
      case AgentActions.randomNumber:
      case AgentActions.tellJoke:
      case AgentActions.defineWord:
      case AgentActions.translateText:
      case AgentActions.unitConvert:
      case AgentActions.memoryQuestion:
        return _localAnswer(command);
      default:
        // The requester already routed this to us as the capable device — run
        // it here. For now the catalog honestly says nothing is wired up.
        return _unwired(command);
    }
  }

  /// Teaches that [phrase] means [meaning] (a command the interpreter
  /// knows, e.g. "show my devices"), persists via [onMemoryChanged], and
  /// fires [onPhraseLearned] so paired devices learn it too. An
  /// uninterpretable [meaning] is refused with a re-ask rather than stored
  /// — a phrase that dead-ends later is worse than one never taught.
  /// Nothing executes here; running the command is the caller's choice.
  AgentDispatchResult learn(String phrase, String meaning) {
    final key = CommandInterpreter.normalizePhrase(phrase);
    if (key.isEmpty) {
      return const AgentDispatchResult(status: AgentResultStatus.unavailable);
    }
    if (_interpreter.interpret(meaning.trim()).outcome !=
        InterpretOutcome.matched) {
      return AgentDispatchResult(
        status: AgentResultStatus.needsInfo,
        dispatch: AgentClarification(
          question: 'I still don\'t understand what "$phrase" should mean.',
          key: 'teach:$key',
          hint: 'Type a command I already know, e.g. "show my devices" or "blink the ESP32".',
        ),
      );
    }
    final cmd = meaning.trim().toLowerCase();
    _learned[key] = cmd;
    onMemoryChanged?.call();
    onPhraseLearned?.call(key, cmd);
    return AgentDispatchResult(
      status: AgentResultStatus.succeeded,
      dispatch: AgentMessage('"$phrase" now means "$cmd".'),
    );
  }

  /// Adopts a phrase taught on a paired device and synced over the mesh.
  /// Persists like a local teach, but never fires [onPhraseLearned] — the
  /// knowledge came FROM the mesh, broadcasting it back would loop forever.
  void adoptLearned(String phrase, String meaning) {
    final key = CommandInterpreter.normalizePhrase(phrase);
    if (key.isEmpty) return;
    _learned[key] = meaning.trim().toLowerCase();
    onMemoryChanged?.call();
  }

  bool _supports(AgentDeviceSnapshot device, String action) =>
      device.capabilities.any((c) => c.id == action);

  List<String> capabilitiesOf(AgentDeviceSnapshot? device) =>
      device?.capabilities.map((c) => c.id).toList() ?? const [];

  List<AgentDeviceSnapshot> _allDevices() => [?local, ...devices()];

  /// Words worth matching on — lowercase, alphanumeric runs of 3+ chars,
  /// minus a few stopwords so "the" in a topic doesn't match "the" in every
  /// fact ("what is the capital of france" must not hit a bike fact).
  static const _stopWords = {
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
  static const _synonyms = {
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
  List<String> _factsAbout(String topic) {
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

    final hits = _facts.where(factMatches).toList();
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
  String? _contactNumber(String name) {
    if (name.isEmpty) return null;
    for (final fact in _factsAbout(name)) {
      final number = _phoneIn(fact);
      if (number != null) return number;
    }
    return null;
  }

  /// Locally executable intents that need no device: greeting, time, math.
  AgentDispatchResult _localAnswer(ParsedCommand command) {
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
            '  \"convert 5 miles to km\"\n'
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
        return AgentDispatchResult(
          status: AgentResultStatus.succeeded,
          dispatch: AgentMessage(
            isVideo
                ? (app == null
                      ? 'Which app should I video call $contact on?'
                      : 'Video calling $contact on $app...')
                : 'Calling $contact...',
            action: AgentActions.callPlace,
            arguments: {
              'contact': contact,
              if (isVideo) 'mode': 'video',
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
        final number = _contactNumber(contact);
        final who = number != null ? '$contact at $number' : contact;
        return AgentDispatchResult(
          status: AgentResultStatus.succeeded,
          dispatch: AgentMessage(
            body != null ? 'Texting $who: "$body"' : 'Opening text to $who...',
            action: AgentActions.messageSend,
            arguments: {
              'contact': contact,
              'number': ?number,
              'body': ?body,
            },
          ),
        );
      // --- Media ---
      case AgentActions.mediaPlay:
        return const AgentDispatchResult(
          status: AgentResultStatus.succeeded,
          dispatch: AgentMessage('Playing.', action: AgentActions.mediaPlay),
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
        final text = command.arguments['text'] as String? ?? '';
        return AgentDispatchResult(
          status: AgentResultStatus.succeeded,
          dispatch: AgentMessage(
            'Reminder: "$text"',
            action: AgentActions.reminderSet,
            arguments: {'text': text},
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
        return AgentDispatchResult(
          status: AgentResultStatus.succeeded,
          dispatch: AgentMessage(
            'Converting $value $from to $to...',
            action: AgentActions.webSearch,
            arguments: {'query': 'convert $value $from to $to'},
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
        final reachable = devices().any(
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
        final isPhone = capabilitiesOf(local).contains(AgentActions.callPlace);
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
        if (_facts.any((f) => f.toLowerCase() == text.toLowerCase())) {
          return AgentDispatchResult(
            status: AgentResultStatus.succeeded,
            dispatch: AgentMessage('I already know that.'),
          );
        }
        _facts.add(text);
        onMemoryChanged?.call();
        onFactLearned?.call(text);
        return AgentDispatchResult(
          status: AgentResultStatus.succeeded,
          dispatch: AgentMessage('Remembered: "$text".'),
        );
      case AgentActions.memoryRecall:
        final topic = (command.arguments['topic'] as String? ?? '').trim();
        if (_facts.isEmpty) {
          return const AgentDispatchResult(
            status: AgentResultStatus.succeeded,
            dispatch: AgentMessage(
              'I don\'t remember anything about you yet. Tell me with "remember that …".',
            ),
          );
        }
        final matches = topic.isEmpty ? _facts.toList() : _factsAbout(topic);
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
            message:
                'What do you want to know? Try "what is my wifi password".',
          );
        }
        final hits = _factsAbout(qTopic);
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
        final gone = _facts
            .where((f) => f.toLowerCase().contains(query.toLowerCase()))
            .toList();
        if (gone.isEmpty) {
          return AgentDispatchResult(
            status: AgentResultStatus.succeeded,
            dispatch: AgentMessage('I don\'t remember anything like "$query".'),
          );
        }
        _facts.removeWhere(
          (f) => f.toLowerCase().contains(query.toLowerCase()),
        );
        onMemoryChanged?.call();
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

  ParsedCommand _withArgument(
    ParsedCommand command,
    String key,
    dynamic value,
  ) {
    final args = Map<String, dynamic>.of(command.arguments);
    final argName = key.split('.').last;
    args[argName] = value;
    return ParsedCommand(
      action: command.action,
      target: command.target,
      arguments: args,
    );
  }

  AgentDeviceSnapshot? _resolve(
    String target,
    List<AgentDeviceSnapshot> snapshot,
  ) {
    final normalized = target.trim().toLowerCase();
    final exactId = snapshot
        .where((device) => device.id.toLowerCase() == normalized)
        .toList();
    if (exactId.length == 1) return exactId.single;
    final matches = snapshot
        .where((device) => device.name.trim().toLowerCase() == normalized)
        .toList();
    return matches.length == 1 ? matches.single : null;
  }
}

/// "yes", "yep", "sure", "ok" — agreement to run on the offered device.
bool _isYes(String answer) => const {
  'yes',
  'yep',
  'yeah',
  'sure',
  'ok',
  'okay',
  'y',
  'do it',
  'go ahead',
}.contains(answer.trim().toLowerCase());

/// Splits "mom on my phone" into ("mom", "my phone") — the trailing device
/// the user named. Returns null when there is no device suffix. "on the …"
/// is never treated as a device so "turn on the lights" stays intact.
(String, String)? _deviceSuffix(String text) {
  final m = RegExp(r'\s+on (?!the )(.+)$').firstMatch(text.trim());
  if (m == null) return null;
  return (text.substring(0, m.start).trim(), m.group(1)!.trim());
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
