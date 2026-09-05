// End to end through the REAL surfaces: a phone-less PC pairs with a phone
// over real sockets, asks to call a taught contact, and the offer travels
// the mesh — the phone's executor (with a recording dial backend) places
// the call with the remembered number and the outcome lands back on the PC.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent_contract.dart';
import 'package:nexus/core/command_service.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/phone_actions.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/mesh/mesh_service.dart';
import 'package:nexus/ui/device_executor.dart';

class _DialRecorder implements PhoneActionBackend {
  final dialed = <String?>[];
  final names = <String>[];
  @override
  Future<PhoneCallOutcome> callContact(String name, {String? number}) async {
    names.add(name);
    dialed.add(number);
    return const PhoneCallOutcome(placed: true, message: 'Calling.');
  }

  @override
  Future<PhoneCallOutcome> videoCall(String name, String? app) async =>
      const PhoneCallOutcome(placed: true, message: 'Calling.');
}

Future<void> _waitFor(bool Function() ok, {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!ok()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for the mesh.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a call on the PC is offered to the paired phone and the outcome returns', () async {
    final tmp = await Directory.systemTemp.createTemp('e2e');
    final storePc = NexusStore(explicitPath: '${tmp.path}/pc.json')
      ..port = 53240
      ..clipboardSync = true;
    final storePhone = NexusStore(explicitPath: '${tmp.path}/phone.json')
      ..port = 53241
      ..clipboardSync = true;
    await storePc.save();
    await storePhone.save();

    final pc = MeshService(
      identity: DeviceInfo(id: 'pc-1', name: 'My PC', platform: 'linux'),
      store: storePc,
      onlineWindow: const Duration(seconds: 3),
      visibleWindow: const Duration(seconds: 3),
      heartbeatInterval: const Duration(seconds: 2),
      connectTimeout: const Duration(milliseconds: 300),
    );
    final phone = MeshService(
      identity: DeviceInfo(id: 'phone-1', name: 'My Phone', platform: 'android'),
      store: storePhone,
      onlineWindow: const Duration(seconds: 3),
      visibleWindow: const Duration(seconds: 3),
      heartbeatInterval: const Duration(seconds: 2),
      connectTimeout: const Duration(milliseconds: 300),
    );

    try {
      await pc.start();
      await phone.start();

      final session = pc.beginPairing();
      final paired = await phone.pairWith(
        address: '127.0.0.1',
        port: pc.port,
        code: session.code,
      );
      expect(paired.ok, isTrue, reason: paired.error);

      // The desktop assistant, wired to its real mesh exactly like the view.
      final service = CommandService(
        devices: () => [
          for (final d in pc.pairedDevices)
            AgentDeviceSnapshot(
              id: d.id,
              name: d.name,
              online: pc.isOnline(d.id),
              capabilities: defaultCapabilitiesFor(d.platform),
            ),
        ],
        local: AgentDeviceSnapshot(
          id: 'pc-1',
          name: 'My PC',
          online: true,
          capabilities: defaultCapabilitiesFor('linux'),
        ),
      );
      service.execute('remember that mom is 0612345678');

      // A plain call is offered, never echoed as a call this PC can't make.
      final offer = service.execute('call mom');
      expect(offer.status, AgentResultStatus.needsInfo);
      final question = offer.dispatch! as AgentClarification;
      expect(question.question, contains('My Phone'));

      // Agreeing produces an approved plan aimed at the phone.
      final agreed = service.execute('yes', answerTo: question.key);
      expect(agreed.status, AgentResultStatus.succeeded);
      final plan = agreed.dispatch! as AgentActionPlan;
      expect(plan.request.target, 'phone-1');
      expect(plan.request.arguments, containsPair('number', '0612345678'));

      // Send it over the real mesh; the phone re-gates and executes.
      final replyFuture = pc.sendAgentRequest('phone-1', plan.request);
      await _waitFor(() {
        final raw = phone.lastIncomingAgentRequest;
        final req = raw?['request'];
        return req is AgentRequest && req.requestId == plan.request.requestId;
      });

      final recorder = _DialRecorder();
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final executor = DeviceExecutor(phoneBackend: recorder);
      final incoming = phone.lastIncomingAgentRequest!;
      final req = incoming['request'] as AgentRequest;
      final outcome = await executor.run(req);
      debugDefaultTargetPlatformOverride = null;
      final result = AgentDispatchResult(
        status: outcome.ok
            ? AgentResultStatus.succeeded
            : AgentResultStatus.unavailable,
        message: outcome.message,
        dispatch: outcome.ok ? AgentMessage(outcome.message) : null,
      );
      await phone.sendAgentResult('pc-1', req.requestId, result);

      // The PC's thread shows the phone's real outcome.
      final reply = await replyFuture;
      expect(reply, isNotNull);
      expect(reply!.status, AgentResultStatus.succeeded);
      expect((reply.dispatch! as AgentMessage).text, 'Calling.');
      // The taught number travelled end to end — no address-book lookup.
      expect(recorder.names, ['mom']);
      expect(recorder.dialed, ['0612345678']);

      // The choice is remembered: the next call skips the question entirely.
      final again = service.execute('call mom');
      expect(again.status, AgentResultStatus.succeeded);
      final againPlan = again.dispatch! as AgentActionPlan;
      expect(againPlan.request.target, 'phone-1');
    } finally {
      await pc.stop();
      await phone.stop();
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    }
  });
}
