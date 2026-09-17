import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent_contract.dart';
import 'package:nexus/core/command_interpreter.dart';
import 'package:nexus/core/command_service.dart';

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

  test('"play my playlist" controls playback; a named song searches Deezer',
      () {
    // "play my playlist" is a control command — no library search, no
    // query argument. A named song or vibe is a real music search that
    // opens the top hit; never a silent fake play.
    final playlist = interpreter.interpret('play my playlist');
    expect(playlist.outcome, InterpretOutcome.matched);
    expect(playlist.command!.action, AgentActions.mediaPlay);
    expect(playlist.command!.arguments['query'], isNull);
    final joe = interpreter.interpret('joue ma playlist');
    expect(joe.command!.action, AgentActions.mediaPlay);
    for (final phrase in [
      'play chill vibes',
      'play hotline bling',
      'joue du jazz',
    ]) {
      final result = interpreter.interpret(phrase);
      expect(result.outcome, InterpretOutcome.matched, reason: phrase);
      expect(result.command!.action, AgentActions.musicSearch, reason: phrase);
      expect(
        result.command!.arguments['query'],
        isNotEmpty,
        reason: phrase,
      );
      expect(result.command!.target, 'local', reason: phrase);
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

  test('"navigate … with <app>" routes to the named nav app', () {
    for (final (phrase, place, app) in [
      ('navigate home with waze', 'home', 'waze'),
      ('take me home on google maps', 'home', 'google maps'),
      ('take me to paris on google maps', 'paris', 'google maps'),
      ('drive me to work with the waze app', 'work', 'waze'),
      ('ramene moi a la maison avec waze', 'home', 'waze'),
      ('navigate to the airport via google maps', 'the airport', 'google maps'),
    ]) {
      final r = interpreter.interpret(phrase);
      expect(r.outcome, InterpretOutcome.matched, reason: phrase);
      expect(r.command!.action, AgentActions.navOpen, reason: phrase);
      expect(r.command!.arguments['query'], place, reason: phrase);
      expect(r.command!.arguments['app'], app, reason: phrase);
    }
    // "with my brother" is a companion, not an app — the destination keeps
    // the whole phrase and no app is claimed.
    final companion = interpreter.interpret('take me to the restaurant with my brother');
    expect(companion.command!.action, AgentActions.navOpen);
    expect(companion.command!.arguments['query'],
        'the restaurant with my brother');
    expect(companion.command!.arguments['app'], isNull);
    // "with netflix" is not a nav app: never mis-routes, stays unmatched.
    final unknown = interpreter.interpret('navigate home with netflix');
    expect(unknown.outcome, InterpretOutcome.unknown);
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

    test('weather and calendar are real commands; news stays honest', () {
      // Weather is fetched live; the calendar opens the real calendar app
      // (events go to the system's new-event screen). News is still not a
      // promised command — it routes through memory first, then falls back
      // to a web search. Never a claimed fake action.
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
      final cal = interpreter.interpret('what is on my calendar');
      expect(cal.command!.action, AgentActions.calendarRead);
      expect(cal.command!.arguments['when'], 'today');
      // "play some music" is generic play, not a song-title search.
      expect(
        interpreter.interpret('play some music').command!.action,
        AgentActions.mediaPlay,
      );
      expect(
        interpreter.interpret('play some music').command!.arguments['query'],
        isNull,
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

    test("the assistant asks back for personal facts instead of searching the web", () {
      // "what is my name" / "what is my wifi password" must ask the user
      // for the answer (and remember it), never search the web for their
      // own secret. "what is my name" moved OUT of this class: the name now
      // has a real profile store and personalizes greetings, so it routes
      // to profile.get (which answers honestly when unknown and points to
      // "call me Sam") instead of a generic memory ask-back.
      for (final pair in [
        (
          'what is my wifi password',
          'memory.ask.my wifi password',
          'your wifi password',
        ),
      ]) {
        final r = interpreter.interpret(pair.$1);
        expect(r.outcome, InterpretOutcome.needsInfo, reason: pair.$1);
        expect(r.missingArgKey, pair.$2, reason: pair.$1);
        expect(r.question, contains(pair.$3), reason: pair.$1);
        expect(r.command!.action, AgentActions.memoryQuestion, reason: pair.$1);
      }
    });

    test('normalization drops a trailing run of sentence punctuation', () {
      expect(
        CommandInterpreter.normalizePhrase('what can you do?'),
        'what can you do',
      );
      expect(
        CommandInterpreter.normalizePhrase('  what time is it?!  '),
        'what time is it',
      );
      expect(CommandInterpreter.normalizePhrase('help!!'), 'help');
      expect(CommandInterpreter.normalizePhrase('open youtube.'), 'open youtube');
      // Siri-style dictation can append the ellipsis character instead of dots.
      expect(CommandInterpreter.normalizePhrase('remember this…'), 'remember this');
      expect(
        CommandInterpreter.normalizePhrase('call mom please?'),
        'call mom',
        reason: 'filler before the mark is still filler',
      );
      // Punctuation inside the phrase is the phrase: a decimal point, a file
      // name, a host. Only a trailing run goes.
      expect(
        CommandInterpreter.normalizePhrase('what is 2.5 plus 3'),
        'what is 2.5 plus 3',
      );
      expect(
        CommandInterpreter.normalizePhrase('open notes.txt'),
        'open notes.txt',
      );
      expect(
        CommandInterpreter.normalizePhrase('open github.com'),
        'open github.com',
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

    test('siri-style wake words and commas normalize away', () {
      for (final phrase in [
        'hey siri, call mom',
        'hey, what time is it',
        'okay, call mom',
        'please, what is the weather in paris',
        'call mom,',
      ]) {
        final r = interpreter.interpret(phrase);
        expect(r.outcome, InterpretOutcome.matched, reason: phrase);
      }
      // A bare "hey," is still a greeting, not empty input.
      expect(
        interpreter.interpret('hey,').command!.action,
        AgentActions.greet,
      );
      // Wake-word stripping never eats a contact: "call siri" stays a call.
      expect(
        interpreter.interpret('call siri').command!.action,
        AgentActions.callPlace,
      );
    });

    test('siri weather phrasing: today, like, tell me, will it rain', () {
      for (final phrase in [
        'how is the weather today',
        'whats the weather like',
        'what is the weather like in paris',
        'tell me the weather in paris',
        'will it rain today',
        'is it going to rain in paris',
        'is it raining outside',
      ]) {
        final r = interpreter.interpret(phrase);
        expect(r.outcome, InterpretOutcome.matched, reason: phrase);
        expect(r.command!.action, AgentActions.weatherGet, reason: phrase);
      }
      final withCity = interpreter.interpret('tell me the weather in paris');
      expect(withCity.command!.arguments['place'], 'paris');
      final rainy = interpreter.interpret('will it rain today');
      expect(rainy.command!.arguments['kind'], 'rain');
    });

    test('siri getting-around phrasing: take me to, drive me to', () {
      for (final phrase in [
        'take me to the office',
        'take me to the airport',
        'drive me to work',
        'get me to the station',
        'emmene moi a la gare',
        'conduis moi a l aeroport',
      ]) {
        final r = interpreter.interpret(phrase);
        expect(r.outcome, InterpretOutcome.matched, reason: phrase);
        expect(r.command!.action, AgentActions.navOpen, reason: phrase);
        expect(r.command!.arguments['query'], isNotEmpty, reason: phrase);
        expect(r.command!.arguments['app'], isNull, reason: phrase);
      }
    });

    test('"add … to google/outlook calendar" routes to that app', () {
      for (final (phrase, title, app) in [
        ('add dinner to google calendar', 'dinner', 'google'),
        ('add dinner to my google calendar', 'dinner', 'google'),
        ('schedule a meeting in outlook calendar', 'a meeting', 'outlook'),
        ('add lunch with mom to my google calendar', 'lunch with mom', 'google'),
        ('plan diner sur outlook calendrier', 'diner', 'outlook'),
      ]) {
        final r = interpreter.interpret(phrase);
        expect(r.outcome, InterpretOutcome.matched, reason: phrase);
        expect(r.command!.action, AgentActions.calendarAdd, reason: phrase);
        expect(r.command!.arguments['title'], title, reason: phrase);
        expect(r.command!.arguments['app'], app, reason: phrase);
      }
      // Without an app name the system new-event screen still opens.
      for (final phrase in ['add dinner to my calendar', 'add dinner to the calendar']) {
        final r = interpreter.interpret(phrase);
        expect(r.command!.action, AgentActions.calendarAdd, reason: phrase);
        expect(r.command!.arguments['app'], isNull, reason: phrase);
      }
    });

    test('timer accepts durations without "for" and french forms', () {
      for (final phrase in [
        'timer 10 minutes',
        'set timer 10 minutes',
        'countdown 5 minutes',
        'mets un minuteur de 10 minutes',
        'minuteur 5 minutes',
      ]) {
        final r = interpreter.interpret(phrase);
        expect(r.outcome, InterpretOutcome.matched, reason: phrase);
        expect(r.command!.action, AgentActions.timerSet, reason: phrase);
        expect(r.command!.arguments['seconds'], isNotNull, reason: phrase);
      }
      // Bare "timer" still asks how long instead of guessing.
      final bare = interpreter.interpret('timer');
      expect(bare.command!.action, AgentActions.timerSet);
      expect(bare.command!.arguments['seconds'], isNull);
    });

    test('siri device phrasing: the flashlight, battery, camera', () {
      for (final phrase in [
        'turn on the flashlight',
        'turn off the torch',
        'turn the flashlight on',
        'allume la torche',
        'eteins la lampe',
      ]) {
        final r = interpreter.interpret(phrase);
        expect(r.outcome, InterpretOutcome.matched, reason: phrase);
        expect(r.command!.action, AgentActions.flashlightToggle, reason: phrase);
      }
      for (final phrase in [
        'how much battery do i have',
        'how much battery is left',
        'what is my battery at',
        'my battery',
        'combien de batterie il me reste',
      ]) {
        final r = interpreter.interpret(phrase);
        expect(r.outcome, InterpretOutcome.matched, reason: phrase);
        expect(r.command!.action, AgentActions.batteryGet, reason: phrase);
      }
      for (final phrase in [
        'take a picture',
        'take a photo',
        'take a selfie',
        'prends une photo',
        'fais un selfie',
      ]) {
        final r = interpreter.interpret(phrase);
        expect(r.outcome, InterpretOutcome.matched, reason: phrase);
        expect(r.command!.action, AgentActions.appOpen, reason: phrase);
        expect(r.command!.arguments['query'], 'camera', reason: phrase);
      }
      // "take a screenshot" stays a screenshot, not a camera open.
      expect(
        interpreter.interpret('take a screenshot').command!.action,
        AgentActions.screenshot,
      );
    });

    test('who am i talking to: intro and location answers exist', () {
      for (final phrase in [
        'who are you',
        'how old are you',
        'are you there',
        'are you a robot',
        'qui es tu',
        'tu es la',
      ]) {
        final r = interpreter.interpret(phrase);
        expect(r.outcome, InterpretOutcome.matched, reason: phrase);
        expect(r.command!.action, AgentActions.intro, reason: phrase);
      }
      for (final phrase in [
        'where am i',
        'where am i at',
        'what is my location',
        'ou suis je',
        'ma position',
      ]) {
        final r = interpreter.interpret(phrase);
        expect(r.outcome, InterpretOutcome.matched, reason: phrase);
        expect(r.command!.action, AgentActions.locationGet, reason: phrase);
      }
    });

    test('siri help phrasing reaches the catalog', () {
      for (final phrase in [
        'what are you able to do',
        'what can you help with',
        'what commands do you know',
        'liste des commandes',
        'tu sais faire quoi',
      ]) {
        final r = interpreter.interpret(phrase);
        expect(r.outcome, InterpretOutcome.matched, reason: phrase);
        expect(r.command!.action, AgentActions.helpGet, reason: phrase);
      }
    });

    test('sun questions route to weather with sunrise/sunset kinds', () {
      for (final phrase in [
        'when is sunset',
        'what time is sunset today',
        'when is sunrise',
        'a quelle heure est le coucher de soleil',
        'quand est le lever du soleil',
      ]) {
        final r = interpreter.interpret(phrase);
        expect(r.outcome, InterpretOutcome.matched, reason: phrase);
        expect(r.command!.action, AgentActions.weatherGet, reason: phrase);
      }
      expect(
        interpreter.interpret('when is sunset').command!.arguments['kind'],
        'sunset',
      );
      expect(
        interpreter.interpret('when is sunrise').command!.arguments['kind'],
        'sunrise',
      );
      expect(
        interpreter.interpret('a quelle heure est le coucher de soleil')
            .command!.arguments['kind'],
        'sunset',
      );
    });

    test('calendar: adding opens the system event screen, opening the app', () {
      final add = interpreter.interpret('add lunch with mom to my calendar');
      expect(add.outcome, InterpretOutcome.matched);
      expect(add.command!.action, AgentActions.calendarAdd);
      expect(add.command!.arguments['title'], 'lunch with mom');
      for (final phrase in [
        'schedule a meeting on friday in my calendar',
        'ajoute un rendez vous chez le medecin a mon calendrier',
      ]) {
        final r = interpreter.interpret(phrase);
        expect(r.outcome, InterpretOutcome.matched, reason: phrase);
        expect(r.command!.action, AgentActions.calendarAdd, reason: phrase);
        expect(r.command!.arguments['title'], isNotEmpty, reason: phrase);
      }
      for (final phrase in ['open my calendar', 'ouvre mon calendrier']) {
        final r = interpreter.interpret(phrase);
        expect(r.outcome, InterpretOutcome.matched, reason: phrase);
        expect(r.command!.action, AgentActions.appOpen, reason: phrase);
        expect(r.command!.arguments['query'], 'calendar', reason: phrase);
      }
      // Reading is a question, not an app launch: "what is on my calendar"
      // returns the real next events, with the horizon captured.
      for (final phrase in [
        'what is on my calendar',
        'what is on my calendar tomorrow',
        'what do i have on my calendar this week',
        'mon agenda',
        'qu est ce que j ai au calendrier demain',
      ]) {
        final r = interpreter.interpret(phrase);
        expect(r.outcome, InterpretOutcome.matched, reason: phrase);
        expect(r.command!.action, AgentActions.calendarRead, reason: phrase);
        final when = r.command!.arguments['when'];
        expect(
          when,
          phrase.contains('tomorrow') || phrase.contains('demain')
              ? 'tomorrow'
              : (phrase.contains('week') ? 'week' : 'today'),
          reason: phrase,
        );
      }
      // "whats on" normalizes to "what is on": alone it is a schedule
      // question, but "what is on netflix" must not become a calendar read.
      for (final phrase in ['whats on', 'whats on tomorrow', "what's on my agenda"]) {
        final r = interpreter.interpret(phrase);
        expect(r.outcome, InterpretOutcome.matched, reason: phrase);
        expect(r.command!.action, AgentActions.calendarRead, reason: phrase);
        expect(
          r.command!.arguments['when'],
          phrase.contains('tomorrow') ? 'tomorrow' : 'today',
          reason: phrase,
        );
      }
      for (final phrase in ['what is on netflix tonight', 'whats on tv']) {
        final r = interpreter.interpret(phrase);
        expect(r.command!.action, isNot(AgentActions.calendarRead), reason: phrase);
      }
      // Generic play stays a control command, never a Deezer search.
      for (final phrase in ['play some music', 'joue de la musique']) {
        final r = interpreter.interpret(phrase);
        expect(r.outcome, InterpretOutcome.matched, reason: phrase);
        expect(r.command!.action, AgentActions.mediaPlay, reason: phrase);
        expect(r.command!.arguments['query'], isNull, reason: phrase);
      }
    });

    test('shopping list: add and read a dedicated list', () {
      final add = interpreter.interpret('add milk to my shopping list');
      expect(add.outcome, InterpretOutcome.matched);
      expect(add.command!.action, AgentActions.shoppingListAdd);
      expect(add.command!.arguments['item'], 'milk');
      for (final phrase in [
        'put eggs on my shopping list',
        'ajoute du pain a ma liste de courses',
      ]) {
        final r = interpreter.interpret(phrase);
        expect(r.outcome, InterpretOutcome.matched, reason: phrase);
        expect(r.command!.action, AgentActions.shoppingListAdd, reason: phrase);
        expect(r.command!.arguments['item'], isNotEmpty, reason: phrase);
      }
      for (final phrase in [
        'show my shopping list',
        'what is on my shopping list',
        'ma liste de courses',
      ]) {
        final r = interpreter.interpret(phrase);
        expect(r.outcome, InterpretOutcome.matched, reason: phrase);
        expect(r.command!.action, AgentActions.shoppingListGet, reason: phrase);
      }
    });

    test('play X on/in/with a known player routes to that app', () {
      for (final (phrase, query, app) in [
        ('play music on spotify', '', 'spotify'),
        ('play on spotify', '', 'spotify'),
        ('play some music on spotify', '', 'spotify'),
        ('play hotline bling on deezer', 'hotline bling', 'deezer'),
        ('play hotline bling with spotify', 'hotline bling', 'spotify'),
        ('play hotline bling in youtube music', 'hotline bling', 'youtube music'),
        ('play hotline bling on the deezer app', 'hotline bling', 'deezer'),
        ('joue hotline bling sur deezer', 'hotline bling', 'deezer'),
        ('joue de la musique sur spotify', '', 'spotify'),
      ]) {
        final r = interpreter.interpret(phrase);
        expect(r.outcome, InterpretOutcome.matched, reason: phrase);
        expect(r.command!.action, AgentActions.musicSearch, reason: phrase);
        expect(r.command!.arguments['query'], query, reason: phrase);
        expect(r.command!.arguments['app'], app, reason: phrase);
      }
      // Multi-connector titles keep their full text on the known-app route:
      // the title is everything up to the connector before the player.
      for (final (phrase, query, app) in [
        ('play love on the brain on spotify', 'love on the brain', 'spotify'),
        ('play rolling in the deep on deezer', 'rolling in the deep', 'deezer'),
      ]) {
        final r = interpreter.interpret(phrase);
        expect(r.command!.action, AgentActions.musicSearch, reason: phrase);
        expect(r.command!.arguments['query'], query, reason: phrase);
        expect(r.command!.arguments['app'], app, reason: phrase);
      }
      // Unknown targets never strip: the whole literal is searched, so song
      // titles containing connectors survive (pre-feature behavior).
      for (final (phrase, query) in [
        ('play hotline bling on netflix', 'hotline bling on netflix'),
        ('play poker face in vegas', 'poker face in vegas'),
        ('play rolling in the deep', 'rolling in the deep'),
        ('play man in the mirror', 'man in the mirror'),
        ('play livin on a prayer', 'livin on a prayer'),
        ('play love on the brain', 'love on the brain'),
        ('play love on top', 'love on top'),
        ('play crazy in love', 'crazy in love'),
        ('play dancing in the dark', 'dancing in the dark'),
      ]) {
        final r = interpreter.interpret(phrase);
        expect(r.outcome, InterpretOutcome.matched, reason: phrase);
        expect(r.command!.action, AgentActions.musicSearch, reason: phrase);
        expect(r.command!.arguments['query'], query, reason: phrase);
        expect(r.command!.arguments['app'], isNull, reason: phrase);
      }
      // Song titles that merely contain "on" keep the literal search.
      final band = interpreter.interpret('play in the band');
      expect(band.command!.action, AgentActions.musicSearch,
          reason: 'song title');
      expect(band.command!.arguments['query'], 'in the band',
          reason: 'song title');
    });

    test('always use X / stop using X set and clear the app default', () {
      for (final (phrase, verb, domain, app, name) in [
        ('always use deezer', 'set', 'music', 'deezer', 'Deezer'),
        ('use spotify', 'set', 'music', 'spotify', 'Spotify'),
        ('use spotify from now on', 'set', 'music', 'spotify', 'Spotify'),
        ('use youtube music from now on', 'set', 'music', 'youtube music',
            'YouTube Music'),
        ('use spotify for music', 'set', 'music', 'spotify', 'Spotify'),
        ('utilise spotify', 'set', 'music', 'spotify', 'Spotify'),
        ('use waze for directions', 'set', 'navigation', 'waze', 'Waze'),
        ('use google maps from now on', 'set', 'navigation', 'google maps',
            'Google Maps'),
        ('always use google', 'set', 'calendar', 'google', 'Google Calendar'),
        ('use outlook for calendar', 'set', 'calendar', 'outlook',
            'Outlook Calendar'),
        ('use google calendar from now on', 'set', 'calendar', 'google',
            'Google Calendar'),
        ('stop using deezer', 'clear', 'music', 'deezer', 'Deezer'),
        ('dont use spotify anymore', 'clear', 'music', 'spotify', 'Spotify'),
        ('arrete d utiliser spotify', 'clear', 'music', 'spotify', 'Spotify'),
        ('no longer use waze', 'clear', 'navigation', 'waze', 'Waze'),
        ('quit using google calendar', 'clear', 'calendar', 'google',
            'Google Calendar'),
      ]) {
        final r = interpreter.interpret(phrase);
        expect(r.outcome, InterpretOutcome.matched, reason: phrase);
        expect(r.command!.action, AgentActions.appDefault, reason: phrase);
        expect(r.command!.arguments['verb'], verb, reason: phrase);
        expect(r.command!.arguments['domain'], domain, reason: phrase);
        expect(r.command!.arguments['app'], app, reason: phrase);
        expect(r.command!.arguments['name'], name, reason: phrase);
      }
      // Unknown names never claim a domain — they fall through untouched
      // instead of misfiring into another rule family.
      for (final phrase in [
        'use netflix',
        'use the flashlight',
        'always use notion',
        'stop using netflix',
      ]) {
        final r = interpreter.interpret(phrase);
        expect(r.command?.action, isNot(AgentActions.appDefault),
            reason: phrase);
      }
    });

    test('everyday user phrasings route to the right action', () {
      // "stop" family: music pauses, never a fake app-close of "the music".
      for (final phrase in ['stop', 'stop the music', 'stop music',
          'stop the song', 'stop it', 'arrete la musique']) {
        final r = interpreter.interpret(phrase);
        expect(r.command!.action, AgentActions.mediaPause, reason: phrase);
      }
      // …while real close/timer phrases stay untouched.
      expect(interpreter.interpret('close spotify').command!.action,
          AgentActions.appClose);
      expect(interpreter.interpret('stop the timer').command!.action,
          AgentActions.timerCancel);
      expect(interpreter.interpret('stop the alarm').command!.action,
          AgentActions.alarmDismiss);
      // Volume asymmetry: "turn volume down" works like "volume up".
      expect(interpreter.interpret('turn volume down').command!.action,
          AgentActions.volumeSet);
      expect(interpreter.interpret('turn volume down').command!.arguments['mode'],
          'down');
      expect(interpreter.interpret('turn volume up').command!.arguments['mode'],
          'up');
      expect(interpreter.interpret('turn it up').command!.arguments['mode'],
          'up');
      expect(interpreter.interpret('unmute').command!.arguments['mode'],
          'toggle');
      // Weather: bare-city and tomorrow forms are real commands.
      final w = interpreter.interpret('weather paris');
      expect(w.command!.action, AgentActions.weatherGet);
      expect(w.command!.arguments['place'], 'paris');
      expect(interpreter.interpret('whats the weather tomorrow').command!.action,
          AgentActions.weatherGet);
      expect(interpreter.interpret('weather in london').command!.arguments['place'],
          'london');
      // "remind me in 10 minutes" is a delay → a real timer.
      final t = interpreter.interpret('remind me in 10 minutes');
      expect(t.command!.action, AgentActions.timerSet);
      expect(t.command!.arguments['seconds'], 600);
      expect(interpreter.interpret('remind me to call mom').command!.action,
          AgentActions.reminderSet);
      // "call mom on facetime" is a video call, never a polluted contact.
      final c = interpreter.interpret('call mom on facetime');
      expect(c.command!.action, AgentActions.callPlace);
      expect(c.command!.arguments['contact'], 'mom');
      expect(c.command!.arguments['mode'], 'video');
      expect(c.command!.arguments['app'], 'facetime');
      // Pronouns resume playback; never a Deezer search for the word "it".
      expect(interpreter.interpret('play it again').command!.action,
          AgentActions.mediaPlay);
      expect(interpreter.interpret('play that song').command!.action,
          AgentActions.mediaPlay);
      final p = interpreter.interpret('play it on spotify');
      expect(p.command!.action, AgentActions.musicSearch);
      expect(p.command!.arguments['query'], '');
      expect(p.command!.arguments['app'], 'spotify');
      // Device suffixes never pollute the song title.
      expect(
          interpreter.interpret('play hotline bling on my phone')
              .command!.arguments['query'],
          'hotline bling');
      // Calendar horizons understand day names and "anything" forms.
      expect(
          interpreter.interpret('what do i have on friday')
              .command!.arguments['when'],
          'week');
      expect(
          interpreter.interpret('do i have anything tomorrow')
              .command!.arguments['when'],
          'tomorrow');
      // Bare arithmetic with word operators.
      final m = interpreter.interpret('15 percent of 80');
      expect(m.command!.action, AgentActions.mathCalc);
      expect(m.command!.arguments['expr'], '15/100*80');
      // "15 minutes" alone is a duration, not arithmetic.
      expect(interpreter.interpret('15 minutes').command?.action,
          isNot(AgentActions.mathCalc));
      // Bare cancel-timer and thanks.
      expect(interpreter.interpret('cancel timer').command!.action,
          AgentActions.timerCancel);
      expect(interpreter.interpret('thanks').command!.action,
          AgentActions.greet);
    });

    test('call me X / my name is X set the profile; what is my name reads it',
        () {
      for (final (phrase, kind, name) in [
        ('call me sam', 'user', 'Sam'),
        ('call me sam smith', 'user', 'Sam Smith'),
        ('my name is sam', 'user', 'Sam'),
        ('my names sam', 'user', 'Sam'),
        ('you can call me sam', 'user', 'Sam'),
        ('je m appelle sam', 'user', 'Sam'),
        ('call yourself sophie', 'assistant', 'Sophie'),
        ('your name is sophie', 'assistant', 'Sophie'),
        ('renames toi sophie', 'assistant', 'Sophie'),
      ]) {
        final r = interpreter.interpret(phrase);
        expect(r.outcome, InterpretOutcome.matched, reason: phrase);
        expect(r.command!.action, AgentActions.profileSet, reason: phrase);
        expect(r.command!.arguments['kind'], kind, reason: phrase);
        expect(r.command!.arguments['name'], name, reason: phrase);
      }
      for (final phrase in [
        'what is my name',
        'whats my name',
        'do you know my name',
        'who am i',
        'what do you call me',
      ]) {
        final r = interpreter.interpret(phrase);
        expect(r.command!.action, AgentActions.profileGet, reason: phrase);
      }
      // Time words are not names: "call me tomorrow" stays a call phrase
      // and must never claim the profile.
      final t = interpreter.interpret('call me tomorrow');
      expect(t.command?.action, isNot(AgentActions.profileSet));
      // Real calls are untouched.
      final c = interpreter.interpret('call mom');
      expect(c.command!.action, AgentActions.callPlace);
      expect(c.command!.arguments['contact'], 'mom');
    });

    test('currency converts stay unitConvert; french words captured', () {
      final usd = interpreter.interpret('convert 100 usd to eur');
      expect(usd.outcome, InterpretOutcome.matched);
      expect(usd.command!.action, AgentActions.unitConvert);
      expect(usd.command!.arguments['from'], 'usd');
      expect(usd.command!.arguments['to'], 'eur');
      final fr = interpreter.interpret('convertis 100 euros en dollars');
      expect(fr.outcome, InterpretOutcome.matched);
      expect(fr.command!.action, AgentActions.unitConvert);
      expect(fr.command!.arguments['from'], 'euros');
      expect(fr.command!.arguments['to'], 'dollars');
      final miles = interpreter.interpret('convert 5 miles to km');
      expect(miles.command!.action, AgentActions.unitConvert);
    });

    test('currency parses with symbols and bare phrasings - no web needed', () {
      for (final phrase in [
        'convert 100\$ in yen',
        '100 dollars in yen',
        '100 usd to jpy',
        r'100€ to dollars',
        'how much is 100 dollars in yen',
        'what is 10 km in miles',
        'convert 5 pounds to dollars',
      ]) {
        final r = interpreter.interpret(phrase);
        expect(r.outcome, InterpretOutcome.matched, reason: phrase);
        expect(r.command!.action, AgentActions.unitConvert, reason: phrase);
        expect(
          (r.command!.arguments['value'] as num) > 0,
          isTrue,
          reason: phrase,
        );
      }
      expect(
        interpreter.interpret('convert 100\$ in yen').command!.arguments['from'],
        '\$',
      );
      // Unknown units never hijack a normal sentence.
      expect(
        interpreter.interpret('2 points in the game').outcome,
        InterpretOutcome.unknown,
      );
      expect(
        interpreter.interpret('100 dollars in the game').outcome,
        InterpretOutcome.unknown,
      );
    });

    test('hey nexus is the wake word - and hey siri still tolerated', () {
      final wake = interpreter.interpret('hey nexus, call mom');
      expect(wake.outcome, InterpretOutcome.matched);
      expect(wake.command!.action, AgentActions.callPlace);
      expect(wake.command!.arguments['contact'], 'mom');
      final legacy = interpreter.interpret('hey siri, what time is it');
      expect(legacy.command!.action, AgentActions.timeGet);
    });

    test('timezone questions parse for curated and unknown places', () {
      final tokyo = interpreter.interpret('what time is it in tokyo');
      expect(tokyo.outcome, InterpretOutcome.matched);
      expect(tokyo.command!.action, AgentActions.timezoneGet);
      expect(tokyo.command!.arguments['place'], 'tokyo');
      expect(
        interpreter.interpret('quelle heure est il a montreal').command!
            .arguments['place'],
        'montreal',
      );
      final unknown = interpreter.interpret('what time is it in atlantis');
      expect(unknown.command!.action, AgentActions.timezoneGet);
      expect(unknown.command!.arguments['place'], 'atlantis');
    });
  });

  group('the object of a send has to be a value', () {
    // Audit finding, reproduced through the real service: "send this to my
    // PC" captured the word "this" and pushed it to every paired device, and
    // "send this to the TV" built a contact called "this to the tv" — a person
    // Nexus invented, with an offer to remember their phone number. Neither
    // sentence names a thing Nexus holds: in a typed conversation "this" has
    // no referent at all.
    test('a demonstrative is not text to copy', () {
      for (final phrase in [
        'send this to my pc',
        'Send this to my PC.',
        'copy this',
        'copy this to my devices',
        'send it to my phone',
      ]) {
        final result = interpreter.interpret(phrase);
        expect(result.outcome, InterpretOutcome.matched, reason: phrase);
        expect(
          result.command!.action,
          AgentActions.clipboardWrite,
          reason: phrase,
        );
        expect(result.command!.arguments['text'], '', reason: phrase);
      }
    });

    test('so the service asks for the text instead of pushing a word', () {
      final service = CommandService(devices: () => const []);
      final result = service.execute('send this to my pc');
      expect(result.status, AgentResultStatus.needsInfo);
      expect(result.message, contains('Nothing to copy'));
      // A question, not a plan: nothing is scripted for a device to run, and
      // the answer the user gives is not remembered as a preference.
      expect(result.dispatch, isNull);
      expect(service.defaultsSnapshot, isEmpty);
    });

    test('a phrase carrying a recipient is not a contact name', () {
      // "send this" names no value, and "send to this"/"send to that" name no
      // recipient — a demonstrative has no referent in a typed conversation,
      // so a message to a person called "this" is invented either way.
      for (final phrase in [
        'send this',
        'send to this',
        'send to that',
      ]) {
        final result = interpreter.interpret(phrase);
        expect(result.outcome, InterpretOutcome.unknown, reason: phrase);
        expect(
          result.command?.action,
          isNot(AgentActions.messageSend),
          reason: '$phrase must not become a message to an invented contact',
        );
      }
    });

    test('a named recipient with nothing to send is understood, not refused', () {
      // The sentence names who to send to and nothing else, so the recipient
      // is parsed and one detail is genuinely missing — the state that asks
      // for it, not "I don't understand" for a sentence whose recipient is
      // right there. The name is the user's own word with the preposition
      // taken off: "to mom" is a recipient called mom, never a contact
      // literally named "to mom".
      for (final entry in const {
        'send to mom': 'mom',
        'send to my wife': 'my wife',
        'send to jamie': 'jamie',
        'send to dr smith': 'dr smith',
        // A run of prepositions is consumed whole: a typo names mom, it does
        // not name a person called "to mom".
        'send to to mom': 'mom',
        'send onto mom': 'mom',
      }.entries) {
        final result = interpreter.interpret(entry.key);
        expect(result.outcome, InterpretOutcome.needsInfo, reason: entry.key);
        expect(result.missingArgKey, 'message.body', reason: entry.key);
        final command = result.command!;
        expect(command.action, AgentActions.messageSend, reason: entry.key);
        expect(command.arguments['contact'], entry.value, reason: entry.key);
        expect(
          command.arguments['contact'],
          isNot(contains(' to ')),
          reason: '${entry.key} must not fold the preposition into the name',
        );
      }
    });

    test('a recipient after the value is the recipient, and the value is the body', () {
      // "send hello to mom" names both halves of its own sentence: what is
      // sent, and who it goes to. Reading it as a contact called "hello to
      // mom" invents a name nobody said; refusing it claims Nexus did not
      // parse a sentence whose parts it plainly did. So the words before the
      // preposition are the body, and what follows is the recipient. An
      // earlier pass refused all of these on purpose; the recipient being
      // understood is what a person asking for it expects.
      for (final entry in const {
        'send hello to mom': ('mom', 'hello'),
        'send love you to mom': ('mom', 'love you'),
        'send happy birthday to mom': ('mom', 'happy birthday'),
      }.entries) {
        final result = interpreter.interpret(entry.key);
        expect(result.outcome, InterpretOutcome.matched, reason: entry.key);
        final command = result.command!;
        expect(command.action, AgentActions.messageSend, reason: entry.key);
        expect(command.arguments['contact'], entry.value.$1, reason: entry.key);
        expect(command.arguments['body'], entry.value.$2, reason: entry.key);
      }

      // A device is a destination for the text, not a person: the clipboard
      // reading keeps every phrase that already worked.
      final device = interpreter.interpret('send hello to my pc');
      expect(device.command!.action, AgentActions.clipboardWrite);
      expect(device.command!.arguments['text'], 'hello');

      // Nothing before the preposition is not a body, and nothing after it is
      // not a recipient: 'send this to mom' names no value to send.
      for (final phrase in const [
        'send this to',
        'send it to',
        'send this to mom',
        'send it to mom',
      ]) {
        final result = interpreter.interpret(phrase);
        expect(result.outcome, InterpretOutcome.unknown, reason: phrase);
        expect(
          result.command?.action,
          isNot(AgentActions.messageSend),
          reason: '$phrase must not become a message to an invented contact',
        );
      }

      // A recipient that is not a device this interpreter knows is a person to
      // send to — the address book decides, never a guess about the noun.
      final unknownDevice = interpreter.interpret('send hello to my fridge');
      expect(unknownDevice.command!.action, AgentActions.messageSend);
      expect(unknownDevice.command!.arguments['contact'], 'my fridge');
      expect(unknownDevice.command!.arguments['body'], 'hello');

      // A real object with no recipient is still a person's name.
      final person = interpreter.interpret('send mom happy birthday');
      expect(person.command!.action, AgentActions.messageSend);
      expect(person.command!.arguments['contact'], 'mom happy birthday');
    });

    test('a draft that says when or where is still a draft', () {
      // Regression pin, measured against the build before the recipient work:
      // treating "on" as a second recipient made every draft that says when
      // or where not understood — including these, which resolved fine before
      // and resolve fine again. "on" is how a message says when, so it may
      // never decide that a sentence carries a second recipient.
      for (final phrase in [
        'text mom on my way',
        'text mom i am on my way',
        'text jamie see you on monday',
        'text mom happy birthday to you',
        "text mom can't wait to see you",
        'text mom dinner at 8',
        'sms mom on my way',
        'message mom running late to dinner',
        'send mom see you on monday',
        'send mom on my way',
      ]) {
        final result = interpreter.interpret(phrase);
        expect(result.outcome, InterpretOutcome.matched, reason: phrase);
        expect(
          result.command!.action,
          AgentActions.messageSend,
          reason: phrase,
        );
        expect(
          result.command!.arguments['contact'],
          isNot(isEmpty),
          reason: phrase,
        );
      }

      // Through the service the draft reaches a send, never the teach loop
      // that asks the user to rephrase a sentence Nexus understood.
      final service = CommandService(devices: () => const []);
      final result = service.execute('text mom on my way');
      expect(result.status, isNot(AgentResultStatus.unavailable));
      expect(result.message, isNot(contains('understand')));
    });

    test('a device marker is not part of the name it follows', () {
      // "send to jamie from my phone" says where the send goes, not who it
      // goes to: the answer must name jamie, not a contact called "jamie from
      // my phone" that no address book holds.
      final result = interpreter.interpret('send to jamie from my phone');
      expect(result.outcome, InterpretOutcome.needsInfo);
      expect(result.missingArgKey, 'message.body');
      expect(result.command!.arguments['contact'], 'jamie');
      expect(result.question, 'What should I send to jamie?');
    });

    test('a recipient that names a device asks for the thing to send', () {
      // Here the missing detail is real and the clipboard path already names
      // it, so this is the one recipient shape that is answered rather than
      // refused: "send to my pc" sends nothing because nothing was said.
      for (final phrase in [
        'send to my pc',
        'send to the phone',
        'send on my laptop',
        // A TV is a device, not a person: reading it as a contact invented
        // one called "the tv" and offered to remember its phone number.
        'send to the tv',
        'send to my tv',
        'send this to the tv',
        'copy to the tv',
      ]) {
        final result = interpreter.interpret(phrase);
        expect(result.outcome, InterpretOutcome.matched, reason: phrase);
        expect(
          result.command!.action,
          AgentActions.clipboardWrite,
          reason: phrase,
        );
        expect(result.command!.arguments['text'], '', reason: phrase);
      }

      final service = CommandService(devices: () => const []);
      final asked = service.execute('send to my pc');
      expect(asked.status, AgentResultStatus.needsInfo);
      expect(asked.message, contains('Nothing to copy'));
      expect(asked.dispatch, isNull);
    });

    test('a real send or copy is untouched', () {
      final pushed = interpreter.interpret('send hello to my pc');
      expect(pushed.command!.action, AgentActions.clipboardWrite);
      expect(pushed.command!.arguments['text'], 'hello');

      final copied = interpreter.interpret('copy hello to my devices');
      expect(copied.command!.action, AgentActions.clipboardWrite);
      expect(copied.command!.arguments['text'], 'hello');

      // A bare "send X" with a real object is still a message to a person.
      final person = interpreter.interpret('send papi salut');
      expect(person.command!.action, AgentActions.messageSend);
      expect(person.command!.arguments['contact'], 'papi salut');
    });

    test('the sibling verbs read the recipient too, instead of inventing one', () {
      // "text to mom" names mom: the preposition introduces the recipient for
      // every verb that takes one, not just for "send". Reading it as part of
      // the name created a contact called "to mom" that the contact path then
      // treated as a real person.
      for (final entry in const {
        'text to mom': 'mom',
        'message to mom': 'mom',
        'sms to mom': 'mom',
        'msg to mom': 'mom',
        'text to mary jane': 'mary jane',
      }.entries) {
        final result = interpreter.interpret(entry.key);
        expect(result.outcome, InterpretOutcome.matched, reason: entry.key);
        final command = result.command!;
        expect(command.action, AgentActions.messageSend, reason: entry.key);
        expect(command.arguments['contact'], entry.value, reason: entry.key);
      }

      // A trailing device marker is where the text goes, not who it goes to —
      // strip it before reading the recipient, or a real send stops working.
      final onDevice = interpreter.interpret('text jamie on my phone');
      expect(onDevice.command!.action, AgentActions.messageSend);
      expect(onDevice.command!.arguments['contact'], 'jamie');

      // An object that carries a recipient and names nobody is not a contact,
      // and neither is a demonstrative: "text to" has no name after the
      // preposition.
      for (final phrase in [
        'text to',
        'text this',
        'text it',
      ]) {
        final result = interpreter.interpret(phrase);
        expect(result.outcome, InterpretOutcome.unknown, reason: phrase);
        expect(
          result.command?.action,
          isNot(AgentActions.messageSend),
          reason: phrase,
        );
      }

      // A copy goes to a device and nowhere else, and a preposition is never
      // the text: "copy to mom" used to put the words "to mom" on the
      // clipboard and push them to every paired device.
      for (final phrase in [
        'copy to mom',
        'copy hello to mom',
        'copy to',
      ]) {
        final result = interpreter.interpret(phrase);
        expect(result.outcome, InterpretOutcome.unknown, reason: phrase);
      }

      // A device really can be sent to, and the recipient is not the text.
      final toDevice = interpreter.interpret('copy to my pc');
      expect(toDevice.command!.action, AgentActions.clipboardWrite);
      expect(toDevice.command!.arguments['text'], '');

      // A person with a device marker is a person: "on my phone" says which
      // device sends it, not what is sent — so "send to mary jane on my phone"
      // is the same understood sentence "send to mary jane" is, asked for its
      // body, never the name "mary jane" pushed to the clipboard.
      final personOnDevice = interpreter.interpret(
        'send to mary jane on my phone',
      );
      expect(personOnDevice.outcome, InterpretOutcome.needsInfo);
      expect(personOnDevice.missingArgKey, 'message.body');
      expect(personOnDevice.command!.action, AgentActions.messageSend);
      expect(personOnDevice.command!.arguments['contact'], 'mary jane');
    });

    test('a device marker is never the person a message is for', () {
      // "text on my phone" names where it would be sent and nobody to send it
      // to. It used to resolve a contact called "my phone" and open a text to
      // a person who does not exist; the honest answer asks who.
      for (final entry in const {
        'text on my phone': 'Who should I text?',
        'call on my phone': 'Who should I call?',
      }.entries) {
        final result = interpreter.interpret(entry.key);
        expect(result.outcome, InterpretOutcome.needsInfo, reason: entry.key);
        expect(result.question, entry.value, reason: entry.key);
        expect(
          result.command!.arguments['contact'],
          isNull,
          reason: '${entry.key} must not name a contact',
        );
      }

      // A device marker after a real name is read off it, for every device
      // this interpreter knows — not only the three nouns a second,
      // hand-written list happened to carry.
      for (final phrase in const [
        'text jamie on my pc',
        'text jamie on my phone',
        'text jamie on my laptop',
        'call jamie on my pc',
      ]) {
        final result = interpreter.interpret(phrase);
        expect(result.command!.arguments['contact'], 'jamie', reason: phrase);
      }

      // Through the service it is a question, not a confident action — and a
      // question whose answer is used once, not remembered as the next call's
      // recipient.
      final service = CommandService(devices: () => const []);
      final asked = service.execute('call on my phone');
      expect(asked.status, AgentResultStatus.needsInfo);
      final clarification = asked.dispatch! as AgentClarification;
      expect(clarification.question, 'Who should I call?');
      expect(clarification.hint, contains('for this one'));

      // And the question is answerable: the reply becomes the recipient, and
      // the sentence is re-run with it rather than making the user type the
      // whole thing again.
      final answered = service.execute('mom', answerTo: clarification.key);
      final told = answered.dispatch! as AgentMessage;
      expect(told.text, contains('mom'));
      expect(told.text, isNot(contains('"my phone"')));
    });

    test('one preposition vocabulary, read by every verb', () {
      // The list lives once in IntentArgs, and this pins that it is read
      // rather than restated: "copy this onto my pc" used to escape the
      // device suffix — which knew only "to" and "on" — and put the words
      // "onto my pc" on the clipboard, while "send this onto my pc" was
      // already right. Every verb, every preposition, one answer.
      for (final preposition in const ['to', 'onto', 'on']) {
        final withValue = interpreter.interpret('copy hello $preposition my pc');
        expect(
          withValue.command!.action,
          AgentActions.clipboardWrite,
          reason: preposition,
        );
        expect(
          withValue.command!.arguments['text'],
          'hello',
          reason: '$preposition must not leave the device in the text',
        );

        final withoutValue = interpreter.interpret('copy $preposition my pc');
        expect(
          withoutValue.command!.action,
          AgentActions.clipboardWrite,
          reason: preposition,
        );
        expect(
          withoutValue.command!.arguments['text'],
          '',
          reason: '$preposition must ask for the text, not invent one',
        );
      }
    });

    test('a text object is handed to the address book, contacts first', () {
      // A text has one recipient and it is the first thing named, so the rest
      // of the object is the draft — including a "to", which is why "text mom
      // can't wait to see you" works (pinned above). The cost of not guessing
      // is this shape: "text hello to mom" is read as a contact called
      // "hello to mom", and the address book is the only thing that can say
      // whether it exists. That is exactly what the build before the recipient
      // work did, and the alternative refused every draft containing "to".
      final result = interpreter.interpret('text hello to mom');
      expect(result.command!.action, AgentActions.messageSend);
      expect(result.command!.arguments['contact'], 'hello to mom');
    });
  });
}
