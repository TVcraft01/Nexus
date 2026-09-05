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

  test(
    '"play <playlist>" stays teachable — playlists are not a separate command',
    () {
      // The advertised media surface is play/pause/skip, not playlist
      // selection. These phrasings must never silently press play on the
      // wrong thing — they stay unknown so the assistant offers to learn.
      for (final phrase in ['play my playlist', 'play chill vibes']) {
        final result = interpreter.interpret(phrase);
        expect(result.outcome, InterpretOutcome.unknown, reason: phrase);
      }
    },
  );

  test('context-dependent phrases like "bring me home" ask to be taught', () {
    for (final phrase in [
      'bring me home',
      'take me home',
      'show me the way home',
    ]) {
      final result = interpreter.interpret(phrase);
      expect(result.outcome, InterpretOutcome.unknown, reason: phrase);
    }
  });

  test('unrecognized input is a teaching opportunity', () {
    final result = interpreter.interpret('teleport me to mars');
    expect(result.outcome, InterpretOutcome.unknown);
  });

  group('Siri/Alexa-style catalog', () {
    test('greetings', () {
      for (final phrase in ['hello', 'hi', 'hey', 'good morning']) {
        final result = interpreter.interpret(phrase);
        expect(result.outcome, InterpretOutcome.matched, reason: phrase);
        expect(result.command!.action, AgentActions.greet, reason: phrase);
      }
    });

    test('time and date', () {
      final time = interpreter.interpret('what time is it');
      expect(time.command!.action, AgentActions.timeGet);
      expect(time.command!.arguments['kind'], 'time');
      expect(
        interpreter.interpret("what's the date").command!.arguments['kind'],
        'date',
      );
      expect(
        interpreter.interpret('current time').command!.action,
        AgentActions.timeGet,
      );
    });

    test('math with words and symbols', () {
      final spoken = interpreter.interpret('what is 2 plus 2');
      expect(spoken.command!.action, AgentActions.mathCalc);
      expect(spoken.command!.arguments['expr'], '2+2');
      final calc = interpreter.interpret('calculate 5 times 3');
      expect(calc.command!.arguments['expr'], '5*3');
      final div = interpreter.interpret('how much is 10 divided by 2');
      expect(div.command!.arguments['expr'], '10/2');
      final bare = interpreter.interpret('2 + 2');
      expect(bare.command!.action, AgentActions.mathCalc);
      expect(bare.command!.arguments['expr'], '2 + 2');
    });

    test('a non-arithmetic "what is …" becomes a web search', () {
      final result = interpreter.interpret('what is the capital of france');
      expect(result.command!.action, AgentActions.webSearch);
      expect(result.command!.arguments['query'], 'the capital of france');
    });

    test('"what does X mean" folds into a define search', () {
      final result = interpreter.interpret('what does bluetooth mean');
      expect(result.command!.action, AgentActions.webSearch);
      expect(result.command!.arguments['query'], 'define bluetooth');
    });

    test('clipboard copy strips the recipient', () {
      final withDevice = interpreter.interpret('copy hello to my phone');
      expect(withDevice.command!.action, AgentActions.clipboardWrite);
      expect(withDevice.command!.arguments['text'], 'hello');
      final plain = interpreter.interpret('copy this link');
      expect(plain.command!.arguments['text'], 'this link');
    });

    test('calls and messages', () {
      final call = interpreter.interpret('call mom');
      expect(call.command!.action, AgentActions.callPlace);
      expect(call.command!.arguments['contact'], 'mom');
      final text = interpreter.interpret('text john');
      expect(text.command!.action, AgentActions.messageSend);
      expect(text.command!.arguments['contact'], 'john');
      final msg = interpreter.interpret('send a message to john');
      expect(msg.command!.action, AgentActions.messageSend);
      expect(msg.command!.arguments['contact'], 'john');
    });

    test('alarms, timers and reminders', () {
      expect(
        interpreter.interpret('set an alarm for 7am').command!.action,
        AgentActions.alarmSet,
      );
      expect(
        interpreter.interpret('set a timer for 5 minutes').command!.action,
        AgentActions.timerSet,
      );
      expect(
        interpreter.interpret('remind me to call the bank').command!.action,
        AgentActions.reminderSet,
      );
    });

    test('unadvertised extras (weather, news, calendar) search the web', () {
      // None of these are promised commands — they must not claim a fake
      // action; falling back to a web search is the honest current answer.
      expect(
        interpreter.interpret("what's the weather").command!.action,
        AgentActions.webSearch,
      );
      expect(
        interpreter.interpret('what is the news').command!.action,
        AgentActions.webSearch,
      );
      expect(
        interpreter.interpret('what is on my calendar').command!.action,
        AgentActions.webSearch,
      );
    });

    test('music play/pause/skip maps to the media actions', () {
      expect(
        interpreter.interpret('pause music').command!.action,
        AgentActions.mediaPause,
      );
      expect(
        interpreter.interpret('next song').command!.action,
        AgentActions.mediaNext,
      );
      expect(
        interpreter.interpret('shuffle').command!.action,
        AgentActions.mediaShuffle,
      );
      expect(
        interpreter.interpret('repeat').command!.action,
        AgentActions.mediaRepeat,
      );
    });

    test('volume words map to the mode they literally mean', () {
      // "unmute" / "volume up and down" / "toggle volume" must toggle —
      // they must never silently become mute.
      (String, String) modeOf(String phrase) => (
        interpreter.interpret(phrase).command!.action,
        interpreter.interpret(phrase).command!.arguments['mode'] as String,
      );
      expect(modeOf('mute'), (AgentActions.volumeSet, 'mute'));
      expect(modeOf('unmute'), (AgentActions.volumeSet, 'toggle'));
      expect(modeOf('volume up and down'), (AgentActions.volumeSet, 'toggle'));
      expect(modeOf('toggle volume'), (AgentActions.volumeSet, 'toggle'));
      expect(modeOf('volume up'), (AgentActions.volumeSet, 'up'));
      expect(modeOf('make it quieter'), (AgentActions.volumeSet, 'down'));
    });

    test('unadvertised smart-home/navigation phrases stay teachable', () {
      // No fake "home control" action exists — these stay teachable
      // (unknown), never a pretend success.
      for (final phrase in [
        'turn on the lights',
        'lock the door',
        'navigate to the office',
        'take me home',
        'bring me home',
      ]) {
        expect(
          interpreter.interpret(phrase).outcome,
          InterpretOutcome.unknown,
          reason: phrase,
        );
      }
    });

    test('search, notes and translation', () {
      final search = interpreter.interpret('search for cats');
      expect(search.command!.action, AgentActions.webSearch);
      expect(search.command!.arguments['query'], 'cats');
      final note = interpreter.interpret('make a note to buy milk');
      expect(note.command!.action, AgentActions.noteCreate);
      expect(note.command!.arguments['text'], 'to buy milk');
      final tr = interpreter.interpret('translate hello to french');
      expect(tr.command!.action, AgentActions.translateText);
      expect(tr.command!.arguments['language'], 'french');
    });

    test('remember/forget/recall are fact-memory commands', () {
      // "remember that …" is a fact — never a note, never a reminder.
      final remember = interpreter.interpret(
        'remember that my wifi password is nexus',
      );
      expect(remember.outcome, InterpretOutcome.matched);
      expect(remember.command!.action, AgentActions.memoryRemember);
      expect(remember.command!.arguments['text'], 'my wifi password is nexus');
      for (final phrase in [
        'remember my bike code is 4321',
        'remember this: mom prefers text',
      ]) {
        expect(
          interpreter.interpret(phrase).command!.action,
          AgentActions.memoryRemember,
          reason: phrase,
        );
      }
      // "remember to …" stays a reminder, never a fact.
      final remind = interpreter.interpret('remember to buy milk');
      expect(remind.command!.action, AgentActions.reminderSet);
      // Forget and recall.
      final forget = interpreter.interpret('forget my wifi password');
      expect(forget.command!.action, AgentActions.memoryForget);
      expect(forget.command!.arguments['text'], 'my wifi password');
      for (final phrase in [
        'what do you know about me',
        'what do you remember',
        'what have i told you',
      ]) {
        expect(
          interpreter.interpret(phrase).command!.action,
          AgentActions.memoryRecall,
          reason: phrase,
        );
      }
      final topic = interpreter.interpret('what do you know about my bike');
      expect(topic.command!.action, AgentActions.memoryRecall);
      expect(topic.command!.arguments['topic'], 'my bike');
    });

    test('normalization folds accents and contractions', () {
      expect(
        CommandInterpreter.normalizePhrase('  Café  Maman '),
        'cafe maman',
      );
      expect(
        CommandInterpreter.normalizePhrase("what's the time"),
        'what is the time',
      );
      // Accented input reaches the same commands as its plain form.
      expect(
        interpreter.interpret('call café').command!.arguments['contact'],
        interpreter.interpret('call cafe').command!.arguments['contact'],
      );
    });
  });
}
