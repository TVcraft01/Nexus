import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent_contract.dart';
import 'package:nexus/core/capability.dart';
import 'package:nexus/core/command_interpreter.dart';
import 'package:nexus/core/command_service.dart';

/// The command surface must be provable: every phrase the app advertises
/// (help text, suggestion chips) — and the natural variants friends type —
/// resolves to the AgentAction the UI/help claims. A phrase that yields
/// `unknown`/`needsInfo` for something advertised, or an action that has no
/// honest destination, is a bug this suite exists to catch.
void main() {
  const interpreter = CommandInterpreter();

  InterpretResult parse(String phrase) => interpreter.interpret(phrase);

  void expectAction(
    String phrase,
    String action, {
    Map<String, dynamic>? args,
    String? target,
  }) {
    final result = parse(phrase);
    expect(result.outcome, InterpretOutcome.matched, reason: phrase);
    expect(result.command!.action, action, reason: phrase);
    if (target != null) {
      expect(result.command!.target, target, reason: phrase);
    }
    if (args != null) {
      for (final entry in args.entries) {
        expect(
          result.command!.arguments[entry.key],
          entry.value,
          reason: '$phrase → ${entry.key}',
        );
      }
    }
  }

  group('every help-text command resolves', () {
    test('time & date', () {
      expectAction('what time is it', AgentActions.timeGet, target: 'local');
      expectAction(
        'what is the date',
        AgentActions.timeGet,
        target: 'local',
        args: {'kind': 'date'},
      );
    });
    test('math', () {
      expectAction(
        'what is 12 times 8',
        AgentActions.mathCalc,
        target: 'local',
      );
      expectAction('2 + 3', AgentActions.mathCalc, target: 'local');
    });
    test('system: open an app', () {
      expectAction(
        'open youtube',
        AgentActions.appOpen,
        target: 'local',
        args: {'query': 'youtube'},
      );
      expectAction(
        'open github.com',
        AgentActions.openUrl,
        target: 'local',
        args: {'url': 'github.com'},
      );
    });
    test('system: battery / screenshot', () {
      expectAction('battery', AgentActions.batteryGet, target: 'local');
      expectAction('screenshot', AgentActions.screenshot, target: 'local');
    });
    test('system: flashlight', () {
      expectAction(
        'flashlight on',
        AgentActions.flashlightToggle,
        target: 'local',
        args: {'state': 'on'},
      );
      expectAction(
        'flashlight off',
        AgentActions.flashlightToggle,
        target: 'local',
        args: {'state': 'off'},
      );
    });
    test('system: brightness', () {
      expectAction(
        'brightness 50',
        AgentActions.brightnessSet,
        target: 'local',
        args: {'mode': 'set', 'level': 50},
      );
      expectAction(
        'brightness up',
        AgentActions.brightnessSet,
        target: 'local',
        args: {'mode': 'up'},
      );
    });
    test('system: volume', () {
      expectAction(
        'volume up',
        AgentActions.volumeSet,
        target: 'local',
        args: {'mode': 'up'},
      );
      expectAction(
        'volume down',
        AgentActions.volumeSet,
        target: 'local',
        args: {'mode': 'down'},
      );
      expectAction(
        'mute',
        AgentActions.volumeSet,
        target: 'local',
        args: {'mode': 'mute'},
      );
    });
    test('system: wifi / bluetooth', () {
      expectAction(
        'wifi on',
        AgentActions.wifiToggle,
        target: 'local',
        args: {'state': 'on'},
      );
      expectAction(
        'wifi off',
        AgentActions.wifiToggle,
        target: 'local',
        args: {'state': 'off'},
      );
      expectAction(
        'bluetooth off',
        AgentActions.bluetoothToggle,
        target: 'local',
        args: {'state': 'off'},
      );
      expectAction(
        'bluetooth on',
        AgentActions.bluetoothToggle,
        target: 'local',
        args: {'state': 'on'},
      );
    });
    test('system: lock screen', () {
      expectAction('lock screen', AgentActions.lockScreen, target: 'local');
    });
    test('communication', () {
      expectAction(
        'call mom',
        AgentActions.callPlace,
        target: 'local',
        args: {'contact': 'mom'},
      );
      expectAction(
        'text dad saying hello',
        AgentActions.messageSend,
        target: 'local',
        args: {'contact': 'dad', 'body': 'hello'},
      );
    });
    test('media', () {
      expectAction('play', AgentActions.mediaPlay, target: 'local');
      expectAction('pause', AgentActions.mediaPause, target: 'local');
      expectAction('next', AgentActions.mediaNext, target: 'local');
      expectAction('next track', AgentActions.mediaNext, target: 'local');
      expectAction('previous', AgentActions.mediaPrev, target: 'local');
      expectAction('shuffle', AgentActions.mediaShuffle, target: 'local');
      expectAction('repeat', AgentActions.mediaRepeat, target: 'local');
    });
    test('productivity: alarm / reminder / define / translate / convert', () {
      expectAction('alarm for 7am', AgentActions.alarmSet, target: 'local');
      expectAction(
        'remind me to buy milk',
        AgentActions.reminderSet,
        target: 'local',
        args: {'text': 'buy milk'},
      );
      expectAction(
        'define serendipity',
        AgentActions.defineWord,
        target: 'local',
      );
      expectAction(
        'translate hello to french',
        AgentActions.translateText,
        target: 'local',
      );
      expectAction(
        'convert 5 miles to km',
        AgentActions.unitConvert,
        target: 'local',
      );
      expectAction(
        'what is 15% of 80',
        AgentActions.mathCalc,
        target: 'local',
        args: {'expr': '15/100*80'},
      );
    });
    test('weather, navigation & email', () {
      expectAction(
        'what is the weather',
        AgentActions.weatherGet,
        target: 'local',
        args: {'place': '', 'kind': 'now'},
      );
      expectAction(
        'what is the weather in paris',
        AgentActions.weatherGet,
        target: 'local',
        args: {'place': 'paris', 'kind': 'now'},
      );
      expectAction(
        'will it rain in paris',
        AgentActions.weatherGet,
        target: 'local',
        args: {'place': 'paris', 'kind': 'rain'},
      );
      expectAction(
        'take me home',
        AgentActions.navOpen,
        target: 'local',
        args: {'query': 'home'},
      );
      expectAction(
        'navigate to the office',
        AgentActions.navOpen,
        target: 'local',
        args: {'query': 'the office'},
      );
      expectAction(
        'email mom saying hello',
        AgentActions.emailSend,
        target: 'local',
        args: {'contact': 'mom', 'body': 'hello'},
      );
      expectAction(
        'play my playlist',
        AgentActions.mediaPlay,
        target: 'local',
      );
    });
    test('live services: music, currency, timezone, sun, calendar, shopping',
        () {
      expectAction(
        'play hotline bling',
        AgentActions.musicSearch,
        target: 'local',
      );
      expectAction(
        'convert 100 usd to eur',
        AgentActions.unitConvert,
        target: 'local',
        args: {'value': 100.0, 'from': 'usd', 'to': 'eur'},
      );
      expectAction(
        'convertis 100 euros en dollars',
        AgentActions.unitConvert,
        target: 'local',
      );
      expectAction(
        'what time is it in tokyo',
        AgentActions.timezoneGet,
        target: 'local',
        args: {'place': 'tokyo'},
      );
      expectAction(
        'when is sunset',
        AgentActions.weatherGet,
        target: 'local',
        args: {'place': '', 'kind': 'sunset'},
      );
      expectAction(
        'add milk to my shopping list',
        AgentActions.shoppingListAdd,
        target: 'local',
        args: {'item': 'milk'},
      );
      expectAction(
        'show my shopping list',
        AgentActions.shoppingListGet,
        target: 'local',
      );
      expectAction(
        'add lunch with mom to my calendar',
        AgentActions.calendarAdd,
        target: 'local',
        args: {'title': 'lunch with mom'},
      );
      expectAction(
        'open my calendar',
        AgentActions.appOpen,
        target: 'local',
        args: {'query': 'calendar'},
      );
    });
    test('siri phrasing: wake words, weather, getting around', () {
      expectAction(
        'hey siri, what time is it',
        AgentActions.timeGet,
        target: 'local',
      );
      expectAction(
        'how is the weather today',
        AgentActions.weatherGet,
        target: 'local',
        args: {'place': '', 'kind': 'now'},
      );
      expectAction(
        'tell me the weather in paris',
        AgentActions.weatherGet,
        target: 'local',
        args: {'place': 'paris', 'kind': 'now'},
      );
      expectAction(
        'will it rain today',
        AgentActions.weatherGet,
        target: 'local',
        args: {'place': '', 'kind': 'rain'},
      );
      expectAction(
        'take me to the airport',
        AgentActions.navOpen,
        target: 'local',
        args: {'query': 'the airport'},
      );
      expectAction('drive me to work', AgentActions.navOpen, target: 'local');
    });
    test('about the assistant: identity, location, camera, devices', () {
      expectAction('who are you', AgentActions.intro, target: 'local');
      expectAction('are you there', AgentActions.intro, target: 'local');
      expectAction('where am i', AgentActions.locationGet, target: 'local');
      expectAction(
        'take a picture',
        AgentActions.appOpen,
        target: 'local',
        args: {'query': 'camera'},
      );
      expectAction(
        'turn on the flashlight',
        AgentActions.flashlightToggle,
        target: 'local',
        args: {'state': 'on'},
      );
      expectAction(
        'how much battery do i have',
        AgentActions.batteryGet,
        target: 'local',
      );
      expectAction(
        'timer 10 minutes',
        AgentActions.timerSet,
        target: 'local',
      );
    });
    test('fun', () {
      expectAction('roll a dice', AgentActions.randomDice, target: 'local');
      expectAction('flip a coin', AgentActions.randomCoin, target: 'local');
      expectAction(
        'random 1 to 100',
        AgentActions.randomNumber,
        target: 'local',
      );
      expectAction('tell me a joke', AgentActions.tellJoke, target: 'local');
    });
    test('web & notes', () {
      expectAction(
        'search for flutter',
        AgentActions.webSearch,
        target: 'local',
      );
      expectAction(
        'note that buy milk',
        AgentActions.noteCreate,
        target: 'local',
      );
      expectAction(
        'copy hello to my devices',
        AgentActions.clipboardWrite,
        target: 'local',
        args: {'text': 'hello'},
      );
    });
    test('devices', () {
      expectAction('show my devices', AgentActions.deviceList, target: 'local');
      expectAction('blink the esp32', AgentActions.ledBlink);
    });
    test('help & greeting', () {
      expectAction('what can you do', AgentActions.helpGet, target: 'local');
      expectAction('hello', AgentActions.greet, target: 'local');
    });
  });

  group('suggestion chips resolve', () {
    test('every chip maps to the action the label advertises', () {
      const chips = <String, String>{
        'what can you do': AgentActions.helpGet,
        'battery': AgentActions.batteryGet,
        'open youtube': AgentActions.appOpen,
        'call mom': AgentActions.callPlace,
        'roll a dice': AgentActions.randomDice,
        'flashlight on': AgentActions.flashlightToggle,
        'tell me a joke': AgentActions.tellJoke,
        'screenshot': AgentActions.screenshot,
      };
      chips.forEach((phrase, action) {
        final result = parse(phrase);
        expect(result.outcome, InterpretOutcome.matched, reason: phrase);
        expect(result.command!.action, action, reason: phrase);
      });
    });
  });

  group('device questions ask Nexus, never the web', () {
    // The bug this guards: the generic "find …" web-search matcher claimed
    // "find my other devices" and opened a search for "my other devices" —
    // a wrong answer that also claimed the assistant cannot do something it
    // does perfectly well. A question about your own devices is a question
    // for Nexus, whatever verb it is asked with.
    test('listing your devices routes to the Nexus registry', () {
      for (final phrase in const [
        'find my other devices',
        'find my devices',
        'find devices',
        'locate my devices',
        'see my devices',
        'my other devices',
        'other devices',
        'show my devices',
        'list my devices',
        'what devices do i have',
        // "where are …" is a location question about *the user's* devices, so
        // it belongs to the registry — not to the memory matcher that owns
        // "where is the X" and would otherwise answer for a device by name.
        'where are my devices',
      ]) {
        expectAction(phrase, AgentActions.deviceList, target: 'local');
      }
    });

    test('the singular "my device" stays a find, not a listing', () {
      // The counterweight. "find my phone" and "where is my laptop" are a
      // standing per-device feature, matched by noun in the find/ring block;
      // a device-list rule that matched "device" too would silently take them
      // over, because it runs first. Only the plural is a listing.
      expectAction('find my device', AgentActions.findDevice, target: 'device');
      expectAction('find my phone', AgentActions.findDevice, target: 'phone');
      expectAction('locate my laptop', AgentActions.findDevice, target: 'laptop');
      expectAction('where is my pc', AgentActions.findDevice, target: 'pc');
    });

    test('a real search still searches', () {
      // Only the device noun moved: "find" on anything else is still a
      // search, and must not start answering as a device listing.
      expectAction('find my keys', AgentActions.webSearch);
      expectAction('search for cats', AgentActions.webSearch);
      expectAction('google the weather in paris', AgentActions.webSearch);
    });

    test('the noun alone is still about that device', () {
      // "my device" with the verb left out is the same question, and it used
      // to dead-end in the teach flow's "I don't understand \"my device\"".
      // The possessive is what makes it a question about *your* device, so a
      // bare "phone" must keep whatever home it already had.
      expectAction('my device', AgentActions.findDevice, target: 'device');
      expectAction('my phone', AgentActions.findDevice, target: 'phone');
      expectAction('my laptop', AgentActions.findDevice, target: 'laptop');
      expect(parse('phone').command?.action, isNot(AgentActions.findDevice));
    });
  });

  group('a device noun is a kind, never a name', () {
    // The defect these guard: "find my device" answered `I don't see "device"
    // online right now` — a placeholder noun quoted back as if it were a
    // device, so the assistant invented one and reported on it. The class is
    // every singular phrasing, because they all fail the same way; the fix is
    // one rule in the catalog, and these tests hold it in place.
    const localPhone = AgentDeviceSnapshot(
      id: 'self-phone',
      name: "TVcraft's phone",
      online: true,
      capabilities: [DeviceCapability(AgentActions.callPlace)],
    );
    const localPc = AgentDeviceSnapshot(
      id: 'self-pc',
      name: "TVcraft's PC",
      online: true,
      capabilities: [DeviceCapability(AgentActions.mediaPlay)],
    );
    const pairedPhone = AgentDeviceSnapshot(
      id: 'p1',
      name: "TVcraft01's phone",
      online: true,
      capabilities: [DeviceCapability(AgentActions.callPlace)],
    );
    const sparePhone = AgentDeviceSnapshot(
      id: 'p2',
      name: 'spare phone',
      online: false,
      capabilities: [DeviceCapability(AgentActions.callPlace)],
    );

    /// The spoken answer, asserted to be a plain honest message rather than a
    /// plan: a find can never be planned, because no device can execute one.
    String answer(
      String phrase, {
      required AgentDeviceSnapshot local,
      List<AgentDeviceSnapshot> devices = const [],
    }) {
      final service = CommandService(devices: () => devices, local: local);
      final result = service.execute(phrase);
      expect(result.status, AgentResultStatus.succeeded, reason: phrase);
      return (result.dispatch! as AgentMessage).text;
    }

    test('the generic noun means the device being spoken to', () {
      // A phone-first user asking for "my device" means the one they hold,
      // so the answer is about this device — and explains that find/ring has
      // no executor yet rather than implying a search ran.
      for (final phrase in const [
        'find my device',
        'locate my device',
        'ring my device',
        'make my device ring',
        'my device',
        'find my phone',
        'where is my phone',
        'ring my phone',
      ]) {
        final said = answer(phrase, local: localPhone);
        expect(said, contains("TVcraft's phone"), reason: phrase);
        expect(said, contains('asking from'), reason: phrase);
        expect(said, contains('release yet'), reason: phrase);
      }
    });

    test('a kind is spoken as the real device it matched', () {
      // "find my phone" from the PC is about the *paired* phone, so it says
      // that device's name — never the kind the user happened to type.
      for (final phrase in const [
        'find my phone',
        'where is my phone',
        'ring my phone',
        'beep my phone',
        'make noise on my phone',
      ]) {
        final said = answer(phrase, local: localPc, devices: const [
          pairedPhone,
        ]);
        expect(said, contains("TVcraft01's phone"), reason: phrase);
        expect(said, contains('online on your mesh'), reason: phrase);
      }
    });

    test('a paired device that is offline is still named, not quoted as a '
        'kind', () {
      final offline = AgentDeviceSnapshot(
        id: pairedPhone.id,
        name: pairedPhone.name,
        online: false,
        capabilities: pairedPhone.capabilities,
      );
      final said = answer('find my phone', local: localPc, devices: [offline]);
      // The same sentence as before, about the same device — which is now
      // the real one rather than the kind the user typed.
      expect(said, contains("I don't see TVcraft01's phone online right now"));
    });

    test('several candidates are asked about with the real list', () {
      final said = answer(
        'find my phone',
        local: localPc,
        devices: const [pairedPhone, sparePhone],
      );
      expect(said, contains('More than one'));
      expect(said, contains("TVcraft01's phone"));
      expect(said, contains('spare phone'));
      expect(said, contains('Devices tab'));
    });

    test('a noun that names nothing uses the real list', () {
      final withPairs = answer(
        'find my watch',
        local: localPc,
        devices: const [pairedPhone],
      );
      expect(withPairs, contains("TVcraft01's phone"));
      expect(withPairs, contains('Devices tab'));

      final alone = answer('find my laptop', local: localPc);
      expect(alone, contains('none are paired yet'));
      expect(alone, contains('Devices tab'));
    });

    test('nothing in the class reports on the noun as a device', () {
      // The class-level invariant, so a future phrasing cannot regress it:
      // no answer may quote the kind and then claim something about it, and
      // none may describe it as missing from the mesh.
      final claimed = RegExp(
        r'"(?:device|phone|laptop|watch|tablet|pc)"\s*(?:is|are|online)',
      );
      for (final local in const [localPhone, localPc]) {
        for (final devices in const <List<AgentDeviceSnapshot>>[
          [],
          [pairedPhone],
          [pairedPhone, sparePhone],
        ]) {
          for (final phrase in const [
            'find my device',
            'where is my device',
            'ring my device',
            'my device',
            'find my phone',
            'where is my phone',
            'ring my phone',
            'beep my phone',
            'make my phone ring',
            'play a sound on my phone',
            'find my laptop',
            'where is my laptop',
            'find my watch',
            'ring my watch',
            'find my tablet',
          ]) {
            final said = answer(phrase, local: local, devices: devices);
            final where = '$phrase on ${local.name} '
                'with ${devices.length} paired';
            expect(claimed.hasMatch(said), isFalse, reason: where);
            expect(said, isNot(contains('I don\'t see "')), reason: where);
          }
        }
      }
    });

    test('the plural still answers from the registry', () {
      // The counterweight to the singular fix: listing the devices Nexus is
      // paired with is a different question, and it must stay with the
      // registry rather than being swallowed by the find/ring rule.
      for (final phrase in const [
        'find my other devices',
        'find my devices',
        'show my devices',
        'list my devices',
        'where are my devices',
        'my other devices',
      ]) {
        final service =
            CommandService(devices: () => const [pairedPhone], local: localPc);
        final dispatch = service.execute(phrase).dispatch;
        expect(dispatch, isA<AgentDeviceList>(), reason: phrase);
        expect((dispatch! as AgentDeviceList).devices, hasLength(1),
            reason: phrase);
      }
    });
  });

  group('natural language variants friends actually type', () {
    test('conversational prefixes are stripped — once and repeatedly', () {
      expectAction(
        'can you open deezer',
        AgentActions.appOpen,
        args: {'query': 'deezer'},
      );
      expectAction(
        'hey please call mom',
        AgentActions.callPlace,
        args: {'contact': 'mom'},
      );
      expectAction(
        'hey can you please open youtube',
        AgentActions.appOpen,
        args: {'query': 'youtube'},
      );
      expectAction('please what time is it', AgentActions.timeGet);
      expectAction('could you turn on the wifi', AgentActions.wifiToggle);
      expectAction('okay can you set an alarm for 7am', AgentActions.alarmSet);
      expectAction('yo tell me a joke', AgentActions.tellJoke);
      expectAction('can you roll a dice for me', AgentActions.randomDice);
      expectAction('hey what is 6 times 7', AgentActions.mathCalc);
    });

    test('imperative variants', () {
      expectAction(
        'launch youtube',
        AgentActions.appOpen,
        args: {'query': 'youtube'},
      );
      expectAction(
        'go to youtube',
        AgentActions.appOpen,
        args: {'query': 'youtube'},
      );
      expectAction(
        'dial mom',
        AgentActions.callPlace,
        args: {'contact': 'mom'},
      );
      expectAction(
        'send a message to dad saying hello',
        AgentActions.messageSend,
      );
      expectAction('whats the time', AgentActions.timeGet);
      expectAction('set alarm for 7am', AgentActions.alarmSet);
    });
  });

  group('regressions from this session’s audits', () {
    test('"find my phone" is a device search, not a web search', () {
      expectAction(
        'find my phone',
        AgentActions.findDevice,
        args: {},
        target: 'phone',
      );
      expectAction('find phone', AgentActions.findDevice, target: 'phone');
      expectAction(
        'where is my phone',
        AgentActions.findDevice,
        target: 'phone',
      );
    });
    test('"ring my phone" rings the device, not a contact', () {
      expectAction('ring my phone', AgentActions.ringDevice, target: 'phone');
      expectAction(
        'make my phone ring',
        AgentActions.ringDevice,
        target: 'phone',
      );
      expectAction('beep my phone', AgentActions.ringDevice, target: 'phone');
    });
    test('"ring mom" still means call mom', () {
      expectAction(
        'ring mom',
        AgentActions.callPlace,
        args: {'contact': 'mom'},
      );
    });
    test('natural and French phrasings route to the right action', () {
      // Call — English word orders and French.
      expectAction(
        'appelle papi',
        AgentActions.callPlace,
        target: 'local',
        args: {'contact': 'papi'},
      );
      expectAction(
        'give mom a call',
        AgentActions.callPlace,
        target: 'local',
        args: {'contact': 'mom'},
      );
      // Text — extra verbs, word orders, and French. A bare trailing
      // message stays with the contact; the native side splits it.
      expectAction(
        'msg dad coucou',
        AgentActions.messageSend,
        target: 'local',
        args: {'contact': 'dad coucou'},
      );
      expectAction(
        'texte papi salut',
        AgentActions.messageSend,
        target: 'local',
        args: {'contact': 'papi salut'},
      );
      expectAction(
        'texto papi',
        AgentActions.messageSend,
        target: 'local',
        args: {'contact': 'papi'},
      );
      expectAction(
        'send mom a text saying hi',
        AgentActions.messageSend,
        target: 'local',
        args: {'contact': 'mom', 'body': 'hi'},
      );
      expectAction(
        'send a text to mom saying hi',
        AgentActions.messageSend,
        target: 'local',
        args: {'contact': 'mom', 'body': 'hi'},
      );
      expectAction(
        'send papi salut',
        AgentActions.messageSend,
        target: 'local',
        args: {'contact': 'papi salut'},
      );
      expectAction(
        'envoie un message a papi disant salut',
        AgentActions.messageSend,
        target: 'local',
        args: {'contact': 'papi', 'body': 'salut'},
      );
      // "send ..." with a device target stays a clipboard write.
      expectAction(
        'send hello to my pc',
        AgentActions.clipboardWrite,
        target: 'local',
        args: {'text': 'hello'},
      );
      // French garnish: greetings, time, battery, open, help.
      expectAction('bonjour', AgentActions.greet, target: 'local');
      expectAction(
        'quelle heure est il',
        AgentActions.timeGet,
        target: 'local',
        args: {'kind': 'time'},
      );
      expectAction('batterie', AgentActions.batteryGet, target: 'local');
      expectAction(
        'ouvre youtube',
        AgentActions.appOpen,
        target: 'local',
        args: {'query': 'youtube'},
      );
      expectAction('aide', AgentActions.helpGet, target: 'local');
    });
    test('video calls only fire in an app the user names', () {
      expectAction(
        'video call mom on whatsapp',
        AgentActions.callPlace,
        target: 'local',
        args: {'contact': 'mom', 'mode': 'video', 'app': 'whatsapp'},
      );
      expectAction(
        'whatsapp video call mom',
        AgentActions.callPlace,
        target: 'local',
        args: {'contact': 'mom', 'mode': 'video', 'app': 'whatsapp'},
      );
      expectAction(
        'skype video call mom',
        AgentActions.callPlace,
        target: 'local',
        args: {'contact': 'mom', 'mode': 'video', 'app': 'skype'},
      );
      expectAction(
        'facetime mom',
        AgentActions.callPlace,
        target: 'local',
        args: {'contact': 'mom', 'mode': 'video', 'app': 'facetime'},
      );
      // No app named — still a video intent, never a silent phone call.
      expectAction(
        'video call mom',
        AgentActions.callPlace,
        target: 'local',
        args: {'contact': 'mom', 'mode': 'video'},
      );
      // "video call mom on my phone" names no app either.
      expectAction(
        'video call mom on my phone',
        AgentActions.callPlace,
        target: 'local',
        args: {'contact': 'mom', 'mode': 'video'},
      );
    });
    test('generic "find X" searches the web, not devices', () {
      expectAction('find restaurants near me', AgentActions.webSearch);
    });
    test(
      'bare bodies and multi-word contacts stay intact for native split',
      () {
        expectAction(
          'send mom a text love you',
          AgentActions.messageSend,
          target: 'local',
          args: {'contact': 'mom love you'},
        );
        expectAction(
          'send a text to mom love you',
          AgentActions.messageSend,
          target: 'local',
          args: {'contact': 'mom love you'},
        );
        expectAction(
          'send a text to varlet florence',
          AgentActions.messageSend,
          target: 'local',
          args: {'contact': 'varlet florence'},
        );
        expectAction(
          'send varlet florence a message saying bonjour',
          AgentActions.messageSend,
          target: 'local',
          args: {'contact': 'varlet florence', 'body': 'bonjour'},
        );
      },
    );
    test('device suffix never leaks into contact or draft', () {
      expectAction(
        'send a text to mom on my phone',
        AgentActions.messageSend,
        target: 'local',
        args: {'contact': 'mom'},
      );
      expectAction(
        'send mom a text on my phone',
        AgentActions.messageSend,
        target: 'local',
        args: {'contact': 'mom'},
      );
      expectAction(
        'send a message to dad on my phone',
        AgentActions.messageSend,
        target: 'local',
        args: {'contact': 'dad'},
      );
      expectAction(
        'text papi saying salut on my phone',
        AgentActions.messageSend,
        target: 'local',
        args: {'contact': 'papi', 'body': 'salut'},
      );
    });
    test('"whats up" greets instead of searching the web', () {
      expectAction('whats up', AgentActions.greet, target: 'local');
      expectAction("what's up", AgentActions.greet, target: 'local');
    });
    test('bare restart/reboot resolve honestly', () {
      expectAction('restart', AgentActions.deviceRestart, target: 'local');
      expectAction('reboot', AgentActions.deviceRestart, target: 'local');
    });
    test('web search queries have no leading space', () {
      expectAction(
        'find restaurants near me',
        AgentActions.webSearch,
        target: 'local',
        args: {'query': 'restaurants near me'},
      );
      expectAction(
        'google cats',
        AgentActions.webSearch,
        target: 'local',
        args: {'query': 'cats'},
      );
      expectAction(
        'what is the meaning of life',
        AgentActions.memoryQuestion,
        target: 'local',
        args: {'topic': 'the meaning of life'},
      );
    });
    test('bare "video call" with no contact is not a call to "call"', () {
      expect(parse('video call').outcome, InterpretOutcome.unknown);
    });
    test('airplane mode and restart resolve to honest actions', () {
      expectAction(
        'airplane mode on',
        AgentActions.airplaneModeSet,
        target: 'local',
        args: {'state': 'on'},
      );
      expectAction(
        'airplane mode off',
        AgentActions.airplaneModeSet,
        target: 'local',
        args: {'state': 'off'},
      );
      expectAction(
        'toggle airplane mode',
        AgentActions.airplaneModeSet,
        target: 'local',
      );
      expectAction(
        'restart this device',
        AgentActions.deviceRestart,
        target: 'local',
      );
      expectAction(
        'reboot my phone',
        AgentActions.deviceRestart,
        target: 'local',
      );
    });
    test('nothing advertised resolves to unknown', () {
      const advertised = [
        'what can you do',
        'battery',
        'open youtube',
        'call mom',
        'roll a dice',
        'flashlight on',
        'tell me a joke',
        'screenshot',
        'what time is it',
        'what is the date',
        'what is 12 times 8',
        '2 + 3',
        'brightness 50',
        'volume up',
        'volume down',
        'mute',
        'wifi on',
        'bluetooth off',
        'lock screen',
        'text dad saying hello',
        'play',
        'pause',
        'next',
        'previous',
        'shuffle',
        'repeat',
        'alarm for 7am',
        'remind me to buy milk',
        'define serendipity',
        'translate hello to french',
        'convert 5 miles to km',
        'flip a coin',
        'random 1 to 100',
        'search for flutter',
        'open github.com',
        'note that buy milk',
        'copy hello to my devices',
        'show my devices',
        'blink the esp32',
        'find my phone',
        'ring my phone',
        'airplane mode on',
        'restart this device',
      ];
      for (final phrase in advertised) {
        final result = parse(phrase);
        expect(result.outcome, InterpretOutcome.matched, reason: phrase);
      }
    });

    test('a sentence mark is punctuation, not part of the command', () {
      // The bug this guards: the exact-match catalogue read "what can you do?"
      // — the phrase the brief names explicitly — as a phrase it had never
      // seen, and "what time is it?" failed while "what time is it" worked.
      // Everything advertised must survive the mark a person types anyway.
      const phrases = [
        'what can you do',
        'help',
        'what time is it',
        'what is the date',
        'who are you',
        'what do you know about me',
        'roll a dice',
        'flip a coin',
        'tell me a joke',
        'hello',
        'battery',
        'screenshot',
        'lock screen',
        'flashlight on',
        'volume up',
      ];
      for (final phrase in phrases) {
        final plain = parse(phrase);
        expect(plain.outcome, InterpretOutcome.matched, reason: phrase);
        for (final marked in ['$phrase?', '$phrase!', '$phrase.', '$phrase?!']) {
          final result = parse(marked);
          expect(result.outcome, plain.outcome, reason: marked);
          expect(result.command?.action, plain.command?.action, reason: marked);
        }
      }

      // The mark must not reach a captured argument either: "paris?" would
      // search for the wrong thing, and "mom?" would teach Nexus a contact
      // whose name ends in a question mark.
      const captured = [
        ('what is the weather in paris', 'what is the weather in paris?'),
        ('call mom', 'call mom?'),
        ('search for flutter', 'search for flutter!'),
        ('define serendipity', 'define serendipity.'),
        ('note that buy milk', 'note that buy milk.'),
        ('remind me to buy milk', 'remind me to buy milk!'),
      ];
      for (final (plain, marked) in captured) {
        final a = parse(plain).command!;
        final b = parse(marked).command!;
        expect(a.arguments, isNotEmpty, reason: plain);
        expect(b.action, a.action, reason: marked);
        expect(
          b.arguments,
          a.arguments,
          reason: '$marked must capture exactly what "$plain" captures',
        );
      }
    });
  });

  group(
    'dispatch: every executor-backed command reaches its executor hook',
    () {
      CommandService service({String platform = 'android'}) => CommandService(
        devices: () => const [],
        local: AgentDeviceSnapshot(
          id: 'local',
          name: 'This device',
          online: true,
          capabilities: defaultCapabilitiesFor(platform),
        ),
        memory: const AgentMemory(),
      );

      test(
        'system & communication actions carry the action on their message',
        () {
          final expected = <String, String>{
            'open youtube': AgentActions.appOpen,
            'battery': AgentActions.batteryGet,
            'screenshot': AgentActions.screenshot,
            'flashlight on': AgentActions.flashlightToggle,
            'brightness 50': AgentActions.brightnessSet,
            'volume up': AgentActions.volumeSet,
            'wifi on': AgentActions.wifiToggle,
            'bluetooth off': AgentActions.bluetoothToggle,
            'lock screen': AgentActions.lockScreen,
            'call mom': AgentActions.callPlace,
            'text dad saying hello': AgentActions.messageSend,
            'play': AgentActions.mediaPlay,
            'pause': AgentActions.mediaPause,
            'next': AgentActions.mediaNext,
            'previous': AgentActions.mediaPrev,
            'alarm for 7am': AgentActions.alarmSet,
            'remind me to buy milk at 8pm': AgentActions.reminderSet,
            'define serendipity': AgentActions.defineWord,
            'search for flutter': AgentActions.webSearch,
            'open github.com': AgentActions.openUrl,
            'note that buy milk': AgentActions.noteCreate,
            'set a timer for 5 minutes': AgentActions.timerSet,
            'what is the weather in paris': AgentActions.weatherGet,
            'take me home': AgentActions.navOpen,
            'email mom': AgentActions.emailSend,
            'play my playlist': AgentActions.mediaPlay,
            'volume 50': AgentActions.volumeSet,
            'where am i': AgentActions.locationGet,
            'take a picture': AgentActions.appOpen,
            'timer 10 minutes': AgentActions.timerSet,
            'turn on the flashlight': AgentActions.flashlightToggle,
            'how much battery do i have': AgentActions.batteryGet,
            'take me to the airport': AgentActions.navOpen,
            'play hotline bling': AgentActions.musicSearch,
            'convert 100 usd to eur': AgentActions.currencyGet,
            'what time is it in tokyo': AgentActions.timezoneGet,
            'when is sunset': AgentActions.weatherGet,
            'add milk to my shopping list': AgentActions.shoppingListAdd,
            'show my shopping list': AgentActions.shoppingListGet,
            'add lunch with mom to my calendar': AgentActions.calendarAdd,
            'open my calendar': AgentActions.appOpen,
          };
          final svc = service();
          expected.forEach((phrase, action) {
            final result = svc.execute(phrase);
            expect(result.status, AgentResultStatus.succeeded, reason: phrase);
            expect(result.dispatch, isA<AgentMessage>(), reason: phrase);
            expect(
              (result.dispatch! as AgentMessage).action,
              action,
              reason: phrase,
            );
          });
        },
      );

      test('pure local answers succeed with plain text', () {
        final svc = service();
        for (final phrase in [
          'what time is it',
          'what is the date',
          'what is 12 times 8',
          '2 + 3',
          'hello',
          'what can you do',
          'roll a dice',
          'flip a coin',
          'random 1 to 100',
          'tell me a joke',
          'who are you',
          'how old are you',
          'are you there',
        ]) {
          final result = svc.execute(phrase);
          expect(result.status, AgentResultStatus.succeeded, reason: phrase);
          final msg = result.dispatch;
          expect(msg, isA<AgentMessage>(), reason: phrase);
          expect((msg! as AgentMessage).action, isNull, reason: phrase);
          expect((msg as AgentMessage).text, isNotEmpty, reason: phrase);
        }
      });

      test('a question mark does not turn an answer into "I don\'t know"', () {
        final svc = service();
        for (final phrase in [
          'what can you do?',
          'what time is it?',
          'who are you?',
          'help?',
        ]) {
          final result = svc.execute(phrase);
          expect(result.status, AgentResultStatus.succeeded, reason: phrase);
          final msg = result.dispatch;
          expect(msg, isA<AgentMessage>(), reason: phrase);
          expect((msg! as AgentMessage).text, isNotEmpty, reason: phrase);
        }
        // The brief's exact example: the help answer, not a teach request.
        final help = svc.execute('what can you do?');
        expect(help.status.isQuestion, isFalse);
        expect(
          (help.dispatch! as AgentMessage).text,
          (svc.execute('what can you do').dispatch! as AgentMessage).text,
        );
      });

      test('find/ring/airplane/restart answer honestly, never dead-end', () {
        final svc = service();
        for (final phrase in [
          'find my phone',
          'ring my phone',
          'airplane mode on',
          'restart this device',
        ]) {
          final result = svc.execute(phrase);
          expect(result.status, AgentResultStatus.succeeded, reason: phrase);
          final msg = result.dispatch;
          expect(msg, isA<AgentMessage>(), reason: phrase);
          expect((msg! as AgentMessage).text, isNotEmpty, reason: phrase);
        }
        // A phone (has callPlace capability) gets the phone-specific airplane
        // answer; a desktop (no callPlace) gets the no-radios answer.
        final phoneAnswer =
            (service(platform: 'android').execute('airplane mode on').dispatch!
                    as AgentMessage)
                .text;
        final desktopAnswer =
            (service(platform: 'linux').execute('airplane mode on').dispatch!
                    as AgentMessage)
                .text;
        expect(phoneAnswer, isNot(desktopAnswer));
      });
    },
  );
}
