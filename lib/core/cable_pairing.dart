import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import '../mesh/updater.dart';

/// Cable pairing: pairing a device that is physically connected to this PC.
///
/// Only runs when the user explicitly asks for it (the "Pair over cable"
/// flow) — nothing here ever auto-detects or auto-pairs in the background.
class CablePairing {
  static Future<bool> get adbAvailable async {
    try {
      final result = await Process.run('adb', ['version']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static const packageId = 'dev.nexus.nexus';

  static Future<List<String>> connectedDevices() async {
    try {
      final result = await Process.run('adb', ['devices']);
      if (result.exitCode != 0) return const [];
      return parseDevicesOutput(result.stdout as String);
    } catch (_) {
      return const [];
    }
  }

  static List<String> parseDevicesOutput(String output) {
    final devices = <String>[];
    for (final line in output.split('\n').skip(1)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final parts = trimmed.split(RegExp(r'\s+'));
      if (parts.length >= 2 && parts[1] == 'device') devices.add(parts[0]);
    }
    return devices;
  }

  static Future<bool> hasNexusInstalled(String serial) async {
    try {
      final result = await Process.run('adb', [
        '-s', serial, 'shell', 'pm', 'list', 'packages', packageId,
      ]);
      return result.exitCode == 0 &&
          (result.stdout as String).contains('package:$packageId');
    } catch (_) {
      return false;
    }
  }

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
    String? tag;
    for (final segment in Uri.parse(url).pathSegments) {
      if (segment.startsWith('v')) tag = segment;
    }
    return tag ?? 'latest';
  }

  static List<int> tunnelCandidates(int pcPort) =>
      [pcPort, pcPort + 1, pcPort + 2, pcPort + 3];

  /// Opens a reverse tunnel from phone localhost to the PC mesh server.
  ///
  /// We remove only Nexus' candidate mappings first. A stale ADB reverse is
  /// otherwise enough to make pairing look like it succeeded while traffic
  /// is sent to an old/dead PC process.
  static Future<int?> openTunnel(String serial, int pcPort) async {
    for (final local in tunnelCandidates(pcPort)) {
      try {
        await Process.run(
          'adb', ['-s', serial, 'reverse', '--remove', 'tcp:$local'],
        );
        final result = await Process.run(
          'adb', ['-s', serial, 'reverse', 'tcp:$local', 'tcp:$pcPort'],
        );
        if (result.exitCode == 0) return local;
        debugPrint('NEXUS cable: adb reverse tcp:$local failed: ${result.stderr}');
      } catch (_) {}
    }
    return null;
  }

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

  static Future<String?> detectUsbTether() async {
    try {
      final links = await Process.run('ip', ['-o', 'link', 'show']);
      if (links.exitCode == 0) {
        final text = links.stdout as String;
        for (final line in text.split('\n')) {
          final iface = RegExp(r'\d+:\s+(\S+)').firstMatch(line)?.group(1) ?? '';
          final lower = iface.toLowerCase();
          if (lower == 'usb0' || lower == 'usb1' ||
              (lower.startsWith('enp') && lower.contains('s0u'))) {
            return 'Phone on USB tethering ($iface) — it can reach this PC over the cable. Pair it with a code as usual (no adb, no developer mode needed).';
          }
        }
      }
      final routes = await Process.run('ip', ['route']);
      if (routes.exitCode == 0 &&
          (routes.stdout as String).contains('192.168.42.')) {
        return 'Phone on USB tethering detected — it can reach this PC over the cable. Pair it with a code as usual.';
      }
    } catch (_) {}
    return null;
  }
}
