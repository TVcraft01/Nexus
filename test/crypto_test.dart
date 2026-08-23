import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/crypto.dart';

void main() {
  group('derivePairingKey', () {
    test('same code yields the same key on both sides', () async {
      final a = await derivePairingKey('ABCD-2345');
      final b = await derivePairingKey('ABCD-2345');
      expect(a, b);
    });

    test('different codes yield different keys', () async {
      final a = await derivePairingKey('ABCD-2345');
      final b = await derivePairingKey('ABCD-2346');
      expect(a, isNot(equals(b)));
    });
  });

  group('deriveSessionKey', () {
    test('is symmetric regardless of id order', () async {
      final a = await deriveSessionKey(pairingSecret: 'SECRET', myId: 'device-a', peerId: 'device-b');
      final b = await deriveSessionKey(pairingSecret: 'SECRET', myId: 'device-b', peerId: 'device-a');
      expect(a, b);
    });

    test('differs between device pairs', () async {
      final a = await deriveSessionKey(pairingSecret: 'SECRET', myId: 'device-a', peerId: 'device-b');
      final c = await deriveSessionKey(pairingSecret: 'SECRET', myId: 'device-a', peerId: 'device-c');
      expect(a, isNot(equals(c)));
    });
  });

  group('AES-GCM encrypt/decrypt', () {
    test('roundtrip restores the original bytes', () async {
      final key = await derivePairingKey('TEST-CODE');
      final plaintext = utf8.encode('hello nexus');
      final blob = await encryptToB64(plaintext, key);
      final decrypted = await decryptFromB64(blob, key);
      expect(utf8.decode(decrypted), 'hello nexus');
    });

    test('two encryptions of the same text are different (fresh nonces)', () async {
      final key = await derivePairingKey('TEST-CODE');
      final a = await encryptToB64(utf8.encode('same text'), key);
      final b = await encryptToB64(utf8.encode('same text'), key);
      expect(a, isNot(equals(b)));
    });

    test('tampered ciphertext is rejected', () async {
      final key = await derivePairingKey('TEST-CODE');
      final blob = await encryptToB64(utf8.encode('secret message'), key);
      final raw = base64Decode(blob);
      raw[raw.length - 1] ^= 0x01; // flip one bit in the MAC
      expect(() => decryptFromB64(base64Encode(raw), key), throwsA(anything));
    });

    test('truncated ciphertext is rejected', () async {
      final key = await derivePairingKey('TEST-CODE');
      final blob = await encryptToB64(utf8.encode('secret message'), key);
      final raw = base64Decode(blob);
      final truncated = base64Encode(raw.sublist(0, raw.length - 8));
      expect(() => decryptFromB64(truncated, key), throwsA(anything));
    });

    test('wrong key is rejected', () async {
      final blob = await encryptToB64(utf8.encode('top secret'), await derivePairingKey('KEY-AAAA'));
      final wrongKey = await derivePairingKey('KEY-BBBB');
      expect(() => decryptFromB64(blob, wrongKey), throwsA(anything));
    });

    test('random blobs of garbage do not decrypt', () async {
      final key = await derivePairingKey('TEST-CODE');
      final garbage = base64Encode(Uint8List.fromList(List.generate(40, (i) => i)));
      expect(() => decryptFromB64(garbage, key), throwsA(anything));
    });
  });
}
