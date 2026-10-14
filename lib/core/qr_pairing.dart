import 'dart:math';

/// Minimal, ephemeral QR pairing token (v2).
///
/// The QR carries ONLY what a scan needs to open a pairing request:
/// version, pairing id, ephemeral public key, expiry, nonce — plus a
/// transport hint (address/port) strictly required to reach the shower on a
/// LAN where mDNS may be filtered. No contacts, files, clipboard, location,
/// history, device name, or stable device identifiers.
///
/// Security properties:
/// - Single-use: the shower marks a pid used on accept/reject; replays fail.
/// - Expires in ~120 seconds.
/// - Tamper-evident: [checksum] covers every field; any mutation fails parse.
/// - Scan leaks nothing: parsing returns transport + key material only. No
///   secret is stored and no session is created until BOTH sides confirm.
/// - Mutual confirmation: B's scan only builds a request; A's explicit
///   [QrInboundRequest] accept is what pairs. The 4-digit [code] shown on
///   both sides is derived from pid|pub|nonce so users compare the same value.
class QrPairingToken {
  static const int currentVersion = 2;

  /// How long a shown QR stays valid.
  static const Duration validity = Duration(seconds: 120);

  final int version;
  final String pairingId;
  final String publicKey;
  final int expiryMs;
  final String nonce;
  final String? address;
  final int port;
  final String code;
  final String checksum;

  const QrPairingToken({
    this.version = currentVersion,
    required this.pairingId,
    required this.publicKey,
    required this.expiryMs,
    required this.nonce,
    this.address,
    required this.port,
    required this.code,
    required this.checksum,
  });

  static final _rng = Random.secure();
  static const _pidAlphabet =
      'ABCDEFGHJKLMNPQRSTUVWXYZ23456789abcdefghjkmnpqrstuvwxyz';
  static const _nonceAlphabet =
      'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  static String _random(int len, String alphabet) => String.fromCharCodes(
    List.generate(len, (_) => alphabet.codeUnitAt(_rng.nextInt(alphabet.length))),
  );

  /// 32 random bytes as base64url (ephemeral per-QR key material, NOT a
  /// stable device identifier).
  static String _randomPub() {
    final bytes = List.generate(32, (_) => _rng.nextInt(256));
    return _b64u(bytes);
  }

  static String _b64u(List<int> bytes) {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
    final out = StringBuffer();
    var i = 0;
    while (i < bytes.length) {
      final b0 = bytes[i++];
      final b1 = i < bytes.length ? bytes[i++] : -1;
      final b2 = i < bytes.length ? bytes[i++] : -1;
      out.writeCharCode(chars.codeUnitAt(b0 >> 2));
      out.writeCharCode(chars.codeUnitAt(((b0 & 3) << 4) | (b1 >= 0 ? b1 >> 4 : 0)));
      if (b1 >= 0) {
        out.writeCharCode(
          chars.codeUnitAt(((b1 & 15) << 2) | (b2 >= 0 ? b2 >> 6 : 0)),
        );
      }
      if (b2 >= 0) out.writeCharCode(chars.codeUnitAt(b2 & 63));
    }
    return out.toString();
  }

  /// djb2 hex — sync integrity checksum, not a security boundary. The real
  /// pairing security is the out-of-band QR + mutual confirmation + the
  /// pid|nonce-derived handshake key. The checksum only makes tampering
  /// fail fast at parse time.
  static String _checksumOf(String canonical) {
    var h = 5381;
    for (var i = 0; i < canonical.length; i++) {
      h = ((h << 5) + h + canonical.codeUnitAt(i)) & 0xFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(8, '0');
  }

  static String canonicalString({
    required String pairingId,
    required String publicKey,
    required int expiryMs,
    required String nonce,
    required String address,
    required int port,
    required String code,
  }) => 'v2|$pairingId|$publicKey|$expiryMs|$nonce|$address|$port|$code';

  /// 4-digit confirmation code both sides display, derived from pid|pub|nonce.
  static String deriveCode(String pairingId, String publicKey, String nonce) {
    var h = 5381;
    final s = '$pairingId|$publicKey|$nonce';
    for (var i = 0; i < s.length; i++) {
      h = ((h << 5) + h + s.codeUnitAt(i)) & 0xFFFFFFFF;
    }
    return (h % 10000).toString().padLeft(4, '0');
  }

  /// Creates a fresh single-use token. [nowMs] is injectable for tests.
  factory QrPairingToken.generate({
    String? address,
    required int port,
    int? nowMs,
  }) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final pid = _random(16, _pidAlphabet);
    final pub = _randomPub();
    final nonce = _random(12, _nonceAlphabet);
    final exp = now + validity.inMilliseconds;
    final code = deriveCode(pid, pub, nonce);
    final addr = (address ?? '').trim();
    final chk = _checksumOf(
      canonicalString(
        pairingId: pid,
        publicKey: pub,
        expiryMs: exp,
        nonce: nonce,
        address: addr,
        port: port,
        code: code,
      ),
    );
    return QrPairingToken(
      pairingId: pid,
      publicKey: pub,
      expiryMs: exp,
      nonce: nonce,
      address: addr.isEmpty ? null : addr,
      port: port,
      code: code,
      checksum: chk,
    );
  }

  String encode() {
    final params = <String, String>{
      'v': '$version',
      'pid': pairingId,
      'pub': publicKey,
      'exp': '$expiryMs',
      'nonce': nonce,
      'port': '$port',
      'code': code,
      'chk': checksum,
    };
    if (address != null && address!.isNotEmpty) params['addr'] = address!;
    return 'nexus://pair?${Uri(queryParameters: params).query}';
  }

  /// Parses a scanned string. Returns null for anything that is not a valid,
  /// unexpired, untampered v2 token. [nowMs] is injectable for tests.
  /// Never throws.
  static QrPairingToken? parse(String raw, {int? nowMs}) {
    final trimmed = raw.trim();
    if (!trimmed.startsWith('nexus://pair')) return null;
    final q = trimmed.contains('?')
        ? trimmed.substring(trimmed.indexOf('?') + 1)
        : '';
    Map<String, String> p;
    try {
      p = Uri.splitQueryString(q);
    } catch (_) {
      return null;
    }
    if ((p['v'] ?? '') != '$currentVersion') return null;
    final pid = p['pid'] ?? '';
    final pub = p['pub'] ?? '';
    final nonce = p['nonce'] ?? '';
    final code = p['code'] ?? '';
    final chk = p['chk'] ?? '';
    final exp = int.tryParse(p['exp'] ?? '');
    final port = int.tryParse(p['port'] ?? '');
    final addr = (p['addr'] ?? '').trim();
    if (pid.length < 8 ||
        pub.length < 16 ||
        nonce.length < 6 ||
        exp == null ||
        port == null ||
        port <= 0 ||
        port > 65535 ||
        code.length != 4 ||
        int.tryParse(code) == null ||
        chk.isEmpty) {
      return null;
    }
    if (deriveCode(pid, pub, nonce) != code) return null;
    if (_checksumOf(
          canonicalString(
            pairingId: pid,
            publicKey: pub,
            expiryMs: exp,
            nonce: nonce,
            address: addr,
            port: port,
            code: code,
          ),
        ) !=
        chk) {
      return null;
    }
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    if (now >= exp) return null;
    // Bound the validity window: a token minted more than ~150s in the
    // future is clock-skew or forgery, not a fresh QR.
    if (exp - now > validity.inMilliseconds + 30000) return null;
    return QrPairingToken(
      pairingId: pid,
      publicKey: pub,
      expiryMs: exp,
      nonce: nonce,
      address: addr.isEmpty ? null : addr,
      port: port,
      code: code,
      checksum: chk,
    );
  }

  bool get expired =>
      DateTime.now().millisecondsSinceEpoch >= expiryMs;
}

/// An inbound QR pairing request waiting for the shower's explicit accept.
/// Created when a valid token's request arrives; pairing happens ONLY via
/// an explicit accept call — never on scan/receipt alone.
class QrInboundRequest {
  final String pairingId;
  final String fromDeviceLabel;
  final String code;
  final int expiryMs;
  final String address;
  final int port;

  const QrInboundRequest({
    required this.pairingId,
    required this.fromDeviceLabel,
    required this.code,
    required this.expiryMs,
    required this.address,
    required this.port,
  });

  bool get expired =>
      DateTime.now().millisecondsSinceEpoch >= expiryMs;
}

/// Pairing state machine for the QR flow:
/// idle -> showingQr -> scanning -> requestSent -> awaitingConfirm ->
/// accepted/denied -> paired -> revoked.
enum QrPairingState {
  idle,
  showingQr,
  scanning,
  requestSent,
  awaitingConfirm,
  accepted,
  denied,
  paired,
  revoked,
}
