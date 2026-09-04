import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent_contract.dart';
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
    test('generic "find X" searches the web, not devices', () {
      expectAction('find restaurants near me', AgentActions.webSearch);
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
            'remind me to buy milk': AgentActions.reminderSet,
            'define serendipity': AgentActions.defineWord,
            'search for flutter': AgentActions.webSearch,
            'open github.com': AgentActions.openUrl,
            'note that buy milk': AgentActions.noteCreate,
            'set a timer for 5 minutes': AgentActions.timerSet,
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
        ]) {
          final result = svc.execute(phrase);
          expect(result.status, AgentResultStatus.succeeded, reason: phrase);
          final msg = result.dispatch;
          expect(msg, isA<AgentMessage>(), reason: phrase);
          expect((msg! as AgentMessage).action, isNull, reason: phrase);
          expect((msg as AgentMessage).text, isNotEmpty, reason: phrase);
        }
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
