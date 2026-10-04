// The file-fetch slice's parser contract: "get report.pdf from my pc" is the
// brief's own sentence, and it must parse to `file.fetch` with the filename
// and the source device — locally, with no model and no cloud. The missing
// half (which device) is asked for, not guessed.
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent_contract.dart';
import 'package:nexus/core/command_interpreter.dart';

void main() {
  const interpreter = CommandInterpreter();

  group('file fetch parsing', () {
    test('accepted phrasings parse to fileFetch with filename and device', () {
      const cases = <String, (String, String)>{
        'get report.pdf from my pc': ('report.pdf', 'pc'),
        'fetch notes.txt from my laptop': ('notes.txt', 'laptop'),
        'send me budget.xlsx from my desktop': ('budget.xlsx', 'desktop'),
        'copy photos.zip from the pc': ('photos.zip', 'pc'),
        'get report.pdf from pc': ('report.pdf', 'pc'),
        'get report.pdf from my work pc': ('report.pdf', 'work pc'),
      };
      cases.forEach((phrase, expected) {
        final result = interpreter.interpret(phrase);
        expect(result.outcome, InterpretOutcome.matched, reason: phrase);
        expect(
          result.command!.action,
          AgentActions.fileFetch,
          reason: phrase,
        );
        expect(result.command!.target, 'remote', reason: phrase);
        expect(
          result.command!.arguments['filename'],
          expected.$1,
          reason: phrase,
        );
        expect(
          result.command!.arguments['deviceName'],
          expected.$2,
          reason: phrase,
        );
      });
    });

    test('a file named without a device asks which device', () {
      for (final phrase in [
        'get report.pdf',
        'fetch notes.txt',
        'send me budget.xlsx',
      ]) {
        final result = interpreter.interpret(phrase);
        expect(result.outcome, InterpretOutcome.needsInfo, reason: phrase);
        expect(
          result.missingArgKey,
          'file.fetch.deviceName',
          reason: phrase,
        );
        expect(result.question, isNotEmpty, reason: phrase);
        expect(
          result.command!.action,
          AgentActions.fileFetch,
          reason: phrase,
        );
        expect(
          result.command!.arguments['deviceName'],
          isNull,
          reason: phrase,
        );
      }
    });

    test('a file-less sentence is not stolen from the other verbs', () {
      // "copy <text>" is still a clipboard write, and navigation still wins:
      // the fetch pattern only claims an object that looks like a file.
      final clip = interpreter.interpret('copy hello to my devices');
      expect(clip.outcome, InterpretOutcome.matched);
      expect(clip.command!.action, AgentActions.clipboardWrite);

      final nav = interpreter.interpret('take me home');
      expect(nav.outcome, InterpretOutcome.matched);
      expect(nav.command!.action, AgentActions.navOpen);
    });
  });
}
