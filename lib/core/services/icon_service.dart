// Which launcher icon Nexus is wearing.
//
// Android resolves a launcher icon from the manifest, so an app cannot swap an
// image while it runs: it declares one <activity-alias> per icon — all pointing
// at MainActivity — and keeps exactly one of them enabled. That is how the
// Telegram and Reddit icon pickers work, and it is why this file is mostly
// about *state*: which mode the user chose, what the system theme is doing, and
// which of the two the launcher should be showing. The switch itself is three
// lines of PackageManager on the other side of one channel (see ICON_CHANNEL in
// MainActivity.kt and the two aliases in AndroidManifest.xml).
//
// A launcher icon also cannot change while Nexus is not running — Android
// resolves it from the manifest at launch. "Auto" therefore means: settled
// every time the app starts, and again the moment the system theme flips while
// the app is open. Nothing here pretends otherwise.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The three choices the Settings sheet offers.
enum IconMode {
  /// The light mark, whatever the system is doing.
  light('light', 'Light'),

  /// The dark mark, whatever the system is doing.
  dark('dark', 'Dark'),

  /// Whichever of the two matches the system theme.
  auto('auto', 'Auto');

  const IconMode(this.token, this.label);

  /// What the platform channel and the stored preference use.
  final String token;

  /// What the sheet shows.
  final String label;

  /// [token] back to a mode — [fallback] for a value written by another build,
  /// so an unknown string can never wedge the service.
  static IconMode fromToken(String? token, {IconMode fallback = IconMode.auto}) {
    for (final mode in values) {
      if (mode.token == token) return mode;
    }
    return fallback;
  }

  /// The mark this mode wants with the system in [brightness]: itself, unless
  /// it is [auto]. One place, so "auto" cannot come to mean two things.
  IconMode resolve(Brightness brightness) => this == IconMode.auto
      ? (brightness == Brightness.dark ? IconMode.dark : IconMode.light)
      : this;
}

/// Storage behind the chosen mode — injectable so tests use an in-memory fake
/// and production persists across restarts. Deliberately the same shape as the
/// SharedPreferences stores in core/app_defaults.dart and core/profile.dart,
/// including the refusal to fail in an environment without the plugin: reads
/// answer null (the default is simply used) and writes no-op, so a desktop run
/// or a test without platform channels can never crash on this.
abstract class IconModeStore {
  Future<IconMode?> read();

  Future<void> write(IconMode mode);
}

/// In-memory implementation for tests.
class MemoryIconModeStore implements IconModeStore {
  IconMode? _mode;

  @override
  Future<IconMode?> read() async => _mode;

  @override
  Future<void> write(IconMode mode) async {
    _mode = mode;
  }
}

/// SharedPreferences-backed store used in production. Instance resolution is
/// lazy and awaited inside each call, so constructing the service early in the
/// widget tree triggers no I/O until the first read or write.
class SharedPrefsIconModeStore implements IconModeStore {
  /// The key the chosen mode is stored under.
  static const String key = 'icon_mode';

  SharedPreferences? _prefs;

  Future<SharedPreferences?> _instance() async {
    try {
      return _prefs ??= await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<IconMode?> read() async {
    final stored = (await _instance())?.getString(key);
    return stored == null ? null : IconMode.fromToken(stored);
  }

  @override
  Future<void> write(IconMode mode) async {
    final prefs = await _instance();
    if (prefs != null) {
      await prefs.setString(key, mode.token);
    }
  }
}

/// What actually flips the icon. Android only: everywhere else [supported] is
/// false, nothing is called, and the settings row explains itself rather than
/// pretending the switch happened.
abstract class LauncherIconSwitcher {
  /// Whether this platform can switch a launcher icon at all.
  bool get supported;

  /// Which mode the launcher is showing now, when the platform can tell us.
  ///
  /// Null means "no opinion" — an unsupported platform, or a build whose
  /// aliases are missing — which the service treats as "switch it".
  Future<IconMode?> current();

  /// Puts [mode] on. False when the platform accepted the call but refused the
  /// change; a platform error throws and is reported by the service.
  Future<bool> apply(IconMode mode);
}

/// The real switcher: one MethodChannel to MainActivity, whose two launcher
/// aliases are declared in AndroidManifest.xml.
class ChannelLauncherIconSwitcher implements LauncherIconSwitcher {
  ChannelLauncherIconSwitcher({@visibleForTesting MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('dev.nexus.nexus/app_icon');

  final MethodChannel _channel;

  @override
  bool get supported => defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<IconMode?> current() async {
    if (!supported) return null;
    final String? token = await _channel.invokeMethod<String>('currentIcon');
    return token == null ? null : IconMode.fromToken(token);
  }

  @override
  Future<bool> apply(IconMode mode) async {
    if (!supported) return false;
    final bool? accepted = await _channel.invokeMethod<bool>('setIcon', <String, Object?>{
      'mode': mode.token,
    });
    return accepted ?? false;
  }
}

/// Owns "which icon is Nexus wearing" for the whole app.
///
/// One instance lives as long as the app ([instance]); tests and any caller
/// that wants isolation build their own with a memory store and a scripted
/// switcher, which is why nothing here reaches for the plugin or the channel
/// directly.
class IconService with WidgetsBindingObserver {
  IconService({IconModeStore? store, LauncherIconSwitcher? switcher})
    : _store = store ?? SharedPrefsIconModeStore(),
      _switcher = switcher ?? ChannelLauncherIconSwitcher();

  /// The app-wide instance.
  static final IconService instance = IconService();

  final IconModeStore _store;
  final LauncherIconSwitcher _switcher;

  /// Auto until the user says otherwise: a phone already in dark mode gets the
  /// dark mark on first launch without anyone opening settings. The shipped
  /// alias is the light one, which is just the state before that first launch.
  IconMode _mode = IconMode.auto;
  String? _failure;
  bool _attached = false;

  /// The mode the user chose — which is not always the mark on screen, because
  /// in [IconMode.auto] the system theme has the last word. Use
  /// [platformMode] to ask what the launcher is actually showing.
  IconMode get mode => _mode;

  /// Whether this build can switch its icon at all: Android can, desktop
  /// cannot.
  bool get switchingSupported => _switcher.supported;

  /// Why the last switch failed, or null. Diagnostics for the row to report,
  /// never an input to a decision.
  String? get failure => _failure;

  /// Reads the stored choice, makes the launcher agree with it, and keeps
  /// agreeing while the app runs. Idempotent — the shell may call it on every
  /// start of the home screen without stacking observers.
  Future<void> attach() async {
    if (!_attached) {
      _attached = true;
      WidgetsBinding.instance.addObserver(this);
    }
    _mode = await _store.read() ?? _mode;
    await _settle();
  }

  /// Stops following the system theme. For a throwaway instance in a test; the
  /// app's own instance never detaches.
  void detach() {
    if (!_attached) return;
    _attached = false;
    WidgetsBinding.instance.removeObserver(this);
  }

  /// The user's choice from the settings sheet. The choice is stored *first*,
  /// so it survives a switch the platform refuses and is retried on the next
  /// start rather than silently forgotten.
  Future<void> setMode(IconMode mode) async {
    _mode = mode;
    await _store.write(mode);
    await _settle();
  }

  /// Which mark the launcher is really showing, when the platform can say.
  Future<IconMode?> platformMode() => _switcher.current();

  @override
  void didChangePlatformBrightness() => unawaited(_settle());

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The system theme can flip while Nexus is in the background and no
    // brightness callback is delivered for it; coming back to the foreground
    // is the first chance to notice.
    if (state == AppLifecycleState.resumed) unawaited(_settle());
  }

  /// Makes the launcher show whatever [_mode] wants right now.
  ///
  /// Overlapping settles need no queue: the enable-one-alias-then-disable-the-
  /// other pair happens inside a single platform call on the platform thread, so
  /// two of them can never interleave into an app with no launcher entry — and a
  /// settle always reads the *latest* [_mode], so the last choice wins even when
  /// the user taps twice while a switch is in flight.
  Future<void> _settle() async {
    final IconMode wanted = _mode.resolve(
      WidgetsBinding.instance.platformDispatcher.platformBrightness,
    );
    if (!_switcher.supported) return;
    try {
      // Ask before switching. Setting a component's enabled state makes
      // launchers re-render — and some OEM launchers restart the app's task —
      // so the common case, already wearing the right icon, should cost
      // nothing.
      if (await _switcher.current() == wanted) {
        _failure = null;
        return;
      }
      if (await _switcher.apply(wanted)) {
        _failure = null;
      } else {
        _failure = 'Android refused the icon switch';
      }
    } on PlatformException catch (error) {
      _failure = error.message ?? error.code;
    } on MissingPluginException {
      _failure = 'This build has no icon channel';
    }
  }
}
