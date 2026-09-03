import 'agent_contract.dart';
import 'command_interpreter.dart';

/// What the assistant remembers between sessions:
///  - [learned]: a phrase the user taught, mapped to the command it means
///    (e.g. "bring me home" -> "show my devices").
///  - [defaults]: an answer to a previous "which …?" question, keyed by the
///    argument (e.g. `media.play.playlist` -> "Chill Mix").
class AgentMemory {
  final Map<String, String> learned;
  final Map<String, dynamic> defaults;

  const AgentMemory({this.learned = const {}, this.defaults = const {}});
}

class CommandService {
  final List<AgentDeviceSnapshot> Function() devices;
  final CommandInterpreter _interpreter;
  final Map<String, String> _learned;
  final Map<String, dynamic> _defaults;
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
    this.local,
    this.locallyExecutable = const {},
    this._interpreter = const CommandInterpreter(),
  }) : _learned = Map.of(memory.learned),
       _defaults = Map.of(memory.defaults);

  /// Snapshot of the taught phrases, for persisting to the store.
  Map<String, String> get learnedSnapshot => Map.unmodifiable(_learned);

  /// Snapshot of the remembered argument defaults, for persisting.
  Map<String, dynamic> get defaultsSnapshot => Map.unmodifiable(_defaults);

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
        _pendingContext['teach:$normalized'] = normalized;
        return AgentDispatchResult(
          status: AgentResultStatus.needsInfo,
          dispatch: AgentClarification(
            question: 'I don\'t understand "$text" yet.',
            key: 'teach:$normalized',
            hint: 'Teach me what it should mean — or tap "what can you do" below to see everything I know.',
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
      final interpreted = _interpreter.interpret(answer);
      if (interpreted.outcome != InterpretOutcome.matched) {
        _pendingContext[key] = phrase; // still waiting for a good answer
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
    if (key.startsWith('arg:')) {
      // Capture the original input before clearing the pending state, so we
      // can re-run it now that the default is remembered.
      final original = _pendingContext.remove(key);
      final argKey = key.substring('arg:'.length);
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
        action == AgentActions.volumeSet) {
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
        return _localAnswer(command);
      default:
        // The requester already routed this to us as the capable device — run
        // it here. For now the catalog honestly says nothing is wired up.
        return _unwired(command);
    }
  }

  /// Teaches that [phrase] means [meaning] (a command the interpreter
  /// knows, e.g. "call TVcraft01 〘✘ΔτΚ⑤⑦〙"), persists via [onMemoryChanged],
  /// and runs it now — so "who did you mean?" only ever has to be answered
  /// once per wording.
  AgentDispatchResult learnAndRun(String phrase, String meaning) {
    final key = CommandInterpreter.normalizePhrase(phrase);
    if (key.isEmpty) {
      return const AgentDispatchResult(status: AgentResultStatus.unavailable);
    }
    final cmd = meaning.trim().toLowerCase();
    _learned[key] = cmd;
    onMemoryChanged?.call();
    onPhraseLearned?.call(key, cmd);
    return _dispatchInput(meaning, AgentApproval.approved, 'learned-phrase');
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
            '  "what time is it" — current time\n'
            '  "what is the date" — today\'s date\n'
            '  "what is 12 times 8" — math\n'
            '  "2 + 3" — bare arithmetic\n'
            '\n'
            'Devices:\n'
            '  "show my devices" — list paired devices\n'
            '  "blink the ESP32" — flash an LED\n'
            '\n'
            'Clipboard:\n'
            '  "copy hello to my devices" — sync text\n'
            '\n'
            'Web & Files:\n'
            '  "search for flutter" — open web search\n'
            '  "open github.com" — open a website\n'
            '  "note that buy milk" — save a note\n'
            '\n'
            'System:\n'
            '  "timer for 5 minutes" — countdown\n'
            '  "system info" — your PC specs\n'
            '  "volume up" / "volume down" / "mute"\n'
            ''
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
        final seconds = command.arguments['seconds'] as int? ?? 0;
        if (seconds <= 0) {
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
