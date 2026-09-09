import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import '../mesh/updater.dart';

/// Cable provisioning: pairing a device that is physically connected to this PC.
///
/// The flow deliberately relies on Android's own ADB authorization. Nexus never
/// attempts to bypass the phone's USB-debugging approval prompt.
class CablePairing {
  static const packageId = 'dev.nexus.nexus';

  static Future<bool> get adbAvailable async {
    try {
      final result = await Process.run('adb', ['version']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Returns every ADB-visible device and its current state.
  /// Typical states are `device`, `unauthorized`, and `offline`.
  static Future<Map<String, String>> deviceStates() async {
    try {
      final result = await Process.run('adb', ['devices']);
      if (result.exitCode != 0) return const {};
      return parseDeviceStates(result.stdout as String);
    } catch (_) {
      return const {};
    }
  }

  static Map<String, String> parseDeviceStates(String output) {
    final devices = <String, String>{};
    for (final line in output.split('\n').skip(1)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final parts = trimmed.split(RegExp(r'\s+'));
      if (parts.length >= 2 && parts[1].isNotEmpty) {
        devices[parts[0]] = parts[1];
      }
    }
    return devices;
  }

  static Future<List<String>> connectedDevices() async {
    final states = await deviceStates();
    return states.entries
        .where((entry) => entry.value == 'device')
        .map((entry) => entry.key)
        .toList();
  }

  static List<String> parseDevicesOutput(String output) =>
      parseDeviceStates(output)
          .entries
          .where((entry) => entry.value == 'device')
          .map((entry) => entry.key)
          .toList();

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
    final result = await Process.run(
      'adb',
      ['-s', serial, 'install', '-r', path],
    );
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
        debugPrint(
          'NEXUS cable: adb reverse tcp:$local failed: ${result.stderr}',
        );
      } catch (_) {}
    }
    return null;
  }

  /// Opens Nexus on an authorized Android device and hands it a short-lived,
  /// one-time pairing payload. The payload contains no long-term secret.
  static Future<String?> launchProvisioning({
    required String serial,
    required String address,
    required int port,
    required String code,
  }) async {
    final expiresAt = DateTime.now()
        .add(const Duration(minutes: 5))
        .millisecondsSinceEpoch;
    final uri = Uri(
      scheme: 'nexus',
      host: 'pair',
      queryParameters: {
        'address': address,
        'port': '$port',
        'code': code,
        'expires': '$expiresAt',
      },
    );
    try {
      final result = await Process.run('adb', [
        '-s',
        serial,
        'shell',
        'am',
        'start',
        '-a',
        'android.intent.action.VIEW',
        '-d',
        uri.toString(),
      ]);
      if (result.exitCode != 0) {
        return (result.stderr as String).trim().isEmpty
            ? 'Android refused to open Nexus.'
            : (result.stderr as String).trim();
      }
      return null;
    } catch (e) {
      return 'Could not start Nexus on the phone: $e';
    }
  }

  static String linuxSetupScript() {
    return '''
#!/usr/bin/env bash
# Nexus setup for a Linux device (Raspberry Pi, another PC, …).
set -euo pipefail

echo "→ Downloading the latest Nexus Linux build…"
curl -fsSL -o /tmp/nexus.tar.gz "https://github.com/TVcraft01/Nexus/releases/latest/download/nexus-linux-x64.tar.gz"
mkdir -p ~/.local/share/nexus
tar -xzf /tmp/nexus.tar.gz -C ~/.local/share/nexus

echo "→ Starting Nexus…"
"\$HOME/.local/share/nexus/nexus" &
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
          if (lower == 'usb0' ||
              lower == 'usb1' ||
              (lower.startsWith('enp') && lower.contains('s0u'))) {
            return 'USB tethering detected on $iface.';
          }
        }
      }
      final routes = await Process.run('ip', ['route']);
      if (routes.exitCode == 0 &&
          (routes.stdout as String).contains('192.168.42.')) {
        return 'USB tethering detected.';
      }
    } catch (_) {}
    return null;
  }
}
