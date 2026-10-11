// A re-pair must actually change the key on the wire.
//
// Pairing mints a shared secret, and the session key is derived from it — but
// the derived key is cached per peer id for the life of the service. Storing
// the new secret therefore updated the paired row and answered `ok` while
// every frame still travelled under the key derived from the *old* secret.
// It stayed invisible for as long as both ends carried the same stale entry
// — both sign with the old key, both verify, nothing looks wrong — and one
// end coming back with no old key at all broke that: it derived from the new
// secret, the long-lived cache kept answering with the old one, so neither
// could prove presence to the other and encrypted requests were dropped as
// unreadable, until the stale end was restarted too.
//
// That is a phone re-pairing, verbatim: the phone keeps its long-lived
// MeshService across a re-scan of the code (or a reconnect after the peer
// restarted), so it is usually the end carrying the stale key — but the peer
// that accepts the pairing caches a key too, and either cache left behind is
// enough to darken the link. These tests re-pair a genuinely warm end with an
// end that comes back without any key of its own (a fresh store: a reinstall,
// a cleared store, or simply a device that re-paired before it had signed
// anything to this peer), and require the link to prove itself again with no
// restart at all.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/mesh/mesh_service.dart';

const _onlineWindow = Duration(seconds: 2);

/// A started service on [port], reading and writing [storePath].
///
/// Load-then-set-then-save, in that order: saving a store that has never
/// loaded writes only defaults and forgets every paired device (see
/// `openPeerStore` in test/rehearsal_peer.dart).
Future<MeshService> _service({
  required String storePath,
  required int port,
  required String id,
  required String name,
  required String platform,
}) async {
  final store = NexusStore(explicitPath: storePath);
  await store.load();
  store.port = port;
  await store.save();
  final mesh = MeshService(
    identity: DeviceInfo(id: id, name: name, platform: platform),
    store: store,
    onlineWindow: _onlineWindow,
    visibleWindow: _onlineWindow,
    heartbeatInterval: const Duration(seconds: 1),
    connectTimeout: const Duration(milliseconds: 300),
  );
  await mesh.start();
  return mesh;
}

/// Beats both ends — the same on-demand heartbeat the connection supervisor
/// dials — until each has proven the other, or [timeout] runs out.
Future<void> _prove(
  MeshService a,
  MeshService b, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await a.beat();
    await b.beat();
    if (a.isOnline(b.identity.id) && b.isOnline(a.identity.id)) return;
    await Future<void>.delayed(const Duration(milliseconds: 120));
  }
  fail(
    'the pair never proved each other after re-pairing '
    '(${a.identity.id} sees ${b.identity.id}: ${a.isOnline(b.identity.id)}, '
    '${b.identity.id} sees ${a.identity.id}: ${b.isOnline(a.identity.id)})',
  );
}

/// Waits out the optimism a fresh pairing bestows on both ends.
///
/// Pairing marks both ends verified by itself — it just minted the secret —
/// so inside the window any online answer proves nothing about the keys. The
/// proof that follows starts after it, where only fresh frames can make the
/// answer yes. The wait asserts nothing: in the repaired pair the two ends
/// hold matching keys, so either of them keeping a link alive shows up as
/// *online* through the wait — the outcome being asked for — and an assertion
/// would call the fix a failure.
Future<void> _letPairingOptimismLapse() async {
  await Future<void>.delayed(_onlineWindow + const Duration(milliseconds: 600));
}

void main() {
  test('the phone re-pairing proves presence again without a restart',
      () async {
    // The device's own end of this: the phone, long-lived, re-pairing to a
    // peer that comes back with no old key — so the phone is the only end
    // that can carry a stale entry, and `pairWith` is the only place that
    // can drop it.
    final tmp = await Directory.systemTemp.createTemp('nexus_repair');
    final storeB = '${tmp.path}/b.json';

    // First pairing: the PC shows a code, the phone types it, and the link
    // proves itself — which warms the phone's key cache for this peer.
    final pc = await _service(
      storePath: '${tmp.path}/a.json',
      port: 53520,
      id: 'device-a',
      name: 'Rehearsal PC',
      platform: 'linux',
    );
    final phone = await _service(
      storePath: storeB,
      port: 53521,
      id: 'device-b',
      name: 'Phone',
      platform: 'android',
    );
    final first = pc.beginPairing();
    final paired = await phone.pairWith(
      address: '127.0.0.1',
      port: pc.port,
      code: first.code,
    );
    expect(paired.ok, isTrue, reason: paired.error);
    await _prove(pc, phone);
    // Both ends have now signed to each other, so the phone holds a cached
    // key derived from the first secret — the stale entry this test is about.
    await _prove(pc, phone);

    // The PC is restarted cold: a new process with not even the paired row
    // on disk, so no old key can exist anywhere on its side. That is the
    // shape any end has that re-pairs before it has signed a single frame to
    // this device — and the one where a stale cache on the phone turns a
    // quiet wrongness into a dead link.
    await pc.stop();
    final pc2 = await _service(
      storePath: '${tmp.path}/a2.json',
      port: 53520,
      id: 'device-a',
      name: 'Rehearsal PC',
      platform: 'linux',
    );

    // The user re-pairs — a new code, on the same two devices. The phone is
    // NOT restarted; it still holds the key it cached under the first secret.
    final second = pc2.beginPairing();
    final again = await phone.pairWith(
      address: '127.0.0.1',
      port: pc2.port,
      code: second.code,
    );
    expect(again.ok, isTrue, reason: again.error);
    expect(second.code, isNot(first.code), reason: 'a fresh code each time');

    await _letPairingOptimismLapse();
    await _prove(phone, pc2);
    expect(phone.isOnline('device-a'), isTrue);
    expect(pc2.isOnline('device-b'), isTrue);
    expect(pc2.onlineCount, 1);

    await phone.stop();
    await pc2.stop();
  });

  test('the end that accepts a re-pair drops the key it kept', () async {
    // The mirror: the surviving, long-lived end is the one being *paired
    // with*, so the clear has to happen where a pair-request is accepted
    // too. (Without this half, `pairWith` clearing its own cache on the
    // requesting end would cover for it.)
    final tmp = await Directory.systemTemp.createTemp('nexus_repair_shower');
    final storeA = '${tmp.path}/a.json';
    final storeB = '${tmp.path}/b.json';

    final pc = await _service(
      storePath: storeA,
      port: 53530,
      id: 'device-a',
      name: 'Rehearsal PC',
      platform: 'linux',
    );
    final phone = await _service(
      storePath: storeB,
      port: 53531,
      id: 'device-b',
      name: 'Phone',
      platform: 'android',
    );
    final first = pc.beginPairing();
    expect(
      (await phone.pairWith(
        address: '127.0.0.1',
        port: pc.port,
        code: first.code,
      ))
          .ok,
      isTrue,
    );
    await _prove(pc, phone);
    // The PC now carries a cached key derived from the first secret.
    await _prove(pc, phone);

    // The old phone is gone for good, and a fresh one arrives: same device
    // id, a store with nothing in it — no old secret to derive from and no
    // cached key, so the PC is the only end that can be carrying one.
    await phone.stop();
    final phone2 = await _service(
      storePath: '${tmp.path}/c.json',
      port: 53532,
      id: 'device-b',
      name: 'Phone',
      platform: 'android',
    );

    // The PC shows a code and the fresh phone types it, so the survivor is
    // the *accepting* side of this pairing.
    final second = pc.beginPairing();
    final again = await phone2.pairWith(
      address: '127.0.0.1',
      port: pc.port,
      code: second.code,
    );
    expect(again.ok, isTrue, reason: again.error);

    await _letPairingOptimismLapse();
    await _prove(pc, phone2);
    expect(pc.isOnline('device-b'), isTrue);
    expect(phone2.isOnline('device-a'), isTrue);

    await pc.stop();
    await phone2.stop();
  });
}
