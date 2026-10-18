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
      expect(
        kSystemActionNames,
        <String>{
          'set_flashlight',
          'set_alarm',
          'set_timer',
          'open_app',
          'get_battery_level',
        },
      );
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
    });

    test('the composed prompt is the persona with the rules after it', () {
      const String persona = 'You are Nexus.';
      expect(
        systemWithActions(persona),
        '$persona\n\n$kSystemActionRules',
      );
    });
  });

  group('parsing what the model wrote', () {
    test('reads each of the five actions', () {
      expect(
        SystemActionCall.tryParse('{"action":"set_flashlight","state":"on"}'),
        isA<SystemActionCall>()
            .having((SystemActionCall c) => c.action, 'action', 'set_flashlight')
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

  group('running an action', () {
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
        SystemActionCall.tryParse('{"action":"open_app","app_name":"Maps"}')!,
      );
      expect(phone.calls.last.$1, AgentActions.appOpen);
      expect(phone.calls.last.$2, <String, dynamic>{'query': 'Maps'});

      await withPhone.execute(
        SystemActionCall.tryParse('{"action":"get_battery_level"}')!,
      );
      expect(phone.calls.last.$1, AgentActions.batteryGet);
      expect(phone.calls.last.$2, isEmpty);
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

    test('the phone\'s own sentence wins for the two it knows better', () async {
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
          SystemActionCall.tryParse('{"action":"open_app","app_name":"maps"}')!,
        )).message,
        'Opened Maps.',
      );
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

    test('a channel that throws becomes a sentence, never a stack trace',
        () async {
      final _Recorder phone = _Recorder()..error = StateError('no plugin');
      final DeviceSystemActions actions = DeviceSystemActions(backend: phone);

      final SystemActionOutcome outcome = await actions.execute(
        SystemActionCall.tryParse('{"action":"set_flashlight","state":"on"}')!,
      );
      expect(outcome.ok, isFalse);
      expect(outcome.message, notOnThisSystem(AgentActions.flashlightToggle));
      expect(outcome.message, isNot(contains('StateError')));
    });
  });
}
