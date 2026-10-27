// The pairing QR's payload: a small JSON object, one device talking to another.
//
// This is the *shell's* pairing format, and it is deliberately the boring one:
// three fields a user can read back and a scanner can parse without a
// handshake — who the device is, its mesh id, and its public key. Everything
// else (addresses, ports, one-time codes, expiry) belongs to the paid-for
// version of pairing the mesh service already speaks (`nexus://pair` v1 and
// v2 in `pair_payload.dart` / `qr_pairing.dart`); this file is what the front
// end can show and read *today*, on a build with no mesh attached yet.
//
// It is JSON rather than a URI for one reason: the other end may be a phone,
// a laptop with a camera, or a paste into a chat — and a JSON object is the one
// shape all three can be handed to without a parser that has to agree with us
// about query strings. The `type` field is what makes a random QR code (a
// website, a coupon, a vCard) refusable by name instead of by guess:
//
//   {"type":"nexus_pair","device_name":"My phone",
//    "device_id":"h3k…","public_key":"…"}
//
// Parsing is strict on purpose. A code that is *nearly* ours — a truncated
// paste, a field renamed by a future build — must not produce a half-device in
// the paired list: it is refused, and the scanner says so on screen.
library;

import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, visibleForTesting;

import 'dart:io' show InternetAddress, InternetAddressType, NetworkInterface;

import 'identity.dart' show DeviceInfo, defaultDeviceName, generateDeviceId;
import 'pair_payload.dart' show PairPayload;

/// The `type` field every Nexus pairing code carries.
const String kNexusPairType = 'nexus_pair';

/// The label the shell pairs under when it has no platform-provided name.
///
/// The real mesh names devices from the platform (`Build.MODEL` on Android,
/// the hostname on a desktop) and the shell has no such channel yet. What it
/// does have is the platform itself, and [defaultDeviceName] already owns that
/// translation — so the QR says "My phone" on Android rather than inventing a
/// model name nobody can check. When a device-name channel lands, this is the
/// one line that changes: [PairIdentity] is the seam.
String defaultPairDeviceName() => defaultDeviceName(defaultPairPlatformToken());

/// This device's platform as the pairing code spells it.
///
/// The same tokens the mesh uses (`android`, `linux`, `macos`), so a device
/// that pairs through either path is described the same way. The name above and
/// the paired card's "is this a PC?" both read this one mapping.
String defaultPairPlatformToken() {
  final TargetPlatform platform = defaultTargetPlatform;
  // `TargetPlatform.name` spells two of these differently from the tokens
  // `defaultDeviceName` matches on.
  return switch (platform) {
    TargetPlatform.iOS => 'ios',
    TargetPlatform.macOS => 'macos',
    _ => platform.name,
  };
}

/// A stand-in for the mesh public key on a build with no mesh attached.
///
/// 32 random bytes as base64url — the same shape and size the real key has, so
/// the payload is structurally what the other device will see once the mesh is
/// wired up. It is generated per app run rather than stored, because a
/// placeholder that survives a restart is indistinguishable from a real key the
/// day somebody reads the list.
String placeholderPublicKey([Random? rng]) {
  final random = rng ?? Random.secure();
  final bytes = List<int>.generate(32, (_) => random.nextInt(256));
  const alphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
  final out = StringBuffer();
  var i = 0;
  while (i < bytes.length) {
    final b0 = bytes[i++];
    final b1 = i < bytes.length ? bytes[i++] : -1;
    final b2 = i < bytes.length ? bytes[i++] : -1;
    out.writeCharCode(alphabet.codeUnitAt(b0 >> 2));
    out.writeCharCode(
      alphabet.codeUnitAt(((b0 & 3) << 4) | (b1 >= 0 ? b1 >> 4 : 0)),
    );
    if (b1 >= 0) {
      out.writeCharCode(
        alphabet.codeUnitAt(((b1 & 15) << 2) | (b2 >= 0 ? b2 >> 6 : 0)),
      );
    }
    if (b2 >= 0) out.writeCharCode(alphabet.codeUnitAt(b2 & 63));
  }
  return out.toString();
}

/// What one device tells another when it shows a pairing QR.
class PairInvite {
  const PairInvite({
    required this.deviceName,
    required this.deviceId,
    required this.publicKey,
    this.addresses = const <String>[],
    this.port = 0,
    this.code = '',
    this.ramBytes,
    this.platform = '',
    this.ollama = false,
  });

  /// What the other user sees on their screen — "Paired with My phone".
  final String deviceName;

  /// The mesh id this device will be known by. Stable for the install.
  final String deviceId;

  /// The key the other device would use to address it. See
  /// [placeholderPublicKey] for what it is on a build with no mesh.
  final String publicKey;

  /// Where the device said it could be reached, best first. Empty when the
  /// code did not carry an address (an older `nexus_pair` payload, or a device
  /// that did not know its own), which is a real answer rather than a failure:
  /// a device can still be paired now and found later by discovery.
  ///
  /// These are IPv4/IPv6 literals on the local network — the same addresses the
  /// mesh announces — and they are what makes a scanned device *dialable* later
  /// without a second scan.
  final List<String> addresses;

  /// The port the other side listens on for the mesh, or 0 when the code did
  /// not say. 51820 is the mesh's own default (see `MeshService.defaultPort`).
  final int port;

  /// The one-time pairing code from a `nexus://pair` code, or empty. The shell
  /// keeps it so the day the mesh is wired into this screen the pairing that
  /// was already made can be completed without asking the user to scan again.
  final String code;

  /// The memory the device says it has, in bytes, or null when it did not say.
  ///
  /// Part of the pairing code because this is the one moment the two devices
  /// are certainly talking: a phone that knows its PC has 16 GB can offer the
  /// bigger model on it without another round trip, and the Devices screen can
  /// add up the mesh's RAM from the list it already has.
  final int? ramBytes;

  /// The platform token the other device named — `linux`, `android`, `macos`.
  ///
  /// It is what lets the paired card offer a trackpad only when the peer is a
  /// desktop, rather than guessing from a name that could be anything. Older
  /// codes do not carry it, and an empty value is truthful: the platform was
  /// never learned.
  final String platform;

  /// Whether the PC said Ollama was answering when it showed this code.
  ///
  /// The phone can route a heavy answer to a desktop it already paired with by
  /// probing `/api/tags` on every answer anyway; this field is the pairing-time
  /// fact that lets the route be chosen without guessing, and it is what makes
  /// a PC that never had Ollama skip the probe until it says otherwise. Older
  /// codes carry no field, and false is the honest default.
  final bool ollama;

  /// The first address, or null. What a row shows when it shows one address.
  String? get address => addresses.isEmpty ? null : addresses.first;

  /// The exact bytes the QR carries. One definition, so the QR a device shows
  /// and the QR another device parses can never disagree about the shape.
  ///
  /// Field order is fixed (type, device_name, device_id, public_key) so the
  /// payload a test asserts on is the payload a person would read.
  String encode() => jsonEncode(<String, Object>{
    'type': kNexusPairType,
    'device_name': deviceName,
    'device_id': deviceId,
    'public_key': publicKey,
    // Omitted when unknown, so the code an older build reads is byte-identical
    // to the one it used to write — and so a device with no network does not
    // advertise an empty address.
    if (addresses.isNotEmpty) 'address': addresses.first,
    if (addresses.length > 1) 'ips': addresses.join(','),
    if (port > 0) 'port': '$port',
    if (code.isNotEmpty) 'code': code,
    if (ramBytes != null && ramBytes! > 0) 'ram_bytes': '$ramBytes',
    if (platform.isNotEmpty) 'platform': platform,
    if (ollama) 'ollama': true,
  });

  /// The PC's code: the same identity, plus the two fields a phone needs to
  /// route to it without a build flag — `name` and `address` under the names
  /// the desktop pair page documents, and `port` as a number rather than the
  /// string the older payloads carry. The older names stay in the object too,
  /// so a phone running an older build still parses it.
  String encodeForDesktop() => jsonEncode(<String, Object>{
    'type': kNexusPairType,
    'name': deviceName,
    'address': address ?? '',
    'port': port,
    'code': code,
    'device_name': deviceName,
    'device_id': deviceId,
    'public_key': publicKey,
    if (addresses.length > 1) 'ips': addresses.join(','),
    if (platform.isNotEmpty) 'platform': platform,
    if (ollama) 'ollama': true,
  });

  /// Reads a scanned string, or null when it is not a Nexus pairing code.
  ///
  /// Never throws: a scanner is pointed at the world, and the world is full of
  /// QR codes that are not ours — a website link, a ticket, a vCard, half a
  /// JSON object with the tail cut off. Every one of those is a null here, and
  /// the caller turns it into one sentence on screen.
  static PairInvite? parse(String raw) {
    final trimmed = raw.trim();
    // Cheap gate first: none of the shaped-wrong payloads below are even JSON.
    if (!trimmed.startsWith('{') || !trimmed.contains(kNexusPairType)) {
      return null;
    }
    Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final type = decoded['type'];
    if (type is! String || type != kNexusPairType) return null;

    final String? name =
        _field(decoded, 'device_name') ?? _field(decoded, 'name');
    final String? id = _field(decoded, 'device_id');
    final String? key = _field(decoded, 'public_key');
    if (name == null || id == null || key == null) return null;
    final List<String> addresses = _addressesOf(decoded);
    final int port = _intOf(decoded, 'port');
    final String? code = _field(decoded, 'code');
    final String? platform = _field(decoded, 'platform');
    final int ramBytes = _intOf(decoded, 'ram_bytes');
    // A device id too short to be an id is a payload somebody typed by hand or
    // a field that lost half its value in a paste. The real id is 32
    // characters (see `generateDeviceId`), and refusing a 3-character one here
    // is the difference between "paired with a phone" and "paired with `a`".
    if (id.length < 8) return null;
    return PairInvite(
      deviceName: name,
      deviceId: id,
      publicKey: key,
      addresses: addresses,
      port: port,
      code: code ?? '',
      ramBytes: ramBytes > 0 ? ramBytes : null,
      platform: platform ?? '',
      ollama: decoded['ollama'] == true,
    );
  }

  /// Every address the payload named, `address` first and `ips` after it, with
  /// duplicates and blanks dropped. A malformed list is not a reason to refuse
  /// the pairing — the device is still who it says it is.
  static List<String> _addressesOf(Map<dynamic, dynamic> json) {
    final List<String> out = <String>[];
    void add(String? raw) {
      for (final String part in (raw ?? '').split(',')) {
        final String trimmed = part.trim();
        if (trimmed.isNotEmpty && !out.contains(trimmed)) out.add(trimmed);
      }
    }

    add(_field(json, 'address'));
    add(_field(json, 'ips'));
    return out;
  }

  /// Reads *any* Nexus pairing code the scanner can be pointed at.
  ///
  /// Two formats are in the world at once and both are honest: this shell's
  /// `nexus_pair` JSON (used by [PairQrPage]), and the mesh's own
  /// `nexus://pair` URI, which carries the device id, its name and the address
  /// it can be reached at — exactly what a row needs to exist. A v2 token is
  /// deliberately *not* here: it carries no device id by design (it is an
  /// ephemeral, single-use handshake), so a screen with no mesh behind it has
  /// nothing to store. The caller says so in words rather than pairing a
  /// nameless row.
  static PairInvite? fromAnyCode(String raw) {
    final PairInvite? ours = parse(raw);
    if (ours != null) return ours;
    final PairPayload? mesh = PairPayload.parse(raw);
    if (mesh == null) return null;
    // The same rule the JSON path applies: a device id too short to be one is a
    // payload somebody typed by hand or a field that lost half its value.
    if (mesh.id.length < 8) return null;
    return PairInvite(
      deviceName: mesh.name,
      deviceId: mesh.id,
      publicKey: '',
      addresses: <String>[
        if (mesh.ip != null && mesh.ip!.isNotEmpty) mesh.ip!,
        for (final String address in mesh.ips)
          if (address.isNotEmpty && address != mesh.ip) address,
      ],
      port: mesh.port,
      code: mesh.code,
      ramBytes: mesh.ramBytes,
    );
  }

  @override
  String toString() =>
      'PairInvite($deviceName, $deviceId, ${addresses.isEmpty ? 'no address' : addresses.first})';

  /// One integer field, accepting the string older payloads wrote and the
  /// number the desktop code writes. Missing or malformed is 0.
  static int _intOf(Map<dynamic, dynamic> json, String key) {
    final Object? value = json[key];
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim()) ?? 0;
    return 0;
  }

  /// One required string field, trimmed, or null when it is missing, empty, or
  /// the wrong kind.
  static String? _field(Map<dynamic, dynamic> json, String key) {
    final Object? value = json[key];
    if (value is! String) return null;
    final String trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

/// Who this device is on the mesh, as the pairing QR says it.
///
/// One seam, because this is exactly the object the mesh service will own the
/// day it is wired into the shell: it has a [DeviceInfo] and a real keypair
/// already (`identity.dart`, `crypto.dart`), and the shell has neither. Until
/// then the default is a name from the platform, a freshly generated id, and
/// [placeholderPublicKey] — honest placeholders rather than a pretend identity.
class PairIdentity {
  const PairIdentity({
    required this.name,
    required this.id,
    required this.publicKey,
    this.addresses = const <String>[],
    this.port = 0,
    this.ramBytes,
    this.token = '',
    this.platform = '',
  });

  /// Test seam, in the same shape as [SpeechInput.override]: a test states who
  /// this device is instead of accepting a random id. The app never sets it.
  @visibleForTesting
  static PairIdentity Function()? override;

  static PairIdentity get current => override?.call() ?? _default();

  static PairIdentity? _memo;

  /// Memoised, so the QR a user shows twice in one session is the same code —
  /// an id that changed between the sheet and the page would make the other
  /// device's scan fail for a reason nobody could see.
  static PairIdentity _default() => _memo ??= PairIdentity(
    name: defaultPairDeviceName(),
    id: generateDeviceId(),
    publicKey: placeholderPublicKey(),
    platform: defaultPairPlatformToken(),
  );

  /// Forgets the memoised identity. Tests use it; the app never does.
  @visibleForTesting
  static void debugReset() => _memo = null;

  /// Makes [info] the identity this process answers with.
  ///
  /// Called once by `startAppServices`, after the store has been loaded: the id
  /// in the store is the one the device keeps, and the QR, the discovery
  /// announcements and the file link all have to speak it. Without this each
  /// launch generated a new id ([generateDeviceId]'s fallback), so no peer could
  /// keep recognising this device — the pairing rows they wrote pointed at an id
  /// this process had already thrown away.
  ///
  /// [override] still wins, so a test that states an identity is unaffected.
  static void install(DeviceInfo info) {
    _memo = PairIdentity(
      name: info.name,
      id: info.id,
      publicKey: placeholderPublicKey(),
      platform: info.platform,
    );
  }

  final String name;
  final String id;
  final String publicKey;

  /// Where this device can be reached, which the QR carries so the other side
  /// has somewhere to dial. Empty by default: the identity is built before any
  /// network call, and an address invented here would be a claim — the page
  /// that draws the code fills these in with the real ones when it has them.
  final List<String> addresses;

  /// The mesh port this device listens on, 0 when the identity does not know.
  final int port;

  /// This device's RAM, when it has been read. Null until a caller fills it in
  /// with [withHardware]; the identity is built synchronously and the probe is
  /// not, which is why it is a field rather than a getter that lies.
  final int? ramBytes;

  /// The file-transfer secret this device shows in its QR ([PairToken]). Empty
  /// until a caller loads it with [withToken]: the identity is built before the
  /// first frame, and the token is a preference read.
  final String token;

  /// The platform token this device names in its QR. Empty for an identity a
  /// test stated without one.
  final String platform;

  PairInvite get invite => PairInvite(
    deviceName: name,
    deviceId: id,
    publicKey: publicKey,
    addresses: addresses,
    port: port,
    code: token,
    ramBytes: ramBytes,
    platform: platform,
  );

  /// The same identity, with the token that authenticates its transfers.
  PairIdentity withToken(String token) => PairIdentity(
    name: name,
    id: id,
    publicKey: publicKey,
    addresses: addresses,
    port: port,
    ramBytes: ramBytes,
    token: token,
    platform: platform,
  );

  /// The same identity, with the addresses the device actually has.
  PairIdentity withAddresses(List<String> addresses, {int? port}) =>
      PairIdentity(
        name: name,
        id: id,
        publicKey: publicKey,
        addresses: addresses,
        port: port ?? this.port,
        ramBytes: ramBytes,
        token: token,
        platform: platform,
      );

  /// The same identity, with the hardware facts the code can carry.
  PairIdentity withHardware({int? ramBytes}) => PairIdentity(
    name: name,
    id: id,
    publicKey: publicKey,
    addresses: addresses,
    port: port,
    ramBytes: ramBytes ?? this.ramBytes,
    token: token,
    platform: platform,
  );
}

/// This device's own non-loopback IPv4 addresses, best first.
///
/// The same rule the mesh uses to decide where it can be reached (`_myIps` in
/// `mesh/mesh_service.dart`): every interface that has an IPv4 address, loopback
/// and link-local excluded. It is read for one reason — to put an address in
/// this device's pairing code — and a failure answers an empty list rather than
/// an error, because a code with no address is still a valid code.
Future<List<String>> localAddresses() async {
  try {
    final List<NetworkInterface> interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    final List<String> out = <String>[];
    for (final NetworkInterface interface in interfaces) {
      for (final InternetAddress address in interface.addresses) {
        final String ip = address.address;
        if (ip.startsWith('169.254.')) continue;
        if (!out.contains(ip)) out.add(ip);
      }
    }
    return out;
  } catch (_) {
    return const <String>[];
  }
}
