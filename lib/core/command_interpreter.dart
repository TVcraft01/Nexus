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
/// A future model (SLM/LLM) can produce the same [ParsedCommand] shape — the
/// interpreter is just the offline, deterministic first pass.
class CommandInterpreter {
  const CommandInterpreter();

  InterpretResult interpret(String input) {
    final text = input.trim().toLowerCase();

    // --- device.list: many phrasings, one intent.
    final deviceList = RegExp(
      r'^(show|list|what|which).*devices?',
    );
    if (deviceList.hasMatch(text) ||
        text == 'devices' ||
        text == 'my devices') {
      return InterpretResult.matched(
        const ParsedCommand(action: AgentActions.deviceList, target: 'local'),
      );
    }

    // --- led.blink: keep the existing flexible form.
    final blink = RegExp(r'^(?:blink|flash) (?:the )?(.+)$').firstMatch(text);
    if (blink != null) {
      return InterpretResult.matched(
        ParsedCommand(
          action: AgentActions.ledBlink,
          target: blink.group(1)!,
        ),
      );
    }

    // --- media.play: "play my playlist" needs a name; "play <name>" names it.
    if (RegExp(r'^play\b').hasMatch(text)) {
      final rest = text.substring(4).trim();
      final generic = RegExp(
        r'^(my )?(playlist|music|songs|tunes|some music)$',
      ).firstMatch(rest);
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

    // Everything else — including context-dependent phrases like "bring me
    // home" — is a teaching opportunity. The user tells us what it should
    // mean once, and we remember it.
    return InterpretResult.unknown();
  }
}
