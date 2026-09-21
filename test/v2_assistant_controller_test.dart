// The assistant controller: one owner for the connection state, and words that
// are readings of that one state rather than tables kept in step by hand.
//
// These drive the shipped controller with a fake only at the device edge, so
// what is asserted is the real derivation the screen renders.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent_contract.dart';
import 'package:nexus/core/device_actions.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/query_log.dart';
import 'package:nexus/core/speech.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/mesh/mesh_service.dart';
import 'package:nexus/ui/device_executor.dart';
import 'package:nexus/ui/nexus_v2/assistant_controller.dart';
import 'package:nexus/ui/nexus_v2/nexus_orb.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeExecutor implements DeviceExecutor {
  _FakeExecutor(this.respond);

  final Future<ActionResult> Function(AgentRequest request) respond;

  @override
  Future<ActionResult> run(AgentRequest request) => respond(request);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    QueryLog.readAllOverride = () async => const [];
    SpeechInput.override = null;
    SpeechOutput.override = null;
    SpeechPlayback.override = null;
  });

  tearDown(() {
    QueryLog.readAllOverride = null;
    SpeechInput.override = null;
    SpeechOutput.override = null;
    SpeechPlayback.override = null;
  });

  Future<NexusAssistantController> controller(DeviceExecutor executor) async {
    final store = NexusStore(
      explicitPath:
          '${Directory.systemTemp.createTempSync('v2_controller').path}/s.json',
    )..autoUpdate = false;
    final mesh = MeshService(
      identity:
          DeviceInfo(id: 'test-phone', name: 'Test Phone', platform: 'android'),
      store: store,
    );
    addTearDown(mesh.stop);
    return NexusAssistantController(mesh: mesh, executor: executor);
  }

  test('a failure is one fact: the globe, its line and the retry all say it',
      () async {
    final c = await controller(
      _FakeExecutor(
        (request) async =>
            const ActionResult(false, 'Could not take the screenshot.'),
      ),
    );

    await c.submit('take a screenshot');

    // The globe and the line are two readings of the same state, so they can
    // never disagree about what just happened.
    expect(c.orbState, NexusOrbState.error);
    expect(c.stateLine, 'That last one did not work');
    // And the recovery belongs to that same failure.
    expect(c.canRetry, isTrue);
    final last = c.conversation.lastResult!;
    expect(last.status, AgentResultStatus.unavailable);
    expect(NexusAssistantController.isFailure(last.status), isTrue);
    expect(last.message, 'Could not take the screenshot.');

    c.dispose();
  });

  test('the presence follows the work, and one writer sets it', () async {
    final gate = Completer<ActionResult>();
    final c = await controller(_FakeExecutor((request) => gate.future));

    final inFlight = c.submit('take a screenshot');

    // Everything the three signals say while the action runs: busy for the
    // composer, working for the globe, and no second ask taken.
    expect(c.busy, isTrue);
    expect(c.orbState, NexusOrbState.working);
    expect(c.stateLine, 'Working on it');
    expect(c.accepts('take another one'), isFalse);

    gate.complete(const ActionResult(true, 'Screenshot saved.'));
    await inFlight;

    expect(c.busy, isFalse);
    expect(c.orbState, NexusOrbState.idle);
    expect(c.stateLine, 'Ready — ask me anything');
    expect(c.canRetry, isFalse);
    expect(c.accepts('what time is it'), isTrue);

    c.dispose();
  });

  test('a suggestion is only offered when the shipped path really runs it',
      () async {
    QueryLog.readAllOverride = () async => [
          '{"kind":"ask","input":"copy hello to my phone",'
              '"route":"clipboard.write","status":"succeeded"}',
          '{"kind":"ask","input":"copy hello to my phone",'
              '"route":"clipboard.write","status":"succeeded"}',
        ];
    final c = await controller(
      _FakeExecutor((request) async => const ActionResult(true, 'ok')),
    );

    await c.loadHabits();

    expect(c.suggestions, isNot(contains('copy hello to my phone')));
    expect(c.suggestions, contains('what time is it'));

    c.dispose();
  });

  test('a done ask with no recovery clears the retry', () async {
    final c = await controller(
      _FakeExecutor(
        (request) async =>
            const ActionResult(false, 'What should I play?', needsDetail: true),
      ),
    );

    await c.submit('play music');

    // A question is not a failure, so nothing about it is red and there is
    // nothing to press again.
    expect(c.orbState, NexusOrbState.idle);
    expect(NexusAssistantController.isFailure(
      c.conversation.lastResult!.status,
    ), isFalse);
    expect(c.canRetry, isFalse);

    c.dispose();
  });
}
