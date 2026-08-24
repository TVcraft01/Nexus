import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import '../mesh/updater.dart';

/// Cable pairing: pairing a device that is physically connected to this PC.
///
/// Only runs when the user explicitly asks for it (the "Pair over cable"
/// flow) — nothing here ever auto-detects or auto-pairs in the background.
///
/// What it does, per device type:
/// - **Android phone over USB**: detected via `adb`. If the Nexus app is not
///   installed yet, the latest release APK is downloaded from GitHub and
///   installed over the cable. Then `adb reverse` maps the phone's mesh port
///   to this PC's mesh port, so the phone can reach this PC *through the
///   cable* — no Wi-Fi needed — and the user completes normal code pairing.
/// - **Other Linux device (e.g. a Raspberry Pi)**: no app is pushed; a setup
///   script is generated that installs the Linux build on that device, after
///   which the two devices pair over the network as usual.
/// - **Anything else (car, etc.)**: there is no app to send; the flow just
///   tells the user how that device connects (e.g. Android Auto).
class CablePairing {
  /// True when the `adb` binary is available on this PC.
  static Future<bool> get adbAvailable async {
    try {
      final result = await Process.run('adb', ['version']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// A device detected on the cable.
  static const packageId = 'dev.nexus.nexus';

  /// Lists devices currently attached over ADB (cable or wireless adb).
  /// Returns an empty list when adb is missing or nothing is attached.
  static Future<List<String>> connectedDevices() async {
    try {
      final result = await Process.run('adb', ['devices']);
      if (result.exitCode != 0) return const [];
      return parseDevicesOutput(result.stdout as String);
    } catch (_) {
      return const [];
    }
  }

  /// Parses `adb devices` output into serials. Split out so it is
  /// unit-testable without adb.
  static List<String> parseDevicesOutput(String output) {
    final devices = <String>[];
    for (final line in output.split('\n').skip(1)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final parts = trimmed.split(RegExp(r'\s+'));
      // "serial\tdevice" (authorized) — ignore "unauthorized"/"offline".
      if (parts.length >= 2 && parts[1] == 'device') {
        devices.add(parts[0]);
      }
    }
    return devices;
  }

  /// Whether the Nexus app is already installed on [serial].
  static Future<bool> hasNexusInstalled(String serial) async {
    try {
      final result = await Process.run('adb', ['-s', serial, 'shell', 'pm', 'list', 'packages', packageId]);
      return result.exitCode == 0 && (result.stdout as String).contains('package:$packageId');
    } catch (_) {
      return false;
    }
  }

  /// Installs the latest release APK on [serial] over the cable. Returns the
  /// installed version tag (e.g. "v0.1.8") or null on failure.
  static Future<String?> installAppOn(String serial) async {
    final url = await Updater.latestApkUrl();
    if (url == null) {
      debugPrint('NEXUS cable: no release APK found on GitHub');
      return null;
    }
    final path = await Updater.download(url);
    if (path == null) {
      debugPrint('NEXUS cable: APK download failed');
      return null;
    }
    final result = await Process.run('adb', ['-s', serial, 'install', '-r', path]);
    if (result.exitCode != 0) {
      debugPrint('NEXUS cable: adb install failed: ${result.stderr}');
      return null;
    }
    // The tag is the version of the APK we just installed, e.g. v0.1.8.
    String? tag;
    for (final segment in Uri.parse(url).pathSegments) {
      if (segment.startsWith('v')) tag = segment;
    }
    return tag ?? 'latest';
  }

  /// Maps [port] on the phone to the same port on this PC over the cable, so
  /// the phone can reach this PC's mesh server without Wi-Fi.
  static Future<bool> reverseTunnel(String serial, int port) async {
    try {
      final result = await Process.run('adb', ['-s', serial, 'reverse', 'tcp:$port', 'tcp:$port']);
      if (result.exitCode != 0) {
        debugPrint('NEXUS cable: adb reverse failed: ${result.stderr}');
        return false;
      }
      // adb reverse silently no-ops when the target process is gone; the
      // port mapping is what matters and it succeeded.
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Generates a setup script that installs the Linux build of Nexus on a
  /// Linux device (Raspberry Pi, other PC) so it can then pair with this one.
  static String linuxSetupScript() {
    return '''
#!/usr/bin/env bash
# Nexus setup for a Linux device (Raspberry Pi, another PC, …).
# Run this on the device you want to add to the mesh:
#   bash <(curl -fsSL https://raw.githubusercontent.com/TVcraft01/Nexus/main/install_linux.sh)
set -euo pipefail

echo "→ Downloading the latest Nexus Linux build…"
curl -fsSL -o /tmp/nexus.tar.gz "https://github.com/TVcraft01/Nexus/releases/latest/download/nexus-linux-x64.tar.gz"
mkdir -p ~/.local/share/nexus
tar -xzf /tmp/nexus.tar.gz -C ~/.local/share/nexus

echo "→ Starting Nexus…"
"\$HOME/.local/share/nexus/nexus" &

echo ""
echo "Done. In Nexus on this device:"
echo "  1. Open the Devices tab → Pair a device → Enter a code"
echo "  2. Enter the code shown on the other device"
echo "  3. Address: the other device's IP (shown in its app), port 51820"
echo ""
echo "After pairing, both devices talk directly — no cloud, no account."
''';
  }

  /// Detects a phone attached over USB *without adb* — i.e. with USB
  /// tethering on. Android's tethering presents an RNDIS/ECM link named
  /// `usb0` (or an `enp*s0u*` on some kernels) and usually hands the PC a
  /// 192.168.42.x address. When present, the phone and this PC are on the
  /// same link and the mesh works over the cable with no developer mode.
  /// Returns a short human-readable description, or null when nothing is
  /// found.
  static Future<String?> detectUsbTether() async {
    try {
      final links = await Process.run('ip', ['-o', 'link', 'show']);
      if (links.exitCode == 0) {
        final text = links.stdout as String;
        for (final line in text.split('\n')) {
          final iface = RegExp(r'\d+:\s+(\S+)').firstMatch(line)?.group(1) ?? '';
          final lower = iface.toLowerCase();
          if (lower == 'usb0' ||
              lower == 'usb1' ||
              lower.startsWith('enp') && lower.contains('s0u')) {
            return 'Phone on USB tethering ($iface) — it can reach this PC '
                'over the cable. Pair it with a code as usual (no adb, no '
                'developer mode needed).';
          }
        }
      }
      final routes = await Process.run('ip', ['route']);
      if (routes.exitCode == 0 &&
          (routes.stdout as String).contains('192.168.42.')) {
        return 'Phone on USB tethering detected — it can reach this PC over '
            'the cable. Pair it with a code as usual.';
      }
    } catch (_) {
      // ip may be missing — fall through.
    }
    return null;
  }
}
