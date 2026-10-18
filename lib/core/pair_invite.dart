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

import 'identity.dart' show defaultDeviceName, generateDeviceId;

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
String defaultPairDeviceName() {
  final TargetPlatform platform = defaultTargetPlatform;
  // `TargetPlatform.name` spells two of these differently from the tokens
  // `defaultDeviceName` matches on, and a name that falls through the switch is
  // a device that calls itself "My device" for no reason a reader can see.
  final String token = switch (platform) {
    TargetPlatform.iOS => 'ios',
    TargetPlatform.macOS => 'macos',
    _ => platform.name,
  };
  return defaultDeviceName(token);
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
  });

  /// What the other user sees on their screen — "Paired with My phone".
  final String deviceName;

  /// The mesh id this device will be known by. Stable for the install.
  final String deviceId;

  /// The key the other device would use to address it. See
  /// [placeholderPublicKey] for what it is on a build with no mesh.
  final String publicKey;

  /// The exact bytes the QR carries. One definition, so the QR a device shows
  /// and the QR another device parses can never disagree about the shape.
  ///
  /// Field order is fixed (type, device_name, device_id, public_key) so the
  /// payload a test asserts on is the payload a person would read.
  String encode() => jsonEncode(<String, String>{
    'type': kNexusPairType,
    'device_name': deviceName,
    'device_id': deviceId,
    'public_key': publicKey,
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

    final String? name = _field(decoded, 'device_name');
    final String? id = _field(decoded, 'device_id');
    final String? key = _field(decoded, 'public_key');
    if (name == null || id == null || key == null) return null;
    // A device id too short to be an id is a payload somebody typed by hand or
    // a field that lost half its value in a paste. The real id is 32
    // characters (see `generateDeviceId`), and refusing a 3-character one here
    // is the difference between "paired with a phone" and "paired with `a`".
    if (id.length < 8) return null;
    return PairInvite(deviceName: name, deviceId: id, publicKey: key);
  }

  /// One required string field, trimmed, or null when it is missing, empty, or
  /// the wrong kind.
  static String? _field(Map<dynamic, dynamic> json, String key) {
    final Object? value = json[key];
    if (value is! String) return null;
    final String trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  @override
  String toString() => 'PairInvite($deviceName, $deviceId)';
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
  static PairIdentity _default() =>
      _memo ??= PairIdentity(
        name: defaultPairDeviceName(),
        id: generateDeviceId(),
        publicKey: placeholderPublicKey(),
      );

  /// Forgets the memoised identity. Tests use it; the app never does.
  @visibleForTesting
  static void debugReset() => _memo = null;

  final String name;
  final String id;
  final String publicKey;

  PairInvite get invite =>
      PairInvite(deviceName: name, deviceId: id, publicKey: publicKey);
}
