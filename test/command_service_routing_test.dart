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

  CommandService makeService({List<AgentDeviceSnapshot> devices = const [phone]}) =>
      CommandService(devices: () => devices, local: pc);

  group('capability routing', () {
    test('asks to run on the phone when the local device cannot', () {
      final service = makeService();
      final result = service.execute('call mom');
      expect(result.status, AgentResultStatus.needsInfo);
      final ask = result.dispatch! as AgentClarification;
      expect(ask.key, 'device:${AgentActions.callPlace}');
      expect(ask.question, contains('My Phone'));
    });

    test('answering "yes" pins the phone and survives the approval re-run', () {
      final service = makeService();
      final ask = service.execute('call mom').dispatch! as AgentClarification;

      final answered = service.execute('yes', answerTo: ask.key);
      expect(answered.status, AgentResultStatus.required); // approval next

      // The approval re-runs the ORIGINAL command — the choice is remembered.
      final approved = service.execute('call mom', approval: AgentApproval.approved);
      expect(approved.status, AgentResultStatus.succeeded);
      final plan = (approved.dispatch! as AgentActionPlan).request;
      expect(plan.target, 'phone1');
      expect(plan.arguments['contact'], 'mom');
    });

    test('a named device skips the search entirely', () {
      final service = makeService();
      final result = service.execute('call mom on my phone', approval: AgentApproval.approved);
      expect(result.status, AgentResultStatus.succeeded);
      final plan = (result.dispatch! as AgentActionPlan).request;
      expect(plan.target, 'phone1');
      expect(plan.arguments['contact'], 'mom');
      expect(result.dispatch, isA<AgentActionPlan>());
    });

    test('unknown or incapable named devices are honest', () {
      final service = makeService();
      final unknown = service.execute('call mom on my laptop', approval: AgentApproval.approved);
      expect(unknown.status, AgentResultStatus.unavailable);
      expect(unknown.message, contains('laptop'));

      // The PC is named but cannot call — never a question, never a plan.
      final incapable = service.execute('call mom on my pc', approval: AgentApproval.approved);
      expect(incapable.status, AgentResultStatus.unavailable);
      expect(incapable.message, contains('can\'t do that'));
    });

    test('a device that can do it locally runs locally — no question', () {
      final service = makeService();
      final result = service.execute('set an alarm for 7am');
      expect(result.status, AgentResultStatus.unavailable); // unwired, not routed
      expect(result.dispatch, isNull);
      expect(result.message, isNotEmpty);
    });

    test('no capable device anywhere → honest unwired message, not a question', () {
      final service = CommandService(
        devices: () => const [
          AgentDeviceSnapshot(id: 'x', name: 'X', online: true),
        ],
        local: pc,
      );
      final result = service.execute('call mom');
      expect(result.status, AgentResultStatus.unavailable);
      expect(result.dispatch, isNull);
    });

    test('messages route like calls, with the contact split off', () {
      final service = makeService();
      final result = service.execute('text john on my phone', approval: AgentApproval.approved);
      expect(result.status, AgentResultStatus.succeeded);
      final plan = (result.dispatch! as AgentActionPlan).request;
      expect(plan.target, 'phone1');
      expect(plan.arguments['contact'], 'john');
    });

    test('an explicit name beats the remembered device', () {
      final service = makeService();
      final ask = service.execute('call mom').dispatch! as AgentClarification;
      service.execute('yes', answerTo: ask.key); // remembers phone1

      final result = service.execute('call dad on my pc', approval: AgentApproval.approved);
      expect(result.status, AgentResultStatus.unavailable); // PC can't call
      expect(result.message, contains('can\'t do that'));
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

    test('a locally executable call plans on this device, gated by approval', () {
      final service = makeSelfService();

      final gated = service.execute('call mom');
      expect(gated.status, AgentResultStatus.required);

      final approved = service.execute('call mom', approval: AgentApproval.approved);
      expect(approved.status, AgentResultStatus.succeeded);
      final plan = (approved.dispatch! as AgentActionPlan).request;
      expect(plan.target, 'self1'); // aimed at THIS device, not over the mesh
      expect(plan.arguments['contact'], 'mom');
    });

    test('a denied local call is denied', () {
      final service = makeSelfService();
      final result = service.execute('call mom', approval: AgentApproval.denied);
      expect(result.status, AgentResultStatus.denied);
    });

    test('without local executors the honest unwired answer stays', () {
      // Same capability list, but nothing declared locally executable —
      // exactly the pre-wiring behavior for alarms and friends.
      final service = CommandService(devices: () => const [], local: self);
      final result = service.execute('call mom', approval: AgentApproval.approved);
      expect(result.status, AgentResultStatus.unavailable);
      expect(result.dispatch, isNull);
      expect(result.message, contains('calls'));
    });
  });

  group('capability defaults', () {
    test('a phone can call and text; a desktop cannot', () {
      final phoneCaps = defaultCapabilitiesFor('android').map((c) => c.id);
      expect(phoneCaps, contains(AgentActions.callPlace));
      expect(phoneCaps, contains(AgentActions.messageSend));

      for (final platform in ['linux', 'windows', 'macos']) {
        final caps = defaultCapabilitiesFor(platform).map((c) => c.id);
        expect(caps, isNot(contains(AgentActions.callPlace)), reason: platform);
        expect(caps, isNot(contains(AgentActions.messageSend)), reason: platform);
        expect(caps, contains(AgentActions.alarmSet), reason: platform);
      }
    });
  });

  group('remote request handling (receiver side)', () {
    test('a routed call is re-gated and answered honestly', () {
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
      expect(result.status, AgentResultStatus.unavailable);
      expect(result.message, contains('calls'));
    });

    test('the remote approval value is never trusted — re-approved locally', () {
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
    });

    test('led.blink to a connected node produces a plan; unknown target is unavailable', () {
      final service = makeService(devices: const [
        AgentDeviceSnapshot(
          id: 'esp1',
          name: 'ESP32',
          online: true,
          capabilities: [DeviceCapability(AgentActions.ledBlink)],
        ),
      ]);
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
}
