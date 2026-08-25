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

/// Honest answers for recognized-but-unwired intents. The assistant
/// understands the request (so it never "teaches" something it knows) but
/// says plainly that nothing is connected to it yet.
const Map<String, String> _notWiredMessages = {
  AgentActions.musicControl: 'Music controls (pause, next, shuffle) aren\'t wired up yet.',
  AgentActions.homeControl: 'Smart-home control isn\'t wired up yet — only the ESP32 blink command works for now.',
  AgentActions.messageSend: 'Sending texts isn\'t wired up yet.',
  AgentActions.callPlace: 'Making calls isn\'t wired up yet.',
  AgentActions.weatherGet: 'I can\'t check the weather yet — no weather service is connected.',
  AgentActions.reminderSet: 'Reminders aren\'t wired up yet.',
  AgentActions.alarmSet: 'Alarms aren\'t wired up yet.',
  AgentActions.timerSet: 'Timers aren\'t wired up yet.',
  AgentActions.navigationRoute: 'Navigation isn\'t wired up yet — but if a phrase like "bring me home" should mean something to you, teach me and I\'ll remember.',
  AgentActions.webSearch: 'Web search isn\'t wired up yet.',
  AgentActions.noteCreate: 'Notes aren\'t wired up yet.',
  AgentActions.translateText: 'Translation isn\'t wired up yet.',
  AgentActions.calendarGet: 'Calendar isn\'t wired up yet.',
  AgentActions.newsGet: 'News isn\'t wired up yet.',
};

class CommandService {
  final List<AgentDeviceSnapshot> Function() devices;
  final CommandInterpreter _interpreter;
  final Map<String, String> _learned;
  final Map<String, dynamic> _defaults;
  final void Function()? onMemoryChanged;

  /// The last input behind each open clarification, keyed by the
  /// [AgentClarification.key] handed to the UI.
  final Map<String, String> _pendingContext = {};

  CommandService({
    required this.devices,
    AgentMemory memory = const AgentMemory(),
    this.onMemoryChanged,
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

    final normalized = text.toLowerCase();

    // 1. A taught phrase wins: the user already told us what this means.
    final taught = _learned[normalized];
    if (taught != null) {
      return _dispatchInput(taught, approval, requestId);
    }

    // 2. Otherwise let the interpreter understand it.
    final interpreted = _interpreter.interpret(normalized);
    switch (interpreted.outcome) {
      case InterpretOutcome.matched:
        return _dispatchParsed(interpreted.command!, approval, requestId);

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
            hint: 'Teach me: type the command it should mean, e.g. "show my devices".',
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
      final interpreted = _interpreter.interpret(answer.toLowerCase());
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
      _learned[phrase] = answer.toLowerCase();
      onMemoryChanged?.call();
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
    return _dispatchParsed(interpreted.command!, approval, requestId);
  }

  /// Routes a recognized command: device list is local, blink goes through
  /// the target resolver + existing [dispatchCommand], and the newer intents
  /// (media, route) report honestly that nothing is wired to them yet.
  AgentDispatchResult _dispatchParsed(
    ParsedCommand command,
    AgentApproval approval,
    String requestId,
  ) {
    if (command.action == AgentActions.deviceList) {
      return dispatchCommand(
        command: command,
        devices: devices(),
        requestId: requestId,
      );
    }
    if (command.action == AgentActions.ledBlink) {
      final snapshot = devices();
      final target = _resolve(command.target, snapshot);
      if (target == null) {
        return dispatchCommand(
          command: command,
          targetDevice: null,
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
    if (command.action == AgentActions.clipboardWrite) {
      return dispatchCommand(
        command: command,
        approval: approval,
        requestId: requestId,
      );
    }
    if (command.action == AgentActions.greet ||
        command.action == AgentActions.timeGet ||
        command.action == AgentActions.mathCalc) {
      return _localAnswer(command);
    }
    if (command.action == AgentActions.mediaPlay) {
      final playlist = command.arguments['playlist'];
      return AgentDispatchResult(
        status: AgentResultStatus.unavailable,
        message: 'Playing "${playlist ?? 'your music'}" isn\'t wired up yet — but I understood, and I\'ll remember your choice.',
      );
    }
    // The rest of the catalog: understood, honestly unwired.
    final message = _notWiredMessages[command.action];
    if (message != null) {
      return AgentDispatchResult(
        status: AgentResultStatus.unavailable,
        message: message,
      );
    }
    return const AgentDispatchResult(
      status: AgentResultStatus.unavailable,
      message: 'This command is not available yet.',
    );
  }

  /// Locally executable intents that need no device: greeting, time, math.
  AgentDispatchResult _localAnswer(ParsedCommand command) {
    switch (command.action) {
      case AgentActions.greet:
        return const AgentDispatchResult(
          status: AgentResultStatus.succeeded,
          dispatch: AgentMessage(
            'Hello! I can list your devices, blink your ESP32, tell you the time, do simple math, and copy text to your other devices. Ask me anything — and if I don\'t understand, I\'ll ask you to teach me.',
          ),
        );
      case AgentActions.timeGet:
        return AgentDispatchResult(
          status: AgentResultStatus.succeeded,
          dispatch: AgentMessage(_formatTime(command.arguments['kind'])),
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
          dispatch: AgentMessage('${command.arguments['expr']} = ${_formatNumber(result)}'),
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
      const weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
      const months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
      return 'It\'s ${weekdays[now.weekday - 1]}, ${months[now.month - 1]} ${now.day}, ${now.year}.';
    }
    final hh = now.hour.toString().padLeft(2, '0');
    final mm = now.minute.toString().padLeft(2, '0');
    return 'It\'s $hh:$mm.';
  }

  String _formatNumber(double value) =>
      value == value.roundToDouble() ? value.toInt().toString() : value.toString();

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
    while (ops.isNotEmpty && ops.last != '(' && precedence(ops.last) >= precedence(token)) {
      if (!apply()) return null;
    }
    ops.add(token);
  }
  while (ops.isNotEmpty) {
    if (!apply()) return null;
  }
  return values.length == 1 && ops.isEmpty ? values.single : null;
}
