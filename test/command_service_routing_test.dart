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

  group('capability routing — shipped behavior', () {
    // The assistant answers every catalog command with a local message that
    // carries the action; the view (this device's executor) is the single
    // place that decides what this platform can really do. There is no
    // cross-device routing question in this release.

    test(
      'a recognized call answers locally with the action the view executes',
      () {
        final service = makeService();
        final result = service.execute('call mom');
        expect(result.status, AgentResultStatus.succeeded);
        final msg = result.dispatch! as AgentMessage;
        expect(msg.action, AgentActions.callPlace);
        expect(msg.arguments?['contact'], 'mom');
      },
    );

    test(
      'typed commands run immediately — no approval card or device question',
      () {
        final service = makeService();
        final result = service.execute(
          'call mom',
          approval: AgentApproval.required,
        );
        expect(result.status, AgentResultStatus.succeeded);
        expect(result.dispatch, isA<AgentMessage>());
      },
    );

    test('"on my phone" folds into the contact, not a separate route', () {
      final service = makeService();
      final msg =
          service.execute('call mom on my phone').dispatch! as AgentMessage;
      expect(msg.action, AgentActions.callPlace);
      expect(msg.arguments?['contact'], 'mom');

      final text =
          service.execute('text john on my phone').dispatch! as AgentMessage;
      expect(text.action, AgentActions.messageSend);
      expect(text.arguments?['contact'], 'john');
    });

    test('an unknown device name stays visible to the executor — never a fake plan', () {
      final service = makeService();
      final result = service.execute('call mom on my laptop');
      final msg = result.dispatch! as AgentMessage;
      expect(msg.action, AgentActions.callPlace);
      // The whole "mom on my laptop" is the contact the resolver sees; the
      // executor asks "who did you mean?" instead of pretending to dial.
      expect(msg.arguments?['contact'], 'mom on my laptop');
      expect(result.dispatch, isNot(isA<AgentActionPlan>()));
    });

    test(
      'no capable device anywhere still answers — the executor stays honest',
      () {
        final service = CommandService(
          devices: () => const [
            AgentDeviceSnapshot(id: 'x', name: 'X', online: true),
          ],
          local: pc,
        );
        final result = service.execute('call mom');
        expect(result.status, AgentResultStatus.succeeded);
        expect(
          (result.dispatch! as AgentMessage).action,
          AgentActions.callPlace,
        );
      },
    );
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
      // unknown on its own, but the adoption makes it reach the call executor
      // hook instead of dying as an unknown.
      final result = service.execute('bring mom');
      expect(result.status, AgentResultStatus.succeeded);
      final msg = result.dispatch! as AgentMessage;
      expect(msg.action, AgentActions.callPlace);
      expect(msg.arguments?['contact'], 'tvcraft01');
    });
  });
}
