// Synced settings, over the mesh.
//
// The frame carries a key and a value, and everything that keeps it safe is
// here: only a whitelisted key is adopted, a value of the wrong shape is
// refused, an older value loses to the one this device already holds, and what
// is adopted is never sent on — that silence is what stops two devices from
// bouncing one change between them forever.
//
// The security half is the point of the file. A frame may name pairing, file
// sharing, clipboard sync, the agent policy or the wake word; every one of them
// must land on the floor, because those are permissions, and a permission that
// a peer can set is not a permission.
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/protocol.dart';
import 'package:nexus/core/shared_settings.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/core/system_prompt.dart';
import 'package:nexus/mesh/mesh_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A mesh whose system prompt is the test's own instance: two meshes in one
/// process would otherwise share the process-wide singleton, and "A sent it to
/// B" would be indistinguishable from "B sent it to itself".
class _Mesh extends MeshService {
  _Mesh({required super.identity, required super.store, required this.prompt})
    : super(
        heartbeatInterval: const Duration(seconds: 2),
        connectTimeout: const Duration(milliseconds: 300),
      );

  final SystemPrompt prompt;

  @override
  SystemPrompt get syncedSystemPrompt => prompt;
}

/// Waits for [cond], or gives up — used instead of a fixed sleep so a fast
/// machine does not pay for a slow one.
Future<void> _waitFor(bool Function() cond) async {
  for (var i = 0; i < 50 && !cond(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

/// The frame a peer would send, built here rather than by the code under test,
/// so a test can say what a *hostile* peer sends.
NexusMessage _frame(
  String key,
  Object? value, {
  String from = 'device-a',
  int ts = 0,
}) => NexusMessage(
  type: NexusMessage.agentSetting,
  from: from,
  to: 'device-b',
  payload: <String, dynamic>{'key': key, 'value': value},
  id: 'frame-$key-$ts',
  ts: ts == 0 ? DateTime.now().millisecondsSinceEpoch : ts,
);

void main() {
  late Directory tmp;
  late NexusStore storeA;
  late NexusStore storeB;
  late _Mesh meshA;
  late _Mesh meshB;
  late SystemPrompt promptA;
  late SystemPrompt promptB;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SystemPrompt.debugReset();
    tmp = await Directory.systemTemp.createTemp('nexus_setting_sync');
    storeA = NexusStore(explicitPath: '${tmp.path}/a.json')
      ..port = 53320
      ..pairingEnabled = true;
    storeB = NexusStore(explicitPath: '${tmp.path}/b.json')
      ..port = 53321
      ..pairingEnabled = true;
    await storeA.save();
    await storeB.save();
    promptA = SystemPrompt(initial: 'A only');
    promptB = SystemPrompt(initial: 'B only');
    meshA = _Mesh(
      identity: DeviceInfo(
        id: 'device-a',
        name: 'Rehearsal PC',
        platform: 'linux',
      ),
      store: storeA,
      prompt: promptA,
    );
    meshB = _Mesh(
      identity: DeviceInfo(id: 'device-b', name: 'Kit', platform: 'linux'),
      store: storeB,
      prompt: promptB,
    );
    await meshA.start();
    await meshB.start();
    final PairingSession session = meshA.beginPairing();
    final PairResult result = await meshB.pairWith(
      address: '127.0.0.1',
      port: meshA.port,
      code: session.code,
    );
    expect(result.ok, isTrue, reason: result.error);
  });

  tearDown(() async {
    await meshA.stop();
    await meshB.stop();
    SystemPrompt.debugReset();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  group('a shared setting travels', () {
    test('the receiver adopts it, and is told where it came from', () async {
      expect(storeB.alwaysMerge, isTrue); // the shipped default
      await meshA.broadcastSetting(SharedSetting.alwaysMerge, false);

      await _waitFor(() => storeB.alwaysMerge == false);
      expect(storeB.alwaysMerge, isFalse, reason: 'B never adopted it');
      final AdoptedSetting? adopted = meshB.lastAdoptedSetting;
      expect(adopted?.setting, SharedSetting.alwaysMerge);
      expect(adopted?.value, isFalse);
      expect(adopted?.previous, isTrue, reason: 'what Undo puts back');
      expect(adopted?.fromName, 'Rehearsal PC');
    });

    test('a system prompt arrives on the other device', () async {
      await meshA.broadcastSetting(
        SharedSetting.systemPrompt,
        'Answer in French',
      );

      await _waitFor(() => promptB.text == 'Answer in French');
      expect(promptB.text, 'Answer in French');
      expect(
        promptA.text,
        'A only',
        reason: 'the sender is not its own reader',
      );
    });

    test('undo puts back what was replaced, and only here', () async {
      await meshA.broadcastSetting(SharedSetting.systemPrompt, 'from A');
      await _waitFor(() => promptB.text == 'from A');

      await meshB.undoAdoptedSetting();
      expect(promptB.text, 'B only');
      expect(
        promptA.text,
        'A only',
        reason: 'Undo is local, not a counter-send',
      );
      expect(meshB.lastAdoptedSetting, isNull);
    });

    test('what is adopted is never sent on — one change, one hop', () async {
      // The UI writes locally first, then broadcasts; a test that only sent
      // would be asserting about a value its own sender never held.
      storeA.alwaysMerge = false;
      await storeA.save();
      await meshA.broadcastSetting(SharedSetting.alwaysMerge, false);
      await _waitFor(() => storeB.alwaysMerge == false);

      // Long enough for a loop to come back twice over.
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(
        meshA.lastAdoptedSetting,
        isNull,
        reason: 'B re-broadcast what it adopted, so A adopted its own change',
      );
      expect(storeA.alwaysMerge, isFalse);
      expect(storeB.alwaysMerge, isFalse);
    });

    test('an older value loses to the one this device already holds', () async {
      final int old = DateTime.now()
          .subtract(const Duration(minutes: 5))
          .millisecondsSinceEpoch;
      storeB.alwaysMerge = false;
      await storeB.save();
      await meshB.broadcastSetting(SharedSetting.alwaysMerge, false);
      await _waitFor(() => storeA.alwaysMerge == false);
      // The adoption above put a notice up; this test is about the *next*
      // frame, so the notice starts clean.
      meshA.dismissAdoptedSetting();

      // A frame that was in flight before that change: same key, older stamp.
      await meshA.debugDeliverSetting(_frame('alwaysMerge', true, ts: old));

      expect(storeA.alwaysMerge, isFalse, reason: 'the late frame won');
      expect(
        meshA.lastAdoptedSetting,
        isNull,
        reason: 'an old frame is not news',
      );
    });
  });

  group('a key that is not shared is refused', () {
    // The five the audit named, plus the two shapes a hostile peer might try:
    // a key that is merely misspelled, and a key with the right name carrying
    // the wrong type.
    test(
      'pairing, file sharing, clipboard sync, agent policy and wake word',
      () async {
        final Map<String, Object?> hostile = <String, Object?>{
          'pairingEnabled': true,
          'fileShare': true,
          'clipboardSync': true,
          'wakeWord': true,
          'agentPolicy': 'auto',
          // Not a setting at all, and a right-shaped key with a wrong-shaped
          // value: both must be dropped by the same two checks.
          'port': 1234,
          'alwaysMerge': 'yes please',
        };
        // Pairing had to be on for these two to meet; from here on it is the
        // user's switch, and the frame below is trying to flip it.
        storeB.pairingEnabled = false;
        await storeB.save();

        for (final MapEntry<String, Object?> entry in hostile.entries) {
          await meshB.debugDeliverSetting(
            _frame(entry.key, entry.value, from: meshA.identity.id),
          );
        }

        expect(
          storeB.pairingEnabled,
          isFalse,
          reason: 'a peer may not let itself in',
        );
        expect(
          storeB.fileShare,
          isFalse,
          reason: 'a peer may not read this disk',
        );
        expect(
          storeB.clipboardSync,
          isFalse,
          reason: 'a peer may not turn on copying',
        );
        expect(
          storeB.wakeWord,
          isFalse,
          reason: 'a peer may not open the microphone',
        );
        expect(storeB.agentPolicy('media.play'), AgentPolicy.ask);
        expect(storeB.port, 53321, reason: 'a peer may not move the listener');
        expect(storeB.alwaysMerge, isTrue, reason: 'a string is not a bool');
        expect(meshB.lastAdoptedSetting, isNull);
      },
    );

    test('and nothing was written to the store for those keys', () async {
      await meshB.debugDeliverSetting(
        _frame('fileShare', true, from: meshA.identity.id),
      );
      // The stamp table is how "last write wins" is decided, so a refused key
      // leaving a stamp behind would be a refused key that still moved state.
      expect(storeB.settingStamp('fileShare'), 0);
      expect(storeB.settingScope('fileShare'), isNull);
    });

    test('the whitelist is exactly the shared settings', () {
      expect(SharedSetting.byKey('systemPrompt'), SharedSetting.systemPrompt);
      expect(SharedSetting.byKey('alwaysMerge'), SharedSetting.alwaysMerge);
      for (final String key in const <String>[
        'pairingEnabled',
        'fileShare',
        'clipboardSync',
        'wakeWord',
        'locationShare',
        'notificationShare',
        'agentPolicy',
        'port',
        'gatewayToken',
      ]) {
        expect(
          SharedSetting.byKey(key),
          isNull,
          reason: '$key must not be shared',
        );
      }
    });
  });

  group('what an older build sees', () {
    test('the new frame is a new type, and the old ones are untouched', () {
      // Additive, in both directions: a build without `agent.setting` has no
      // case for it, so it falls through the relay's switch and does nothing —
      // and nothing about the frames it *does* know changed.
      const Set<String> before = <String>{
        NexusMessage.ping,
        NexusMessage.pong,
        NexusMessage.pairRequest,
        NexusMessage.pairAccept,
        NexusMessage.pairReject,
        NexusMessage.clipboard,
        NexusMessage.clipboardAck,
        NexusMessage.agentLearned,
        NexusMessage.agentFact,
        NexusMessage.agentReminder,
        NexusMessage.agentDefault,
        NexusMessage.agentProfile,
        NexusMessage.brainAsk,
        NexusMessage.brainAnswer,
      };
      expect(before.contains(NexusMessage.agentSetting), isFalse);

      // The old frames still encode and decode exactly as they did.
      for (final String type in before) {
        final NexusMessage msg = NexusMessage(
          type: type,
          from: 'device-a',
          payload: const <String, dynamic>{'k': 'v'},
          id: 'i',
          ts: 7,
        );
        final NexusMessage back = NexusMessage.fromJson(msg.toJson());
        expect(back.type, type);
        expect(back.payload, const <String, dynamic>{'k': 'v'});
        expect(back.ts, 7);
      }
    });

    test('the new frame itself round trips, so a newer peer is understood', () {
      final NexusMessage msg = _frame('systemPrompt', 'hello', ts: 1234);
      final NexusMessage back = NexusMessage.fromJson(msg.toJson());
      expect(back.type, NexusMessage.agentSetting);
      expect(back.payload['key'], 'systemPrompt');
      expect(back.payload['value'], 'hello');
      expect(back.ts, 1234);
      debugPrint('frame: ${msg.toString()}');
    });
  });
}
