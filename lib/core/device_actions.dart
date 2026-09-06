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

  /// Closest contact names when a call couldn't be placed — the assistant
  /// offers them as "who did you mean?" and learns from the answer.
  final List<String> candidates;

  const ActionResult(this.ok, this.message, {this.candidates = const []});
}

/// Runs the small device-local actions the assistant can execute natively.
abstract class DeviceActionBackend {
  Future<ActionResult> run(String action, Map<String, dynamic> args);

  /// One-shot location fix (lat, lon) for "what is the weather" without a
  /// city. Null when the platform can't provide one — the weather fetch
  /// then falls back to IP detection, never a dead end.
  Future<(double, double)?> currentLocation() async => null;

  /// Opens [url] through the system app chooser so the user picks the app
  /// (music player, browser, …). False when this platform has no chooser —
  /// the caller then falls back to the default app.
  Future<bool> openLinkChooser(String url, String title) async => false;
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
  Future<(double, double)?> currentLocation() async {
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>('location');
      final lat = (raw?['lat'] as num?)?.toDouble();
      final lon = (raw?['lon'] as num?)?.toDouble();
      if (raw?['ok'] == true && lat != null && lon != null) {
        return (lat, lon);
      }
    } catch (_) {
      // fall through: null → IP detection
    }
    return null;
  }

  @override
  Future<bool> openLinkChooser(String url, String title) async {
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        'openChooser',
        {'url': url, 'title': title},
      );
      return raw?['ok'] == true;
    } catch (_) {
      return false;
    }
  }

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
          AgentActions.alarmSet => 'setAlarm',
          AgentActions.brightnessSet => 'brightness',
          AgentActions.appOpen => 'openApp',
          AgentActions.appClose => 'closeApp',
          AgentActions.messageSend => 'sendText',
          AgentActions.emailSend => 'sendEmail',
          AgentActions.navOpen => 'navigateTo',
          AgentActions.calendarAdd => 'calendarEvent',
          AgentActions.mediaPlay ||
          AgentActions.mediaPause ||
          AgentActions.mediaNext ||
          AgentActions.mediaPrev ||
          AgentActions.mediaShuffle ||
          AgentActions.mediaRepeat => 'mediaControl',
          _ => 'unknown',
        },
        args,
      );
      if (raw == null) return const ActionResult(false, 'Not available here.');
      return ActionResult(
        raw['ok'] == true,
        raw['message']?.toString() ?? 'Done.',
        candidates: (raw['candidates'] as List<dynamic>? ?? const [])
            .map((c) => c.toString())
            .toList(),
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

  @override
  Future<(double, double)?> currentLocation() async => null;

  @override
  Future<bool> openLinkChooser(String url, String title) async => false;
}

/// The desktop executor: timers via notify-send, web search via xdg-open.
class DesktopDeviceActionBackend implements DeviceActionBackend {
  @override
  Future<(double, double)?> currentLocation() async => null;

  @override
  Future<bool> openLinkChooser(String url, String title) async => false;

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
