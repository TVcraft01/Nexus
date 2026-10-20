// The action vocabulary, the parser that guards it, and the sentences it
// produces — the three things that decide whether "it's dark in here" turns a
// torch on or puts a JSON object on the user's screen.
//
// The native side is not faked away here: `DeviceActionBackend` is the seam, and
// a recorder in its place is exactly what the shell does with a fake brain. The
// Kotlin methods behind it (`torch`, `setAlarm`, `setTimer`, `openApp`,
// `battery`) are already covered by `test/device_executor_test.dart` and the
// device runs in `docs/evidence/`.
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent_contract.dart';
import 'package:nexus/core/device_actions.dart';
import 'package:nexus/core/system_actions.dart';

/// The phone, as these tests see it: what was asked of it, and what it answers.
class _Recorder extends DeviceActionBackend {
  final List<(String, Map<String, dynamic>)> calls =
      <(String, Map<String, dynamic>)>[];

  /// What the phone says back. The default is the happy path; a test that wants
  /// a refusal sets this, and a test that wants a channel failure sets [error].
  ActionResult reply = const ActionResult(true, 'Done.');

  Object? error;

  @override
  Future<ActionResult> run(String action, Map<String, dynamic> args) async {
    calls.add((action, args));
    final Object? failure = error;
    if (failure != null) throw failure;
    return reply;
  }
}

void main() {
  group('the rules the model is given', () {
    test('name every action exactly once, and nothing else', () {
      expect(kSystemActionNames, <String>{
        'set_flashlight',
        'set_alarm',
        'set_timer',
        'open_app',
        'get_battery_level',
        'set_wifi',
        'set_bluetooth',
        'set_volume',
        'set_brightness',
        'get_time',
        'play_music',
        'call_number',
      });
      // The prompt is the only place the model can learn the vocabulary, so
      // every name in the set has to appear in it — a name the rules forget is
      // an action the model will never ask for.
      for (final String name in kSystemActionNames) {
        expect(
          kSystemActionRules,
          contains('"action":"$name"'),
          reason: '$name is in the vocabulary but not in the rules',
        );
      }
    });

    test('tells the model to answer with JSON alone, and to talk otherwise', () {
      expect(kSystemActionRules, contains('ONLY one JSON object'));
      expect(kSystemActionRules, contains('answer normally'));
      expect(
        kSystemActionRules,
        contains('Never say you did something yourself'),
        reason: 'the model asks; the app acts and says so',
      );
      // The A25 hallucinated an alarm after a long paste. The rule is explicit,
      // not inferred from "do not act unless asked": a small model needs the
      // exception named or it treats a message with a time in it as a request.
      expect(
        kSystemActionRules,
        contains('ONLY set an alarm if the user explicitly asks you to'),
      );
      expect(kSystemActionRules, contains('pasted in'));
    });

    test('the composed prompt asks for thoughts, then the action rules', () {
      const String persona = 'You are Nexus.';
      expect(
        systemWithActions(persona),
        '$persona\n\n$kNexusReasoningRules\n\n$kSystemActionRules',
      );
      expect(kNexusReasoningRules, contains('<thought>'));
      expect(kNexusReasoningRules, contains('</thought>'));
    });

    test('the model is told not to do math with its actions', () {
      // Measured on the A25: asked "what is 6 times 7", the model answered
      // `{"action":"set_timer","seconds":420}` — it read the numbers as a
      // length of time. The shell answers sums itself now; this is the rule
      // that tells the model why it must not reach for an action instead.
      expect(kSystemActionRules, contains('Do not use tools to do math'));
      expect(kSystemActionRules, contains('If you cannot answer, just say so'));
    });
  });

  test('the rules forbid key-value prose and invented now-playing', () {
    // The phone answered "play Yesterday by The Beatles" with
    // `song: Yesterday, artist: The Beatles` — a claim about a player it never
    // opened. The vocabulary now has play_music, and the rule says what it
    // cannot do, in the words a small model is given.
    expect(kSystemActionRules, contains('Do not output key-value pairs.'));
    expect(
      kSystemActionRules,
      contains('If you cannot perform an action, speak in plain English.'),
    );
    expect(kSystemActionRules, contains('Never name a song or an artist'));
  });

  group('the phrase bridge', () {
    test('a music request becomes play_music before the model is asked', () {
      expect(actionFromPhrase('play some music')?.action, 'play_music');
      expect(actionFromPhrase('play music')?.action, 'play_music');
      // Bare play/resume may be about a track or preview already loaded; it is
      // not the same request as opening a player.
      expect(actionFromPhrase('resume'), isNull);
      expect(actionFromPhrase('play'), isNull);
      // And a named song is not something this action can make appear.
      expect(actionFromPhrase('play yesterday by the beatles'), isNull);
    });
  });

  group('parsing what the model wrote', () {
    test('play_music is an action with no arguments', () {
      expect(
        SystemActionCall.tryParse('{"action":"play_music"}'),
        isA<SystemActionCall>()
            .having((SystemActionCall c) => c.action, 'action', 'play_music')
            .having((SystemActionCall c) => c.args, 'args', isEmpty),
      );
      // A song name does not turn it into a different action, and is not stored
      // as though the phone could play it.
      final SystemActionCall? named = SystemActionCall.tryParse(
        '{"action":"play_music","song":"Yesterday"}',
      );
      expect(named?.action, 'play_music');
      expect(named?.args, isEmpty);
    });

    test('reads each action in the vocabulary', () {
      expect(
        SystemActionCall.tryParse('{"action":"set_flashlight","state":"on"}'),
        isA<SystemActionCall>()
            .having(
              (SystemActionCall c) => c.action,
              'action',
              'set_flashlight',
            )
            .having((SystemActionCall c) => c.args['state'], 'state', 'on'),
      );
      expect(
        SystemActionCall.tryParse(
          '{"action":"set_alarm","hour":7,"minute":30}',
        ),
        isA<SystemActionCall>()
            .having((SystemActionCall c) => c.action, 'action', 'set_alarm')
            .having((SystemActionCall c) => c.args['hour'], 'hour', 7)
            .having((SystemActionCall c) => c.args['minute'], 'minute', 30),
      );
      expect(
        SystemActionCall.tryParse('{"action":"set_timer","seconds":300}'),
        isA<SystemActionCall>()
            .having((SystemActionCall c) => c.action, 'action', 'set_timer')
            .having((SystemActionCall c) => c.args['seconds'], 'seconds', 300),
      );
      expect(
        SystemActionCall.tryParse(
          '{"action":"open_app","app_name":"Google Maps"}',
        ),
        isA<SystemActionCall>()
            .having((SystemActionCall c) => c.action, 'action', 'open_app')
            .having(
              (SystemActionCall c) => c.args['app_name'],
              'app_name',
              'Google Maps',
            ),
      );
      expect(
        SystemActionCall.tryParse('{"action":"get_battery_level"}'),
        isA<SystemActionCall>().having(
          (SystemActionCall c) => c.action,
          'action',
          'get_battery_level',
        ),
      );
      expect(
        SystemActionCall.tryParse('{"action":"set_wifi","state":"off"}'),
        isA<SystemActionCall>()
            .having((SystemActionCall c) => c.action, 'action', 'set_wifi')
            .having((SystemActionCall c) => c.args['state'], 'state', 'off'),
      );
      expect(
        SystemActionCall.tryParse('{"action":"set_bluetooth","state":"on"}'),
        isA<SystemActionCall>()
            .having((SystemActionCall c) => c.action, 'action', 'set_bluetooth')
            .having((SystemActionCall c) => c.args['state'], 'state', 'on'),
      );
      expect(
        SystemActionCall.tryParse('{"action":"set_volume","level":40}'),
        isA<SystemActionCall>()
            .having((SystemActionCall c) => c.action, 'action', 'set_volume')
            .having((SystemActionCall c) => c.args['level'], 'level', 40),
      );
      expect(
        SystemActionCall.tryParse('{"action":"set_brightness","level":"70"}'),
        isA<SystemActionCall>()
            .having(
              (SystemActionCall c) => c.action,
              'action',
              'set_brightness',
            )
            .having((SystemActionCall c) => c.args['level'], 'level', 70),
      );
      // The near-miss a 0.5B writes for the same intent, understood rather than
      // thrown away — refusing it would cost the user their volume for a
      // naming quibble, exactly as `app`/`app_name` once did.
      expect(
        SystemActionCall.tryParse('{"action":"set_volume","percent":15}')
            ?.args['level'],
        15,
      );
    });

    test('finds the object inside the sentence a chatty model adds', () {
      final SystemActionCall? call = SystemActionCall.tryParse(
        'Sure — here you go:\n{"action":"set_flashlight","state":"off"}\nEnjoy.',
      );
      expect(call?.action, 'set_flashlight');
      expect(call?.args['state'], 'off');
    });

    test('accepts a state in any case and a number written as a string', () {
      expect(
        SystemActionCall.tryParse('{"action":"set_flashlight","state":"ON"}')
            ?.args['state'],
        'on',
      );
      expect(
        SystemActionCall.tryParse('{"action":"set_timer","seconds":"90"}')
            ?.args['seconds'],
        90,
      );
    });

    test('refuses an action the app does not have', () {
      expect(
        SystemActionCall.tryParse('{"action":"launch_missiles"}'),
        isNull,
        reason: 'a guess costs a sentence on screen, never a torch',
      );
    });

    test('refuses a known action with the wrong arguments', () {
      // No state, a state that is not on/off, no hour, a minute that is not a
      // minute, a timer of nothing, and an app with no name.
      for (final String reply in <String>[
        '{"action":"set_flashlight"}',
        '{"action":"set_flashlight","state":"maybe"}',
        '{"action":"set_wifi"}',
        '{"action":"set_wifi","state":"true"}',
        '{"action":"set_bluetooth","state":"maybe"}',
        '{"action":"set_volume"}',
        '{"action":"set_volume","level":101}',
        '{"action":"set_volume","level":-1}',
        // 0 is a real volume and a screen the user cannot see to undo.
        '{"action":"set_brightness","level":0}',
        '{"action":"set_brightness","level":101}',
        '{"action":"set_alarm","hour":7}',
        '{"action":"set_alarm","hour":7,"minute":75}',
        '{"action":"set_alarm","hour":24,"minute":10}',
        '{"action":"set_timer","seconds":0}',
        '{"action":"set_timer","seconds":-5}',
        '{"action":"open_app"}',
        '{"action":"open_app","app_name":"   "}',
      ]) {
        expect(
          SystemActionCall.tryParse(reply),
          isNull,
          reason: 'refused: $reply',
        );
      }
    });

    test('refuses JSON that is broken, not an object, or just prose', () {
      for (final String reply in <String>[
        '',
        'It is quite dark in here, would you like the light on?',
        '{"action":"set_flashlight","state":"on"',
        '{"action":',
        '["set_flashlight"]',
        '{"not_action":"set_flashlight"}',
        '{"action":42}',
      ]) {
        expect(
          SystemActionCall.tryParse(reply),
          isNull,
          reason: 'refused: $reply',
        );
      }
    });

    test('is not fooled by braces inside a string', () {
      // A brace in the app's name must not end the object early — which is why
      // the scanner tracks quotes rather than counting characters.
      final SystemActionCall? call = SystemActionCall.tryParse(
        'ok: {"action":"open_app","app_name":"Notes {beta}"}',
      );
      expect(call?.args['app_name'], 'Notes {beta}');
    });
  });

  group('a model with no clock', () {
    test('a time object is read as a request for the clock, not as an answer', () {
      // Verbatim from the A25 at 14:24. Before this rule the thread showed
      // `{"time": "07:30"}` as though it were the time; the shell now answers
      // the request with its own clock instead.
      expect(
        SystemActionCall.tryParse('{"time": "07:30"}')?.action,
        'get_time',
      );
      // A block that is not about the clock is still prose: the rule is narrow
      // on purpose, so a model discussing arbitrary JSON is not overruled.
      expect(SystemActionCall.tryParse('{"colour": "red"}'), isNull);
    });
  });

  group('running an action', () {
    test('the clock is answered by the shell, not the phone', () async {
      // The model asked for this action on the A25 before it existed, so the
      // vocabulary now has it — and the answer is the shell's own clock: no
      // permission, no channel, and nothing the model could have guessed.
      final _Recorder phone = _Recorder();
      final DeviceSystemActions actions = DeviceSystemActions(
        backend: phone,
        clock: () => DateTime(2026, 10, 19, 15, 5),
      );

      final SystemActionOutcome outcome = await actions.execute(
        SystemActionCall.tryParse('{"action":"get_time"}')!,
      );

      expect(outcome.ok, isTrue);
      expect(outcome.message, "It's 15:05 on Monday 19 October 2026.");
      expect(phone.calls, isEmpty, reason: 'the clock needs no native call');
    });

    test('speaks the app\'s own name for each action, and passes the arguments '
        'the native side expects', () async {
      final _Recorder phone = _Recorder();
      const DeviceSystemActions actions = DeviceSystemActions();
      final DeviceSystemActions withPhone = DeviceSystemActions(backend: phone);

      expect(actions, isA<SystemActions>());

      await withPhone.execute(
        SystemActionCall.tryParse('{"action":"set_flashlight","state":"on"}')!,
      );
      expect(phone.calls.last.$1, AgentActions.flashlightToggle);
      expect(phone.calls.last.$2, <String, dynamic>{'mode': 'on'});

      await withPhone.execute(
        SystemActionCall.tryParse(
          '{"action":"set_alarm","hour":7,"minute":5}',
        )!,
      );
      expect(phone.calls.last.$1, AgentActions.alarmSet);
      expect(phone.calls.last.$2, <String, dynamic>{'hour': 7, 'minute': 5});

      await withPhone.execute(
        SystemActionCall.tryParse('{"action":"set_timer","seconds":300}')!,
      );
      expect(phone.calls.last.$1, AgentActions.timerSet);
      expect(phone.calls.last.$2, <String, dynamic>{'seconds': 300});

      await withPhone.execute(
        SystemActionCall.tryParse('{"action":"call_number","number":"mom"}')!,
      );
      expect(phone.calls.last.$1, AgentActions.callPlace);
      expect(phone.calls.last.$2, <String, dynamic>{'number': 'mom'});

      await withPhone.execute(
        SystemActionCall.tryParse('{"action":"open_app","app_name":"Maps"}')!,
      );
      expect(phone.calls.last.$1, AgentActions.appOpen);
      expect(phone.calls.last.$2, <String, dynamic>{'query': 'Maps'});

      await withPhone.execute(
        SystemActionCall.tryParse('{"action":"play_music"}')!,
      );
      expect(phone.calls.last.$1, AgentActions.musicPlay);
      expect(phone.calls.last.$2, isEmpty);

      await withPhone.execute(
        SystemActionCall.tryParse('{"action":"get_battery_level"}')!,
      );
      expect(phone.calls.last.$1, AgentActions.batteryGet);
      expect(phone.calls.last.$2, isEmpty);

      // The four settings actions. Each names the native method the app already
      // had, with the arguments that method reads.
      await withPhone.execute(
        SystemActionCall.tryParse('{"action":"set_wifi","state":"off"}')!,
      );
      expect(phone.calls.last.$1, AgentActions.wifiToggle);
      expect(phone.calls.last.$2, <String, dynamic>{'mode': 'off'});

      await withPhone.execute(
        SystemActionCall.tryParse('{"action":"set_bluetooth","state":"on"}')!,
      );
      expect(phone.calls.last.$1, AgentActions.bluetoothToggle);
      expect(phone.calls.last.$2, <String, dynamic>{'mode': 'on'});

      await withPhone.execute(
        SystemActionCall.tryParse('{"action":"set_volume","level":40}')!,
      );
      expect(phone.calls.last.$1, AgentActions.volumeSet);
      expect(phone.calls.last.$2, <String, dynamic>{
        'mode': 'set',
        'level': 40,
      });

      await withPhone.execute(
        SystemActionCall.tryParse('{"action":"set_brightness","level":70}')!,
      );
      expect(phone.calls.last.$1, AgentActions.brightnessSet);
      expect(phone.calls.last.$2, <String, dynamic>{
        'mode': 'set',
        'level': 70,
      });
    });

    test('never writes its own sentence over the phone\'s for a setting', () async {
      final _Recorder phone = _Recorder();
      final DeviceSystemActions actions = DeviceSystemActions(backend: phone);

      // The case the whole rule exists for: Android refused the switch and
      // opened the panel instead. "Wi-Fi on." here would be a lie about a radio
      // that is still off, so the phone's sentence is the one the user reads.
      phone.reply = const ActionResult(
        true,
        "Android won't let an app switch Wi-Fi — I opened the Wi-Fi panel, "
        "flip it there.",
      );
      expect(
        (await actions.execute(
          SystemActionCall.tryParse('{"action":"set_wifi","state":"on"}')!,
        )).message,
        "Android won't let an app switch Wi-Fi — I opened the Wi-Fi panel, "
        "flip it there.",
      );

      // And what the phone achieved is what it reports when it did switch.
      phone.reply = const ActionResult(true, 'Bluetooth off.');
      expect(
        (await actions.execute(
          SystemActionCall.tryParse(
            '{"action":"set_bluetooth","state":"off"}',
          )!,
        )).message,
        'Bluetooth off.',
      );

      phone.reply = const ActionResult(true, 'Volume set to 40%.');
      expect(
        (await actions.execute(
          SystemActionCall.tryParse('{"action":"set_volume","level":40}')!,
        )).message,
        'Volume set to 40%.',
      );
    });

    test('the line it puts in the thread is the short one for the three it '
        'knows completely', () async {
      final _Recorder phone = _Recorder();
      final DeviceSystemActions actions = DeviceSystemActions(backend: phone);

      Future<String> run(String reply) async {
        final SystemActionOutcome outcome = await actions.execute(
          SystemActionCall.tryParse(reply)!,
        );
        expect(outcome.ok, isTrue);
        return outcome.message;
      }

      expect(
        await run('{"action":"set_flashlight","state":"on"}'),
        'Flashlight on.',
      );
      expect(
        await run('{"action":"set_flashlight","state":"off"}'),
        'Flashlight off.',
      );
      expect(
        await run('{"action":"set_alarm","hour":7,"minute":5}'),
        'Alarm set for 07:05.',
      );
      expect(
        await run('{"action":"set_timer","seconds":300}'),
        'Timer set for 5 minutes.',
      );
      expect(
        await run('{"action":"set_timer","seconds":90}'),
        'Timer set for 1 min 30 s.',
      );
      expect(
        await run('{"action":"set_timer","seconds":7200}'),
        'Timer set for 2 hours.',
      );
      expect(
        await run('{"action":"set_timer","seconds":1}'),
        'Timer set for 1 second.',
      );
    });

    test(
      'the phone\'s own sentence wins for the two it knows better',
      () async {
        final _Recorder phone = _Recorder();
        final DeviceSystemActions actions = DeviceSystemActions(backend: phone);

        phone.reply = const ActionResult(true, 'Battery at 84%.');
        expect(
          (await actions.execute(
            SystemActionCall.tryParse('{"action":"get_battery_level"}')!,
          )).message,
          'Battery at 84%.',
        );

        // Opening an app is the case where the phone knows *what* it opened —
        // "Opened Maps." is the part the user cannot see for themselves.
        phone.reply = const ActionResult(true, 'Opened Maps.');
        expect(
          (await actions.execute(
            SystemActionCall.tryParse(
              '{"action":"open_app","app_name":"maps"}',
            )!,
          )).message,
          'Opened Maps.',
        );
      },
    );

    test('a refused play_music says the one honest sentence', () async {
      final _Recorder phone = _Recorder();
      final DeviceSystemActions actions = DeviceSystemActions(backend: phone);
      // The phone may have a better idea of *why*, and it is not used: the two
      // facts a user can act on are "blocked" and "not installed", and the pill
      // must not dress either up as a success.
      phone.reply = const ActionResult(false, 'No activity found');

      final SystemActionOutcome outcome = await actions.execute(
        SystemActionCall.tryParse('{"action":"play_music"}')!,
      );
      expect(outcome.ok, isFalse);
      expect(outcome.message, kMusicUnavailableText);
      expect(outcome.message, isNot(contains('No activity')));
    });

    test('an opened music player reports what the phone opened', () async {
      final _Recorder phone = _Recorder();
      final DeviceSystemActions actions = DeviceSystemActions(backend: phone);
      phone.reply = const ActionResult(true, 'Opened YouTube Music.');

      final SystemActionOutcome outcome = await actions.execute(
        SystemActionCall.tryParse('{"action":"play_music"}')!,
      );
      expect(outcome.ok, isTrue);
      expect(outcome.message, 'Opened YouTube Music.');
    });

    test('a refusal keeps the phone\'s reason and is not a success', () async {
      final _Recorder phone = _Recorder();
      final DeviceSystemActions actions = DeviceSystemActions(backend: phone);
      phone.reply = const ActionResult(
        false,
        'What app should I open?',
        needsDetail: true,
      );

      final SystemActionOutcome outcome = await actions.execute(
        SystemActionCall.tryParse('{"action":"open_app","app_name":"qqq"}')!,
      );
      expect(outcome.ok, isFalse);
      expect(outcome.message, 'What app should I open?');
    });

    test(
      'a channel that throws becomes a sentence, never a stack trace',
      () async {
        final _Recorder phone = _Recorder()..error = StateError('no plugin');
        final DeviceSystemActions actions = DeviceSystemActions(backend: phone);

        final SystemActionOutcome outcome = await actions.execute(
          SystemActionCall.tryParse(
            '{"action":"set_flashlight","state":"on"}',
          )!,
        );
        expect(outcome.ok, isFalse);
        expect(outcome.message, notOnThisSystem(AgentActions.flashlightToggle));
        expect(outcome.message, isNot(contains('StateError')));
      },
    );
  });
}
