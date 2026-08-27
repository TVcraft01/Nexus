import 'dart:io';
import 'dart:math';

/// A device's stable identity within the Nexus mesh.
class DeviceInfo {
  final String id;

  /// Mutable so a rename takes effect live (announcements and heartbeats
  /// carry the current name to every paired device) instead of waiting for
  /// the next restart.
  String name;
  final String platform; // 'android' | 'linux' | 'windows' | 'macos' | 'ios' | 'other'

  DeviceInfo({
    required this.id,
    required this.name,
    required this.platform,
  });

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'platform': platform};

  factory DeviceInfo.fromJson(Map<String, dynamic> json) => DeviceInfo(
        id: json['id'] as String,
        name: json['name'] as String,
        platform: json['platform'] as String? ?? 'other',
      );
}

const _idAlphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';

/// A random, unguessable 32-char device id (not an identifier that reveals
/// anything about the device — just a stable name for the mesh).
String generateDeviceId() {
  final rng = Random.secure();
  final buf = StringBuffer();
  for (var i = 0; i < 32; i++) {
    buf.write(_idAlphabet[rng.nextInt(_idAlphabet.length)]);
  }
  return buf.toString();
}

/// Alphabet without easily-confused characters (I, O, 0, 1, l).
const _codeAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

/// An 8-character pairing code in the form XXXX-XXXX.
///
/// The code IS the shared secret: only a device that saw it (via QR or by
/// typing it) can complete pairing, and everything after pairing is
/// encrypted with a key derived from it.
String generatePairingCode() {
  final rng = Random.secure();
  final buf = StringBuffer();
  for (var i = 0; i < 8; i++) {
    buf.write(_codeAlphabet[rng.nextInt(_codeAlphabet.length)]);
    if (i == 3) buf.write('-');
  }
  return buf.toString();
}

String sanitizeDeviceName(String raw) {
  final name = raw.trim();
  if (name.isEmpty) return 'My device';
  return name.length > 24 ? name.substring(0, 24) : name;
}

/// Friendly default name based on the platform, using the machine hostname
/// on desktop so two PCs don't both call themselves "Linux PC".
String defaultDeviceName(String platform) {
  switch (platform) {
    case 'android':
      return 'My phone';
    case 'linux':
    case 'windows':
    case 'macos':
      final host = _safeHostname();
      return host.isNotEmpty ? host : 'My computer';
    default:
      return 'My device';
  }
}

String _safeHostname() {
  try {
    return Platform.localHostname.split('.').first;
  } catch (_) {
    return '';
  }
}
