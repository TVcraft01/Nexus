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

  test('"play <playlist>" maps to media with an honest query arg', () {
    // The advertised surface now includes targeted play ("play my
    // playlist"). It parses as media.play WITH the query — the executor
    // answers honestly that library search isn't wired up, instead of
    // silently pressing play on the wrong thing.
    for (final phrase in ['play my playlist', 'play chill vibes']) {
      final result = interpreter.interpret(phrase);
      expect(result.outcome, InterpretOutcome.matched, reason: phrase);
      expect(result.command!.action, AgentActions.mediaPlay, reason: phrase);
      expect(
        result.command!.arguments['query'],
        isNotEmpty,
        reason: phrase,
      );
    }
  });

  test('"bring me home" and friends open navigation', () {
    for (final phrase in ['bring me home', 'take me home']) {
      final result = interpreter.interpret(phrase);
      expect(result.outcome, InterpretOutcome.matched, reason: phrase);
      expect(result.command!.action, AgentActions.navOpen, reason: phrase);
      expect(result.command!.arguments['query'], 'home', reason: phrase);
    }
    final office = interpreter.interpret('navigate to the office');
    expect(office.command!.action, AgentActions.navOpen);
    expect(office.command!.arguments['query'], 'the office');
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

    test('a non-arithmetic "what is …" asks memory before the web', () {
      // Personal questions must never web-search the user's own secrets;
      // generic ones reach the web honestly via the service fallback when
      // memory has nothing (covered at service level).
      final result = interpreter.interpret('what is the capital of france');
      expect(result.command!.action, AgentActions.memoryQuestion);
      expect(result.command!.arguments['topic'], 'the capital of france');
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

    test('weather is a real command; news and calendar stay honest', () {
      // Weather is now fetched live; news/calendar are still not promised
      // commands — they route through memory first, then fall back to a web
      // search. Never a claimed fake action.
      // No city is still a real command: empty place means location/IP.
      final bare = interpreter.interpret("what's the weather");
      expect(bare.outcome, InterpretOutcome.matched);
      expect(bare.command!.action, AgentActions.weatherGet);
      expect(bare.command!.arguments['place'], '');
      final inParis = interpreter.interpret('what is the weather in paris');
      expect(inParis.command!.action, AgentActions.weatherGet);
      expect(inParis.command!.arguments['place'], 'paris');
      expect(
        interpreter.interpret('will it rain in paris').command!
            .arguments['kind'],
        'rain',
      );
      expect(
        interpreter.interpret('what is the news').command!.action,
        AgentActions.memoryQuestion,
      );
      expect(
        interpreter.interpret('what is on my calendar').command!.action,
        AgentActions.memoryQuestion,
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

    test('unadvertised smart-home phrases stay teachable', () {
      // No fake "home control" action exists — these stay teachable
      // (unknown), never a pretend success. Navigation is real now.
      for (final phrase in ['turn on the lights', 'lock the door']) {
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
    });

    test('personal questions route to memory, math and search do not', () {
      for (final pair in [
        ('what is my wifi password', 'my wifi password'),
        ("what is mom's number", 'mom is number'),
        ('who is mom', 'mom'),
        ('where is the bike code', 'bike code'),
      ]) {
        final r = interpreter.interpret(pair.$1);
        expect(r.outcome, InterpretOutcome.matched, reason: pair.$1);
        expect(r.command!.action, AgentActions.memoryQuestion, reason: pair.$1);
        expect(r.command!.arguments['topic'], pair.$2, reason: pair.$1);
      }
      // Non-personal paths unchanged.
      expect(
        interpreter.interpret('what is 2 plus 2').command!.action,
        AgentActions.mathCalc,
      );
      expect(
        interpreter.interpret('search for cats').command!.action,
        AgentActions.webSearch,
      );
      expect(
        interpreter.interpret('what is the capital of france').command!.action,
        AgentActions.memoryQuestion,
      );
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
