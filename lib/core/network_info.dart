import 'dart:io';

final RegExp _private172 = RegExp(r'^172\.(1[6-9]|2\d|3[01])\.');

/// The device's LAN IPv4 address (e.g. 192.168.1.100), or null if it cannot
/// be determined. This is used to embed a reachable address in pairing QR
/// codes so scanning a QR is enough — no typing an address.
Future<String?> detectLanIpv4() async {
  try {
    final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
    String? fallback;
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        final ip = addr.address;
        if (ip.startsWith('127.') || ip.startsWith('169.254.')) continue;
        fallback ??= ip;
        // Prefer private LAN ranges (10.x, 192.168.x, 172.16-31.x).
        if (ip.startsWith('10.') || ip.startsWith('192.168.') || _private172.hasMatch(ip)) {
          return ip;
        }
      }
    }
    return fallback;
  } catch (_) {
    return null;
  }
}

/// Every non-loopback IPv4 address on this device — LAN, VPN, and Tailscale
/// (100.x.y.z) interfaces alike.
///
/// Paired devices store all of these and try them in order, which is what
/// makes "access from far away" work: the LAN address works at home, and the
/// Tailscale address works from anywhere (as long as both devices are on the
/// same tailnet).
Future<List<String>> detectAllIpv4s() async {
  final out = <String>[];
  try {
    final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        final ip = addr.address;
        if (ip.startsWith('127.') || ip.startsWith('169.254.')) continue;
        if (!out.contains(ip)) out.add(ip);
      }
    }
  } catch (_) {
    // No interfaces readable — return what we have (likely nothing).
  }
  return out;
}
