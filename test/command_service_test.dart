import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent_contract.dart';
import 'package:nexus/core/command_service.dart';

void main() {
  const devices = [
    AgentDeviceSnapshot(
      id: 'esp32',
      name: 'Desk ESP32',
      online: true,
      capabilities: [DeviceCapability(AgentActions.ledBlink)],
    ),
    AgentDeviceSnapshot(id: 'phone', name: 'My Phone', online: true),
  ];
  final service = CommandService(devices: () => devices);

  test('lists the injected snapshots', () {
    final result = service.execute('show my devices');
    expect(result.status, AgentResultStatus.succeeded);
    expect((result.dispatch! as AgentDeviceList).devices, devices);
  });

  test('resolves exact ID and unique display name', () {
    for (final target in ['esp32', 'Desk ESP32']) {
      final result = service.execute(
        'blink the $target',
        approval: AgentApproval.approved,
        requestId: target,
      );
      expect(result.status, AgentResultStatus.succeeded, reason: target);
      final plan = (result.dispatch! as AgentActionPlan).request;
      expect(plan.target, 'esp32', reason: target);
      expect(
        plan.isAuthorized(
          DeviceCapabilities(
            deviceId: 'esp32',
            capabilities: [DeviceCapability(AgentActions.ledBlink)],
          ),
        ),
        isTrue,
        reason: target,
      );
    }
  });

  test('rejects ambiguous and missing names', () {
    final ambiguous = CommandService(
      devices: () => const [
        AgentDeviceSnapshot(id: 'a', name: 'Board', online: true),
        AgentDeviceSnapshot(id: 'b', name: 'Board', online: true),
      ],
    ).execute('blink the board', approval: AgentApproval.approved);
    expect(ambiguous.status, AgentResultStatus.unavailable);

    // Missing target stays unavailable even before any approval decision —
    // there must never be an approval prompt for a device that does not exist.
    for (final approval in [AgentApproval.approved, AgentApproval.required]) {
      final missing = service.execute('blink the unknown', approval: approval);
      expect(
        missing.status,
        AgentResultStatus.unavailable,
        reason: approval.name,
      );
      expect(missing.dispatch, isNull);
    }
  });

  test('requires and respects explicit local approval', () {
    for (final approval in [AgentApproval.required, AgentApproval.denied]) {
      final result = service.execute('blink the esp32', approval: approval);
      expect(
        result.status,
        approval == AgentApproval.required
            ? AgentResultStatus.required
            : AgentResultStatus.denied,
      );
      expect(result.dispatch, isNull);
    }
  });

  group('locally executable intents', () {
    test('greeting answers', () {
      final result = service.execute('hello');
      expect(result.status, AgentResultStatus.succeeded);
      expect((result.dispatch! as AgentMessage).text, contains('Hello'));
    });

    test('time and date answer locally', () {
      final time = service.execute('what time is it');
      expect(time.status, AgentResultStatus.succeeded);
      expect(
        (time.dispatch! as AgentMessage).text,
        matches(RegExp(r"It's \d{2}:\d{2}\.")),
      );

      final date = service.execute("what's the date");
      expect(date.status, AgentResultStatus.succeeded);
      expect(
        (date.dispatch! as AgentMessage).text,
        contains(DateTime.now().year.toString()),
      );
    });

    test('simple math computes locally', () {
      final result = service.execute('what is 2 plus 2');
      expect(result.status, AgentResultStatus.succeeded);
      expect((result.dispatch! as AgentMessage).text, '2+2 = 4');

      final bare = service.execute('10 / 2');
      expect(bare.status, AgentResultStatus.succeeded);
      expect((bare.dispatch! as AgentMessage).text, '10 / 2 = 5');
    });

    test('broken math is an honest unavailable', () {
      final result = service.execute('calculate 1 divided by 0');
      expect(result.status, AgentResultStatus.unavailable);
      expect(result.dispatch, isNull);
    });
  });

  group('clipboard.write', () {
    test('requires approval, then produces a typed plan', () {
      final pending = service.execute('copy hello to my phone');
      expect(pending.status, AgentResultStatus.required);
      expect(pending.dispatch, isNull);

      final approved = service.execute(
        'copy hello to my phone',
        approval: AgentApproval.approved,
        requestId: 'copy-1',
      );
      expect(approved.status, AgentResultStatus.succeeded);
      final plan = (approved.dispatch! as AgentActionPlan).request;
      expect(plan.action, AgentActions.clipboardWrite);
      expect(plan.target, 'local');
      expect(plan.arguments['text'], 'hello');
      expect(plan.requestId, 'copy-1');
    });

    test('denied and empty text never plan', () {
      final denied = service.execute(
        'copy hello',
        approval: AgentApproval.denied,
      );
      expect(denied.status, AgentResultStatus.denied);
      expect(denied.dispatch, isNull);

      final empty = service.execute(
        'copy to my phone',
        approval: AgentApproval.approved,
      );
      expect(empty.status, AgentResultStatus.unavailable);
      expect(empty.dispatch, isNull);
    });
  });

  group('the catalog always answers or teaches — nothing silent', () {
    test(
      'recognized commands dispatch their action so the executor stays honest',
      () {
        // Every recognized phrase yields a local message carrying the action
        // (the view/executor decides what this platform can really do). It
        // must never be a teach prompt or a silent unavailable.
        for (final phrase in [
          'call mom',
          'text john',
          'set an alarm for 7am',
          "what's the weather",
          'search for cats',
          'pause the music',
        ]) {
          final result = service.execute(phrase);
          expect(result.status, AgentResultStatus.succeeded, reason: phrase);
          final msg = result.dispatch! as AgentMessage;
          expect(msg.text, isNotEmpty, reason: phrase);
          expect(msg.action, isNotNull, reason: phrase);
        }
      },
    );

    test('unrecognized phrases ask to be taught — never fake a result', () {
      for (final phrase in ['navigate to the office', 'turn on the lights']) {
        final result = service.execute(phrase);
        expect(result.status, AgentResultStatus.needsInfo, reason: phrase);
        expect(
          (result.dispatch! as AgentClarification).key,
          startsWith('teach:'),
          reason: phrase,
        );
      }
    });
  });

  group('evaluateMath', () {
    test('evaluates the four operations with precedence and parens', () {
      expect(evaluateMath('2+2'), 4);
      expect(evaluateMath('2*3+4'), 10);
      expect(evaluateMath('10/2'), 5);
      expect(evaluateMath('(1+2)*3'), 9);
      expect(evaluateMath('10 - 3 - 2'), 5);
      expect(evaluateMath('2+2+2+2'), 8);
    });

    test('rejects invalid or unsafe input', () {
      expect(evaluateMath(''), isNull);
      expect(evaluateMath('1/0'), isNull);
      expect(evaluateMath('abc'), isNull);
      expect(evaluateMath('2+'), isNull);
      expect(evaluateMath('(2+2'), isNull);
    });
  });
}
