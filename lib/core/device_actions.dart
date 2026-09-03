import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart' show MethodChannel;

import 'agent_contract.dart';

/// The outcome of one device-local action.
class ActionResult {
  final bool ok;
  final String message;
  const ActionResult(this.ok, this.message);
}

/// Runs the small device-local actions the assistant can execute natively.
abstract class DeviceActionBackend {
  Future<ActionResult> run(String action, Map<String, dynamic> args);
}

/// Returns the platform-appropriate backend.
DeviceActionBackend deviceActionBackend() {
  if (defaultTargetPlatform == TargetPlatform.android) {
    return RealDeviceActionBackend();
  }
  if (defaultTargetPlatform == TargetPlatform.linux) {
    return DesktopDeviceActionBackend();
  }
  return const UnavailableDeviceActionBackend();
}

class RealDeviceActionBackend implements DeviceActionBackend {
  static const _channel = MethodChannel('dev.nexus.nexus/device');

  @override
  Future<ActionResult> run(String action, Map<String, dynamic> args) async {
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        switch (action) {
          AgentActions.timerSet => 'setTimer',
          AgentActions.webSearch => 'webSearch',
          AgentActions.volumeSet => 'volume',
          AgentActions.batteryGet => 'battery',
          AgentActions.flashlightToggle => 'torch',
          AgentActions.lockScreen => 'lock',
          AgentActions.wifiToggle => 'wifi',
          AgentActions.bluetoothToggle => 'bluetooth',
          _ => 'unknown',
        },
        args,
      );
      if (raw == null) return const ActionResult(false, 'Not available here.');
      return ActionResult(
        raw['ok'] == true,
        raw['message']?.toString() ?? 'Done.',
      );
    } catch (_) {
      return const ActionResult(
        false,
        'That action is not available on this device.',
      );
    }
  }
}

class UnavailableDeviceActionBackend implements DeviceActionBackend {
  const UnavailableDeviceActionBackend();

  @override
  Future<ActionResult> run(String action, Map<String, dynamic> args) async =>
      const ActionResult(false, 'That action is not available on this device.');
}

/// The desktop executor: timers via notify-send, web search via xdg-open.
class DesktopDeviceActionBackend implements DeviceActionBackend {
  @override
  Future<ActionResult> run(String action, Map<String, dynamic> args) async {
    switch (action) {
      case AgentActions.timerSet:
        return _timer(args);
      case AgentActions.webSearch:
        return _webSearch(args);
      default:
        return const ActionResult(
          false,
          'That action is not available on this device.',
        );
    }
  }

  Future<ActionResult> _timer(Map<String, dynamic> args) async {
    final seconds = args['seconds'];
    if (seconds is! int || seconds <= 0) {
      return const ActionResult(false, 'I need a duration — like "5 minutes".');
    }
    unawaited(_notify('Nexus · Timer', 'Timer set for $seconds seconds.'));
    unawaited(
      Process.run('sh', [
        '-c',
        'sleep $seconds; notify-send "Nexus · Timer" "Timer finished."',
      ]).catchError((_) => ProcessResult(0, 0, '', '')),
    );
    return ActionResult(true, 'Timer set for $seconds seconds.');
  }

  Future<ActionResult> _webSearch(Map<String, dynamic> args) async {
    final query = args['query']?.toString() ?? '';
    if (query.isEmpty) {
      return const ActionResult(false, 'What should I search for?');
    }
    final url =
        'https://www.google.com/search?q=${Uri.encodeQueryComponent(query)}';
    try {
      await Process.run('xdg-open', [url]);
    } catch (_) {
      return const ActionResult(false, 'I could not open a browser here.');
    }
    return ActionResult(true, 'Searching for "$query".');
  }

  Future<void> _notify(String title, String body) async {
    try {
      await Process.run('notify-send', ['-t', '5000', title, body]);
    } catch (_) {}
  }
}
