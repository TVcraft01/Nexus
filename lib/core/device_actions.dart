import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart' show MethodChannel;

import 'agent_contract.dart';

/// The outcome of one device-local action (alarm, timer, torch…).
class ActionResult {
  final bool ok;
  final String message;
  const ActionResult(this.ok, this.message);
}

/// Runs the small device-local actions the assistant can execute natively:
/// alarms, timers, web search, navigation, torch, battery, volume. Notes are
/// handled in Dart (a plain file append) so they work on every platform.
abstract class DeviceActionBackend {
  Future<ActionResult> run(String action, Map<String, dynamic> args);
}

/// Android executes natively through the platform channel; desktop uses shell
/// tools every Linux box has (notify-send, xdg-open, sysfs). Anything else
/// answers honestly that the action isn't available here.
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
          AgentActions.alarmSet => 'setAlarm',
          AgentActions.timerSet => 'setTimer',
          AgentActions.webSearch => 'webSearch',
          AgentActions.navigationRoute => 'navigateTo',
          AgentActions.torchToggle => 'torch',
          AgentActions.batteryGet => 'battery',
          AgentActions.volumeSet => 'volume',
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
      // Missing channel (desktop, tests): answer honestly, never crash.
      return const ActionResult(false, 'That action is not available on this device.');
    }
  }
}

class UnavailableDeviceActionBackend implements DeviceActionBackend {
  const UnavailableDeviceActionBackend();

  @override
  Future<ActionResult> run(String action, Map<String, dynamic> args) async =>
      const ActionResult(false, 'That action is not available on this device.');
}

/// The desktop's real executor: battery from sysfs, timers/alarms via
/// notify-send (with the actual notification fired after the duration), and
/// web search via xdg-open. No torch, no calls, no volume — those answer
/// honestly that this device can't do them.
class DesktopDeviceActionBackend implements DeviceActionBackend {
  @override
  Future<ActionResult> run(String action, Map<String, dynamic> args) async {
    switch (action) {
      case AgentActions.batteryGet:
        return _battery();
      case AgentActions.timerSet:
        return _timer(args);
      case AgentActions.alarmSet:
      case AgentActions.reminderSet:
        return _alarm(args, label: action == AgentActions.alarmSet ? 'Alarm' : 'Reminder');
      case AgentActions.webSearch:
        return _webSearch(args);
      default:
        return const ActionResult(false, 'That action is not available on this device.');
    }
  }

  Future<ActionResult> _battery() async {
    final supply = Directory('/sys/class/power_supply');
    if (!supply.existsSync()) {
      return const ActionResult(false, 'No battery found on this device.');
    }
    for (final dir in supply.listSync().whereType<Directory>()) {
      if (!dir.path.split('/').last.startsWith('BAT')) continue;
      final cap = File('${dir.path}/capacity');
      if (!cap.existsSync()) continue;
      final value = int.tryParse(cap.readAsStringSync().trim());
      if (value != null) return ActionResult(true, 'Battery at $value%.');
    }
    return const ActionResult(false, 'No battery found on this device.');
  }

  Future<ActionResult> _timer(Map<String, dynamic> args) async {
    final seconds = args['seconds'];
    if (seconds is! int || seconds <= 0) {
      return const ActionResult(false, 'I need a duration — like "5 minutes".');
    }
    unawaited(_notify('Nexus · Timer', 'Timer set for $seconds seconds.'));
    unawaited(Process.run(
      'sh',
      ['-c', 'sleep $seconds; notify-send "Nexus · Timer" "Timer finished."'],
    ).catchError((_) => ProcessResult(0, 0, '', '')));
    return ActionResult(true, 'Timer set for $seconds seconds.');
  }

  Future<ActionResult> _alarm(Map<String, dynamic> args, {required String label}) async {
    final hour = args['hour'];
    final minute = args['minute'];
    if (hour is! int || minute is! int) {
      return const ActionResult(false, 'I need a time — like 7am or 18:30.');
    }
    final now = DateTime.now();
    var when = DateTime(now.year, now.month, now.day, hour, minute);
    if (!when.isAfter(now)) when = when.add(const Duration(days: 1));
    final delay = when.difference(now).inSeconds;
    final hh = when.hour.toString().padLeft(2, '0');
    final mm = when.minute.toString().padLeft(2, '0');
    unawaited(_notify('Nexus · $label', '$label set for $hh:$mm.'));
    unawaited(Process.run(
      'sh',
      ['-c', 'sleep $delay; notify-send "Nexus · $label" "$label: it is $hh:$mm."'],
    ).catchError((_) => ProcessResult(0, 0, '', '')));
    return ActionResult(true, '$label set for $hh:$mm.');
  }

  Future<ActionResult> _webSearch(Map<String, dynamic> args) async {
    final query = args['query']?.toString() ?? '';
    if (query.isEmpty) {
      return const ActionResult(false, 'What should I search for?');
    }
    final url = 'https://www.google.com/search?q=${Uri.encodeQueryComponent(query)}';
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
    } catch (_) {
      // notify-send missing — the action still succeeded, just no popup.
    }
  }
}
