import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent_contract.dart';
import 'package:nexus/core/command_service.dart';

void main() {
  const phone = AgentDeviceSnapshot(
    id: 'phone1',
    name: 'My Phone',
    online: true,
    capabilities: [
      DeviceCapability(AgentActions.callPlace),
      DeviceCapability(AgentActions.messageSend),
      DeviceCapability(AgentActions.alarmSet),
    ],
  );
  const pc = AgentDeviceSnapshot(
    id: 'pc1',
    name: 'My PC',
    online: true,
    capabilities: [
      DeviceCapability(AgentActions.alarmSet),
      DeviceCapability(AgentActions.mediaPlay),
    ],
  );

  CommandService makeService({
    List<AgentDeviceSnapshot> devices = const [phone],
  }) => CommandService(devices: () => devices, local: pc);

  group('capability routing — contact actions reach the device that can run them', () {
    // A contact action is answered by the catalog and runs wherever it can:
    // a phone self-dials, a phone-less device with a reachable phone offers
    // to have that phone do it (the mesh thesis), and when nothing anywhere
    // can run it the catalog honestly asks to teach the number.

    test('a phone-less device with a reachable phone offers the call there', () {
      final service = makeService();
      final result = service.execute('call mom');
      expect(result.status, AgentResultStatus.needsInfo);
      final question = result.dispatch! as AgentClarification;
      expect(question.key, 'device:${AgentActions.callPlace}');
      expect(question.question, contains('My Phone'));

      // The user agrees — the call goes to the phone as an approved plan
      // with no second local prompt: the phone re-gates the request itself.
      final agreed = service.execute('yes', answerTo: question.key);
      expect(agreed.status, AgentResultStatus.succeeded);
      final plan = agreed.dispatch! as AgentActionPlan;
      expect(plan.request.target, 'phone1');
      expect(plan.request.arguments['contact'], 'mom');
      expect(plan.request.approval, AgentApproval.approved);
    });

    test('a taught number rides along so the phone dials straight through', () {
      final service = makeService();
      service.execute('remember that mom is 0612345678');
      final result = service.execute('call mom');
      final question = result.dispatch! as AgentClarification;
      final agreed = service.execute('yes', answerTo: question.key);
      final plan = agreed.dispatch! as AgentActionPlan;
      expect(plan.request.arguments, containsPair('number', '0612345678'));
      expect(plan.request.arguments['contact'], 'mom');
    });

    test('texts are offered the same way, body included', () {
      final service = makeService();
      final result = service.execute('text mom saying love you');
      final question = result.dispatch! as AgentClarification;
      expect(question.key, 'device:${AgentActions.messageSend}');
      final agreed = service.execute('yes', answerTo: question.key);
      final plan = agreed.dispatch! as AgentActionPlan;
      expect(plan.request.target, 'phone1');
      expect(plan.request.arguments['contact'], 'mom');
      expect(plan.request.arguments['body'], 'love you');
    });

    test('the chosen device is remembered — the next call skips the question', () {
      final service = makeService();
      final first = service.execute('call mom');
      expect(first.status, AgentResultStatus.needsInfo);
      final question = first.dispatch! as AgentClarification;
      expect(question.key, 'device:${AgentActions.callPlace}');
      final agreed = service.execute('yes', answerTo: question.key);
      expect(agreed.status, AgentResultStatus.succeeded);

      final again = service.execute('call mom');
      expect(again.status, AgentResultStatus.succeeded);
      final plan = again.dispatch! as AgentActionPlan;
      expect(plan.request.target, 'phone1');
      expect(plan.request.approval, AgentApproval.approved);
    });

    test('naming the phone pins the route without a question', () {
      final service = makeService();
      final result = service.execute('call mom on my phone');
      expect(result.status, AgentResultStatus.succeeded);
      final plan = result.dispatch! as AgentActionPlan;
      expect(plan.request.target, 'phone1');
      // "on my phone" is a device marker — the contact stays clean.
      expect(plan.request.arguments['contact'], 'mom');

      final text = service.execute('text john on my phone');
      expect(text.status, AgentResultStatus.succeeded);
      expect(
        (text.dispatch! as AgentActionPlan).request.target,
        'phone1',
      );
    });

    test('an unknown device name is refused honestly — no fake plan', () {
      final service = makeService();
      final result = service.execute('call mom on my laptop');
      expect(result.status, AgentResultStatus.unavailable);
      expect(result.message, contains('my laptop'));
    });

    test('two phones produce a "which one?" question naming both', () {
      final service = CommandService(
        devices: () => const [
          phone,
          AgentDeviceSnapshot(
            id: 'phone2',
            name: 'Work Phone',
            online: true,
            capabilities: [DeviceCapability(AgentActions.callPlace)],
          ),
        ],
        local: pc,
      );
      final result = service.execute('call mom');
      expect(result.status, AgentResultStatus.needsInfo);
      final question = result.dispatch! as AgentClarification;
      expect(question.question, contains('Which device'));
      expect(question.hint, contains('My Phone'));
      expect(question.hint, contains('Work Phone'));

      // Naming one routes there — and is remembered for next time.
      final agreed = service.execute('work phone', answerTo: question.key);
      expect(agreed.status, AgentResultStatus.succeeded);
      final plan = agreed.dispatch! as AgentActionPlan;
      expect(plan.request.target, 'phone2');
      final again = service.execute('call mom');
      expect(again.status, AgentResultStatus.succeeded);
      expect(
        (again.dispatch! as AgentActionPlan).request.target,
        'phone2',
      );
    });

    test('no phone anywhere answers honestly — a taught number is surfaced, otherwise it teaches', () {
      final service = CommandService(
        devices: () => const [
          AgentDeviceSnapshot(id: 'x', name: 'X', online: true),
        ],
        local: pc,
      );
      // No taught number and no phone reachable: echoing "Calling mom..."
      // would only fail at the executor. The honest answer asks to teach
      // the number — never a doomed action.
      final result = service.execute('call mom');
      expect(result.status, AgentResultStatus.succeeded);
      final msg = result.dispatch! as AgentMessage;
      expect(msg.action, isNull);
      expect(msg.text, contains('Teach me'));

      // With the number taught, the memory is surfaced even though this
      // PC can't dial — the action still flows to the executor.
      service.execute('remember that mom is 0612345678');
      final known = service.execute('call mom').dispatch! as AgentMessage;
      expect(known.action, AgentActions.callPlace);
      expect(known.arguments, containsPair('number', '0612345678'));
    });
  });

  group('local execution fallback', () {
    const self = AgentDeviceSnapshot(
      id: 'self1',
      name: 'This Phone',
      online: true,
      capabilities: [DeviceCapability(AgentActions.callPlace)],
    );

    CommandService makeSelfService() => CommandService(
      devices: () => const [],
      local: self,
      locallyExecutable: const {AgentActions.callPlace},
    );

    test(
      'a call on the capable device answers as a self-run message, not a plan',
      () {
        final service = makeSelfService();

        final result = service.execute('call mom');
        expect(result.status, AgentResultStatus.succeeded);
        final msg = result.dispatch! as AgentMessage;
        expect(msg.action, AgentActions.callPlace); // self-run executor hook
        expect(msg.arguments?['contact'], 'mom');
        expect(result.dispatch, isNot(isA<AgentActionPlan>()));
      },
    );

    test(
      'typed commands are never gated by approval — plans and remote are',
      () {
        final service = makeSelfService();
        expect(
          service.execute('call mom', approval: AgentApproval.required).status,
          AgentResultStatus.succeeded,
        );
        // Approval gating lives where plans and remote requests are made:
        final denied = service.handleRemoteRequest(
          AgentRequest(
            requestId: 'r-deny',
            target: 'self1',
            action: AgentActions.callPlace,
            arguments: const {'contact': 'mom'},
            approval: AgentApproval.approved,
          ),
          approval: AgentApproval.denied,
        );
        expect(denied.status, AgentResultStatus.denied);
      },
    );
  });

  group('capability defaults', () {
    test('a phone advertises calls and texts; desktops do not', () {
      final android = defaultCapabilitiesFor('android').map((c) => c.id);
      expect(android, contains(AgentActions.callPlace));
      expect(android, contains(AgentActions.messageSend));
      expect(android, contains(AgentActions.alarmSet));

      for (final platform in ['linux', 'windows', 'macos']) {
        final caps = defaultCapabilitiesFor(platform).map((c) => c.id);
        expect(caps, isNot(contains(AgentActions.callPlace)), reason: platform);
        expect(
          caps,
          isNot(contains(AgentActions.messageSend)),
          reason: platform,
        );
        expect(caps, contains(AgentActions.mediaPlay), reason: platform);
      }
    });
  });

  group('remote request handling (receiver side)', () {
    test(
      'a remote call the receiver cannot self-run answers honestly — unwired',
      () {
        final service = makeService();
        final result = service.handleRemoteRequest(
          AgentRequest(
            requestId: 'r1',
            target: 'pc1',
            action: AgentActions.callPlace,
            arguments: const {'contact': 'mom'},
            approval: AgentApproval.approved,
          ),
          approval: AgentApproval.approved,
        );
        // The receiver's UI runs self-run actions (dialing) through the device
        // backend after approval; the pure service keeps the honest answer for
        // everything it alone cannot execute — never a silent success.
        expect(result.status, AgentResultStatus.unavailable);
        expect(result.dispatch, isNull);
        expect(result.message, isNotEmpty);
      },
    );

    test(
      'the remote approval value is never trusted — re-approved locally',
      () {
        final service = makeService();
        // The remote says "approved" but this device's UI never approved:
        final gated = service.handleRemoteRequest(
          AgentRequest(
            requestId: 'r2',
            target: 'phone1',
            action: AgentActions.alarmSet,
            approval: AgentApproval.approved,
          ),
        );
        expect(gated.status, AgentResultStatus.required);

        final denied = service.handleRemoteRequest(
          AgentRequest(
            requestId: 'r3',
            target: 'phone1',
            action: AgentActions.alarmSet,
            approval: AgentApproval.approved,
          ),
          approval: AgentApproval.denied,
        );
        expect(denied.status, AgentResultStatus.denied);
      },
    );

    test('led.blink to a connected node produces a plan; unknown target is unavailable', () {
      final service = makeService(
        devices: const [
          AgentDeviceSnapshot(
            id: 'esp1',
            name: 'ESP32',
            online: true,
            capabilities: [DeviceCapability(AgentActions.ledBlink)],
          ),
        ],
      );
      final ok = service.handleRemoteRequest(
        AgentRequest(
          requestId: 'r4',
          target: 'esp1',
          action: AgentActions.ledBlink,
          approval: AgentApproval.approved,
        ),
        approval: AgentApproval.approved,
      );
      expect(ok.status, AgentResultStatus.succeeded);
      expect((ok.dispatch! as AgentActionPlan).request.target, 'esp1');

      final missing = service.handleRemoteRequest(
        AgentRequest(
          requestId: 'r5',
          target: 'nope',
          action: AgentActions.ledBlink,
          approval: AgentApproval.approved,
        ),
        approval: AgentApproval.approved,
      );
      expect(missing.status, AgentResultStatus.unavailable);
    });

    test('remote clipboard writes are re-approved here before dispatch', () {
      final service = makeService();
      final result = service.handleRemoteRequest(
        AgentRequest(
          requestId: 'r6',
          target: 'local',
          action: AgentActions.clipboardWrite,
          arguments: const {'text': 'hello'},
          approval: AgentApproval.approved,
        ),
        approval: AgentApproval.approved,
      );
      expect(result.status, AgentResultStatus.succeeded);
      expect(
        (result.dispatch! as AgentActionPlan).request.arguments['text'],
        'hello',
      );
    });
  });

  group('learned phrase sync', () {
    test('a local teach fires onPhraseLearned for the mesh broadcast', () {
      String? seen;
      final service = CommandService(
        devices: () => const [phone],
        local: pc,
        onPhraseLearned: (phrase, meaning) => seen = '$phrase -> $meaning',
      );
      final result = service.learn('Call TVcraft', 'call TVcraft01');
      // Teaching stores and broadcasts — it does not execute; the
      // conversation paths run the meaning right after an in-chat teach.
      expect(result.status, AgentResultStatus.succeeded);
      expect((result.dispatch! as AgentMessage).text, contains('now means'));
      // Normalized phrase, lowercased meaning — exactly what the mesh should
      // carry to the other devices.
      expect(seen, 'call tvcraft -> call tvcraft01');
      expect(service.learnedSnapshot['call tvcraft'], 'call tvcraft01');
    });

    test('a remote adoption applies locally but never re-broadcasts', () {
      var broadcast = 0;
      final service = CommandService(
        devices: () => const [phone],
        local: pc,
        onPhraseLearned: (_, _) => broadcast++,
      );
      service.adoptLearned('Bring Mom', 'call TVcraft01');
      expect(broadcast, 0); // knowledge came FROM the mesh — no echo back
      expect(service.learnedSnapshot['bring mom'], 'call tvcraft01');

      // The adopted phrase now behaves like any taught one: "bring mom" is
      // unknown on its own, but the adoption turns it into a call — offered
      // to the reachable phone instead of dying as an unknown or echoing a
      // call this PC can never place.
      final result = service.execute('bring mom');
      expect(result.status, AgentResultStatus.needsInfo);
      final question = result.dispatch! as AgentClarification;
      expect(question.key, 'device:${AgentActions.callPlace}');
      final agreed = service.execute('yes', answerTo: question.key);
      final plan = agreed.dispatch! as AgentActionPlan;
      expect(plan.request.target, 'phone1');
      expect(plan.request.arguments['contact'], 'tvcraft01');
    });
  });
}
