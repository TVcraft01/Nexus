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

  /// Whether the action failed because something the *user* has to supply was
  /// missing — a contact, a query, a duration. "Who should I call?" is a
  /// question about the request, not a verdict on it, so it must be reported
  /// as one; everything else that fails here really could not run.
  final bool needsDetail;

  /// Closest contact names when a call couldn't be placed — the assistant
  /// offers them as "who did you mean?" and learns from the answer.
  final List<String> candidates;

  /// Structured payload from the native side (e.g. calendar events) that the
  /// executor formats into the answer. Null when the action has no payload.
  final Map<String, dynamic>? data;

  const ActionResult(
    this.ok,
    this.message, {
    this.needsDetail = false,
    this.candidates = const [],
    this.data,
  });
}

/// The system the user is actually on, in the words they would use for it.
///
/// "Platform" is developer wording, and a dead end that blames "this platform"
/// leaves the user nothing to act on. The user is on Windows, or on their
/// phone, and the answer should say so.
String platformName([TargetPlatform? platform]) {
  return switch (platform ?? defaultTargetPlatform) {
    TargetPlatform.android => 'your phone',
    TargetPlatform.iOS => 'your iPhone',
    TargetPlatform.windows => 'Windows',
    TargetPlatform.macOS => 'macOS',
    TargetPlatform.linux => 'Linux',
    TargetPlatform.fuchsia => 'this device',
  };
}

/// What each action does, in the user's words, and the systems that have it.
///
/// The single owner of the wording for "Nexus can't do this here": the entry
/// says *what* was asked for and *where* it does work, both checked against the
/// backends below and the executor's own branches rather than guessed. Keeping
/// it in one table is what stops the answers drifting into a bare verdict —
/// "not available on this device" says neither what was missing nor what to do
/// about it.
///
/// Only actions that can actually hit a gap need an entry. An action without
/// one still gets no bare verdict, but it also gets no invented claim about
/// which systems can do it — see [notOnThisSystem].
const _gapWords = <String, (String what, String where)>{
  AgentActions.appOpen: ('open apps by name', 'Windows, Linux and your phone'),
  AgentActions.appClose: ('close apps for you', 'your phone'),
  AgentActions.screenshot: (
    'take a screenshot',
    'Windows, Linux and your phone',
  ),
  AgentActions.batteryGet: (
    'read the battery',
    'Windows, Linux and your phone',
  ),
  AgentActions.brightnessSet: (
    'change the brightness',
    'Windows, Linux and your phone',
  ),
  AgentActions.flashlightToggle: ('use the flashlight', 'your phone'),
  AgentActions.wifiToggle: (
    'open your Wi-Fi settings',
    'Windows, Linux and your phone',
  ),
  AgentActions.bluetoothToggle: (
    'open your Bluetooth settings',
    'Windows, Linux and your phone',
  ),
  AgentActions.lockScreen: (
    'lock the screen for you',
    'Windows, Linux and your phone',
  ),
  AgentActions.mediaPlay: (
    'control your music',
    'Windows, Linux and your phone',
  ),
  AgentActions.alarmSet: ('set an alarm', 'Windows and your phone'),
  AgentActions.volumeSet: (
    'change the volume',
    'Windows, Linux and your phone',
  ),
  AgentActions.calendarRead: ('read your calendar', 'your phone'),
};

/// What the user asked for, in their words — never empty, so an answer that
/// says Nexus could not do something always names the something.
String capabilityWord(String action) =>
    _gapWords[action]?.$1 ?? 'do that';

/// The sentence itself: what Nexus could not do, which system the user is on,
/// and the systems that *do* have it. One shape for every gap answer, so none
/// of them can drift back into a verdict with nothing behind it.
///
/// It promises no more than that. Routing the work to a paired device is not
/// something Nexus can do for these actions today, so the sentence never
/// offers it.
String gapAnswer(String what, String where) =>
    "I can't $what on ${platformName()} — Nexus does that on $where.";

/// The same answer, for an action Nexus knows by name.
///
/// An action with no entry still gets no bare verdict — but it also gets no
/// invented claim about which systems can do it, because that would be a
/// guess dressed up as an answer.
String notOnThisSystem(String action) {
  final words = _gapWords[action];
  if (words == null) {
    return "I can't do that on ${platformName()} — Nexus hasn't got that one "
        'here.';
  }
  return gapAnswer(words.$1, words.$2);
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
          AgentActions.calendarRead => 'calendarRead',
          // Not an agent action — a Kotlin-side playback method for the
          // in-app 30s Deezer preview ("play hotline bling" actually plays).
          'mediaPreview' => 'mediaPreview',
          _ => 'unknown',
        },
        args,
      );
      if (raw == null) {
        // The Android side is there but said nothing back. That is a failure
        // of this action, not a system that lacks the feature, so it says so
        // instead of blaming "this device".
        return const ActionResult(
          false,
          "Your phone didn't answer that one — it needs Android to reply, "
              "and it didn't. Try again, and check Nexus's permissions.",
        );
      }
      return ActionResult(
        raw['ok'] == true,
        raw['message']?.toString() ?? 'Done.',
        candidates: (raw['candidates'] as List<dynamic>? ?? const [])
            .map((c) => c.toString())
            .toList(),
        data: raw['events'] is List
            ? {'events': raw['events'] as List}
            : null,
      );
    } catch (_) {
      // The channel itself threw: a missing permission or an unwired method on
      // the phone. Same honesty rule — name the action, then what to try.
      return ActionResult(
        false,
        "Your phone couldn't ${capabilityWord(action)} just now — check "
            "Nexus's permissions in Android settings and try again.",
      );
    }
  }
}

/// The backend for systems Nexus has no device integration on at all (Windows
/// and macOS ship no native channel; the executor answers for them).
class UnavailableDeviceActionBackend implements DeviceActionBackend {
  const UnavailableDeviceActionBackend();

  @override
  Future<ActionResult> run(String action, Map<String, dynamic> args) async =>
      ActionResult(false, notOnThisSystem(action));

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
        return ActionResult(false, notOnThisSystem(action));
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
      return const ActionResult(
        false,
        'What should I search for?',
        needsDetail: true,
      );
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
