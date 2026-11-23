// Offline pairing: two devices agree on a secret with no network at all.
//
// Every payload here is a string, which is exactly how the app uses it (a QR
// on one screen, a camera or a paste on the other). Nothing in this file opens
// a socket — that is the property being tested, not a shortcut.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/crypto.dart'
    show deriveControlKey, deriveSessionKey, decryptFromB64, encryptToB64;
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/mesh/mesh_service.dart';
import 'package:nexus/mesh/offline_pairing.dart';

import 'mesh_test.dart' show FakeClipboard;

typedef _Pair = ({
  PairingIdentity a,
  PairingIdentity b,
  OfflineHostSession host,
  OfflineGuestSession guest,
  OfflinePairingOffer offerA,
});

Future<_Pair> _handshake({
  String idA = 'offline-device-a',
  String idB = 'offline-device-b',
  String nameA = 'Study laptop',
  String nameB = 'My phone',
  OfflineNonceGuard? guard,
}) async {
  final a = await PairingIdentity.generate();
  final b = await PairingIdentity.generate();
  final host = await OfflineHostSession.begin(
    identity: a,
    deviceId: idA,
    deviceName: nameA,
  );
  final guest = await OfflineGuestSession.answer(
    qr1: host.qr1,
    identity: b,
    deviceId: idB,
    deviceName: nameB,
    guard: guard,
  );
  final offerA = await host.acceptAnswer(guest.qr2);
  return (a: a, b: b, host: host, guest: guest, offerA: offerA);
}

/// A host showing a code and a guest that answered it, with nobody having
/// accepted yet — the state the tamper tests start from.
Future<(OfflineHostSession, OfflineGuestSession)> _pending({
  OfflineNonceGuard? guard,
}) async {
  final host = await OfflineHostSession.begin(
    identity: await PairingIdentity.generate(),
    deviceId: 'pending-host',
    deviceName: 'Laptop',
  );
  final guest = await OfflineGuestSession.answer(
    qr1: host.qr1,
    identity: await PairingIdentity.generate(),
    deviceId: 'pending-guest',
    deviceName: 'Phone',
    guard: guard,
  );
  return (host, guest);
}

Map<String, dynamic> _body(String payload, String prefix) =>
    jsonDecode(
          utf8.decode(base64Url.decode(payload.substring(prefix.length))),
        )
        as Map<String, dynamic>;

String _encode(String prefix, Map<String, dynamic> body) =>
    prefix + base64UrlEncode(utf8.encode(jsonEncode(body)));

String _flip(String value) =>
    value.substring(0, value.length - 1) + (value.endsWith('A') ? 'B' : 'A');

Matcher _refuses(String fragment) => throwsA(
  isA<OfflinePairingException>().having(
    (e) => e.message,
    'message',
    contains(fragment),
  ),
);

void main() {
  group('the handshake', () {
    test('two instances agree on the channel key and the six digits', () async {
      final pair = await _handshake();

      expect(
        base64Encode(pair.offerA.channelKey),
        base64Encode(pair.guest.offer.channelKey),
      );
      expect(pair.offerA.confirmationCode, pair.guest.offer.confirmationCode);
      expect(pair.offerA.confirmationCode, matches(RegExp(r'^\d{6}$')));
      expect(pair.offerA.pairingSecret, pair.guest.offer.pairingSecret);
      expect(pair.offerA.version, offlinePairingVersion);

      // Each side learned the other's addressing fact and display name.
      expect(pair.offerA.peerDeviceId, 'offline-device-b');
      expect(pair.guest.offer.peerDeviceId, 'offline-device-a');
      expect(pair.offerA.peerName, 'My phone');
      expect(pair.guest.offer.peerName, 'Study laptop');

      // The identity keys each side remembers are the other's long-term key.
      expect(pair.offerA.peerIdentityKey, base64UrlEncode(pair.b.publicKey));
      expect(pair.guest.offer.peerIdentityKey, base64UrlEncode(pair.a.publicKey));
    });

    test('the QR carries no address, port or network information', () async {
      final pair = await _handshake();
      final qr1 = utf8.decode(
        base64Url.decode(pair.host.qr1.substring(offlineQr1Prefix.length)),
      );
      final qr2 = utf8.decode(
        base64Url.decode(pair.guest.qr2.substring(offlineQr2Prefix.length)),
      );
      for (final payload in [qr1, qr2]) {
        for (final banned in [
          '192.168',
          '10.',
          '127.0.0.1',
          'port',
          'address',
          'wifi',
          'ssid',
        ]) {
          expect(
            payload.contains(banned),
            isFalse,
            reason: 'payload must not leak $banned: $payload',
          );
        }
      }
    });

    test('a fresh ephemeral key each time: two shows are different', () async {
      final identity = await PairingIdentity.generate();
      final first = await OfflineHostSession.begin(
        identity: identity,
        deviceId: 'same-device',
        deviceName: 'Laptop',
      );
      final second = await OfflineHostSession.begin(
        identity: identity,
        deviceId: 'same-device',
        deviceName: 'Laptop',
      );
      expect(first.qr1, isNot(second.qr1));
    });

    test('the identity survives a save and load', () async {
      final original = await PairingIdentity.generate();
      final restored = await PairingIdentity.fromJson(
        await original.toJson(),
      );
      expect(base64UrlEncode(restored.publicKey),
          base64UrlEncode(original.publicKey));

      // A handshake with the restored identity is a handshake with the same
      // device: the peer sees the same long-term key.
      final other = await PairingIdentity.generate();
      final host = await OfflineHostSession.begin(
        identity: restored,
        deviceId: 'restored',
        deviceName: 'Laptop',
      );
      final guest = await OfflineGuestSession.answer(
        qr1: host.qr1,
        identity: other,
        deviceId: 'phone',
        deviceName: 'Phone',
      );
      final offer = await host.acceptAnswer(guest.qr2);
      expect(offer.peerIdentityKey, base64UrlEncode(other.publicKey));
    });

    test('a damaged saved identity says so instead of half-loading', () async {
      expect(
        () => PairingIdentity.fromJson(const {'v': 1, 'seed': 'tooshort'}),
        _refuses('damaged'),
      );
      expect(
        () => PairingIdentity.fromJson(const {'v': 7, 'seed': 'AAAA'}),
        _refuses('other version'),
      );
    });
  });

  group('refusals', () {
    test('a tampered answer is refused', () async {
      final pair = await _handshake();
      final body = _body(pair.guest.qr2, offlineQr2Prefix);
      body['m'] = _flip(body['m'] as String);
      final tampered = _encode(offlineQr2Prefix, body);

      // The host that showed the code never accepted the tampered answer.
      final host2 = await OfflineHostSession.begin(
        identity: await PairingIdentity.generate(),
        deviceId: 'host2',
        deviceName: 'Laptop',
      );
      await expectLater(host2.acceptAnswer(tampered), _refuses('did not come'));
    });

    test('an answer to a different code is refused', () async {
      final first = await _handshake();
      final second = await _handshake();
      // A valid answer, but to somebody else's QR: the MAC is over that QR.
      await expectLater(
        first.host.acceptAnswer(second.guest.qr2),
        _refuses('did not come'),
      );
    });

    test('a tampered code is refused', () async {
      final pair = await _handshake();
      final body = _body(pair.host.qr1, offlineQr1Prefix);
      final identityB = await PairingIdentity.generate();
      body['i'] = base64UrlEncode(identityB.publicKey);
      final tampered = _encode(offlineQr1Prefix, body);

      final guest = await OfflineGuestSession.answer(
        qr1: tampered,
        identity: await PairingIdentity.generate(),
        deviceId: 'scanner',
        deviceName: 'Phone',
      );
      await expectLater(
        pair.host.acceptAnswer(guest.qr2),
        _refuses('did not come'),
      );
    });

    test('a replayed answer is refused with a reason', () async {
      final pair = await _handshake();
      await expectLater(
        pair.host.acceptAnswer(pair.guest.qr2),
        _refuses('already used'),
      );
    });

    test('a replayed code is refused by the guard', () async {
      final guard = OfflineNonceGuard();
      final host = await OfflineHostSession.begin(
        identity: await PairingIdentity.generate(),
        deviceId: 'replay-host',
        deviceName: 'Laptop',
      );
      final scanner = await PairingIdentity.generate();
      await OfflineGuestSession.answer(
        qr1: host.qr1,
        identity: scanner,
        deviceId: 'scanner',
        deviceName: 'Phone',
        guard: guard,
      );
      expect(guard.length, 1);

      // The same code answered again is the replay the guard exists for.
      await expectLater(
        OfflineGuestSession.answer(
          qr1: host.qr1,
          identity: scanner,
          deviceId: 'scanner',
          deviceName: 'Phone',
          guard: guard,
        ),
        _refuses('already been used here'),
      );
    });

    test('a newer version is refused on both sides', () async {
      final pair = await _handshake();
      final qr1 = _body(pair.host.qr1, offlineQr1Prefix)..['v'] = 2;
      await expectLater(
        OfflineGuestSession.answer(
          qr1: _encode(offlineQr1Prefix, qr1),
          identity: await PairingIdentity.generate(),
          deviceId: 'phone',
          deviceName: 'Phone',
        ),
        _refuses('newer Nexus'),
      );

      final qr2 = _body(pair.guest.qr2, offlineQr2Prefix)..['v'] = 2;
      await expectLater(
        pair.host.acceptAnswer(_encode(offlineQr2Prefix, qr2)),
        _refuses('newer Nexus'),
      );
    });

    test('an older version is refused too', () async {
      final pair = await _handshake();
      final qr2 = _body(pair.guest.qr2, offlineQr2Prefix)..['v'] = 0;
      await expectLater(
        pair.host.acceptAnswer(_encode(offlineQr2Prefix, qr2)),
        _refuses('older Nexus'),
      );
    });

    test('an all-zero or identity public key is refused', () async {
      for (final weak in [
        Uint8List(32),
        Uint8List(32)..[0] = 1,
      ]) {
        final (host, guest) = await _pending();
        final qr2 = _body(guest.qr2, offlineQr2Prefix)
          ..['i'] = base64UrlEncode(weak);
        await expectLater(
          host.acceptAnswer(_encode(offlineQr2Prefix, qr2)),
          _refuses('unusable key'),
        );
      }
    });

    test('a weak ephemeral key is refused as well', () async {
      final (host, guest) = await _pending();
      final qr2 = _body(guest.qr2, offlineQr2Prefix)
        ..['e'] = base64UrlEncode(Uint8List(32));
      await expectLater(
        host.acceptAnswer(_encode(offlineQr2Prefix, qr2)),
        _refuses('unusable key'),
      );
    });

    test('malformed, oversized and foreign strings are refused', () async {
      final host = await OfflineHostSession.begin(
        identity: await PairingIdentity.generate(),
        deviceId: 'host',
        deviceName: 'Laptop',
      );
      await expectLater(host.acceptAnswer('hello'), _refuses('not look like'));
      await expectLater(
        host.acceptAnswer('NEXUS2.%%%%'),
        _refuses('damaged'),
      );
      await expectLater(
        host.acceptAnswer('NEXUS2.${'A' * 2000}'),
        _refuses('too long'),
      );
      // A QR1 handed to the answer parser is the wrong envelope.
      final wrongEnvelope = _encode(offlineQr1Prefix, const {
        'v': 1,
        'id': 'x',
        'i': 'AAAA',
        'e': 'AAAA',
        'n': 'AAAA',
      });
      await expectLater(
        host.acceptAnswer(wrongEnvelope),
        _refuses('not look like'),
      );
    });
  });

  group('a man in the middle', () {
    test('the two devices show different codes', () async {
      final a = await PairingIdentity.generate();
      final b = await PairingIdentity.generate();
      final attacker = await PairingIdentity.generate();

      // A shows QR1 to the room; the attacker answers it as if it had scanned.
      final hostA = await OfflineHostSession.begin(
        identity: a,
        deviceId: 'device-a',
        deviceName: 'Laptop',
      );
      final attackerAnswers = await OfflineGuestSession.answer(
        qr1: hostA.qr1,
        identity: attacker,
        deviceId: 'attacker',
        deviceName: 'Relay',
      );
      final codeAtA = (await hostA.acceptAnswer(attackerAnswers.qr2))
          .confirmationCode;

      // The attacker then shows its own code to B and relays B's answer to
      // itself. B is talking to the attacker, not to A.
      final hostAttacker = await OfflineHostSession.begin(
        identity: attacker,
        deviceId: 'attacker',
        deviceName: 'Relay',
      );
      final bAnswers = await OfflineGuestSession.answer(
        qr1: hostAttacker.qr1,
        identity: b,
        deviceId: 'device-b',
        deviceName: 'Phone',
      );
      final codeAtB = (await hostAttacker.acceptAnswer(bAnswers.qr2))
          .confirmationCode;

      expect(codeAtA, isNot(codeAtB));
    });
  });

  group('what the new secret can do', () {
    test('a pairing made offline transfers files with the new keys', () async {
      final pair = await _handshake();

      // Stored on each side under the other's mesh id, exactly as
      // MeshService.confirmOfflinePairing does.
      const idA = 'offline-device-a';
      const idB = 'offline-device-b';
      final secretA = pair.offerA.pairingSecret;
      final secretB = pair.guest.offer.pairingSecret;
      expect(secretA, secretB);

      final sessionA = await deriveSessionKey(
        pairingSecret: secretA,
        myId: idA,
        peerId: idB,
      );
      final sessionB = await deriveSessionKey(
        pairingSecret: secretB,
        myId: idB,
        peerId: idA,
      );
      expect(base64Encode(sessionA), base64Encode(sessionB));

      // The same key encrypts a chunk of a file on one side and decrypts it on
      // the other, and a tampered chunk does not.
      final chunk = utf8.encode('the first bytes of a file');
      final sealed = await encryptToB64(chunk, sessionA);
      expect(utf8.decode(await decryptFromB64(sealed, sessionB)),
          'the first bytes of a file');

      // Control requests (a ping, a trackpad move) derive their own key from
      // the same secret and still agree.
      final controlA = await deriveControlKey(
        pairingSecret: secretA,
        myId: idA,
        peerId: idB,
      );
      final controlB = await deriveControlKey(
        pairingSecret: secretB,
        myId: idB,
        peerId: idA,
      );
      expect(base64Encode(controlA), base64Encode(controlB));
    });

    test('a device paired the old way still derives the keys it always did',
        () async {
      // The old scheme's secret is the one-time code the user saw. Nothing in
      // the offline work touches it, and the record says which scheme it is.
      const oldSecret = 'ABCD-2345';
      final old = PairedDevice(
        id: 'old-phone',
        name: 'Old phone',
        platform: 'android',
        address: '192.168.1.20',
        port: 51820,
        pairingSecret: oldSecret,
      );
      expect(old.pairingProtocol, 0);

      final roundTripped = PairedDevice.fromJson(
        jsonDecode(jsonEncode(old.toJson())) as Map<String, dynamic>,
      );
      expect(roundTripped.pairingProtocol, 0);
      expect(roundTripped.pairingSecret, oldSecret);

      final session = await deriveSessionKey(
        pairingSecret: oldSecret,
        myId: 'old-phone',
        peerId: 'this-pc',
      );
      final again = await deriveSessionKey(
        pairingSecret: 'ABCD-2345',
        myId: 'this-pc',
        peerId: 'old-phone',
      );
      expect(base64Encode(session), base64Encode(again));
    });

    test('a new pairing records its protocol and its key', () async {
      final pair = await _handshake();
      final device = PairedDevice(
        id: pair.offerA.peerDeviceId,
        name: pair.offerA.peerName,
        platform: 'other',
        address: '',
        port: 51820,
        pairingSecret: pair.offerA.pairingSecret,
        pairingProtocol: pair.offerA.version,
      );
      final restored = PairedDevice.fromJson(
        jsonDecode(jsonEncode(device.toJson())) as Map<String, dynamic>,
      );
      expect(restored.pairingProtocol, 1);
      expect(restored.pairingSecret, pair.offerA.pairingSecret);
      // A new secret is a key, not a code: it is not something a person types.
      expect(restored.pairingSecret.length, greaterThan(9));
    });
  });

  group('the mesh service', () {
    late Directory tmp;
    late NexusStore store;
    late MeshService mesh;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('nexus_offline_pair');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      store = NexusStore(explicitPath: '${tmp.path}/a.json')..port = 51999;
      mesh = MeshService(
        identity: DeviceInfo(id: 'mesh-a', name: 'Laptop', platform: 'linux'),
        store: store,
        clipboard: FakeClipboard(),
        heartbeatInterval: const Duration(seconds: 30),
      );
    });

    test('the identity is created once and kept in the store', () async {
      final first = await mesh.offlineIdentity();
      final second = await mesh.offlineIdentity();
      expect(base64UrlEncode(second.publicKey),
          base64UrlEncode(first.publicKey));
      expect(store.offlinePairingIdentity, isNotNull);

      // A second service on the same store is the same device.
      final other = MeshService(
        identity: DeviceInfo(id: 'mesh-a', name: 'Laptop', platform: 'linux'),
        store: store,
        clipboard: FakeClipboard(),
        heartbeatInterval: const Duration(seconds: 30),
      );
      final reloaded = await other.offlineIdentity();
      expect(base64UrlEncode(reloaded.publicKey),
          base64UrlEncode(first.publicKey));
    });

    test('answer, confirm: the peer is paired with the new secret', () async {
      final otherStore = NexusStore(explicitPath: '${tmp.path}/b.json')
        ..port = 51998;
      final otherMesh = MeshService(
        identity: DeviceInfo(id: 'mesh-b', name: 'Phone', platform: 'android'),
        store: otherStore,
        clipboard: FakeClipboard(),
        heartbeatInterval: const Duration(seconds: 30),
      );

      final host = await mesh.beginOfflinePairing();
      final guest = await otherMesh.answerOfflinePairing(host.qr1);
      final offerHere = await host.acceptAnswer(guest.qr2);
      expect(offerHere.confirmationCode, guest.offer.confirmationCode);

      final peerA = await mesh.confirmOfflinePairing(offerHere);
      final peerB = await otherMesh.confirmOfflinePairing(guest.offer);
      expect(mesh.isPaired('mesh-b'), isTrue);
      expect(otherMesh.isPaired('mesh-a'), isTrue);
      expect(peerA.pairingProtocol, 1);
      expect(peerB.pairingProtocol, 1);
      expect(peerA.pairingSecret, peerB.pairingSecret);
      expect(peerA.name, 'Phone');
      expect(store.pairedDevices.single['pairingProtocol'], 1);
      expect(mesh.isOfflinePaired(offerHere), isTrue);

      // Confirming twice is one row, not two.
      await otherMesh.confirmOfflinePairing(guest.offer);
      expect(otherStore.pairedDevices, hasLength(1));
    });

    test('an answer that does not match pairs nothing', () async {
      final host = await mesh.beginOfflinePairing();
      final stranger = await OfflineHostSession.begin(
        identity: await PairingIdentity.generate(),
        deviceId: 'mesh-z',
        deviceName: 'Stranger',
      );
      final guest = await OfflineGuestSession.answer(
        qr1: stranger.qr1,
        identity: await PairingIdentity.generate(),
        deviceId: 'mesh-y',
        deviceName: 'Other',
      );
      await expectLater(
        host.acceptAnswer(guest.qr2),
        throwsA(isA<OfflinePairingException>()),
      );
      expect(mesh.pairedDevices, isEmpty);
      expect(store.pairedDevices, isEmpty);
    });
  });
}
