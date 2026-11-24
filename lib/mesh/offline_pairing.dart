import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Offline pairing: two devices agree on a secret with no network at all.
///
/// Everything here is a string in and a string out, so the same code runs for
/// a camera scan, a copy/pasted code, and a test with the network switched
/// off. Nothing in this file opens a socket, and nothing in either QR carries
/// an address.
///
/// The shape is the one a Signal-style pairing uses:
///
///   A (host)                          B (guest)
///   identity keypair, long-lived      identity keypair, long-lived
///   ephemeral keypair, this pairing   ephemeral keypair, this pairing
///   QR1 = v, idA, ephA, nonceA, name  ──scanned by B──▶
///                                     ◀──QR2 = v, idB, ephB, nonceB, MAC──
///   both derive the same channel key and the same 6-digit code
///   both users tap "these match"      both users tap "these match"
///
/// The MAC over QR1 plus B's fields is what lets A know B really scanned *this*
/// code; the identity keys are mixed into the exchange so a later transcript
/// cannot be replayed by a stranger who only saw the QR. Both codes are derived
/// from the full transcript, so an attacker who swaps a key in the middle makes
/// the two devices show different codes.
///
/// Honest limits, deliberately not overclaimed:
///  * The 6-digit code is about 20 bits. It catches accidents and casual
///    tampering; it is not a defence against a determined attacker who can run
///    millions of handshakes. The real authenticity guarantee is that the two
///    people are looking at each other's screens (and at the QR itself).
///  * There is no user authentication beyond "hold both devices": anyone who
///    has both devices in hand can complete a pairing, which is the point.
///  * The private identity key is persisted by the caller ([OfflineIdentityStore]).
///    This build has no OS-keystore dependency, so it lands where every other
///    pairing secret this app owns lives; moving it to Keystore/libsecret is a
///    separate change and is not claimed here.

/// The protocol label. Change it whenever the transcript changes shape.
const String offlinePairingLabel = 'nexus/offline-pair/v1';

/// The version byte both payloads carry. A payload from another version is
/// refused rather than guessed at.
const int offlinePairingVersion = 1;

/// QR1's envelope prefix, then base64url of the JSON body.
const String offlineQr1Prefix = 'NEXUS1.';

/// QR2's envelope prefix.
const String offlineQr2Prefix = 'NEXUS2.';

/// A payload longer than this is refused before it is decoded: a QR is a few
/// hundred characters, and a pasted blob that is not one should not be parsed.
const int offlinePayloadMaxChars = 1024;

final _x25519 = X25519();
final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

/// A pairing that did not complete, with a sentence a person can act on.
/// Nothing here carries a stack trace or a secret.
class OfflinePairingException implements Exception {
  /// What to show the user.
  final String message;

  const OfflinePairingException(this.message);

  @override
  String toString() => message;
}

// ---------------------------------------------------------------------------
// Identity
// ---------------------------------------------------------------------------

/// The device's long-term X25519 identity: generated once, reused for every
/// offline pairing this device ever does.
///
/// Long-term means it is what another device remembers about us; it is NOT what
/// protects a single pairing (the ephemeral keys do that, so a leaked identity
/// key cannot decrypt an old pairing transcript on its own).
class PairingIdentity {
  final SimpleKeyPair _keyPair;
  final Uint8List _publicKey;

  PairingIdentity._(this._keyPair, this._publicKey);

  /// A fresh identity. Only ever called the first time a device pairs offline.
  static Future<PairingIdentity> generate() async {
    final pair = await _x25519.newKeyPair();
    final pub = await pair.extractPublicKey();
    return PairingIdentity._(pair, Uint8List.fromList(pub.bytes));
  }

  /// Rebuild an identity from its stored seed. X25519 derives the public key
  /// from the seed, so the stored form is one 32-byte secret and nothing else.
  static Future<PairingIdentity> fromSeed(List<int> seed) async {
    if (seed.length != 32) {
      throw const OfflinePairingException(
        'The saved pairing identity is damaged. Pair offline again from a '
        'device that still has its own.',
      );
    }
    final pair = await _x25519.newKeyPairFromSeed(seed);
    final pub = await pair.extractPublicKey();
    return PairingIdentity._(pair, Uint8List.fromList(pub.bytes));
  }

  /// Our public key, the one that goes in a QR.
  Uint8List get publicKey => Uint8List.fromList(_publicKey);

  /// The 32-byte secret to persist. Never logged, never shown.
  Future<Uint8List> extractSeed() async => Uint8List.fromList(
    await _keyPair.extractPrivateKeyBytes(),
  );

  /// What gets written to the identity store.
  Future<Map<String, dynamic>> toJson() async => {
    'v': offlinePairingVersion,
    'seed': base64UrlEncode(await extractSeed()),
  };

  /// Read an identity back, refusing anything this build cannot understand.
  static Future<PairingIdentity> fromJson(Map<String, dynamic> json) async {
    final version = json['v'];
    final seed = json['seed'];
    if (version != offlinePairingVersion || seed is! String) {
      throw const OfflinePairingException(
        'The saved pairing identity is from another version of Nexus.',
      );
    }
    return fromSeed(_decode(seed, what: 'identity'));
  }
}

/// Where the identity seed is kept. Production passes the app's own store;
/// tests pass [MemoryOfflineIdentityStore].
abstract class OfflineIdentityStore {
  Future<Map<String, dynamic>?> read();
  Future<void> write(Map<String, dynamic> identity);
}

/// In-memory identity store, for tests and for a first run that has not
/// written anything yet.
class MemoryOfflineIdentityStore implements OfflineIdentityStore {
  Map<String, dynamic>? _identity;

  MemoryOfflineIdentityStore([Map<String, dynamic>? initial])
    : _identity = initial;

  @override
  Future<Map<String, dynamic>?> read() async => _identity;

  @override
  Future<void> write(Map<String, dynamic> identity) async {
    _identity = Map<String, dynamic>.of(identity);
  }
}

/// The device identity, generated on first use and persisted through
/// [store]. Safe to call on every pairing: only the first call generates.
Future<PairingIdentity> loadOrCreateIdentity(OfflineIdentityStore store) async {
  final saved = await store.read();
  if (saved != null) return PairingIdentity.fromJson(saved);
  final identity = await PairingIdentity.generate();
  await store.write(await identity.toJson());
  return identity;
}

// ---------------------------------------------------------------------------
// Result
// ---------------------------------------------------------------------------

/// What both sides end up holding once the handshake succeeded — and the same
/// values on both devices when nobody tampered with the exchange.
class OfflinePairingOffer {
  /// The AES-GCM key for this pairing (32 bytes, from HKDF-SHA256).
  final Uint8List channelKey;

  /// The six digits both screens show. Equal on both devices, or the pair is
  /// not the pair.
  final String confirmationCode;

  /// The other device's long-term identity key, base64url. What we store so a
  /// future pairing with the same device can be recognised.
  final String peerIdentityKey;

  /// The other device's display name, when its payload carried one.
  final String peerName;

  /// The other device's mesh id, so the peer can be stored under the id its
  /// announcements will arrive with. Carried in both payloads (the mesh id is
  /// announced in plaintext on the LAN already; it is not a secret, and a
  /// pairing with no addressing would be a key nobody can dial).
  final String peerDeviceId;

  /// The protocol version this offer came from.
  final int version;

  const OfflinePairingOffer({
    required this.channelKey,
    required this.confirmationCode,
    required this.peerIdentityKey,
    required this.peerName,
    required this.peerDeviceId,
    this.version = offlinePairingVersion,
  });

  /// The channel key as the string the existing mesh code stores as a
  /// pairing secret. Every session/control key the mesh derives from that
  /// secret then works unchanged, which is what lets a pairing made offline
  /// transfer files the moment it is confirmed.
  String get pairingSecret => base64UrlEncode(channelKey);
}

// ---------------------------------------------------------------------------
// Host: A shows QR1, reads QR2 back
// ---------------------------------------------------------------------------

/// Device A: holds the code on screen and waits for the answer.
class OfflineHostSession {
  final PairingIdentity identity;
  final String deviceId;
  final String deviceName;
  final SimpleKeyPair _ephemeral;
  final Uint8List _nonce;

  /// What A shows. Has no address, no port, nothing but the handshake.
  final String qr1;

  /// Answers already accepted, so a replay is refused with a reason instead of
  /// quietly re-deriving a key.
  final Set<String> _usedResponseNonces = {};

  OfflineHostSession._(
    this.identity,
    this.deviceId,
    this.deviceName,
    this._ephemeral,
    this._nonce,
    this.qr1,
  );

  /// Start showing: build a fresh ephemeral key and nonce and encode QR1.
  static Future<OfflineHostSession> begin({
    required PairingIdentity identity,
    required String deviceId,
    required String deviceName,
  }) async {
    final ephemeral = await _x25519.newKeyPair();
    final ephPub = await ephemeral.extractPublicKey();
    final nonce = _randomBytes(16);
    final body = <String, dynamic>{
      'v': offlinePairingVersion,
      'id': _cleanId(deviceId),
      'i': base64UrlEncode(identity.publicKey),
      'e': base64UrlEncode(ephPub.bytes),
      'n': base64UrlEncode(nonce),
      'd': _cleanName(deviceName),
    };
    return OfflineHostSession._(
      identity,
      _cleanId(deviceId),
      _cleanName(deviceName),
      ephemeral,
      nonce,
      offlineQr1Prefix + base64UrlEncode(_utf8(jsonEncode(body))),
    );
  }

  /// Read B's answer. Throws [OfflinePairingException] for a damaged, wrong,
  /// replayed or foreign answer; returns the offer when it is genuine.
  ///
  /// This does NOT store the pairing. The callers show [confirmationCode] and
  /// store the offer only when a person taps "codes match".
  Future<OfflinePairingOffer> acceptAnswer(String qr2) async {
    final body = _parseEnvelope(
      qr2,
      prefix: offlineQr2Prefix,
      what: 'answer',
    );
    final version = _versionOf(body);
    final peerDeviceId = _idField(body);
    final peerId = _keyField(body, 'i');
    final peerEph = _keyField(body, 'e');
    final peerNonce = _nonceField(body, 'n');
    final mac = _stringField(body, 'm', maxLength: 128);
    final peerName = _cleanName(
      body['d'] is String ? body['d'] as String : 'Paired device',
    );

    final responseNonceKey = base64UrlEncode(peerNonce);
    if (_usedResponseNonces.contains(responseNonceKey)) {
      throw const OfflinePairingException(
        'That answer was already used. Show a fresh code on this device.',
      );
    }

    final shared = await _mix(
      identity: identity,
      ephemeral: _ephemeral,
      peerIdentity: peerId,
      peerEphemeral: peerEph,
      host: true,
    );
    final transcript = _transcript(
      aIdentity: identity.publicKey,
      aMeshId: deviceId,
      aEphemeral: await _publicOf(_ephemeral),
      aNonce: _nonce,
      bIdentity: peerId,
      bMeshId: peerDeviceId,
      bEphemeral: peerEph,
      bNonce: peerNonce,
      version: version,
    );

    final expected = await _mac(
      shared: shared,
      transcript: transcript,
      qr1: qr1,
      peerMeshId: peerDeviceId,
      peerIdentity: peerId,
      peerEphemeral: peerEph,
      peerNonce: peerNonce,
      peerName: peerName,
    );
    if (!_constantTimeStringEquals(expected, mac)) {
      throw const OfflinePairingException(
        'That answer did not come from the device that scanned your code. '
        'Nothing was paired — show a fresh code and try again.',
      );
    }

    _usedResponseNonces.add(responseNonceKey);
    return OfflinePairingOffer(
      channelKey: await _channelKey(shared, transcript),
      confirmationCode: await _confirmationCode(shared, transcript),
      peerIdentityKey: base64UrlEncode(peerId),
      peerName: peerName,
      peerDeviceId: peerDeviceId,
      version: version,
    );
  }
}

// ---------------------------------------------------------------------------
// Guest: B scanned QR1, shows QR2
// ---------------------------------------------------------------------------

/// Device B: read A's code, answer it, and hold the offer to confirm.
class OfflineGuestSession {
  /// What B shows back to A.
  final String qr2;

  /// What B will store if the two codes match.
  final OfflinePairingOffer offer;

  /// A's display name, from its QR.
  final String hostName;

  const OfflineGuestSession._({
    required this.qr2,
    required this.offer,
    required this.hostName,
  });

  /// Answer a scanned QR1.
  ///
  /// [guard] remembers QR1 nonces this device has already answered, so the
  /// same code cannot be answered twice; pass null only in a one-shot test.
  static Future<OfflineGuestSession> answer({
    required String qr1,
    required PairingIdentity identity,
    required String deviceId,
    required String deviceName,
    OfflineNonceGuard? guard,
  }) async {
    final body = _parseEnvelope(qr1, prefix: offlineQr1Prefix, what: 'code');
    final version = _versionOf(body);
    final hostDeviceId = _idField(body);
    final hostId = _keyField(body, 'i');
    final hostEph = _keyField(body, 'e');
    final hostNonce = _nonceField(body, 'n');
    final hostName = _cleanName(
      body['d'] is String ? body['d'] as String : 'Paired device',
    );

    guard?.remember(hostNonce);

    final ephemeral = await _x25519.newKeyPair();
    final ephPub = Uint8List.fromList(
      (await ephemeral.extractPublicKey()).bytes,
    );
    final nonce = _randomBytes(16);
    final myName = _cleanName(deviceName);

    final shared = await _mix(
      identity: identity,
      ephemeral: ephemeral,
      peerIdentity: hostId,
      peerEphemeral: hostEph,
      host: false,
    );
    final transcript = _transcript(
      aIdentity: hostId,
      aMeshId: hostDeviceId,
      aEphemeral: hostEph,
      aNonce: hostNonce,
      bIdentity: identity.publicKey,
      bMeshId: _cleanId(deviceId),
      bEphemeral: ephPub,
      bNonce: nonce,
      version: version,
    );
    final mac = await _mac(
      shared: shared,
      transcript: transcript,
      qr1: qr1,
      peerMeshId: _cleanId(deviceId),
      peerIdentity: identity.publicKey,
      peerEphemeral: ephPub,
      peerNonce: nonce,
      peerName: myName,
    );

    final body2 = <String, dynamic>{
      'v': offlinePairingVersion,
      'id': _cleanId(deviceId),
      'i': base64UrlEncode(identity.publicKey),
      'e': base64UrlEncode(ephPub),
      'n': base64UrlEncode(nonce),
      'd': myName,
      'm': mac,
    };
    return OfflineGuestSession._(
      qr2: offlineQr2Prefix + base64UrlEncode(_utf8(jsonEncode(body2))),
      hostName: hostName,
      offer: OfflinePairingOffer(
        channelKey: await _channelKey(shared, transcript),
        confirmationCode: await _confirmationCode(shared, transcript),
        peerIdentityKey: base64UrlEncode(hostId),
        peerName: hostName,
        peerDeviceId: hostDeviceId,
        version: version,
      ),
    );
  }
}

/// Remembers the QR1 nonces a device has answered, so replaying a code that
/// was already used gets a sentence instead of a second handshake.
///
/// Bounded on purpose: a long-running app must not grow a set forever, and a
/// code old enough to have fallen out of the window is also old enough that
/// its ephemeral key is gone.
class OfflineNonceGuard {
  final Map<String, DateTime> _seen = {};
  final Duration window;
  final int limit;

  OfflineNonceGuard({
    this.window = const Duration(minutes: 10),
    this.limit = 512,
  });

  /// Throws when this exact nonce was answered inside the window; records it
  /// otherwise.
  void remember(List<int> nonce) {
    final now = DateTime.now();
    _seen.removeWhere((_, at) => now.difference(at) > window);
    final key = base64UrlEncode(nonce);
    final first = _seen[key];
    if (first != null && now.difference(first) <= window) {
      throw const OfflinePairingException(
        'That code has already been used here. Ask the other device to show a '
        'fresh one.',
      );
    }
    if (_seen.length >= limit) {
      final oldest = _seen.entries.reduce((a, b) => a.value.isBefore(b.value) ? a : b);
      _seen.remove(oldest.key);
    }
    _seen[key] = now;
  }

  /// Test seam: how many codes this guard is remembering.
  int get length => _seen.length;
}

// ---------------------------------------------------------------------------
// Shared pieces
// ---------------------------------------------------------------------------

/// `s1 || s2 || s3 || s4`, each 32 bytes, in an order both sides can compute:
///
///   s1 = DH(ephA, ephB)   s2 = DH(idA, ephB)
///   s3 = DH(ephA, idB)    s4 = DH(idA, idB)
///
/// A computes them with its own private keys and B's public ones; B computes
/// the same values with its own private keys and A's public ones.
Future<Uint8List> _mix({
  required PairingIdentity identity,
  required SimpleKeyPair ephemeral,
  required Uint8List peerIdentity,
  required Uint8List peerEphemeral,
  required bool host,
}) async {
  _rejectWeakKey(peerIdentity);
  _rejectWeakKey(peerEphemeral);
  final peerIdKey = SimplePublicKey(peerIdentity, type: KeyPairType.x25519);
  final peerEphKey = SimplePublicKey(peerEphemeral, type: KeyPairType.x25519);

  // Each of these four is one exchange, and the two sides compute the same
  // four exchanges in this order. s2 and s3 are the cross terms, and they are
  // the reason this order is written out rather than built from "mine" and
  // "theirs": the host's identity pairs with the guest's ephemeral, while the
  // guest's identity pairs with the host's ephemeral. Swapping those two
  // produces four valid-looking exchanges and two devices that disagree.
  final ephemeralXEphemeral = await _dh(ephemeral, peerEphKey);
  final identityXEphemeral = await _dh(identity._keyPair, peerEphKey);
  final ephemeralXIdentity = await _dh(ephemeral, peerIdKey);
  final identityXIdentity = await _dh(identity._keyPair, peerIdKey);

  final parts = <Uint8List>[
    ephemeralXEphemeral,
    host ? identityXEphemeral : ephemeralXIdentity,
    host ? ephemeralXIdentity : identityXEphemeral,
    identityXIdentity,
  ];
  final out = BytesBuilder(copy: false);
  parts.forEach(out.add);
  return out.toBytes();
}

Future<Uint8List> _dh(SimpleKeyPair mine, SimplePublicKey peer) async {
  final secret = await _x25519.sharedSecretKey(
    keyPair: mine,
    remotePublicKey: peer,
  );
  final bytes = Uint8List.fromList(await secret.extractBytes());
  // A small-order point collapses the shared secret to zero; the X25519
  // implementations differ on whether that is an error or a value, so check
  // the value itself rather than trusting either behaviour.
  var allZero = true;
  for (final byte in bytes) {
    if (byte != 0) {
      allZero = false;
      break;
    }
  }
  if (allZero) {
    throw const OfflinePairingException(
      'That device sent a key that cannot make a secret. Pairing stopped.',
    );
  }
  return bytes;
}

const _allZeroKey = <int>[
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
];

const _identityPointKey = <int>[
  1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
];

/// A public key that is all zeros or the curve identity is not a public key.
/// Anything else that is small-order still lands in [_dh], where the all-zero
/// secret is refused; between them every low-order key the RFC lists is
/// rejected before it can produce a channel key.
void _rejectWeakKey(Uint8List key) {
  if (key.length != 32) {
    throw const OfflinePairingException(
      'That pairing code has a key of the wrong size. Ask for a fresh one.',
    );
  }
  if (_constantTimeEquals(key, _allZeroKey) ||
      _constantTimeEquals(key, _identityPointKey)) {
    throw const OfflinePairingException(
      'That device sent an unusable key. Pairing stopped.',
    );
  }
}

String _transcript({
  required List<int> aIdentity,
  required String aMeshId,
  required List<int> aEphemeral,
  required List<int> aNonce,
  required List<int> bIdentity,
  required String bMeshId,
  required List<int> bEphemeral,
  required List<int> bNonce,
  required int version,
}) =>
    '$offlinePairingLabel'
    '|v=$version'
    '|meshA=$aMeshId'
    '|idA=${base64UrlEncode(aIdentity)}'
    '|ephA=${base64UrlEncode(aEphemeral)}'
    '|nonceA=${base64UrlEncode(aNonce)}'
    '|meshB=$bMeshId'
    '|idB=${base64UrlEncode(bIdentity)}'
    '|ephB=${base64UrlEncode(bEphemeral)}'
    '|nonceB=${base64UrlEncode(bNonce)}';

/// The AES-GCM channel key. Its own HKDF label over the whole transcript, so a
/// key swap anywhere changes it.
Future<Uint8List> _channelKey(Uint8List shared, String transcript) async {
  final key = await _hkdf.deriveKey(
    secretKey: SecretKey(shared),
    info: _utf8('$transcript|channel'),
  );
  return Uint8List.fromList(await key.extractBytes());
}

/// The six digits both screens show.
///
/// Deliberately a SEPARATE derivation from the channel key (own HKDF label),
/// but over the same full transcript: the code cannot be used to derive the
/// channel key, and any change to a key or nonce changes the code. That is the
/// property the man-in-the-middle test pins.
Future<String> _confirmationCode(Uint8List shared, String transcript) async {
  final key = await _hkdf.deriveKey(
    secretKey: SecretKey(shared),
    info: _utf8('$transcript|code'),
  );
  final bytes = await key.extractBytes();
  final value =
      ((bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3]) &
      0x7fffffff;
  return (value % 1000000).toString().padLeft(6, '0');
}

/// A's proof that B read *this* QR1: an HMAC under a key the shared secret
/// produces, over QR1 verbatim plus B's own fields.
Future<String> _mac({
  required Uint8List shared,
  required String transcript,
  required String qr1,
  required String peerMeshId,
  required List<int> peerIdentity,
  required List<int> peerEphemeral,
  required List<int> peerNonce,
  required String peerName,
}) async {
  final key = await _hkdf.deriveKey(
    secretKey: SecretKey(shared),
    info: _utf8('$transcript|mac'),
  );
  final keyBytes = await key.extractBytes();
  final message =
      'v=$offlinePairingVersion'
      '|qr1=$qr1'
      '|mesh=$peerMeshId'
      '|id=${base64UrlEncode(peerIdentity)}'
      '|eph=${base64UrlEncode(peerEphemeral)}'
      '|nonce=${base64UrlEncode(peerNonce)}'
      '|name=$peerName';
  final mac = await Hmac.sha256().calculateMac(
    _utf8(message),
    secretKey: SecretKey(keyBytes),
  );
  return base64UrlEncode(mac.bytes);
}

// ---------------------------------------------------------------------------
// Payload parsing
// ---------------------------------------------------------------------------

Map<String, dynamic> _parseEnvelope(
  String raw, {
  required String prefix,
  required String what,
}) {
  final text = raw.replaceAll(RegExp(r'\s+'), '');
  if (text.length > offlinePayloadMaxChars) {
    throw OfflinePairingException(
      'That $what is too long to be a Nexus pairing code.',
    );
  }
  if (!text.startsWith(prefix)) {
    throw OfflinePairingException(
      'That does not look like a Nexus pairing $what.',
    );
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(
      utf8.decode(base64Url.decode(text.substring(prefix.length))),
    );
  } on FormatException {
    throw OfflinePairingException(
      'That pairing $what is damaged. Ask for a fresh one.',
    );
  }
  if (decoded is! Map<String, dynamic>) {
    throw OfflinePairingException(
      'That pairing $what is damaged. Ask for a fresh one.',
    );
  }
  return decoded;
}

int _versionOf(Map<String, dynamic> body) {
  final version = body['v'];
  if (version is! int) {
    throw const OfflinePairingException(
      'That pairing code is missing its version. Ask for a fresh one.',
    );
  }
  if (version != offlinePairingVersion) {
    throw OfflinePairingException(
      version > offlinePairingVersion
          ? 'That code comes from a newer Nexus. Update this device first.'
          : 'That code comes from an older Nexus. Update the other device first.',
    );
  }
  return version;
}

Uint8List _keyField(Map<String, dynamic> body, String field) {
  final value = _stringField(body, field, maxLength: 128);
  final bytes = _decode(value, what: 'key');
  if (bytes.length != 32) {
    throw const OfflinePairingException(
      'That pairing code has a key of the wrong size. Ask for a fresh one.',
    );
  }
  return bytes;
}

String _idField(Map<String, dynamic> body) {
  final value = body['id'];
  if (value is! String || value.isEmpty || value.length > 64) {
    throw const OfflinePairingException(
      'That pairing code is missing the device id. Ask for a fresh one.',
    );
  }
  return value;
}

Uint8List _nonceField(Map<String, dynamic> body, String field) {
  final value = _stringField(body, field, maxLength: 64);
  final bytes = _decode(value, what: 'nonce');
  if (bytes.length != 16) {
    throw const OfflinePairingException(
      'That pairing code has a malformed nonce. Ask for a fresh one.',
    );
  }
  return bytes;
}

String _stringField(
  Map<String, dynamic> body,
  String field, {
  required int maxLength,
}) {
  final value = body[field];
  if (value is! String || value.isEmpty || value.length > maxLength) {
    throw const OfflinePairingException(
      'That pairing code is missing a field or has one too long. Ask for a '
      'fresh one.',
    );
  }
  return value;
}

Uint8List _decode(String value, {required String what}) {
  try {
    return Uint8List.fromList(base64Url.decode(value));
  } on FormatException {
    throw OfflinePairingException(
      'That pairing $what is damaged. Ask for a fresh one.',
    );
  }
}

Future<Uint8List> _publicOf(SimpleKeyPair pair) async =>
    Uint8List.fromList((await pair.extractPublicKey()).bytes);

String _cleanName(String raw) {
  final name = raw.trim();
  if (name.isEmpty) return 'Paired device';
  return name.length > 24 ? name.substring(0, 24) : name;
}

/// Our own mesh id, kept to what an announcement would carry. An id is never
/// empty in practice ([generateDeviceId] makes 32 characters); the fallback
/// keeps a hand-built test session from producing an unparseable payload.
String _cleanId(String raw) {
  final id = raw.trim();
  if (id.isEmpty || id.length > 64) return 'device';
  return id;
}

Uint8List _utf8(String value) => Uint8List.fromList(utf8.encode(value));

final _rng = Random.secure();

Uint8List _randomBytes(int length) {
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = _rng.nextInt(256);
  }
  return out;
}

// ---------------------------------------------------------------- utilities

bool _constantTimeStringEquals(String a, String b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return difference == 0;
}

bool _constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a[i] ^ b[i];
  }
  return difference == 0;
}
