// The distributed brain (Phase 5), proven over two real paired mesh
// devices: the phone's brain tries its tiny on-device model first and
// escalates over the mesh to the PC's stronger brain. Real sockets, real
// pairing, real handoff — the only fakes are the models themselves (no
// Ollama, no on-device inference, no mic in this environment).
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/brain.dart';
import 'package:nexus/core/distributed_brain.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/core/tiny_brain.dart';
import 'package:nexus/mesh/mesh_service.dart';

/// A clipboard that lives in memory — no platform channels needed in tests.
class _FakeClipboard implements ClipboardBackend {
  String? value;
  @override
  Future<String?> readText() async => value;
  @override
  Future<void> writeText(String text) async => value = text;
}

/// The on-device model: a fixed answer (or none) with a fixed confidence.
class _FakeTinyBrain extends TinyBrain {
  _FakeTinyBrain({this.answer});
  final TinyAnswer? answer;
  int askCalls = 0;

  @override
  Future<String?> modelName() async => 'phi3:mini';

  @override
  Future<TinyAnswer?> ask({
    required String system,
    required List<ChatTurn> history,
  }) async {
    askCalls++;
    return answer;
  }
}

/// The PC's strong brain: answers instantly and records everything it was
/// given, so the handoff payload is provably intact.
class _FakePeerBrain extends LocalBrain {
  String replyText = 'pc answer';
  bool reachable = true;
  String? lastSystem;
  List<ChatTurn>? lastHistory;
  int replyCalls = 0;

  @override
  Future<String?> availableModel({bool refresh = false}) async =>
      'llama3.2:3b';

  @override
  Future<BrainReply> reply({
    required String system,
    required List<ChatTurn> history,
    double temperature = 0.7,
    int maxTokens = 300,
  }) {
    replyCalls++;
    lastSystem = system;
    lastHistory = history;
    return Future.value((text: replyText, reachable: reachable));
  }
}

/// The PC's brain when it never answers — for proving the handoff timeout.
class _SilentPeerBrain extends LocalBrain {
  @override
  Future<String?> availableModel({bool refresh = false}) async =>
      'llama3.2:3b';

  @override
  Future<BrainReply> reply({
    required String system,
    required List<ChatTurn> history,
    double temperature = 0.7,
    int maxTokens = 300,
  }) => Completer<BrainReply>().future;
}

const _system = 'You are Nexus, a personal assistant on Sam\'s devices.';
const _history = [
  (role: 'user', content: 'what is the meaning of life'),
  (role: 'assistant', content: 'forty-two, roughly'),
];

void main() {
  /// Two real paired mesh services: a PC that answers brain asks, and a
  /// phone that escalates to it. Returns them plus the PC's brain.
  Future<(MeshService, MeshService, LocalBrain)> pair({
    LocalBrain? peerBrain,
    bool peerHasBrain = true,
  }) async {
    final tmp = await Directory.systemTemp.createTemp('brain_mesh');
    final storeA = NexusStore(explicitPath: '${tmp.path}/a.json')
      ..port = 53230
      ..clipboardSync = true;
    final storeB = NexusStore(explicitPath: '${tmp.path}/b.json')
      ..port = 53231
      ..clipboardSync = true;
    await storeA.save();
    await storeB.save();
    final brain = peerBrain ?? _FakePeerBrain();
    final meshA = MeshService(
      identity: DeviceInfo(id: 'brain-pc', name: 'Brain PC', platform: 'linux'),
      store: storeA,
      clipboard: _FakeClipboard(),
      onlineWindow: const Duration(seconds: 3),
      visibleWindow: const Duration(seconds: 3),
      heartbeatInterval: const Duration(seconds: 2),
      connectTimeout: const Duration(milliseconds: 300),
    );
    if (peerHasBrain) meshA.brain = brain;
    final meshB = MeshService(
      identity: DeviceInfo(
        id: 'brain-phone',
        name: 'Brain Phone',
        platform: 'android',
      ),
      store: storeB,
      clipboard: _FakeClipboard(),
      onlineWindow: const Duration(seconds: 3),
      visibleWindow: const Duration(seconds: 3),
      heartbeatInterval: const Duration(seconds: 2),
      connectTimeout: const Duration(milliseconds: 300),
    );
    try {
      await meshA.start();
      await meshB.start();
      final session = meshA.beginPairing();
      final result = await meshB.pairWith(
        address: '127.0.0.1',
        port: meshA.port,
        code: session.code,
      );
      expect(result.ok, isTrue, reason: result.error);
      // The brain capability travels in heartbeat pings — wait for it to
      // reach the phone before testing the handoff (only when the PC
      // actually has a brain to advertise).
      if (peerHasBrain) {
        for (var i = 0; i < 50 && !meshB.peerHasBrain('brain-pc'); i++) {
          await Future.delayed(const Duration(milliseconds: 200));
        }
        expect(meshB.peerHasBrain('brain-pc'), isTrue,
            reason: 'the PC should advertise its brain after pairing');
      }
      addTearDown(() async {
        await meshA.stop();
        await meshB.stop();
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      return (meshA, meshB, brain);
    } catch (_) {
      await meshA.stop();
      await meshB.stop();
      rethrow;
    }
  }

  test('mesh handoff: the PC\'s brain answers a delegated question intact',
      () async {
    final (pc, phone, peer) = await pair();
    final peerBrain = peer as _FakePeerBrain;
    final brain = DistributedBrain(
      mesh: phone,
      handoffTimeout: const Duration(seconds: 5),
    );

    expect(await brain.availableModel(), 'mesh:brain-pc');
    final reply = await brain.reply(system: _system, history: _history);

    expect(reply.text, 'pc answer');
    expect(reply.reachable, isTrue);
    // The question arrived at the PC's brain exactly as the phone asked it.
    expect(peerBrain.replyCalls, 1);
    expect(peerBrain.lastSystem, _system);
    expect(peerBrain.lastHistory, _history);
  });

  test('the tiny model answers everyday questions without touching the mesh',
      () async {
    final (pc, phone, peer) = await pair();
    final peerBrain = peer as _FakePeerBrain;
    final tiny = _FakeTinyBrain(
      answer: const TinyAnswer(text: 'tiny answer', confidence: 0.95),
    );
    final brain = DistributedBrain(
      mesh: phone,
      tiny: tiny,
      handoffTimeout: const Duration(seconds: 5),
    );

    final reply = await brain.reply(system: _system, history: _history);

    expect(reply.text, 'tiny answer');
    expect(reply.reachable, isTrue);
    expect(tiny.askCalls, 1);
    expect(peerBrain.replyCalls, 0); // the mesh was never used
    expect(await brain.availableModel(), 'phi3:mini'); // a local model exists
  });

  test('an unsure tiny answer escalates to the PC', () async {
    final (pc, phone, peer) = await pair();
    final peerBrain = peer as _FakePeerBrain;
    final tiny = _FakeTinyBrain(
      answer: const TinyAnswer(text: 'maybe?', confidence: 0.4),
    );
    final brain = DistributedBrain(
      mesh: phone,
      tiny: tiny,
      handoffTimeout: const Duration(seconds: 5),
    );

    final reply = await brain.reply(system: _system, history: _history);

    expect(reply.text, 'pc answer'); // the stronger brain's word wins
    expect(peerBrain.replyCalls, 1);
  });

  test('a phone without a tiny model goes straight to the PC', () async {
    final (pc, phone, peer) = await pair();
    final peerBrain = peer as _FakePeerBrain;
    final brain = DistributedBrain(mesh: phone, handoffTimeout: const Duration(seconds: 5));

    final reply = await brain.reply(system: _system, history: _history);

    expect(reply.text, 'pc answer');
    expect(peerBrain.replyCalls, 1);
  });

  test('every brain down → honest null, never a fake answer', () async {
    final (pc, phone, peer) = await pair();
    final peerBrain = peer as _FakePeerBrain;
    peerBrain.replyText = '';
    peerBrain.reachable = false;
    final brain = DistributedBrain(mesh: phone, handoffTimeout: const Duration(seconds: 5));

    final reply = await brain.reply(system: _system, history: _history);

    expect(reply.text, isNull);
    expect(reply.reachable, isFalse); // the engine falls back to the teach card
  });

  test('a silent peer times out into an honest null', () async {
    final (pc, phone, peerBrain) = await pair(
      peerBrain: _SilentPeerBrain(),
    );
    final brain = DistributedBrain(
      mesh: phone,
      handoffTimeout: const Duration(milliseconds: 300),
    );

    final reply = await brain.reply(system: _system, history: _history);

    expect(reply.text, isNull);
    expect(reply.reachable, isFalse);
  });

  test('no paired brain at all → honest offline, refused fast', () async {
    final (pc, phone, peer) = await pair(peerHasBrain: false);
    final peerBrain = peer as _FakePeerBrain;
    final brain = DistributedBrain(
      mesh: phone,
      handoffTimeout: const Duration(seconds: 5),
    );

    // No model anywhere: the brain reports offline, so the engine never
    // even tries a doomed conversation.
    expect(await brain.availableModel(), isNull);
    final reply = await brain.reply(system: _system, history: _history);
    expect(reply.text, isNull);
    expect(reply.reachable, isFalse);
    expect(peerBrain.replyCalls, 0);

    // And a direct ask to a brainless peer is refused immediately — the
    // reply is a non-null BrainReply with no text, NOT a timeout.
    final direct = await phone.requestBrainAnswer(
      'brain-pc',
      system: _system,
      history: _history,
      timeout: const Duration(seconds: 5),
    );
    expect(direct, isNotNull);
    expect(direct!.text, isNull);
    expect(direct.reachable, isFalse);
  });

  test('a brain-capable peer advertises; a brainless one does not', () async {
    final (pc, phone, peerBrain) = await pair(peerHasBrain: false);
    expect(phone.peerHasBrain('brain-pc'), isFalse);
    expect(phone.brainPeerIds, isEmpty);
  });
}