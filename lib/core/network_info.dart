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
