// The device executor: everything this device can DO with a parsed action.
// One class owns the ~30 platform actions (open apps, screenshots, calls,
// texts, media, timers…) and the switch that routes an AgentRequest to the
// right one. The assistant view decides WHAT the assistant should say; this
// module decides how an action actually runs on this machine/phone, through
// the platform backends (or honest "not on this device" answers). Pure Dart
// with injectable backends — testable without a widget tree.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:path_provider/path_provider.dart'
    show getApplicationDocumentsDirectory;
import 'package:url_launcher/url_launcher.dart'
    show canLaunchUrl, launchUrl, LaunchMode;

import '../core/agent_contract.dart';
import '../core/command_interpreter.dart';
import '../core/device_actions.dart';
import '../core/phone_actions.dart';

/// Executes device-local actions for the assistant on THIS platform.
class DeviceExecutor {
  DeviceExecutor({
    DeviceActionBackend? deviceBackend,
    PhoneActionBackend? phoneBackend,
  }) : _deviceBackend = deviceBackend ?? deviceActionBackend(),
       _phoneBackend = phoneBackend ?? RealPhoneActionBackend();

  final DeviceActionBackend _deviceBackend;
  final PhoneActionBackend _phoneBackend;

  /// Parses follow-up answers ('time': '7am') into what the native side
  /// expects, then runs the action through the platform backend (or the
  /// Dart-side note append). Shared by local typed actions and remote
  /// requests that were approved on this device.
  Future<ActionResult> run(AgentRequest request) async {
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
      if (prepared['mode'] == 'video') {
        return _videoCall(
          prepared['contact']?.toString() ?? '',
          prepared['app']?.toString(),
        );
      }
      return _placeCall(
        prepared['contact']?.toString() ?? '',
        prepared['number']?.toString(),
      );
    }
    if (request.action == AgentActions.messageSend) {
      return _sendText(
        prepared['contact']?.toString() ?? '',
        prepared['number']?.toString(),
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
        // Launching an app needs a real Intent — an app process cannot run
        // `/system/bin/am` (Android denies it to non-shell UIDs). Kotlin
        // fuzzy-matches the app's display name and opens it.
        return await _deviceBackend.run(AgentActions.appOpen, {
          'query': query,
          'hint': _androidPackageName(query),
        });
      }
      // Desktop "open X": known services open in the browser; otherwise look
      // for a real program (PATH lookup on Linux; `where` + the App Paths
      // registry on Windows). Unknown names get an honest reply — never a
      // fake win from a bare-word xdg-open.
      final site = _desktopSiteUrl(query);
      if (site != null) return await _openUrl(site);
      if (defaultTargetPlatform == TargetPlatform.linux) {
        final found = await _whichLinuxApp(query);
        if (found != null) {
          try {
            // Fire-and-forget: GUI apps stay open, so we must not await exit.
            await Process.start(found, const []);
            return ActionResult(true, 'Opened $query.');
          } catch (_) {}
        }
        return ActionResult(
          false,
          'I couldn\'t find an app called "$query" on this PC — try "open $query.com" to open its website, or give me the exact app name.',
        );
      }
      if (defaultTargetPlatform == TargetPlatform.windows) {
        final exe = await _findWindowsApp(query);
        if (exe != null) {
          try {
            // Fire-and-forget: GUI apps stay open, so we must not await exit.
            await Process.start(exe, const []);
            return ActionResult(true, 'Opened $query.');
          } catch (_) {}
        }
        return ActionResult(
          false,
          'I couldn\'t find an app called "$query" on this PC — try "open $query.com" to open its website, or give me the exact app name.',
        );
      }
      return const ActionResult(
        false,
        'Opening apps is not supported on this platform.',
      );
    } catch (_) {
      return ActionResult(false, 'Could not open $query.');
    }
  }

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

  /// Maps a bare app name to the website of a known web service. Desktop
  /// "open youtube" opens YouTube in the browser — no bogus bare-word launch.
  String? _desktopSiteUrl(String query) {
    final q = query.toLowerCase().trim().replaceFirst(RegExp(r'^the '), '');
    const sites = <String, String>{
      'youtube': 'https://www.youtube.com',
      'spotify': 'https://open.spotify.com',
      'netflix': 'https://www.netflix.com',
      'gmail': 'https://mail.google.com',
      'mail': 'https://mail.google.com',
      'maps': 'https://maps.google.com',
      'photos': 'https://photos.google.com',
      'gallery': 'https://photos.google.com',
      'calendar': 'https://calendar.google.com',
      'drive': 'https://drive.google.com',
      'docs': 'https://docs.google.com',
      'sheets': 'https://sheets.google.com',
      'slides': 'https://slides.google.com',
      'keep': 'https://keep.google.com',
      'news': 'https://news.google.com',
      'podcast': 'https://podcasts.google.com',
      'twitter': 'https://x.com',
      'x': 'https://x.com',
      'facebook': 'https://www.facebook.com',
      'instagram': 'https://www.instagram.com',
      'whatsapp': 'https://web.whatsapp.com',
      'telegram': 'https://web.telegram.org',
      'discord': 'https://discord.com/app',
      'slack': 'https://app.slack.com',
      'teams': 'https://teams.microsoft.com',
      'zoom': 'https://zoom.us',
      'tiktok': 'https://www.tiktok.com',
      'reddit': 'https://www.reddit.com',
      'pinterest': 'https://www.pinterest.com',
      'snapchat': 'https://www.snapchat.com',
      'linkedin': 'https://www.linkedin.com',
      'deezer': 'https://www.deezer.com',
      'github': 'https://github.com',
    };
    return sites[q];
  }

  /// Resolves a bare name to an executable on Linux (`command -v`).
  Future<String?> _whichLinuxApp(String name) async {
    try {
      final r = await Process.run('sh', [
        '-c',
        'command -v -- "\$1"',
        'sh',
        name,
      ]);
      if (r.exitCode == 0) {
        final path = r.stdout.toString().trim();
        if (path.isNotEmpty) return path;
      }
    } catch (_) {}
    return null;
  }

  /// Finds an installed Windows program by name: `where` on PATH first, then
  /// the App Paths registry (where installers register chrome.exe, …).
  Future<String?> _findWindowsApp(String name) async {
    for (final candidate in [name, '$name.exe']) {
      try {
        final where = await Process.run('where.exe', [candidate]);
        if (where.exitCode == 0) {
          final line = where.stdout.toString().split('\n').first.trim();
          if (line.isNotEmpty) return line;
        }
      } catch (_) {}
    }
    for (final root in const ['HKLM', 'HKCU']) {
      try {
        final reg = await Process.run('reg.exe', [
          'query',
          '$root\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\App Paths\\$name.exe',
          '/ve',
        ]);
        if (reg.exitCode == 0) {
          for (final line in reg.stdout.toString().split('\n')) {
            if (line.contains('REG_SZ')) {
              final path = line.split('REG_SZ').last.trim();
              if (path.isNotEmpty) return path;
            }
          }
        }
      } catch (_) {}
    }
    return null;
  }

  /// Sets display brightness on Linux via `xrandr` (X11, no root needed).
  /// Wayland has no xrandr brightness, so it answers honestly and points at
  /// the settings slider.
  Future<ActionResult> _linuxBrightness(String mode, int? level) async {
    try {
      final verbose = await Process.run('xrandr', ['--current', '--verbose']);
      if (verbose.exitCode != 0) {
        return const ActionResult(
          false,
          'Brightness needs X11 here (xrandr) — on Wayland, drag the brightness slider in your desktop settings.',
        );
      }
      // Map each connected output to its current brightness factor.
      final outputs = <String, double>{};
      String? current;
      for (final line in verbose.stdout.toString().split('\n')) {
        final head = RegExp(r'^(\S+) connected').firstMatch(line);
        if (head != null) {
          current = head.group(1);
          outputs[current!] = 1.0;
          continue;
        }
        final bright = RegExp(r'Brightness:\s*([0-9.]+)').firstMatch(line);
        if (bright != null && current != null) {
          outputs[current] = double.parse(bright.group(1)!);
        }
      }
      if (outputs.isEmpty) {
        return const ActionResult(
          false,
          'No controllable display found on this desktop.',
        );
      }
      var anyOk = false;
      for (final entry in outputs.entries) {
        final target = level != null
            ? level.clamp(0, 100) / 100
            : mode == 'down'
            ? (entry.value - 0.1).clamp(0.05, 1.0)
            : (entry.value + 0.1).clamp(0.05, 1.0);
        final r = await Process.run('xrandr', [
          '--output',
          entry.key,
          '--brightness',
          target.toStringAsFixed(2),
        ]);
        if (r.exitCode == 0) anyOk = true;
      }
      if (anyOk) {
        if (level != null) {
          return ActionResult(
            true,
            'Brightness set to ${level.clamp(0, 100)}%.',
          );
        }
        return ActionResult(
          true,
          mode == 'down' ? 'Brightness down.' : 'Brightness up.',
        );
      }
      return const ActionResult(
        false,
        'Could not change brightness on this display.',
      );
    } catch (_) {
      return const ActionResult(
        false,
        'Could not change brightness on this display.',
      );
    }
  }

  /// Sets display brightness on Windows via the WMI monitor interface.
  /// Laptop panels support it; external monitors usually don't expose it —
  /// that case answers honestly instead of claiming a change.
  Future<ActionResult> _windowsBrightness(String mode, int? level) async {
    final script =
        "\$m = Get-WmiObject -Namespace root\\WMI -Class WmiMonitorBrightnessMethods -ErrorAction SilentlyContinue; " +
        "if (-not \$m) { 'NONE'; exit 0 }; " +
        "if ('$mode' -eq 'set') { \$t = ${level ?? 50} } else { " +
        "\$c = (Get-WmiObject -Namespace root\\WMI -Class WmiMonitorBrightness -ErrorAction SilentlyContinue).CurrentBrightness; " +
        "\$t = if ('$mode' -eq 'up') { [Math]::Min(100, \$c + 10) } else { [Math]::Max(0, \$c - 10) } }; " +
        "\$m.WmiSetBrightness(1, \$t); 'OK'";
    try {
      final r = await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        script,
      ]);
      if (r.exitCode == 0 && r.stdout.toString().contains('OK')) {
        if (level != null) {
          return ActionResult(
            true,
            'Brightness set to ${level.clamp(0, 100)}%.',
          );
        }
        return ActionResult(
          true,
          mode == 'down' ? 'Brightness down.' : 'Brightness up.',
        );
      }
      return const ActionResult(
        false,
        "This display doesn't expose brightness control — drag the slider in Windows Settings, or try on a laptop screen.",
      );
    } catch (_) {
      return const ActionResult(false, 'Could not change brightness.');
    }
  }

  /// Synthesizes a global media/volume key on Windows (VK codes via
  /// keybd_event — no permissions needed, no PowerShell modules).
  Future<ActionResult> _windowsKeyEvent(int vk, String okText) async {
    final script =
        "Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public class K{[DllImport(\"user32.dll\")]public static extern void keybd_event(byte b,byte s,uint f,System.UIntPtr x);}';" +
        "[K]::keybd_event($vk,0,0,[System.UIntPtr]::Zero);" +
        "[K]::keybd_event($vk,0,2,[System.UIntPtr]::Zero)";
    try {
      final r = await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        script,
      ]);
      if (r.exitCode == 0) return ActionResult(true, okText);
      return const ActionResult(
        false,
        'Windows did not accept the key — is the session locked?',
      );
    } catch (_) {
      return const ActionResult(false, 'Could not send the key.');
    }
  }

  /// Opens the OS settings page an app may not toggle directly (Wi-Fi,
  /// Bluetooth…): Windows `ms-settings:` URIs; GNOME/KDE control panels on
  /// Linux. Mirrors the Android rule — Nexus takes you to the switch.
  Future<ActionResult> _openSettingsPanel({
    String? windowsUri,
    required String linuxGnome,
    required String linuxKde,
    required String noun,
    required String why,
  }) async {
    final tp = defaultTargetPlatform;
    if (tp == TargetPlatform.windows && windowsUri != null) {
      try {
        final r = await Process.run('cmd', ['/c', 'start', '', windowsUri]);
        if (r.exitCode == 0) {
          return ActionResult(
            true,
            '$why — I opened your $noun settings; flip the switch there.',
          );
        }
      } catch (_) {}
      return ActionResult(
        false,
        'I could not open the $noun settings on this PC.',
      );
    }
    if (tp == TargetPlatform.linux) {
      for (final entry in <(String, String)>[
        ('gnome-control-center', linuxGnome),
        ('systemsettings5', linuxKde),
      ]) {
        if (entry.$2.isEmpty) continue;
        try {
          // Fire-and-forget: control panels single-instance via D-Bus.
          await Process.start(entry.$1, [entry.$2]);
          return ActionResult(
            true,
            '$why — I opened your $noun settings; flip the switch there.',
          );
        } catch (_) {}
      }
      return ActionResult(
        false,
        'I could not open the $noun settings here — no GNOME/KDE control panel was found.',
      );
    }
    return const ActionResult(
      false,
      'Settings panels are not available on this platform.',
    );
  }

  Future<ActionResult> _closeApp(String query) async {
    if (query.isEmpty)
      return const ActionResult(false, 'What app should I close?');
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        return await _deviceBackend.run(AgentActions.appClose, {
          'query': query,
          'hint': _androidPackageName(query),
        });
      }
      if (defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.windows) {
        // Android can stop background apps; desktop OSes don't let an app
        // kill others. Say so instead of pretending.
        return const ActionResult(
          false,
          'Closing apps works on Android (Nexus stops background apps there). From this PC I can only launch things — close it the usual way.',
        );
      }
      return const ActionResult(
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
        // Screen capture needs the system MediaProjection consent flow; no
        // shell tool an app may run. Answer honestly instead of failing.
        return const ActionResult(
          false,
          'Screenshots need a permission Nexus does not ask for yet.',
        );
      }
      if (defaultTargetPlatform == TargetPlatform.linux) {
        final dir = await getApplicationDocumentsDirectory();
        final path =
            '${dir.path}${Platform.pathSeparator}screenshot_${DateTime.now().millisecondsSinceEpoch}.png';
        for (final tool in const <List<String>>[
          ['gnome-screenshot', '-f', 'PATH'],
          ['scrot', 'PATH'],
        ]) {
          final cmd = tool.map((e) => e == 'PATH' ? path : e).toList();
          final result = await Process.run(cmd[0], cmd.sublist(1));
          if (result.exitCode == 0) {
            return ActionResult(true, 'Screenshot saved.');
          }
        }
        return const ActionResult(
          false,
          'Screenshots need gnome-screenshot or scrot installed on this desktop.',
        );
      }
      if (defaultTargetPlatform == TargetPlatform.windows) {
        final dir = await getApplicationDocumentsDirectory();
        final path =
            '${dir.path}${Platform.pathSeparator}screenshot_${DateTime.now().millisecondsSinceEpoch}.png';
        final escaped = path.replaceAll("'", "''");
        final script =
            "Add-Type -AssemblyName System.Windows.Forms;" +
            "Add-Type -AssemblyName System.Drawing;" +
            "try {" +
            "\$b = [System.Windows.Forms.SystemInformation]::VirtualScreen;" +
            "\$bmp = New-Object System.Drawing.Bitmap \$b.Width, \$b.Height;" +
            "\$g = [System.Drawing.Graphics]::FromImage(\$bmp);" +
            "\$g.CopyFromScreen(\$b.X, \$b.Y, 0, 0, \$bmp.Size);" +
            "\$bmp.Save('$escaped');" +
            "exit 0 } catch { exit 1 }";
        final result = await Process.run('powershell', [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          script,
        ]);
        if (result.exitCode == 0) {
          return ActionResult(true, 'Screenshot saved to $path.');
        }
        return const ActionResult(
          false,
          "The screen capture failed — screenshots need an unlocked, interactive desktop (locked screens and some remote sessions can't be captured).",
        );
      }
      return const ActionResult(
        false,
        'Screenshots are not supported on this platform.',
      );
    } catch (_) {
      return const ActionResult(false, 'Could not take screenshot.');
    }
  }

  Future<ActionResult> _getBattery() async {
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        // Use MethodChannel → Kotlin BatteryManager (works without root)
        return await _deviceBackend.run(AgentActions.batteryGet, {});
      }
      if (defaultTargetPlatform == TargetPlatform.linux) {
        for (final battery in const ['BAT0', 'BAT1']) {
          final result = await Process.run('cat', [
            '/sys/class/power_supply/$battery/capacity',
          ]);
          if (result.exitCode == 0) {
            return ActionResult(
              true,
              'Battery: ${result.stdout.toString().trim()}%',
            );
          }
        }
        return const ActionResult(
          false,
          'This PC has no battery — it runs on wall power.',
        );
      }
      if (defaultTargetPlatform == TargetPlatform.windows) {
        final script =
            "\$b = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue; if (\$b) { \$b.EstimatedChargeRemaining } else { 'NONE' }";
        final result = await Process.run('powershell', [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          script,
        ]);
        if (result.exitCode == 0) {
          final level = int.tryParse(result.stdout.toString().trim());
          if (level != null) return ActionResult(true, 'Battery: $level%');
          return const ActionResult(
            false,
            'This PC has no battery — it runs on wall power.',
          );
        }
      }
      return const ActionResult(false, 'Battery info not available here.');
    } catch (_) {
      return const ActionResult(false, 'Could not read battery.');
    }
  }

  Future<ActionResult> _setBrightness(Map<String, dynamic> args) async {
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        // Kotlin writes the brightness when Nexus has "modify system
        // settings" access, otherwise opens the display settings panel.
        return await _deviceBackend.run(AgentActions.brightnessSet, {
          'mode': args['mode'] as String? ?? 'up',
          'level': args['level'] as int? ?? 50,
        });
      }
      final mode = args['mode'] as String? ?? 'up';
      final level = args['level'] as int?;
      if (defaultTargetPlatform == TargetPlatform.linux) {
        return await _linuxBrightness(mode, level);
      }
      if (defaultTargetPlatform == TargetPlatform.windows) {
        return await _windowsBrightness(mode, level);
      }
      return const ActionResult(
        false,
        'Brightness control is not available on this platform.',
      );
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
      if (defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.windows) {
        // Flashlight is phone hardware — answer honestly, never fake a win.
        return const ActionResult(
          false,
          'Flashlight needs a camera flash, which is phone hardware — this PC has none. Android phones in Nexus can do it.',
        );
      }
      return const ActionResult(
        false,
        'Flashlight control is not available on this platform.',
      );
    } catch (_) {
      return const ActionResult(false, 'Could not control flashlight.');
    }
  }

  Future<ActionResult> _toggleWifi(String? state) async {
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        // Apps can't toggle Wi-Fi on modern Android; Kotlin opens the
        // Wi-Fi settings panel where the user flips the switch.
        return await _deviceBackend.run(AgentActions.wifiToggle, {
          'state': state,
        });
      }
      if (defaultTargetPlatform == TargetPlatform.linux) {
        // nmcli can toggle when the user may manage the session; otherwise
        // fall back to the desktop's Wi-Fi panel (the same rule as Android).
        final action = state == 'off' ? 'disable' : 'enable';
        try {
          final nm = await Process.run('nmcli', ['radio', 'wifi', action]);
          if (nm.exitCode == 0) {
            return ActionResult(true, "WiFi ${state == 'off' ? 'off' : 'on'}.");
          }
        } catch (_) {}
        return await _openSettingsPanel(
          windowsUri: 'ms-settings:network-wifi',
          linuxGnome: 'wifi',
          linuxKde: 'network',
          noun: 'Wi-Fi',
          why: "Apps can't switch Wi-Fi for you on a desktop",
        );
      }
      if (defaultTargetPlatform == TargetPlatform.windows) {
        return await _openSettingsPanel(
          windowsUri: 'ms-settings:network-wifi',
          linuxGnome: 'wifi',
          linuxKde: 'network',
          noun: 'Wi-Fi',
          why: "Apps can't switch Wi-Fi for you on a desktop",
        );
      }
      return const ActionResult(false, 'Wi-Fi control is not available here.');
    } catch (_) {
      return const ActionResult(false, 'Could not toggle Wi-Fi.');
    }
  }

  Future<ActionResult> _toggleBluetooth(String? state) async {
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        // Apps can't toggle Bluetooth on modern Android; Kotlin opens the
        // Bluetooth settings panel where the user flips the switch.
        return await _deviceBackend.run(AgentActions.bluetoothToggle, {
          'state': state,
        });
      }
      if (defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.windows) {
        // Same rule as Android: no toggle from an app — open the panel.
        return await _openSettingsPanel(
          windowsUri: 'ms-settings:bluetooth',
          linuxGnome: 'bluetooth',
          linuxKde: 'bluetooth',
          noun: 'Bluetooth',
          why: "Apps can't switch Bluetooth for you on a desktop",
        );
      }
      return const ActionResult(
        false,
        'Bluetooth control is not available here.',
      );
    } catch (_) {
      return const ActionResult(false, 'Could not toggle Bluetooth.');
    }
  }

  Future<ActionResult> _lockScreen() async {
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        // Locking the screen needs Device Admin (or root); Kotlin explains.
        return await _deviceBackend.run(AgentActions.lockScreen, {});
      }
      if (defaultTargetPlatform == TargetPlatform.windows) {
        final r = await Process.run('rundll32.exe', [
          'user32.dll,LockWorkStation',
        ]);
        if (r.exitCode == 0) {
          return const ActionResult(true, 'Locked the screen.');
        }
        return const ActionResult(
          false,
          'Could not lock the screen from here — try Win+L.',
        );
      }
      if (defaultTargetPlatform == TargetPlatform.linux) {
        for (final cmd in const <List<String>>[
          ['loginctl', 'lock-sessions'],
          ['gnome-screensaver-command', '-l'],
          ['xdg-screensaver', 'lock'],
        ]) {
          try {
            final r = await Process.run(cmd[0], cmd.sublist(1));
            if (r.exitCode == 0) {
              return const ActionResult(true, 'Locked the screen.');
            }
          } catch (_) {}
        }
        return const ActionResult(
          false,
          "Could not lock the screen from here — use your desktop's lock shortcut (Super+L, Ctrl+Alt+L).",
        );
      }
      return const ActionResult(false, 'Lock screen not available here.');
    } catch (_) {
      return const ActionResult(false, 'Could not lock screen.');
    }
  }

  Future<ActionResult> _placeCall(String contact, String? number) async {
    if (contact.isEmpty) return const ActionResult(false, 'Who should I call?');
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        // A taught number ("remember that mom is 06…") skips contact lookup
        // entirely — Kotlin places the call with the number and never asks
        // for READ_CONTACTS. Without one, it resolves the contact against
        // the address book (asking READ_CONTACTS / CALL_PHONE on first use)
        // and names the closest matches when nothing fits.
        final outcome = await _phoneBackend.callContact(
          contact,
          number: number,
        );
        return ActionResult(
          outcome.placed || outcome.launched,
          outcome.message,
        );
      }
      return const ActionResult(
        false,
        "Calling needs a phone — this PC can't dial. On your Android device with Nexus, say \"call mom\" and it dials for you.",
      );
    } catch (_) {
      return const ActionResult(false, 'The call could not be placed.');
    }
  }

  /// Video calling only ever happens in an app the user named — a bare
  /// "video call mom" gets an honest which-app reply, never a silent phone
  /// call or a made-up default app.
  Future<ActionResult> _videoCall(String contact, String? app) async {
    if (contact.isEmpty) {
      return const ActionResult(false, 'Who should I video call?');
    }
    if (app == null || app.trim().isEmpty) {
      return ActionResult(
        false,
        'I only start video calls in an app you name — say "video call '
        '$contact on whatsapp" (WhatsApp or Telegram).',
      );
    }
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        final outcome = await _phoneBackend.videoCall(contact, app);
        return ActionResult(
          outcome.placed || outcome.launched,
          outcome.message,
        );
      }
      return const ActionResult(
        false,
        "Video calling needs a phone — this PC can't do it. On your Android device with Nexus, say \"video call mom on whatsapp\" and it opens the app with the contact.",
      );
    } catch (_) {
      return const ActionResult(false, 'Could not start the video call.');
    }
  }

  Future<ActionResult> _sendText(
    String contact,
    String? number,
    String? body,
  ) async {
    if (contact.isEmpty) return const ActionResult(false, 'Who should I text?');
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        return await _deviceBackend.run(AgentActions.messageSend, {
          'contact': contact,
          if (number != null) 'number': number,
          'body': body,
        });
      }
      return const ActionResult(
        false,
        "Texting needs a phone — this PC can't send SMS. On your Android device with Nexus, say \"text dad saying hello\" and it drafts it for you.",
      );
    } catch (_) {
      return const ActionResult(false, 'Could not open messaging.');
    }
  }

  Future<ActionResult> _mediaControl(String action) async {
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        final agentAction = switch (action) {
          'play' => AgentActions.mediaPlay,
          'pause' => AgentActions.mediaPause,
          'next' => AgentActions.mediaNext,
          'previous' => AgentActions.mediaPrev,
          'shuffle' => AgentActions.mediaShuffle,
          'repeat' => AgentActions.mediaRepeat,
          _ => AgentActions.mediaPlay,
        };
        return await _deviceBackend.run(agentAction, {'mode': action});
      }
      if (action == 'shuffle' || action == 'repeat') {
        return const ActionResult(
          false,
          'Shuffle and repeat live inside the music app — I can only play, pause and skip from here.',
        );
      }
      if (defaultTargetPlatform == TargetPlatform.linux) {
        final cmd = switch (action) {
          'play' || 'pause' => 'play-pause',
          'next' => 'next',
          'previous' => 'previous',
          _ => 'play-pause',
        };
        final r = await Process.run('playerctl', [cmd]);
        if (r.exitCode == 0) {
          final verb = action == 'play' || action == 'pause'
              ? 'play/pause'
              : action;
          return ActionResult(true, '$verb sent to your music.');
        }
        return const ActionResult(
          false,
          'No music player is responding — playerctl needs an MPRIS app (Spotify, Rhythmbox, …) actually running.',
        );
      }
      if (defaultTargetPlatform == TargetPlatform.windows) {
        final key = switch (action) {
          'next' => 0xB0, // VK_MEDIA_NEXT_TRACK
          'previous' => 0xB1, // VK_MEDIA_PREV_TRACK
          _ => 0xB3, // VK_MEDIA_PLAY_PAUSE
        };
        final text = switch (action) {
          'next' => 'Next track.',
          'previous' => 'Previous track.',
          'pause' => 'Paused.',
          _ => 'Playing.',
        };
        return await _windowsKeyEvent(key, text);
      }
      return const ActionResult(false, 'Media control not available here.');
    } catch (_) {
      return const ActionResult(false, 'Could not control media.');
    }
  }

  Future<ActionResult> _setAlarm(Map<String, dynamic> args) async {
    final hour = args['hour'] as int? ?? 0;
    final minute = args['minute'] as int? ?? 0;
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        // Kotlin fires the real ACTION_SET_ALARM intent.
        return await _deviceBackend.run(AgentActions.alarmSet, {
          'hour': hour,
          'minute': minute,
        });
      }
      if (defaultTargetPlatform == TargetPlatform.windows) {
        // Windows 10/11 ships "Alarms & Clock"; open it at its alarms view.
        final r = await Process.run('cmd', ['/c', 'start', '', 'ms-clock:']);
        if (r.exitCode == 0) {
          return const ActionResult(
            true,
            'Opened the Windows Clock app — set the alarm there.',
          );
        }
        return const ActionResult(
          false,
          'I could not open the Clock app on this PC.',
        );
      }
      if (defaultTargetPlatform == TargetPlatform.linux) {
        // gnome-clocks is the closest desktop equivalent when installed.
        final which = await Process.run('sh', [
          '-c',
          'command -v gnome-clocks',
        ]);
        if (which.exitCode == 0) {
          final path = which.stdout.toString().trim();
          try {
            // Fire-and-forget: the clock app stays open, don't await exit.
            await Process.start(path, const []);
            return const ActionResult(
              true,
              'Opened gnome-clocks — set the alarm there.',
            );
          } catch (_) {}
        }
        return const ActionResult(
          false,
          "Alarms are for the device you carry — Nexus sets real alarms from your Android phone. This PC has no alarm clock I can reach.",
        );
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
      // No real reminder service exists yet (on any platform), so save it
      // as a note — and say so instead of pretending a reminder was set.
      final saved = await _appendNote('[Reminder] $text');
      return ActionResult(
        saved.ok,
        saved.ok
            ? 'Reminder saved as a note on this device — real reminders aren\'t wired into this release yet.'
            : saved.message,
      );
    } catch (_) {
      return const ActionResult(false, 'Could not set reminder.');
    }
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
      if (defaultTargetPlatform == TargetPlatform.linux) {
        final (args, okText) = switch (mode) {
          'up' => (
            <String>['set-sink-volume', '@DEFAULT_SINK@', '+10%'],
            'Volume up.',
          ),
          'down' => (
            <String>['set-sink-volume', '@DEFAULT_SINK@', '-10%'],
            'Volume down.',
          ),
          _ => (
            <String>['set-sink-mute', '@DEFAULT_SINK@', 'toggle'],
            'Volume muted.',
          ),
        };
        final r = await Process.run('pactl', args);
        if (r.exitCode == 0) return ActionResult(true, okText);
        return const ActionResult(
          false,
          'No audio server responded — volume needs PulseAudio/PipeWire (pactl) on this desktop.',
        );
      }
      if (defaultTargetPlatform == TargetPlatform.windows) {
        final key = switch (mode) {
          'up' => 0xAF, // VK_VOLUME_UP
          'down' => 0xAE, // VK_VOLUME_DOWN
          _ => 0xAD, // VK_VOLUME_MUTE (toggles)
        };
        final text = switch (mode) {
          'up' => 'Volume up.',
          'down' => 'Volume down.',
          _ => 'Volume muted.',
        };
        return await _windowsKeyEvent(key, text);
      }
      return const ActionResult(false, 'Could not change volume here.');
    } catch (_) {
      return const ActionResult(false, 'Could not change volume here.');
    }
  }
}
