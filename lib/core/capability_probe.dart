import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show MethodChannel;

/// Checks local hardware and facilities without prompting or using the network.
abstract class CapabilityProbe {
  Future<Set<String>> probe();
}

/// Probes facilities available to this process on supported desktop/mobile OSes.
class RealCapabilityProbe implements CapabilityProbe {
  RealCapabilityProbe({
    @visibleForTesting this.platformOverride,
    @visibleForTesting this.androidProbe,
    @visibleForTesting this.linuxChecks,
  });

  @visibleForTesting
  final String? platformOverride;

  @visibleForTesting
  final Future<Set<String>> Function()? androidProbe;

  @visibleForTesting
  final Map<String, Future<bool> Function()>? linuxChecks;

  static const MethodChannel _androidChannel = MethodChannel(
    'dev.nexus.nexus/device',
  );

  String get _platform => platformOverride ?? _runtimePlatform;

  @override
  Future<Set<String>> probe() async {
    try {
      switch (_platform) {
        case 'android':
          final values = await (androidProbe?.call() ?? _probeAndroid());
          return values.where((value) => value.isNotEmpty).toSet();
        case 'linux':
          return await _probeLinux();
        default:
          return <String>{};
      }
    } catch (_) {
      return <String>{};
    }
  }

  Future<Set<String>> _probeAndroid() async => await _androidChannel
      .invokeListMethod<String>('probeCapabilities')
      .then((values) => values?.toSet() ?? <String>{});

  Future<Set<String>> _probeLinux() async {
    final checks =
        linuxChecks ??
        <String, Future<bool> Function()>{
          'filesystem': () async => Directory.systemTemp.exists(),
          'display': () async {
            final environment = Platform.environment;
            return (environment['DISPLAY'] ?? '').isNotEmpty ||
                (environment['WAYLAND_DISPLAY'] ?? '').isNotEmpty ||
                await Directory('/dev/dri').exists() ||
                await File('/dev/fb0').exists();
          },
          'serial-port': () async {
            final dev = Directory('/dev');
            if (!await dev.exists()) return false;
            await for (final entity in dev.list(followLinks: false)) {
              final name = entity.uri.pathSegments.isEmpty
                  ? ''
                  : entity.uri.pathSegments.last;
              if (name.startsWith('ttyUSB') ||
                  name.startsWith('ttyACM') ||
                  name.startsWith('ttyS') ||
                  name.startsWith('ttyAMA')) {
                return true;
              }
            }
            return false;
          },
          'ssh-client': () => _hasExecutable('ssh'),
          // Presence of the binary is a cheap local check; Ollama is not contacted.
          'ollama': () => _hasExecutable('ollama'),
        };

    final found = <String>{};
    for (final entry in checks.entries) {
      try {
        if (await entry.value()) found.add(entry.key);
      } catch (_) {
        // A failed check means only this capability is absent.
      }
    }
    return found;
  }

  Future<bool> _hasExecutable(String name) async {
    for (final directory in (Platform.environment['PATH'] ?? '').split(
      Platform.pathSeparator,
    )) {
      if (directory.isEmpty) continue;
      try {
        final stat = await File('$directory/$name').stat();
        if (stat.type == FileSystemEntityType.file && (stat.mode & 0x49) != 0) {
          return true;
        }
      } catch (_) {
        // Missing or unreadable PATH entries do not imply an executable.
      }
    }
    return false;
  }

  static String get _runtimePlatform {
    if (Platform.isAndroid) return 'android';
    if (Platform.isLinux) return 'linux';
    return 'unknown';
  }
}

/// Deterministic injectable probe for tests and local harnesses.
class FakeCapabilityProbe implements CapabilityProbe {
  FakeCapabilityProbe([Set<String> capabilities = const <String>{}])
    : _capabilities = Set<String>.of(capabilities);

  final Set<String> _capabilities;

  @override
  Future<Set<String>> probe() async => Set<String>.of(_capabilities);
}
