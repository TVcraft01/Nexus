import 'agent_contract.dart';
import 'answers.dart';
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

  /// The contact [name] resolves to after a confirmed "did you mean?" or a
  /// taught fact ("alx means alex" / "remember that tv is TVcraft01"), or
  /// null when none is known. A phone fact ("mom is 06…") never counts as
  /// an alias — that number is the dial target, not a rewritten name.
  String? _contactAlias(String name) {
    final lower = name.trim().toLowerCase();
    if (lower.isEmpty) return null;
    for (final fact in _facts) {
      final m = RegExp(
        r'^' + RegExp.escape(lower) + r'\s+(?:is|means)\s+(.+)$',
        caseSensitive: false,
      ).firstMatch(fact);
      if (m == null) continue;
      final value = m.group(1)!.trim();
      final digits = value.replaceAll(RegExp(r'[^\d+]'), '');
      if (digits.length >= 9 && digits.length <= 15) return null;
      return value;
    }
    return null;
  }

  /// Remembers that the user's wording [from] means contact [to], so the
  /// next "call $from" resolves straight to $to without asking again.
  /// Persists as a fact, like anything the user teaches.
  void learnContactAlias(String from, String to) {
    final fact = '${from.trim()} means ${to.trim()}';
    if (_facts.any((f) => f.toLowerCase() == fact.toLowerCase())) return;
    _facts.add(fact);
    onMemoryChanged?.call();
    onFactLearned?.call(fact);
  }

  /// Whether [input] parses as something actionable — a known command, or a
  /// known command still missing one argument — rather than an unknown
  /// phrase. The view uses this to decide that a message typed while a
  /// clarification is open is a NEW request, never the answer to a stale
  /// question ("call mom" while "teach me 'open deezer'" is open must call
  /// mom, not become a lesson about deezer).
  bool parsesAsCommand(String input) {
    final normalized = CommandInterpreter.normalizePhrase(input);
    return _interpreter.interpret(normalized).outcome !=
        InterpretOutcome.unknown;
  }

  /// Drops a pending clarification. Called when the user moves on and types
  /// a new command instead of answering — the question must vanish from the
  /// service's memory so it can never swallow a later input.
  void cancelPending(String key) {
    _pendingContext.remove(key);
  }

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
        // A fact may already answer this ("remember that my name is john"
        // then "what is my name") — don't ask for what the user already
        // told us. Only a plain fact answer qualifies: the web-search
        // fallback carries an action, so asking still wins there.
        final fromFacts = localAnswer(interpreted.command!, _answerContext);
        if (fromFacts.status == AgentResultStatus.succeeded &&
            fromFacts.dispatch is AgentMessage &&
            (fromFacts.dispatch as AgentMessage).action == null) {
          return fromFacts;
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
    // Contact actions: answered here on the device that can run them, and
    // honestly taught when nothing anywhere can. But when THIS device can't
    // execute a call or text and a paired device can, echoing the action
    // would only fail here — offer to have the paired device do it instead.
    if (action == AgentActions.callPlace ||
        action == AgentActions.messageSend) {
      return _contactAction(command, approval, requestId, rawInput);
    }
    if (action == AgentActions.emailSend) {
      // Email runs through the same message+action path as texts, but the
      // device's own mail app resolves the address — no cross-device offer
      // needed (desktops open mailto: directly).
      return localAnswer(command, _answerContext);
    }
    if (        action == AgentActions.greet ||
        action == AgentActions.intro ||
        action == AgentActions.timeGet ||
        action == AgentActions.mathCalc ||
        action == AgentActions.helpGet ||
        action == AgentActions.webSearch ||
        action == AgentActions.noteCreate ||
        action == AgentActions.timerSet ||
        action == AgentActions.openUrl ||
        action == AgentActions.weatherGet ||
        action == AgentActions.navOpen ||
        action == AgentActions.locationGet ||
        action == AgentActions.musicSearch ||
        action == AgentActions.currencyGet ||
        action == AgentActions.timezoneGet ||
        action == AgentActions.calendarAdd ||
        action == AgentActions.shoppingListAdd ||
        action == AgentActions.shoppingListGet ||
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
        action == AgentActions.mediaPlay ||
        action == AgentActions.mediaPause ||
        action == AgentActions.mediaNext ||
        action == AgentActions.mediaPrev ||
        action == AgentActions.mediaShuffle ||
        action == AgentActions.mediaRepeat ||
        action == AgentActions.alarmSet ||
        action == AgentActions.alarmDismiss ||
        action == AgentActions.timerStatus ||
        action == AgentActions.timerCancel ||
        action == AgentActions.darkModeSet ||
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
      return localAnswer(command, _answerContext);
    }
    return _unwired(command);
  }

  AgentDispatchResult _unwired(ParsedCommand command) {
    return const AgentDispatchResult(
      status: AgentResultStatus.unavailable,
      message: 'This command is not available yet.',
    );
  }

  /// A call or text command. The catalog decides the words and resolves a
  /// taught number; then this device's own abilities decide where it runs:
  ///  - a device that genuinely dials keeps it (its view self-runs it),
  ///  - when nothing anywhere can run it, the catalog's answer stands (the
  ///    honest "teach me the number" prompt), and
  ///  - when THIS device can't but a paired one can, echoing the action
  ///    would only fail here — offer to have the paired device do it.
  AgentDispatchResult _contactAction(
    ParsedCommand command,
    AgentApproval approval,
    String requestId,
    String? rawInput,
  ) {
    // Resolve learned "did you mean" aliases first: the user said "call
    // alx", confirmed Alex once, and the fact "alx means alex" now routes
    // straight to Alex — no question on the next try. ("remember that tv
    // is TVcraft01" teaches the same way.)
    var resolved = command;
    final contact = (command.arguments['contact'] as String?) ?? '';
    final alias = _contactAlias(contact);
    if (alias != null) {
      final args = Map<String, dynamic>.of(command.arguments);
      args['contact'] = alias;
      resolved = ParsedCommand(
        action: command.action,
        target: command.target,
        arguments: args,
      );
    }
    final answer = localAnswer(resolved, _answerContext);
    // Only an executable action card can be offered elsewhere — teach
    // prompts, "who should I call" re-asks and plain answers stay put.
    final card = answer.dispatch;
    if (answer.status != AgentResultStatus.succeeded ||
        card is! AgentMessage ||
        card.action == null) {
      return answer;
    }
    // A device that genuinely runs calls and texts keeps them (a phone
    // dials its own, address book included).
    final self = local;
    if (self != null && _supports(self, command.action)) return answer;
    final reachable = devices()
        .where((d) => d.online && _supports(d, command.action))
        .toList();
    // No paired executor anywhere: the catalog's answer stands.
    if (reachable.isEmpty) return answer;
    // This device can't, a paired one can — offer it. The resolved number
    // and body ride along so the remote dials or texts straight through.
    return _routeDeviceAction(
      ParsedCommand(
        action: command.action,
        target: command.target,
        arguments: card.arguments ?? command.arguments,
      ),
      approval,
      requestId,
      rawInput,
    );
  }

  /// Finds the device a contact action should run on, or asks the user to
  /// pick one. Called from [_contactAction] when this device cannot execute
  /// a call or text but a paired device can.
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
    // gate in handleRemoteRequest. A plan aimed at a PAIRED device also runs
    // without a second local prompt: reaching this point means the user
    // already chose that device (the "do it on My Phone?" question, a named
    // device, or a remembered choice) — the remote re-gates anyway.
    final remotePlan = command.target.isNotEmpty &&
        (local == null || command.target != local!.id);
    final autoRun = locallyExecutable.contains(command.action) || remotePlan;
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
      case AgentActions.intro:
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
      case AgentActions.weatherGet:
      case AgentActions.navOpen:
      case AgentActions.locationGet:
      case AgentActions.musicSearch:
      case AgentActions.currencyGet:
      case AgentActions.timezoneGet:
      case AgentActions.calendarAdd:
      case AgentActions.shoppingListAdd:
      case AgentActions.shoppingListGet:
      case AgentActions.emailSend:
        return localAnswer(command, _answerContext);
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

  List<AgentDeviceSnapshot> _allDevices() => [?local, ...devices()];

  /// The catalog's window onto this service — built once, sees the live
  /// [_facts] list and the persistence/broadcast callbacks memory writes fire.
  AnswerContext? _answerCtx;
  AnswerContext get _answerContext => _answerCtx ??= AnswerContext(
    facts: _facts,
    devices: devices,
    local: local,
    onMemoryChanged: onMemoryChanged,
    onFactLearned: onFactLearned,
  );

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
