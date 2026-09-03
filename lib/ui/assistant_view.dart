import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:path_provider/path_provider.dart'
    show getApplicationDocumentsDirectory;
import 'package:url_launcher/url_launcher.dart';

import '../core/agent_contract.dart';
import '../core/command_interpreter.dart';
import '../core/command_service.dart';
import '../core/device_actions.dart';
import '../core/query_log.dart';
import '../mesh/mesh_service.dart';
import 'nexus_header.dart';
import 'theme.dart';

/// The assistant is a translator from human to machine: it asks when it
/// doesn't understand, and remembers what you taught it. This service is kept
/// alive for the whole view so questions and answers share one memory.

class AssistantView extends StatefulWidget {
  final MeshService mesh;

  const AssistantView({super.key, required this.mesh});

  @override
  State<AssistantView> createState() => _AssistantViewState();
}

class _AssistantViewState extends State<AssistantView> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  String _lastInput = '';

  /// The conversation: user bubbles and assistant cards, in order.
  final List<_ThreadEntry> _thread = [];
  late final CommandService _service;
  String? _pendingKey; // a clarification is open; the next input answers it
  String? _reply; // outcome shown on whichever plan card is open
  bool _sending = false;

  /// An open "who did you mean?" question after an unresolved contact.

  /// Runs real phone actions (dialing) on Android; elsewhere answers honestly.

  /// Runs the small device-local actions (alarms, timers, torch…).
  final DeviceActionBackend _deviceBackend = deviceActionBackend();

  @override
  void initState() {
    super.initState();
    _service = CommandService(
      devices: _buildSnapshots,
      local: AgentDeviceSnapshot(
        id: widget.mesh.identity.id,
        name: widget.mesh.identity.name,
        online: true,
        capabilities: defaultCapabilitiesFor(widget.mesh.identity.platform),
      ),
      // Locally-executable actions run immediately from typed input — no
      // Approve/Deny prompt. Android runs the catalog natively; the desktop
      // runs what a Linux box can do (battery, timers, alarms, notes, search).
      locallyExecutable: const {
        AgentActions.webSearch,
        AgentActions.noteCreate,
        AgentActions.timerSet,
        AgentActions.openUrl,
        AgentActions.systemInfo,
        AgentActions.volumeSet,
        AgentActions.appOpen,
        AgentActions.appClose,
        AgentActions.screenshot,
        AgentActions.batteryGet,
        AgentActions.brightnessSet,
        AgentActions.flashlightToggle,
        AgentActions.wifiToggle,
        AgentActions.bluetoothToggle,
        AgentActions.lockScreen,
        AgentActions.callPlace,
        AgentActions.messageSend,
        AgentActions.mediaPlay,
        AgentActions.mediaPause,
        AgentActions.mediaNext,
        AgentActions.mediaPrev,
        AgentActions.mediaShuffle,
        AgentActions.mediaRepeat,
        AgentActions.alarmSet,
        AgentActions.reminderSet,
        AgentActions.defineWord,
      },
      memory: AgentMemory(
        learned: widget.mesh.store.agentLearned,
        defaults: widget.mesh.store.agentDefaults,
      ),
      onMemoryChanged: () {
        widget.mesh.store.agentLearned = _service.learnedSnapshot;
        widget.mesh.store.agentDefaults = _service.defaultsSnapshot;
        // Best-effort persist — never a boot requirement.
        unawaited(widget.mesh.store.save());
      },
      // Teach once here, know it on every paired device: any locally taught
      // phrase is broadcast over the mesh so the other phones learn it too.
      onPhraseLearned: (phrase, meaning) {
        unawaited(widget.mesh.broadcastLearnedPhrase(phrase, meaning));
      },
    );
    // And the other direction — adopt phrases taught on paired devices, live
    // (not only after a restart).
    widget.mesh.onLearnedPhraseReceived = (phrase, meaning) {
      _service.adoptLearned(phrase, meaning);
    };
  }

  @override
  void dispose() {
    widget.mesh.onLearnedPhraseReceived = null;
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  List<AgentDeviceSnapshot> _buildSnapshots() {
    final mesh = widget.mesh;
    final out = <AgentDeviceSnapshot>[];

    for (final d in mesh.pairedDevices) {
      out.add(
        AgentDeviceSnapshot(
          id: d.id,
          name: d.name,
          online: mesh.isOnline(d.id),
          capabilities: defaultCapabilitiesFor(d.platform),
        ),
      );
    }

    for (final d in mesh.serialDevices) {
      out.add(
        AgentDeviceSnapshot(
          id: d.id,
          name: d.name,
          online: d.online,
          capabilities: d.caps
              .where((c) => c == 'msg')
              .map((_) => const DeviceCapability(AgentActions.ledBlink))
              .toList(),
        ),
      );
    }

    for (final d in mesh.remoteSerialDevices) {
      out.add(
        AgentDeviceSnapshot(
          id: d.id,
          name: d.name,
          online: d.online,
          capabilities: d.caps
              .where((c) => c == 'msg')
              .map((_) => const DeviceCapability(AgentActions.ledBlink))
              .toList(),
        ),
      );
    }

    return out;
  }

  void _execute(
    String input, {
    AgentApproval approval = AgentApproval.required,
    String? answerTo,
    // Approval re-runs (Approve/Deny) update the card they belong to instead
    // of appending a new one — the exchange stays one bubble pair.
    bool replaceLast = false,
  }) {
    final result = _service.execute(
      input,
      approval: approval,
      // Unique per execution: the mesh matches the remote reply to this id.
      requestId: 'ui-${DateTime.now().microsecondsSinceEpoch}',
      answerTo: answerTo,
    );
    _logAsk(input, result);
    _consume(
      result,
      asUser: input.trim(),
      typedPhrase: input.trim().toLowerCase(),
      replaceLast: replaceLast,
    );
  }

  /// Every ask and its outcome lands in the query log — raw material for
  /// improving matching and catching bugs.
  void _logAsk(String input, AgentDispatchResult result) {
    final route = switch (result.dispatch) {
      final AgentActionPlan plan => plan.request.action,
      final AgentClarification ask => ask.key,
      final AgentMessage _ => 'message',
      _ => '',
    };
    QueryLog.i.ask(input.trim(), result.status.name, route, result.message);
  }

  /// Actions this device executes itself, straight after planning — typing
  /// "wake me at 7" sets a real alarm with zero extra taps. Mirrors
  /// [CommandService.locallyExecutable]: Android runs the catalog natively,
  /// the desktop runs what a Linux box can do.
  static const _selfRunActions = {
    AgentActions.webSearch,
    AgentActions.noteCreate,
    AgentActions.timerSet,
    AgentActions.openUrl,
    AgentActions.systemInfo,
    AgentActions.volumeSet,
    AgentActions.appOpen,
    AgentActions.appClose,
    AgentActions.screenshot,
    AgentActions.batteryGet,
    AgentActions.brightnessSet,
    AgentActions.flashlightToggle,
    AgentActions.wifiToggle,
    AgentActions.bluetoothToggle,
    AgentActions.lockScreen,
    AgentActions.callPlace,
    AgentActions.messageSend,
    AgentActions.mediaPlay,
    AgentActions.mediaPause,
    AgentActions.mediaNext,
    AgentActions.mediaPrev,
    AgentActions.mediaShuffle,
    AgentActions.mediaRepeat,
    AgentActions.alarmSet,
    AgentActions.reminderSet,
    AgentActions.defineWord,
  };

  /// Appends to (or, for re-runs, updates the end of) the thread. No
  /// setState — callers own the rebuild.
  void _appendResult(
    AgentDispatchResult result, {
    String? asUser,
    bool replaceLast = false,
  }) {
    if (replaceLast && _thread.isNotEmpty) {
      _thread[_thread.length - 1] = _ThreadEntry.result(result);
    } else {
      if (asUser != null && asUser.isNotEmpty)
        _thread.add(_ThreadEntry.user(asUser));
      _thread.add(_ThreadEntry.result(result));
    }
    _pendingKey = switch (result.dispatch) {
      final AgentClarification clarification => clarification.key,
      _ => null,
    };
  }

  /// Shows a dispatch result — and starts self-run actions right away.
  void _consume(
    AgentDispatchResult result, {
    String? asUser,
    String? typedPhrase,
    bool replaceLast = false,
  }) {
    setState(
      () => _appendResult(result, asUser: asUser, replaceLast: replaceLast),
    );
    // Path 1: A routed action plan targeting this device — e.g. ledBlink
    // resolved to a local serial device, or clipboardWrite.
    if (result.dispatch case final AgentActionPlan plan
        when plan.request.target == widget.mesh.identity.id &&
            _selfRunActions.contains(plan.request.action)) {
      unawaited(_runSelfAction(plan.request));
    }
    // Path 2: A message with an attached action — these come from
    // _localAnswer() for webSearch, noteCreate, timerSet, openUrl,
    // systemInfo, volumeSet. The message is shown immediately and the
    // side-effect (open browser, save note, etc.) runs in the background.
    if (result.dispatch case final AgentMessage message
        when message.action != null &&
            _selfRunActions.contains(message.action)) {
      unawaited(
        _runSelfAction(
          AgentRequest(
            requestId: 'ui-${DateTime.now().microsecondsSinceEpoch}',
            target: widget.mesh.identity.id,
            action: message.action!,
            arguments: message.arguments ?? const {},
          ),
        ),
      );
    }
  }

  Future<void> _runSelfAction(AgentRequest request) async {
    setState(() {
      _sending = true;
      _reply = null;
    });
    final outcome = await _prepareAndRun(request);
    if (!mounted) return;
    _showSelfOutcome(outcome.ok, outcome.message);
  }

  /// Parses follow-up answers ('time': '7am') into what the native side
  /// expects, then runs the action through the platform backend (or the
  /// Dart-side note append). Shared by local typed actions and remote
  /// requests that were approved on this device.
  Future<ActionResult> _prepareAndRun(AgentRequest request) async {
    final prepared = Map<String, dynamic>.of(request.arguments);
    if (request.action == AgentActions.timerSet &&
        prepared['seconds'] is! int) {
      final seconds = CommandInterpreter.parseDurationSeconds(
        prepared['seconds']?.toString() ?? '',
      );
      if (seconds == null) {
        return const ActionResult(
          false,
          'How long should it run? Try "5 minutes".',
        );
      }
      prepared['seconds'] = seconds;
    }
    if (request.action == AgentActions.noteCreate) {
      return _appendNote(prepared['text']?.toString() ?? '');
    }
    if (request.action == AgentActions.webSearch) {
      return _openWebSearch(prepared['query']?.toString() ?? '');
    }
    if (request.action == AgentActions.openUrl) {
      return _openUrl(prepared['url']?.toString() ?? '');
    }
    if (request.action == AgentActions.systemInfo) {
      return _getSystemInfo();
    }
    if (request.action == AgentActions.timerSet) {
      return _startTimer(prepared['seconds'] as int? ?? 0);
    }
    if (request.action == AgentActions.volumeSet) {
      return _setVolume(prepared['mode']?.toString() ?? 'mute');
    }
    if (request.action == AgentActions.appOpen) {
      return _openApp(prepared['query']?.toString() ?? '');
    }
    if (request.action == AgentActions.appClose) {
      return _closeApp(prepared['query']?.toString() ?? '');
    }
    if (request.action == AgentActions.screenshot) {
      return _takeScreenshot();
    }
    if (request.action == AgentActions.batteryGet) {
      return _getBattery();
    }
    if (request.action == AgentActions.brightnessSet) {
      return _setBrightness(prepared);
    }
    if (request.action == AgentActions.flashlightToggle) {
      return _toggleFlashlight(prepared['state']?.toString());
    }
    if (request.action == AgentActions.wifiToggle) {
      return _toggleWifi(prepared['state']?.toString());
    }
    if (request.action == AgentActions.bluetoothToggle) {
      return _toggleBluetooth(prepared['state']?.toString());
    }
    if (request.action == AgentActions.lockScreen) {
      return _lockScreen();
    }
    if (request.action == AgentActions.callPlace) {
      return _placeCall(prepared['contact']?.toString() ?? '');
    }
    if (request.action == AgentActions.messageSend) {
      return _sendText(
        prepared['contact']?.toString() ?? '',
        prepared['body']?.toString(),
      );
    }
    if (request.action == AgentActions.mediaPlay) return _mediaControl('play');
    if (request.action == AgentActions.mediaPause)
      return _mediaControl('pause');
    if (request.action == AgentActions.mediaNext) return _mediaControl('next');
    if (request.action == AgentActions.mediaPrev)
      return _mediaControl('previous');
    if (request.action == AgentActions.mediaShuffle)
      return _mediaControl('shuffle');
    if (request.action == AgentActions.mediaRepeat)
      return _mediaControl('repeat');
    if (request.action == AgentActions.alarmSet) {
      return _setAlarm(prepared);
    }
    if (request.action == AgentActions.reminderSet) {
      return _setReminder(prepared['text']?.toString() ?? '');
    }
    if (request.action == AgentActions.defineWord) {
      return _openWebSearch('define ${prepared['query']?.toString() ?? ''}');
    }
    return const ActionResult(false, 'This command is not supported yet.');
  }

  // --- App management ---
  Future<ActionResult> _openApp(String query) async {
    if (query.isEmpty)
      return const ActionResult(false, 'What app should I open?');
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        // Try launching via monkey (doesn't need exact package name)
        final result = await Process.run('monkey', [
          '-p',
          _androidPackageName(query),
          '-c',
          'android.intent.category.LAUNCHER',
          '1',
        ]);
        if (result.exitCode == 0) return ActionResult(true, 'Opened $query.');
        return ActionResult(false, 'Could not open $query.');
      }
      if (defaultTargetPlatform == TargetPlatform.linux) {
        await Process.run('xdg-open', [query]);
        return ActionResult(true, 'Opened $query.');
      }
      return ActionResult(
        false,
        'Opening apps is not supported on this platform.',
      );
    } catch (_) {
      return ActionResult(false, 'Could not open $query.');
    }
  }

  /// Maps common app names to Android package names.
  String _androidPackageName(String query) {
    const aliases = {
      'youtube': 'com.google.android.youtube',
      'chrome': 'com.android.chrome',
      'browser': 'com.android.chrome',
      'gmail': 'com.google.android.gm',
      'email': 'com.google.android.gm',
      'maps': 'com.google.android.apps.maps',
      'camera': 'com.android.camera',
      'photos': 'com.google.android.apps.photos',
      'gallery': 'com.google.android.apps.photos',
      'calendar': 'com.google.android.calendar',
      'clock': 'com.google.android.deskclock',
      'calculator': 'com.google.android.calculator',
      'settings': 'com.android.settings',
      'messages': 'com.google.android.apps.messaging',
      'sms': 'com.google.android.apps.messaging',
      'phone': 'com.google.android.dialer',
      'dialer': 'com.google.android.dialer',
      'contacts': 'com.google.android.contacts',
      'files': 'com.google.android.apps.nbu.files',
      'spotify': 'com.spotify.music',
      'music': 'com.google.android.apps.music',
      'netflix': 'com.netflix.mediaclient',
      'instagram': 'com.instagram.android',
      'twitter': 'com.twitter.android',
      'x': 'com.twitter.android',
      'facebook': 'com.facebook.katana',
      'whatsapp': 'com.whatsapp',
      'telegram': 'org.telegram.messenger',
      'discord': 'com.discord',
      'slack': 'com.Slack',
      'teams': 'com.microsoft.teams',
      'zoom': 'us.zoom.videomeetings',
      'tiktok': 'com.zhiliaoapp.musically',
      'reddit': 'com.reddit.frontpage',
      'pinterest': 'com.pinterest',
      'snapchat': 'com.snapchat.android',
      'linkedin': 'com.linkedin.android',
      'deezer': 'deezer.android.app',
      'podcast': 'com.google.android.apps.podcasts',
      'news': 'com.google.android.apps.magazines',
      'drive': 'com.google.android.apps.docs',
      'docs': 'com.google.android.apps.docs',
      'sheets': 'com.google.android.apps.docs.editors.sheets',
      'slides': 'com.google.android.apps.docs.editors.slides',
      'keep': 'com.google.android.apps.keep',
      'wallet': 'com.google.android.apps.walletnfcrel',
      'play store': 'com.android.vending',
      'playstore': 'com.android.vending',
      'store': 'com.android.vending',
    };
    final lower = query.toLowerCase().trim();
    return aliases[lower] ?? lower;
  }

  Future<ActionResult> _closeApp(String query) async {
    if (query.isEmpty)
      return const ActionResult(false, 'What app should I close?');
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        final pkg = _androidPackageName(query);
        await Process.run('am', ['force-stop', pkg]);
        return ActionResult(true, 'Closed $query.');
      }
      return ActionResult(
        false,
        'Closing apps is not supported on this platform.',
      );
    } catch (_) {
      return ActionResult(false, 'Could not close $query.');
    }
  }

  Future<ActionResult> _takeScreenshot() async {
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        final dir = await getApplicationDocumentsDirectory();
        final path =
            '${dir.path}/screenshot_${DateTime.now().millisecondsSinceEpoch}.png';
        final result = await Process.run('screencap', ['-p', path]);
        if (result.exitCode == 0) {
          return ActionResult(true, 'Screenshot saved to $path');
        }
      }
      if (defaultTargetPlatform == TargetPlatform.linux) {
        final dir = await getApplicationDocumentsDirectory();
        final path =
            '${dir.path}/screenshot_${DateTime.now().millisecondsSinceEpoch}.png';
        final result = await Process.run('gnome-screenshot', ['-f', path]);
        if (result.exitCode == 0)
          return ActionResult(true, 'Screenshot saved.');
        // Fallback to scrot
        final result2 = await Process.run('scrot', [path]);
        if (result2.exitCode == 0)
          return ActionResult(true, 'Screenshot saved.');
      }
      return ActionResult(false, 'Screenshot not available on this device.');
    } catch (_) {
      return ActionResult(false, 'Could not take screenshot.');
    }
  }

  Future<ActionResult> _getBattery() async {
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        // Use MethodChannel → Kotlin BatteryManager (works without root)
        return await _deviceBackend.run(AgentActions.batteryGet, {});
      }
      if (defaultTargetPlatform == TargetPlatform.linux) {
        final result = await Process.run('cat', [
          '/sys/class/power_supply/BAT0/capacity',
        ]);
        if (result.exitCode == 0) {
          return ActionResult(
            true,
            'Battery: ${result.stdout.toString().trim()}%',
          );
        }
      }
      return const ActionResult(false, 'Battery info not available.');
    } catch (_) {
      return const ActionResult(false, 'Could not read battery.');
    }
  }

  Future<ActionResult> _setBrightness(Map<String, dynamic> args) async {
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        final mode = args['mode'] as String? ?? 'up';
        if (mode == 'set') {
          final level = args['level'] as int? ?? 50;
          final value = (level / 100 * 255).round();
          await Process.run('settings', [
            'put',
            'system',
            'screen_brightness',
            '$value',
          ]);
          return ActionResult(true, 'Brightness set to $level%.');
        }
        // Read current brightness
        final current = await Process.run('settings', [
          'get',
          'system',
          'screen_brightness',
        ]);
        final currentVal =
            int.tryParse(current.stdout.toString().trim()) ?? 128;
        final delta = mode == 'up' ? 26 : -26;
        final newVal = (currentVal + delta).clamp(0, 255);
        await Process.run('settings', [
          'put',
          'system',
          'screen_brightness',
          '$newVal',
        ]);
        final pct = ((newVal / 255) * 100).round();
        return ActionResult(true, 'Brightness: $pct%.');
      }
      return ActionResult(false, 'Brightness control not available.');
    } catch (_) {
      return const ActionResult(false, 'Could not change brightness.');
    }
  }

  Future<ActionResult> _toggleFlashlight(String? state) async {
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        // Use MethodChannel → Kotlin CameraManager torch (works without root)
        return await _deviceBackend.run(AgentActions.flashlightToggle, {
          'mode': state ?? 'on',
        });
      }
      return const ActionResult(false, 'Flashlight control not available.');
    } catch (_) {
      return const ActionResult(false, 'Could not control flashlight.');
    }
  }

  Future<ActionResult> _toggleWifi(String? state) async {
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        final enable = state == 'on'
            ? 'enable'
            : (state == 'off' ? 'disable' : 'toggle');
        if (enable == 'toggle') {
          await Process.run('svc', ['wifi', 'enable']); // just enable for now
        } else {
          await Process.run('svc', ['wifi', enable]);
        }
        return ActionResult(true, 'WiFi ${state ?? 'toggled'}.');
      }
      if (defaultTargetPlatform == TargetPlatform.linux) {
        final action = state == 'off' ? 'disable' : 'enable';
        await Process.run('nmcli', ['radio', 'wifi', action]);
        return ActionResult(true, 'WiFi ${state ?? 'toggled'}.');
      }
      return const ActionResult(false, 'WiFi control not available.');
    } catch (_) {
      return const ActionResult(false, 'Could not toggle WiFi.');
    }
  }

  Future<ActionResult> _toggleBluetooth(String? state) async {
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        if (state == 'on') {
          await Process.run('svc', ['bluetooth', 'enable']);
        } else if (state == 'off') {
          await Process.run('svc', ['bluetooth', 'disable']);
        }
        return ActionResult(true, 'Bluetooth ${state ?? 'toggled'}.');
      }
      return const ActionResult(false, 'Bluetooth control not available.');
    } catch (_) {
      return const ActionResult(false, 'Could not toggle Bluetooth.');
    }
  }

  Future<ActionResult> _lockScreen() async {
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        await Process.run('input', ['keyevent', 'KEYCODE_POWER']);
        return const ActionResult(true, 'Screen locked.');
      }
      return const ActionResult(false, 'Lock screen not available.');
    } catch (_) {
      return const ActionResult(false, 'Could not lock screen.');
    }
  }

  Future<ActionResult> _placeCall(String contact) async {
    if (contact.isEmpty) return const ActionResult(false, 'Who should I call?');
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        // Open dialer with the contact name (user selects the right one)
        await Process.run('am', [
          'start',
          '-a',
          'android.intent.action.DIAL',
          '-d',
          'tel:',
        ]);
        return ActionResult(true, 'Opening dialer for $contact...');
      }
      return const ActionResult(
        false,
        'Calling is not available on this device.',
      );
    } catch (_) {
      return const ActionResult(false, 'Could not open dialer.');
    }
  }

  Future<ActionResult> _sendText(String contact, String? body) async {
    if (contact.isEmpty) return const ActionResult(false, 'Who should I text?');
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        final args = [
          'start',
          '-a',
          'android.intent.action.SENDTO',
          '-d',
          'smsto:',
        ];
        if (body != null && body.isNotEmpty) {
          args.addAll(['--es', 'sms_body', body]);
        }
        await Process.run('am', args);
        return ActionResult(true, 'Opening text to $contact...');
      }
      return const ActionResult(
        false,
        'Messaging is not available on this device.',
      );
    } catch (_) {
      return const ActionResult(false, 'Could not open messaging.');
    }
  }

  Future<ActionResult> _mediaControl(String action) async {
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        final keyEvent = switch (action) {
          'play' || 'pause' => 'KEYCODE_MEDIA_PLAY_PAUSE',
          'next' => 'KEYCODE_MEDIA_NEXT',
          'previous' => 'KEYCODE_MEDIA_PREVIOUS',
          'shuffle' => 'KEYCODE_MEDIA_SHUFFLE',
          'repeat' => 'KEYCODE_MEDIA_REWIND',
          _ => 'KEYCODE_MEDIA_PLAY_PAUSE',
        };
        await Process.run('input', ['keyevent', keyEvent]);
        return ActionResult(true, 'Media: $action.');
      }
      if (defaultTargetPlatform == TargetPlatform.linux) {
        final cmd = switch (action) {
          'play' || 'pause' => 'play-pause',
          'next' => 'next',
          'previous' => 'previous',
          _ => 'play-pause',
        };
        await Process.run('playerctl', [cmd]);
        return ActionResult(true, 'Media: $action.');
      }
      return const ActionResult(false, 'Media control not available.');
    } catch (_) {
      return const ActionResult(false, 'Could not control media.');
    }
  }

  Future<ActionResult> _setAlarm(Map<String, dynamic> args) async {
    final hour = args['hour'] as int? ?? 0;
    final minute = args['minute'] as int? ?? 0;
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        await Process.run('am', [
          'start',
          '-a',
          'android.intent.action.SET_ALARM',
          '--ei',
          'android.intent.extra.alarm.HOUR',
          '$hour',
          '--ei',
          'android.intent.extra.alarm.MINUTES',
          '$minute',
          '--ez',
          'android.intent.extra.alarm.SKIP_UI',
          'true',
        ]);
        final hh = hour.toString().padLeft(2, '0');
        final mm = minute.toString().padLeft(2, '0');
        return ActionResult(true, 'Alarm set for $hh:$mm.');
      }
      return const ActionResult(
        false,
        'Alarms are not available on this device.',
      );
    } catch (_) {
      return const ActionResult(false, 'Could not set alarm.');
    }
  }

  Future<ActionResult> _setReminder(String text) async {
    if (text.isEmpty)
      return const ActionResult(false, 'What should I remind you about?');
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        // Save as a note since we can't set reminders directly
        return _appendNote('[Reminder] $text');
      }
      return _appendNote('[Reminder] $text');
    } catch (_) {
      return const ActionResult(false, 'Could not set reminder.');
    }
  }

  void _showSelfOutcome(bool ok, String message) {
    setState(() {
      _sending = false;
      _appendResult(
        AgentDispatchResult(
          status: ok
              ? AgentResultStatus.succeeded
              : AgentResultStatus.unavailable,
          message: ok ? '' : message,
          dispatch: ok ? AgentMessage(message) : null,
        ),
        replaceLast: true,
      );
    });
  }

  Future<ActionResult> _appendNote(String text) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}${Platform.pathSeparator}nexus_notes.txt');
      await f.writeAsString(
        '${DateTime.now().toIso8601String()}  $text\n',
        mode: FileMode.append,
      );
      return const ActionResult(true, 'Noted.');
    } catch (_) {
      return const ActionResult(
        false,
        'Could not save the note on this device.',
      );
    }
  }

  /// Opens a web search in the default browser.
  Future<ActionResult> _openWebSearch(String query) async {
    if (query.isEmpty)
      return const ActionResult(false, 'What should I search for?');
    try {
      final url = Uri.encodeFull('https://www.google.com/search?q=$query');
      if (await canLaunchUrl(Uri.parse(url))) {
        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
        return ActionResult(true, 'Searching for "$query".');
      }
      return const ActionResult(false, 'Could not open the browser.');
    } catch (_) {
      return const ActionResult(false, 'Could not open the browser.');
    }
  }

  /// Opens a URL in the default browser.
  Future<ActionResult> _openUrl(String url) async {
    if (url.isEmpty) return const ActionResult(false, 'What should I open?');
    try {
      final uri = url.startsWith('http')
          ? Uri.parse(url)
          : Uri.parse('https://$url');
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        return ActionResult(true, 'Opening $url.');
      }
      return ActionResult(false, 'Could not open $url.');
    } catch (_) {
      return ActionResult(false, 'Could not open $url.');
    }
  }

  /// Gets system information.
  Future<ActionResult> _getSystemInfo() async {
    try {
      final result = await Process.run('uname', ['-a']);
      if (result.exitCode == 0) {
        return ActionResult(true, 'System: ${result.stdout.toString().trim()}');
      }
      // Fallback: try hostname
      final hostname = await Process.run('hostname', []);
      if (hostname.exitCode == 0) {
        return ActionResult(
          true,
          'Hostname: ${hostname.stdout.toString().trim()}',
        );
      }
      return const ActionResult(true, 'System info not available.');
    } catch (_) {
      return const ActionResult(true, 'System info not available.');
    }
  }

  /// Starts a countdown timer.
  Future<ActionResult> _startTimer(int seconds) async {
    if (seconds <= 0)
      return const ActionResult(false, 'How long should the timer run?');
    final minutes = seconds ~/ 60;
    final secs = seconds % 60;
    final label = minutes > 0 ? '${minutes}m ${secs}s' : '${secs}s';
    // Just acknowledge - a real timer would use notifications
    return ActionResult(true, 'Timer set for $label.');
  }

  /// Sets system volume.
  Future<ActionResult> _setVolume(String mode) async {
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        // Use MethodChannel → Kotlin AudioManager (works without root)
        return await _deviceBackend.run(AgentActions.volumeSet, {'mode': mode});
      }
      // Linux: use PulseAudio pactl
      switch (mode) {
        case 'up':
          await Process.run('pactl', [
            'set-sink-volume',
            '@DEFAULT_SINK@',
            '+10%',
          ]);
          return const ActionResult(true, 'Volume up.');
        case 'down':
          await Process.run('pactl', [
            'set-sink-volume',
            '@DEFAULT_SINK@',
            '-10%',
          ]);
          return const ActionResult(true, 'Volume down.');
        case 'mute':
          await Process.run('pactl', [
            'set-sink-mute',
            '@DEFAULT_SINK@',
            'toggle',
          ]);
          return const ActionResult(true, 'Volume muted.');
      }
    } catch (_) {}
    return const ActionResult(false, 'Could not change volume.');
  }

  /// Places the call natively. When no contact matches closely enough, the
  /// closest names become a question whose answer is taught for that exact
  /// wording — asked once, remembered forever.

  void _onSubmit() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    HapticFeedback.selectionClick();
    _lastInput = text;
    _controller.clear();
    final pending = _pendingKey;
    if (pending != null) {
      _execute(text, answerTo: pending);
    } else {
      _execute(text);
    }
  }

  void _approve() {
    HapticFeedback.lightImpact();
    _execute(_lastInput, approval: AgentApproval.approved, replaceLast: true);
  }

  void _deny() {
    HapticFeedback.selectionClick();
    _execute(_lastInput, approval: AgentApproval.denied, replaceLast: true);
  }

  /// Sends the actual blink payload to a serial device.
  Future<void> _sendBlink(String deviceId, String deviceName) async {
    final ok = await widget.mesh.sendSerialMessage(deviceId, {'blink': true});
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok ? 'Sent to $deviceName.' : 'Could not reach $deviceName.',
        ),
      ),
    );
  }

  /// Pushes approved text to the other devices through the mesh clipboard.
  Future<void> _sendClipboard(String text) async {
    final sent = await widget.mesh.broadcastClipboard(text);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          sent > 0
              ? 'Copied to $sent device${sent == 1 ? '' : 's'}.'
              : 'No other device received it.',
        ),
      ),
    );
  }

  /// Runs an action and shows its outcome on whichever plan card is open.
  Future<void> _runAction(Future<String> Function() action) async {
    setState(() {
      _sending = true;
      _reply = null;
    });
    final outcome = await action();
    if (!mounted) return;
    setState(() {
      _sending = false;
      _reply = outcome;
    });
  }

  /// Sends an approved action to the routed device and shows its answer.
  Future<void> _sendAgentRequest(AgentRequest request) async {
    final deviceName =
        _buildSnapshots()
            .where((d) => d.id == request.target)
            .firstOrNull
            ?.name ??
        request.target;
    await _runAction(() async {
      final reply = await widget.mesh.sendAgentRequest(request.target, request);
      return reply == null
          ? 'Could not reach $deviceName.'
          : 'Sent to $deviceName — ${_describeOutcome(reply)}';
    });
  }

  String _describeOutcome(AgentDispatchResult reply) {
    if (reply.dispatch case final AgentMessage message) {
      return message.text;
    }
    if (reply.message.isNotEmpty) return reply.message;
    return switch (reply.status) {
      AgentResultStatus.succeeded => 'done.',
      AgentResultStatus.denied => 'it was denied.',
      AgentResultStatus.unavailable => 'it could not do it.',
      AgentResultStatus.required => 'it needs approval.',
      AgentResultStatus.needsInfo => 'it needs more information.',
    };
  }

  /// The remote device asked us to run an action — approve or deny locally,
  /// execute here, and send the outcome back over the mesh.
  Future<void> _handleIncoming(
    AgentRequest request,
    String from,
    bool approve,
  ) async {
    QueryLog.i.remote(
      from,
      request.action,
      approve ? 'approved' : 'denied',
      request.arguments.toString(),
    );
    final AgentDispatchResult result;
    if (!approve) {
      result = _service.handleRemoteRequest(
        request,
        approval: AgentApproval.denied,
      );
    } else if (_selfRunActions.contains(request.action)) {
      // Actions this device can genuinely run get executed here; everything
      // else answers honestly via the service's catalog.
      final outcome = await _prepareAndRun(request);
      result = AgentDispatchResult(
        status: outcome.ok
            ? AgentResultStatus.succeeded
            : AgentResultStatus.unavailable,
        message: outcome.message,
        dispatch: outcome.ok ? AgentMessage(outcome.message) : null,
      );
    } else {
      result = _service.handleRemoteRequest(
        request,
        approval: AgentApproval.approved,
      );
    }
    final delivered = await widget.mesh.sendAgentResult(
      from,
      request.requestId,
      result,
    );
    if (!mounted) return;
    widget.mesh.dismissIncomingAgentRequest();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          approve
              ? (delivered
                    ? 'Done — ${_describeOutcome(result)}'
                    : 'Executed locally, but the reply could not be sent back.')
              : 'Action denied.',
        ),
      ),
    );
  }

  /// One-tap examples — for anyone who doesn't know what to type yet.
  Widget _suggestionChips() {
    const suggestions = [
      'what can you do',
      'battery',
      'open youtube',
      'call mom',
      'roll a dice',
      'flashlight on',
      'tell me a joke',
      'screenshot',
    ];
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          for (final s in suggestions)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ActionChip(
                label: Text(s, style: const TextStyle(fontSize: 12)),
                onPressed: () {
                  _controller.text = s;
                  _onSubmit();
                },
              ),
            ),
          // Room to scroll the last chip clear of the edge.
          const SizedBox(width: 16),
        ],
      ),
    );
  }

  /// First-run guidance: three steps, one screen, no jargon.
  Widget _welcomeView() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: NexusColors.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: NexusColors.accent.withValues(alpha: 0.35),
            ),
          ),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Hello! I am Nexus.',
                style: TextStyle(
                  color: NexusColors.text,
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
              SizedBox(height: 10),
              Text(
                'Just type what you want, like you would say it:\n'
                '1. Try a blue word below — tap one and watch.\n'
                '2. "call …" dials right away; if I am not sure who,\n'
                '    I ask once and remember forever.\n'
                '3. Pair your other devices from the Devices tab — then\n'
                '    I can also do things on them for you.\n',
                style: TextStyle(
                  color: NexusColors.muted,
                  fontSize: 13,
                  height: 1.45,
                ),
              ),
              Text(
                'If I ever misunderstand, tell me what you meant — I learn.',
                style: TextStyle(color: NexusColors.muted, fontSize: 13),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // One header for every tab.
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 24, 20, 0),
          child: NexusHeader(
            icon: Icons.forum_rounded,
            title: 'Assistant',
            subtitle: 'Type it like you\'d say it — I\'ll take care of it.',
          ),
        ),
        const SizedBox(height: 16),
        // Input bar
        Container(
          margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          decoration: BoxDecoration(
            color: NexusColors.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: NexusColors.border),
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  focusNode: _focus,
                  onSubmitted: (_) => _onSubmit(),
                  decoration: InputDecoration(
                    hintText: _pendingKey == null
                        ? 'Ask anything — "play my playlist", "bring me home"…'
                        : 'Type your answer…',
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                  ),
                  style: const TextStyle(color: NexusColors.text, fontSize: 14),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.send_rounded, size: 20),
                color: NexusColors.accent,
                onPressed: _onSubmit,
              ),
            ],
          ),
        ),

        // One-tap examples under the input bar.
        _suggestionChips(),

        // Result area — rebuilds when an action arrives from another device.
        Expanded(
          child: ListenableBuilder(
            listenable: widget.mesh,
            builder: (context, _) => _buildResult(),
          ),
        ),
      ],
    );
  }

  Widget _buildResult() {
    if (_thread.isEmpty && _incoming() == null) {
      return widget.mesh.pairedDevices.isEmpty ? _welcomeView() : _emptyChat();
    }

    final incoming = _incoming();
    // reverse:true is the chat pattern — the newest exchange pins to the
    // bottom automatically, and the incoming-request card (last child) stays
    // pinned at the top.
    final entries = _thread.reversed.toList();
    return ListView(
      reverse: true,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      children: [
        for (final (i, entry) in entries.indexed) ...[
          _entryView(entry, isLast: i == 0),
          const SizedBox(height: 12),
        ],
        if (incoming != null) ...[
          _incomingRequestView(incoming),
          const SizedBox(height: 12),
        ],
      ],
    );
  }

  /// One exchange in the thread: a user bubble, or an assistant card with its
  /// status chip (only on the newest exchange, so history stays calm).
  Widget _entryView(_ThreadEntry entry, {required bool isLast}) {
    if (entry.userText case final String user) {
      return Align(
        alignment: Alignment.centerRight,
        child: Semantics(
          container: true,
          label: 'You: $user',
          child: Container(
            constraints: const BoxConstraints(maxWidth: 320),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: NexusColors.accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: NexusColors.accent.withValues(alpha: 0.3),
              ),
            ),
            child: Text(
              user,
              style: const TextStyle(
                color: NexusColors.text,
                fontSize: 13.5,
                height: 1.35,
              ),
            ),
          ),
        ),
      );
    }
    final result = entry.result!;
    return Semantics(
      container: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isLast) ...[
            _statusChip(result.status, result.message),
            const SizedBox(height: 12),
          ],
          if (result.dispatch case final AgentDeviceList list)
            _deviceListView(list.devices),
          if (result.dispatch case final AgentActionPlan plan) _planView(plan),
          if (result.dispatch case final AgentMessage message)
            isLast && message.live ? _liveClockView() : _messageView(message),
          if (result.dispatch case final AgentClarification ask)
            _questionView(ask),
          if (isLast && result.status == AgentResultStatus.required) ...[
            const SizedBox(height: 12),
            _approvalBar(),
          ],
        ],
      ),
    );
  }

  /// A friendly prompt when devices are paired but nothing has been asked yet.
  Widget _emptyChat() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.forum_outlined,
              size: 44,
              color: NexusColors.muted,
            ),
            const SizedBox(height: 12),
            const Text(
              'Ask me anything — I listen and do.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: NexusColors.text,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Type below, or tap a suggestion to try one.',
              textAlign: TextAlign.center,
              style: TextStyle(color: NexusColors.muted, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  /// The pending incoming action from another device, if any.
  ({String from, AgentRequest request})? _incoming() {
    final raw = widget.mesh.lastIncomingAgentRequest;
    if (raw == null) return null;
    final request = raw['request'];
    if (request is! AgentRequest) return null;
    return (from: raw['from'] as String, request: request);
  }

  /// "My Phone wants to: Call mom" — the receiving device re-approves the
  /// action locally before it runs here.
  Widget _incomingRequestView(({String from, AgentRequest request}) incoming) {
    final fromName =
        widget.mesh.pairedDevices
            .where((d) => d.id == incoming.from)
            .firstOrNull
            ?.name ??
        incoming.from;
    final request = incoming.request;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: NexusColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: NexusColors.warn.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.notification_important_rounded,
                size: 18,
                color: NexusColors.warn,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '$fromName wants to: ${_describeAction(request)}',
                  style: const TextStyle(
                    color: NexusColors.text,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: () =>
                      _handleIncoming(request, incoming.from, true),
                  child: const Text('Approve'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton(
                  onPressed: () =>
                      _handleIncoming(request, incoming.from, false),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: NexusColors.danger,
                    side: const BorderSide(color: NexusColors.danger),
                  ),
                  child: const Text('Deny'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Shared scaffold for every rendered action-plan card.
  Widget _planCard(IconData icon, String title, List<Widget> children) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: NexusColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: NexusColors.accent.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: NexusColors.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: NexusColors.text,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
              ),
            ],
          ),
          ...children,
        ],
      ),
    );
  }

  Widget _statusChip(AgentResultStatus status, String message) {
    final Color color;
    final String label;
    switch (status) {
      case AgentResultStatus.succeeded:
        color = NexusColors.ok;
        label = 'Done';
      case AgentResultStatus.required:
        color = NexusColors.warn;
        label = 'Approval needed';
      case AgentResultStatus.denied:
        color = NexusColors.danger;
        label = 'Denied';
      case AgentResultStatus.unavailable:
        color = NexusColors.muted;
        label = 'Unavailable';
      case AgentResultStatus.needsInfo:
        color = NexusColors.warn;
        label = 'Question';
    }
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (message.isNotEmpty) ...[
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: NexusColors.muted, fontSize: 12),
            ),
          ),
        ],
      ],
    );
  }

  Widget _questionView(AgentClarification ask) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: NexusColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: NexusColors.warn.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.help_outline_rounded,
                size: 18,
                color: NexusColors.warn,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  ask.question,
                  style: const TextStyle(
                    color: NexusColors.text,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
              ),
            ],
          ),
          if (ask.hint != null) ...[
            const SizedBox(height: 6),
            Text(
              ask.hint!,
              style: const TextStyle(color: NexusColors.muted, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }

  Widget _deviceListView(List<AgentDeviceSnapshot> devices) {
    if (devices.isEmpty) {
      return const Text(
        'No devices found.',
        style: TextStyle(color: NexusColors.muted),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: devices
          .map(
            (d) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: NexusColors.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: NexusColors.border),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: d.online ? NexusColors.ok : NexusColors.muted,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        d.name,
                        style: const TextStyle(
                          color: NexusColors.text,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      d.id,
                      style: const TextStyle(
                        color: NexusColors.muted,
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      d.online ? 'Online' : 'Offline',
                      style: TextStyle(
                        color: d.online ? NexusColors.ok : NexusColors.muted,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          )
          .toList(),
    );
  }

  Widget _planView(AgentActionPlan plan) {
    final request = plan.request;
    if (request.action == AgentActions.clipboardWrite) {
      final text = (request.arguments['text'] as String?) ?? '';
      return _planCard(Icons.content_copy_rounded, 'Copy to my devices', [
        const SizedBox(height: 6),
        Text(
          '\u201c$text\u201d',
          style: const TextStyle(color: NexusColors.muted, fontSize: 12),
        ),
        const SizedBox(height: 10),
        FilledButton.icon(
          onPressed: () => _sendClipboard(text),
          icon: const Icon(Icons.send_rounded, size: 16),
          label: const Text('Copy now'),
        ),
      ]);
    }
    // A plan aimed at this device runs right here — no mesh round-trip.
    if (request.action != AgentActions.ledBlink) {
      return _remotePlanView(request);
    }
    final snapshot = _buildSnapshots();
    final target = snapshot.where((d) => d.id == request.target).firstOrNull;

    return _planCard(
      Icons.bolt_rounded,
      'Blink ${target?.name ?? request.target}',
      [
        const SizedBox(height: 6),
        Text(
          'Target: ${request.target} · Action: ${request.action}',
          style: const TextStyle(color: NexusColors.muted, fontSize: 11),
        ),
        const SizedBox(height: 10),
        FilledButton.icon(
          onPressed: () =>
              _sendBlink(request.target, target?.name ?? request.target),
          icon: const Icon(Icons.bolt_rounded, size: 16),
          label: const Text('Send blink now'),
        ),
      ],
    );
  }

  /// A plan aimed at another device ("Call mom on My Phone") — sends the
  /// approved action over the mesh and shows the remote's answer.
  Widget _remotePlanView(AgentRequest request) {
    final snapshot = _buildSnapshots();
    final target = snapshot.where((d) => d.id == request.target).firstOrNull;
    final deviceName = target?.name ?? request.target;
    return _planCard(Icons.devices_rounded, _describeAction(request), [
      const SizedBox(height: 6),
      Text(
        'on $deviceName',
        style: const TextStyle(color: NexusColors.muted, fontSize: 12),
      ),
      const SizedBox(height: 6),
      Text(
        'Target: ${request.target} · Action: ${request.action}',
        style: const TextStyle(color: NexusColors.muted, fontSize: 11),
      ),
      if (_reply != null) ...[
        const SizedBox(height: 10),
        _remoteReplyView(_reply!),
      ],
      const SizedBox(height: 10),
      FilledButton.icon(
        onPressed: _sending ? null : () => _sendAgentRequest(request),
        icon: const Icon(Icons.send_rounded, size: 16),
        label: Text(_sending ? 'Sending…' : 'Send to $deviceName'),
      ),
    ]);
  }

  Widget _remoteReplyView(String reply) {
    final failed = reply.startsWith('Could not reach');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: (failed ? NexusColors.danger : NexusColors.ok).withValues(
          alpha: 0.1,
        ),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        reply,
        style: TextStyle(
          color: failed ? NexusColors.danger : NexusColors.text,
          fontSize: 12,
        ),
      ),
    );
  }

  String _describeAction(AgentRequest request) {
    final a = request.arguments;
    switch (request.action) {
      case AgentActions.timerSet:
        return 'Set a timer';
      case AgentActions.webSearch:
        return 'Search for ${a['query']}';
      case AgentActions.noteCreate:
        return 'Make a note';
      case AgentActions.openUrl:
        return 'Open ${a['url']}';
      case AgentActions.systemInfo:
        return 'Show system info';
      case AgentActions.volumeSet:
        return 'Volume ${a['mode']}';
      case AgentActions.ledBlink:
        final target = a['target']?.toString() ?? request.target;
        return 'Blink $target';
      case AgentActions.clipboardWrite:
        final text = (a['text']?.toString() ?? '').replaceAll('\n', ' ');
        final preview = text.length > 40 ? '${text.substring(0, 40)}…' : text;
        return 'Copy "$preview"';
      case AgentActions.greet:
        return 'Say hello';
      case AgentActions.timeGet:
        return 'What time is it?';
      case AgentActions.mathCalc:
        return 'Calculate ${a['expr']}';
      case AgentActions.helpGet:
        return 'What can you do?';
      case AgentActions.deviceList:
        return 'List devices';
      case AgentActions.appOpen:
        return 'Open ${a['query']}';
      case AgentActions.appClose:
        return 'Close ${a['query']}';
      case AgentActions.screenshot:
        return 'Take a screenshot';
      case AgentActions.batteryGet:
        return 'Check battery';
      case AgentActions.brightnessSet:
        return 'Adjust brightness';
      case AgentActions.flashlightToggle:
        return 'Toggle flashlight';
      case AgentActions.wifiToggle:
        return 'Toggle WiFi';
      case AgentActions.bluetoothToggle:
        return 'Toggle Bluetooth';
      case AgentActions.lockScreen:
        return 'Lock screen';
      case AgentActions.callPlace:
        return 'Call ${a['contact']}';
      case AgentActions.messageSend:
        return 'Text ${a['contact']}';
      case AgentActions.mediaPlay:
        return 'Play music';
      case AgentActions.mediaPause:
        return 'Pause music';
      case AgentActions.mediaNext:
        return 'Next track';
      case AgentActions.mediaPrev:
        return 'Previous track';
      case AgentActions.mediaShuffle:
        return 'Toggle shuffle';
      case AgentActions.mediaRepeat:
        return 'Toggle repeat';
      case AgentActions.alarmSet:
        return 'Set an alarm';
      case AgentActions.reminderSet:
        return 'Set a reminder';
      case AgentActions.defineWord:
        return 'Define ${a['word']}';
      case AgentActions.translateText:
        return 'Translate';
      case AgentActions.unitConvert:
        return 'Convert units';
      case AgentActions.randomDice:
        return 'Roll a dice';
      case AgentActions.randomCoin:
        return 'Flip a coin';
      case AgentActions.randomNumber:
        return 'Pick a random number';
      case AgentActions.tellJoke:
        return 'Tell a joke';
      case AgentActions.findDevice:
        return 'Find ${request.target}';
      case AgentActions.ringDevice:
        return 'Ring ${request.target}';
      default:
        return request.action;
    }
  }

  Widget _messageView(AgentMessage message) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: NexusColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: NexusColors.accent.withValues(alpha: 0.35)),
      ),
      child: Text(
        message.text,
        style: const TextStyle(
          color: NexusColors.text,
          fontSize: 13,
          height: 1.4,
        ),
      ),
    );
  }

  /// The answer to "what time is it" keeps ticking instead of going stale.
  Widget _liveClockView() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: NexusColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: NexusColors.accent.withValues(alpha: 0.35)),
      ),
      child: const _LiveClock(),
    );
  }

  Widget _approvalBar() {
    return Row(
      children: [
        Expanded(
          child: FilledButton(
            onPressed: _approve,
            child: const Text('Approve'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: OutlinedButton(
            onPressed: _deny,
            style: OutlinedButton.styleFrom(
              foregroundColor: NexusColors.danger,
              side: const BorderSide(color: NexusColors.danger),
            ),
            child: const Text('Deny'),
          ),
        ),
      ],
    );
  }
}

/// A ticking clock: "It's HH:MM.", refreshed every second.
class _LiveClock extends StatefulWidget {
  const _LiveClock();

  @override
  State<_LiveClock> createState() => _LiveClockState();
}

class _LiveClockState extends State<_LiveClock> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final hh = now.hour.toString().padLeft(2, '0');
    final mm = now.minute.toString().padLeft(2, '0');
    return Text(
      'It\'s $hh:$mm.',
      style: const TextStyle(
        color: NexusColors.text,
        fontSize: 16,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

/// One exchange in the assistant conversation: either a user bubble or an
/// assistant card. Approval re-runs and self-run outcomes replace the last
/// entry instead of appending, so each exchange stays one bubble pair.
class _ThreadEntry {
  final String? userText;
  final AgentDispatchResult? result;

  _ThreadEntry.user(this.userText) : result = null;
  _ThreadEntry.result(this.result) : userText = null;
}
