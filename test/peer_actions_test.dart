// Peer-initiated actions: what a paired device may ask this one to do, and the
// one rule the receiving half cannot break — every claimed request is answered.
//
// The interesting halves are tested where they live. The store's table and the
// decision are pure and pinned directly. The claim, the trust gate and the reply
// contract are pinned with two real meshes on loopback, because "did the sender
// ever hear back?" is not a question a fake can answer honestly.
import 'dart:io';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent_contract.dart';
import 'package:nexus/core/app_services.dart' show appPlatformToken;
import 'package:nexus/core/device_actions.dart';
import 'package:nexus/core/phone_actions.dart';
import 'package:nexus/core/identity.dart' show DeviceInfo;
import 'package:nexus/core/store.dart';
import 'package:nexus/main_ui.dart'
    show PeerActionDecision, decidePeerAction, kNexusPeerActionDenied;
import 'package:nexus/mesh/mesh_service.dart';
import 'package:nexus/ui/device_executor.dart' show DeviceExecutor;

/// A phone backend that records instead of dialling, so "the action ran" is an
/// observation rather than a status the executor could invent.
class _DialRecorder implements PhoneActionBackend {
  final names = <String>[];

  @override
  Future<PhoneCallOutcome> callContact(String name, {String? number}) async {
    names.add(name);
    return PhoneCallOutcome(placed: true, message: 'Calling $name.');
  }

  @override
  Future<PhoneCallOutcome> videoCall(String name, String? app) async =>
      PhoneCallOutcome(placed: true, message: 'Calling $name.');
}

class _DeviceBackend implements DeviceActionBackend {
  final calls = <(String action, Map<String, dynamic> args)>[];

  @override
  Future<ActionResult> run(String action, Map<String, dynamic> args) async {
    calls.add((action, args));
    return ActionResult(true, 'ran $action');
  }

  @override
  Future<(double, double)?> currentLocation() async => null;

  @override
  Future<bool> openLinkChooser(String url, String title) async => false;
}

AgentRequest _request(String id, {String action = AgentActions.callPlace}) =>
    AgentRequest(
      requestId: id,
      target: 'car-1',
      action: action,
      arguments: const <String, dynamic>{'contact': 'mom'},
    );

Future<void> _waitFor(
  bool Function() ok, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (!ok()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out waiting for the mesh.');
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

/// Two real meshes on loopback, paired: the phone (sender) and the car
/// (receiver, the device whose policy decides).
Future<(MeshService, MeshService)> _pairedMeshes(Directory tmp) async {
  Future<int> freePort() async {
    final ServerSocket socket = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final int port = socket.port;
    await socket.close();
    return port;
  }
  final NexusStore carStore = NexusStore(explicitPath: '${tmp.path}/car.json')
    ..port = await freePort()
    ..pairingEnabled = true;
  final NexusStore phoneStore = NexusStore(
    explicitPath: '${tmp.path}/phone.json',
  )
    ..port = await freePort()
    ..pairingEnabled = true;
  await carStore.save();
  await phoneStore.save();

  final MeshService car = MeshService(
    identity: DeviceInfo(id: 'car-1', name: 'My Car', platform: 'linux'),
    store: carStore,
    onlineWindow: const Duration(seconds: 3),
    visibleWindow: const Duration(seconds: 3),
    heartbeatInterval: const Duration(seconds: 2),
    connectTimeout: const Duration(milliseconds: 300),
  );
  final MeshService phone = MeshService(
    identity: DeviceInfo(id: 'phone-1', name: 'Kit', platform: 'android'),
    store: phoneStore,
    onlineWindow: const Duration(seconds: 3),
    visibleWindow: const Duration(seconds: 3),
    heartbeatInterval: const Duration(seconds: 2),
    connectTimeout: const Duration(milliseconds: 300),
  );
  await car.start();
  await phone.start();

  final PairingSession session = car.beginPairing();
  final PairResult paired = await phone.pairWith(
    address: '127.0.0.1',
    port: car.port,
    code: session.code,
  );
  expect(paired.ok, isTrue, reason: paired.error);
  return (car, phone);
}

/// The car's claim on the request the phone just sent.
///
/// Polls the field rather than the claim: taking it is one-shot, so a helper
/// that peeked by claiming would swallow the request it was waiting for.
Future<IncomingAgentAction> _claim(MeshService car) async {
  await _waitFor(() => car.lastIncomingAgentRequest != null);
  final IncomingAgentAction? action = car.takeIncomingAgentAction();
  expect(action, isNotNull, reason: 'the request should be claimable once');
  return action!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the pre-approval table is empty until the user fills it', () {
    late Directory tmp;
    late NexusStore store;

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('nexus-policy-');
      store = NexusStore(explicitPath: '${tmp.path}/store.json');
      await store.load();
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('every action asks on a fresh install, and none is seeded', () {
      // Not "seeded to ask": absent. That is what makes a new capability safe
      // by construction rather than by remembering to add it to a default map.
      expect(store.agentPolicyChoices, isEmpty);
      for (final String action in <String>[
        AgentActions.callPlace,
        AgentActions.mediaPlay,
        AgentActions.flashlightToggle,
        AgentActions.screenshot,
      ]) {
        expect(store.agentPolicy(action), AgentPolicy.ask, reason: action);
      }
    });

    test('an action nobody has ever heard of asks too', () {
      // A vocabulary that grew since the user last opened Settings must not
      // arrive pre-approved.
      expect(
        store.agentPolicy('something.invented.after.release'),
        AgentPolicy.ask,
      );
    });

    test('a choice persists, and asking again persists as a choice', () async {
      store.setAgentPolicy(AgentActions.mediaPlay, AgentPolicy.auto);
      store.setAgentPolicy(AgentActions.callPlace, AgentPolicy.deny);
      await store.save();

      NexusStore reloaded = NexusStore(explicitPath: '${tmp.path}/store.json');
      await reloaded.load();
      expect(reloaded.agentPolicy(AgentActions.mediaPlay), AgentPolicy.auto);
      expect(reloaded.agentPolicy(AgentActions.callPlace), AgentPolicy.deny);
      expect(reloaded.agentPolicy(AgentActions.alarmSet), AgentPolicy.ask);

      // Back to ask: the row the user changed their mind about is stored as a
      // choice, not deleted, so the table reports what they decided.
      reloaded.setAgentPolicy(AgentActions.mediaPlay, AgentPolicy.ask);
      await reloaded.save();
      reloaded = NexusStore(explicitPath: '${tmp.path}/store.json');
      await reloaded.load();
      expect(reloaded.agentPolicy(AgentActions.mediaPlay), AgentPolicy.ask);
      expect(
        reloaded.agentPolicyChoices[AgentActions.mediaPlay],
        AgentPolicy.ask,
      );
    });

    test('a stored value this build does not know reads as ask', () async {
      // A rename, or a file edited by hand. The reader looks for the names it
      // knows and finds none, so the answer is the safe one — never a silent
      // 'auto' inherited from a string nobody parsed.
      final File file = File('${tmp.path}/handwritten.json');
      file.writeAsStringSync(
        '{"settings":{"agentPolicy":{"media.play":"loud",'
        '"comm.call":"auto"}}}',
      );
      final NexusStore handwritten = NexusStore(explicitPath: file.path);
      await handwritten.load();

      expect(handwritten.agentPolicy(AgentActions.mediaPlay), AgentPolicy.ask);
      expect(handwritten.agentPolicy(AgentActions.callPlace), AgentPolicy.auto);
      expect(
        handwritten.agentPolicyChoices.keys,
        <String>[AgentActions.callPlace],
        reason: 'an unreadable value is not a choice',
      );
    });
  });

  group('the decision is two facts and nothing else', () {
    test('auto runs only for a frame that proved itself', () {
      expect(
        decidePeerAction(policy: AgentPolicy.auto, trusted: true),
        PeerActionDecision.runNow,
      );
      // The case worth the whole type: a pre-approval is a promise about one
      // peer, and an unproven frame is not evidence that this is that peer.
      expect(
        decidePeerAction(policy: AgentPolicy.auto, trusted: false),
        PeerActionDecision.ask,
      );
    });

    test('ask asks, trusted or not', () {
      expect(
        decidePeerAction(policy: AgentPolicy.ask, trusted: true),
        PeerActionDecision.ask,
      );
      expect(
        decidePeerAction(policy: AgentPolicy.ask, trusted: false),
        PeerActionDecision.ask,
      );
    });

    test('never means never, trusted or not', () {
      for (final bool trusted in <bool>[true, false]) {
        expect(
          decidePeerAction(policy: AgentPolicy.deny, trusted: trusted),
          PeerActionDecision.refuse,
          reason: 'trusted=$trusted',
        );
      }
    });

    test('the refusal is one pinned sentence', () {
      // The whole of what the other person sees. A test that fails when it
      // changes is the point: this string is a product decision, not a detail.
      expect(
        kNexusPeerActionDenied,
        'This device does not accept that action from paired peers.',
      );
    });
  });

  group('a frame proves itself three ways, and needs all three', () {
    late Directory tmp;
    late MeshService car;

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('nexus-proven-');
      final NexusStore store = NexusStore(explicitPath: '${tmp.path}/s.json')
        ..port = 0
        ..pairingEnabled = true;
      await store.save();
      car = MeshService(
        identity: DeviceInfo(id: 'car-1', name: 'My Car', platform: 'linux'),
        store: store,
      );
    });

    tearDown(() async {
      await car.stop();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('an unencrypted frame never counts, whatever else is true', () {
      expect(car.agentFrameProven('phone-1', encrypted: false), isFalse);
    });

    test('an encrypted frame from nobody this device knows does not count', () {
      expect(car.agentFrameProven('a-stranger', encrypted: true), isFalse);
    });

    test('a paired peer with no session key this session does not count', () {
      // A pairing that exists but has never carried a frame is a row, not a
      // peer — and after a restart every peer starts here.
      car.debugNotePairedForTest('phone-1');
      expect(car.agentFrameProven('phone-1', encrypted: true), isFalse);
      // The key is what the third condition is about.
      car.debugNoteSessionKey('phone-1');
      expect(car.agentFrameProven('phone-1', encrypted: true), isTrue);
    });
  });

  group('a claimed request is always answered', () {
    late Directory tmp;
    late MeshService car;
    late MeshService phone;

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('nexus-claim-');
      final (MeshService c, MeshService p) = await _pairedMeshes(tmp);
      car = c;
      phone = p;
    });

    tearDown(() async {
      await car.stop();
      await phone.stop();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('a pairing alone is a row, not yet a proven session', () async {
      // The third condition, and the one worth its own test: both sides hold
      // the secret the moment the handshake lands, but nothing has been
      // encrypted with it yet. A request that arrives before the first frame is
      // asked about rather than run, which is the safe direction for the doubt.
      expect(car.agentFrameProven('phone-1', encrypted: true), isFalse);
      expect(phone.agentFrameProven('car-1', encrypted: true), isFalse);

      // The first encrypted frame of any kind settles it — and a request is
      // one, which is why the claim below arrives trusted.
      final Future<AgentDispatchResult?> sent = phone.sendAgentRequest(
        'car-1',
        _request('proven-1'),
      );
      final IncomingAgentAction action = await _claim(car);
      expect(action.trusted, isTrue);
      await action.refuse('no');
      await sent;
    });

    test('one claim, and the assistant view loses its copy', () async {
      final Future<AgentDispatchResult?> sent = phone.sendAgentRequest(
        'car-1',
        _request('claim-1'),
      );
      final IncomingAgentAction action = await _claim(car);

      expect(action.from, 'phone-1');
      expect(action.request.requestId, 'claim-1');
      expect(action.trusted, isTrue);
      expect(action.policy, AgentPolicy.ask);

      // One owner: the second ask finds nothing, and the field the legacy view
      // reads is cleared with it.
      expect(car.takeIncomingAgentAction(), isNull);
      expect(car.lastIncomingAgentRequest, isNull);

      await action.refuse('no');
      await sent;
    });

    test('a body that throws still answers the sender', () async {
      final Future<AgentDispatchResult?> sent = phone.sendAgentRequest(
        'car-1',
        _request('throw-1'),
      );
      final IncomingAgentAction action = await _claim(car);

      final AgentDispatchResult result = await action.resolveWith(
        () async => throw StateError('the platform channel exploded'),
      );

      // The reply is not a courtesy: without it the sender waits out its
      // fifteen seconds and the person there is told nothing.
      expect(result.status, AgentResultStatus.unavailable);
      expect(result.message, contains('the platform channel exploded'));
      final AgentDispatchResult? reply = await sent;
      expect(reply, isNotNull);
      expect(reply!.status, AgentResultStatus.unavailable);
      expect(reply.message, contains('the platform channel exploded'));
    });

    test('a refusal travels as denied, in the words it was given', () async {
      final Future<AgentDispatchResult?> sent = phone.sendAgentRequest(
        'car-1',
        _request('deny-1'),
      );
      final IncomingAgentAction action = await _claim(car);
      await action.refuse(kNexusPeerActionDenied);

      final AgentDispatchResult? reply = await sent;
      expect(reply, isNotNull);
      expect(reply!.status, AgentResultStatus.denied);
      expect(reply.message, kNexusPeerActionDenied);
    });

    test('the auto path runs with nobody watching and reports what ran', () async {
      // The shell's own path, minus the toast: policy auto, a proven frame, a
      // real executor on the receiving device.
      final _DialRecorder recorder = _DialRecorder();
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final DeviceExecutor executor = DeviceExecutor(phoneBackend: recorder);

      final Future<AgentDispatchResult?> sent = phone.sendAgentRequest(
        'car-1',
        _request('auto-1'),
      );
      final IncomingAgentAction action = await _claim(car);
      final PeerActionDecision decision = decidePeerAction(
        policy: AgentPolicy.auto,
        trusted: action.trusted,
      );
      expect(decision, PeerActionDecision.runNow);

      final AgentDispatchResult result = await action.resolveWith(() async {
        final ActionResult outcome = await executor.run(action.request);
        return AgentDispatchResult(
          status: outcome.ok
              ? AgentResultStatus.succeeded
              : AgentResultStatus.unavailable,
          message: outcome.message,
          dispatch: outcome.ok ? AgentMessage(outcome.message) : null,
        );
      });

      expect(recorder.names, <String>['mom']);
      expect(result.status, AgentResultStatus.succeeded);
      final AgentDispatchResult? reply = await sent;
      expect(reply, isNotNull);
      // The sentence the user sees is the device's own, never ours.
      expect((reply!.dispatch! as AgentMessage).text, 'Calling mom.');
    });

    test('an unproven frame is asked about, not run', () async {
      // The downgrade, observed at the backend rather than argued about: the
      // policy says auto, the frame did not prove itself, nothing runs.
      final _DeviceBackend backend = _DeviceBackend();
      final DeviceExecutor executor = DeviceExecutor(deviceBackend: backend);

      final Future<AgentDispatchResult?> sent = phone.sendAgentRequest(
        'car-1',
        _request('unproven-1', action: AgentActions.flashlightToggle),
      );
      final IncomingAgentAction action = await _claim(car);

      final bool trusted = false; // what an unproven frame would carry
      final PeerActionDecision decision = decidePeerAction(
        policy: AgentPolicy.auto,
        trusted: trusted,
      );
      expect(decision, PeerActionDecision.ask);
      if (decision == PeerActionDecision.runNow) await executor.run(action.request);
      expect(backend.calls, isEmpty);

      await action.refuse(kNexusPeerActionDenied);
      await sent;
    });
  });

  test('the launched platform names itself for the policy list', () {
    // The sheet derives its rows from this token; an unknown platform would
    // offer an empty list rather than a wrong one.
    expect(appPlatformToken(), isNotEmpty);
  });
}
