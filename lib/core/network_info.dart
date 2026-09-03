import 'dart:async';
import 'dart:convert';
import 'dart:io';

final RegExp _private172 = RegExp(r'^172\.(1[6-9]|2\d|3[01])\.');

/// Whether an IP belongs to Tailscale's CGNAT range (100.64.0.0/10 and
/// 100.100.0.0/10) or is assigned to a Tailscale interface.
bool isTailscaleIp(String ip) =>
    ip.startsWith('100.64.') ||
    ip.startsWith('100.100.') ||
    ip.startsWith('100.128.');

/// The device's LAN IPv4 address (e.g. 192.168.1.100), or null if it cannot
/// be determined. This is used to embed a reachable address in pairing QR
/// codes so scanning a QR is enough — no typing an address.
Future<String?> detectLanIpv4() async {
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    String? fallback;
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        final ip = addr.address;
        if (ip.startsWith('127.') || ip.startsWith('169.254.')) continue;
        fallback ??= ip;
        // Prefer private LAN ranges (10.x, 192.168.x, 172.16-31.x).
        if (ip.startsWith('10.') ||
            ip.startsWith('192.168.') ||
            _private172.hasMatch(ip)) {
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
///
/// IP priority: LAN (10.x, 192.168.x, 172.16-31.x) first, then Tailscale
/// (100.x), then other VPNs, so the fastest route is tried first.
Future<List<String>> detectAllIpv4s() async {
  final lan = <String>[];
  final tailscale = <String>[];
  final vpn = <String>[];
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        final ip = addr.address;
        if (ip.startsWith('127.') || ip.startsWith('169.254.')) continue;
        // Tailscale interface: names often contain "tailscale" or "utun"
        // and the IP is in the CGNAT range.
        final ifaceName = iface.name.toLowerCase();
        final isTailscale =
            isTailscaleIp(ip) ||
            ifaceName.contains('tailscale') ||
            ifaceName.startsWith('utun');
        if (isTailscale) {
          if (!tailscale.contains(ip)) tailscale.add(ip);
        } else if (ip.startsWith('10.') ||
            ip.startsWith('192.168.') ||
            _private172.hasMatch(ip)) {
          if (!lan.contains(ip)) lan.add(ip);
        } else {
          if (!vpn.contains(ip)) vpn.add(ip);
        }
      }
    }
  } catch (_) {
    // No interfaces readable — return what we have (likely nothing).
  }
  return [...lan, ...tailscale, ...vpn];
}

/// Cached result of [detectTailscaleInfo] so the `tailscale status --json`
/// subprocess is only spawned once per session.
TailscaleInfo? _tailscaleInfoCache;
bool _tailscaleProbeDone = false;

/// Whether Tailscale is installed and online on this device.
/// Delegates to [detectTailscaleInfo] so the subprocess runs at most once.
Future<bool> isTailscaleAvailable() async {
  if (_tailscaleProbeDone) return _tailscaleInfoCache?.online ?? false;
  final info = await detectTailscaleInfo();
  return info?.online ?? false;
}

/// The Tailscale hostname and IPv4 for this device, or null when Tailscale
/// is not running. Caches its result so the `tailscale status --json`
/// subprocess is spawned at most once per session.
Future<TailscaleInfo?> detectTailscaleInfo() async {
  if (_tailscaleProbeDone) return _tailscaleInfoCache;
  try {
    final result = await Process.run('tailscale', ['status', '--json']).timeout(
      const Duration(seconds: 3),
      onTimeout: () {
        throw TimeoutException('tailscale status timed out');
      },
    );
    _tailscaleProbeDone = true;
    if (result.exitCode != 0) {
      _tailscaleInfoCache = null;
      return null;
    }
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    final self = json['Self'] as Map<String, dynamic>?;
    if (self == null) {
      _tailscaleInfoCache = null;
      return null;
    }
    final ip = self['TailscaleIPs'] as List?;
    final ipv4 = ip != null && ip.isNotEmpty ? ip.first.toString() : null;
    final hostname =
        self['HostName']?.toString() ?? self['DNSName']?.toString();
    final online = self['Online'] == true;
    _tailscaleInfoCache = TailscaleInfo(
      hostname: hostname,
      ipv4: ipv4,
      online: online,
    );
    return _tailscaleInfoCache;
  } catch (_) {
    _tailscaleProbeDone = true;
    _tailscaleInfoCache = null;
    return null;
  }
}

/// Information about this device's Tailscale status.
class TailscaleInfo {
  /// The Tailscale hostname (the name this device uses on the tailnet).
  final String? hostname;

  /// The Tailscale IPv4 address (e.g. 100.64.1.2).
  final String? ipv4;

  /// Whether the Tailscale daemon reports as online (connected to a tailnet).
  final bool online;

  const TailscaleInfo({this.hostname, this.ipv4, this.online = false});
}
