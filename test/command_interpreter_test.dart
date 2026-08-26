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
      expect(interpreter.interpret("what's the date").command!.arguments['kind'], 'date');
      expect(interpreter.interpret('current time').command!.action, AgentActions.timeGet);
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
      expect(interpreter.interpret('set an alarm for 7am').command!.action, AgentActions.alarmSet);
      expect(interpreter.interpret('set a timer for 5 minutes').command!.action, AgentActions.timerSet);
      expect(interpreter.interpret('remind me to call the bank').command!.action, AgentActions.reminderSet);
    });

    test('weather, news and calendar', () {
      expect(interpreter.interpret("what's the weather").command!.action, AgentActions.weatherGet);
      expect(interpreter.interpret('what is the news').command!.action, AgentActions.newsGet);
      expect(interpreter.interpret('what is on my calendar').command!.action, AgentActions.calendarGet);
    });

    test('music control and play', () {
      final pause = interpreter.interpret('pause the music');
      expect(pause.command!.action, AgentActions.musicControl);
      expect(pause.command!.arguments['mode'], 'pause');
      expect(interpreter.interpret('next song').command!.arguments['mode'], 'next');
      expect(interpreter.interpret('shuffle my music').command!.arguments['mode'], 'shuffle');
    });

    test('smart home', () {
      final on = interpreter.interpret('turn on the lights');
      expect(on.command!.action, AgentActions.homeControl);
      expect(on.command!.arguments['state'], 'on');
      expect(on.command!.arguments['device'], 'lights');
      expect(interpreter.interpret('lock the door').command!.action, AgentActions.homeControl);
    });

    test('navigation recognizes explicit destinations but not home', () {
      final office = interpreter.interpret('navigate to the office');
      expect(office.command!.action, AgentActions.navigationRoute);
      expect(office.command!.arguments['place'], 'the office');
      expect(interpreter.interpret('get directions to the airport').command!.action, AgentActions.navigationRoute);
      // Vague home phrases stay teachable.
      for (final phrase in ['take me home', 'bring me home']) {
        expect(interpreter.interpret(phrase).outcome, InterpretOutcome.unknown, reason: phrase);
      }
    });

    test('search, notes and translation', () {
      final search = interpreter.interpret('search for cats');
      expect(search.command!.action, AgentActions.webSearch);
      expect(search.command!.arguments['query'], 'cats');
      final note = interpreter.interpret('make a note to buy milk');
      expect(note.command!.action, AgentActions.noteCreate);
      expect(note.command!.arguments['text'], 'to buy milk');
      expect(interpreter.interpret('remember that the wifi password is nexus').command!.action, AgentActions.noteCreate);
      final tr = interpreter.interpret('translate hello to french');
      expect(tr.command!.action, AgentActions.translateText);
      expect(tr.command!.arguments['language'], 'french');
    });

    test('normalization folds accents and contractions', () {
      expect(CommandInterpreter.normalizePhrase('  Café  Maman '), 'cafe maman');
      expect(CommandInterpreter.normalizePhrase("what's the time"), 'what is the time');
      // Accented input reaches the same commands as its plain form.
      expect(
        interpreter.interpret('call café').command!.arguments['contact'],
        interpreter.interpret('call cafe').command!.arguments['contact'],
      );
    });
  });
}
