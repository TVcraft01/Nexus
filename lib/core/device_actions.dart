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
