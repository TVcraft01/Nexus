import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// All cryptography in Nexus.
///
/// Pairing: the pairing code (XXXX-XXXX) is the shared secret. Both sides
/// derive the same 256-bit key from it with HKDF-SHA256 and use AES-GCM.
/// Because the code is shown out-of-band (QR / screen), only a device that
/// actually saw it can decrypt a pairing handshake — this is what stops a
/// stranger on your network from pairing with you.
///
/// After pairing, every message is encrypted with a session key derived from
/// the pairing secret plus both device ids (HKDF), so each device pair gets
/// its own key. AES-GCM authenticates the data, so a tampered or truncated
/// message is detected and rejected.
///
/// Note (honest): this is not forward-secret. If a pairing secret ever leaks,
/// past traffic recorded by an attacker could be decrypted. Forward secrecy
/// (X25519 key exchange per connection) is a planned improvement.

final _aesGcm = AesGcm.with256bits();

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

final _rng = Random.secure();

Uint8List _randomBytes(int length) {
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = _rng.nextInt(256);
  }
  return out;
}

/// The 256-bit key used for the pairing handshake, derived from the pairing
/// code alone so both sides can compute it before they know each other's id.
Future<Uint8List> derivePairingKey(String code) async {
  final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  final key = await hkdf.deriveKey(
    secretKey: SecretKey(_bytes(code)),
    info: _bytes('nexus/pair/v1'),
  );
  return Uint8List.fromList(await key.extractBytes());
}

/// The per-peer session key used after pairing. Salted with both device ids
/// (sorted, so both sides agree) so each pair of devices uses a distinct key.
Future<Uint8List> deriveSessionKey({
  required String pairingSecret,
  required String myId,
  required String peerId,
}) async {
  final ids = [myId, peerId]..sort();
  final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  final key = await hkdf.deriveKey(
    secretKey: SecretKey(_bytes(pairingSecret)),
    nonce: _bytes(ids.join('|')),
    info: _bytes('nexus/session/v1'),
  );
  return Uint8List.fromList(await key.extractBytes());
}

/// Encrypt [plaintext] with AES-GCM and return
/// base64(iv || ciphertext || mac) — one self-contained blob.
Future<String> encryptToB64(List<int> plaintext, List<int> key) async {
  final nonce = _randomBytes(12);
  final box = await _aesGcm.encrypt(plaintext, secretKey: SecretKey(key), nonce: nonce);
  final out = BytesBuilder()
    ..add(nonce)
    ..add(box.cipherText)
    ..add(box.mac.bytes);
  return base64Encode(out.toBytes());
}

/// Decrypt a blob produced by [encryptToB64]. Throws on wrong key, tampering
/// or truncation — callers must treat a throw as "this message is not from
/// who we think it is".
Future<Uint8List> decryptFromB64(String payload, List<int> key) async {
  final raw = base64Decode(payload);
  if (raw.length < 12 + 16) {
    throw const FormatException('ciphertext too short');
  }
  final nonce = raw.sublist(0, 12);
  final body = raw.sublist(12);
  final cipherText = body.sublist(0, body.length - 16);
  final mac = body.sublist(body.length - 16);
  final box = SecretBox(cipherText, nonce: nonce, mac: Mac(mac));
  final clear = await _aesGcm.decrypt(box, secretKey: SecretKey(key));
  return Uint8List.fromList(clear);
}
