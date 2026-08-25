import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent_contract.dart';
import 'package:nexus/core/command_interpreter.dart';

void main() {
  const interpreter = CommandInterpreter();

  test('many phrasings map to device.list', () {
    for (final phrase in [
      'show my devices',
      'list devices',
      'what devices do I have',
      'which are my devices',
      'devices',
    ]) {
      final result = interpreter.interpret(phrase);
      expect(result.outcome, InterpretOutcome.matched, reason: phrase);
      expect(result.command!.action, AgentActions.deviceList, reason: phrase);
      expect(result.command!.target, 'local', reason: phrase);
    }
  });

  test('blink keeps its flexible form and captures the target', () {
    for (final phrase in ['blink the esp32', 'flash Desk ESP32']) {
      final result = interpreter.interpret(phrase);
      expect(result.outcome, InterpretOutcome.matched, reason: phrase);
      expect(result.command!.action, AgentActions.ledBlink, reason: phrase);
      expect(result.command!.target, isNotEmpty, reason: phrase);
    }
  });

  test('"play my playlist" asks which playlist', () {
    final result = interpreter.interpret('play my playlist');
    expect(result.outcome, InterpretOutcome.needsInfo);
    expect(result.missingArgKey, 'media.play.playlist');
    expect(result.question, isNotNull);
  });

  test('"play <name>" names the playlist', () {
    final result = interpreter.interpret('play chill vibes');
    expect(result.outcome, InterpretOutcome.matched);
    expect(result.command!.action, AgentActions.mediaPlay);
    expect(result.command!.arguments['playlist'], 'chill vibes');
  });

  test('context-dependent phrases like "bring me home" ask to be taught', () {
    for (final phrase in ['bring me home', 'take me home', 'show me the way home']) {
      final result = interpreter.interpret(phrase);
      expect(result.outcome, InterpretOutcome.unknown, reason: phrase);
    }
  });

  test('unrecognized input is a teaching opportunity', () {
    final result = interpreter.interpret('teleport me to mars');
    expect(result.outcome, InterpretOutcome.unknown);
  });
}
