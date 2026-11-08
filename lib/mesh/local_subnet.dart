// Which addresses may be swept, and which may never be.
//
// A discovery sweep dials every host on one subnet, which is only acceptable
// on the private network this device is already on. Nothing here may ever
// produce a public address: not a hotspot peer's public IP, not a VPN exit, not
// the internet. The sweep is also the reason the window is one /24 — dart:io
// exposes no netmask, a home network is a /24 in practice, and a /16 would be
// 65,534 connections a phone never finishes.
import 'dart:io';

/// Whether [ip] is an RFC1918 address: 10/8, 172.16/12 or 192.168/16.
bool isPrivateIPv4(String ip) {
  final List<String> parts = ip.split('.');
  if (parts.length != 4) return false;
  final List<int> octets = <int>[];
  for (final String part in parts) {
    final int? value = int.tryParse(part);
    if (value == null || value < 0 || value > 255) return false;
    octets.add(value);
  }
  if (octets[0] == 10) return true;
  if (octets[0] == 192 && octets[1] == 168) return true;
  if (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) return true;
  return false;
}

/// The host addresses of the /24 around [ip], excluding [ip] itself.
///
/// A public or malformed address yields no hosts at all: refusing to sweep is
/// the only safe answer when the range cannot be proven private.
List<String> subnetHosts(String ip, {int maxHosts = 254}) {
  if (!isPrivateIPv4(ip)) return const <String>[];
  final List<String> parts = ip.split('.');
  final String prefix = '${parts[0]}.${parts[1]}.${parts[2]}';
  final List<String> hosts = <String>[];
  for (int last = 1; last <= 254 && hosts.length < maxHosts; last++) {
    final String host = '$prefix.$last';
    if (host == ip) continue;
    hosts.add(host);
  }
  return hosts;
}

/// Every host on this device's own private /24s, or an empty list when it has
/// none (no Wi-Fi, or only public and VPN addresses).
///
/// Tailscale's 100.64/10 and other carrier ranges are deliberately not RFC1918
/// and so contribute nothing: a tailnet is not a subnet to dial 254 hosts on.
Future<List<String>> ownSubnetHosts() async {
  final List<String> hosts = <String>[];
  try {
    for (final NetworkInterface iface
        in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      for (final InternetAddress address in iface.addresses) {
        if (address.isLoopback) continue;
        for (final String host in subnetHosts(address.address)) {
          if (!hosts.contains(host)) hosts.add(host);
        }
      }
    }
  } catch (_) {
    // No interfaces readable: an empty sweep is the honest answer, not a
    // guess at a range.
  }
  return hosts;
}
