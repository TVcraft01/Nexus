// The two switches behind the composer's `+`.
//
// They are not attachments, which is why they are here rather than in the
// sheet's own state: memory injection and web lookups are facts about every
// answer that follows, and a switch that forgot itself when the sheet closed
// would be a preference the user has to set again every morning.
//
// Defaults are the app's promises: memory on (it is the thing that makes
// "remember my name" work), web search off (nothing leaves this device unless
// the user says so, and the sheet says exactly what turning it on sends).
import 'package:flutter/foundation.dart'
    show ChangeNotifier, debugPrint, visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

/// Storage behind [ComposerSettings]. Injectable for the same reason every
/// other preference store in the app is: a widget test must not need a plugin.
abstract class ComposerSettingsStore {
  Future<bool?> readMemory();
  Future<bool?> readWeb();
  Future<void> writeMemory(bool value);
  Future<void> writeWeb(bool value);
}

/// In-memory store for tests.
class MemoryComposerSettingsStore implements ComposerSettingsStore {
  MemoryComposerSettingsStore({this.memory, this.web});

  bool? memory;
  bool? web;

  @override
  Future<bool?> readMemory() async => memory;

  @override
  Future<bool?> readWeb() async => web;

  @override
  Future<void> writeMemory(bool value) async => memory = value;

  @override
  Future<void> writeWeb(bool value) async => web = value;
}

/// One preference each. A missing store means the defaults, not a failure.
class PrefsComposerSettingsStore implements ComposerSettingsStore {
  static const String memoryKey = 'composer_memory_enabled';
  static const String webKey = 'composer_web_search_enabled';

  SharedPreferences? _prefs;

  Future<SharedPreferences?> _instance() async {
    try {
      return _prefs ??= await SharedPreferences.getInstance();
    } catch (error) {
      debugPrint('COMPOSER: no preferences store ($error)');
      return null;
    }
  }

  @override
  Future<bool?> readMemory() async => (await _instance())?.getBool(memoryKey);

  @override
  Future<bool?> readWeb() async => (await _instance())?.getBool(webKey);

  @override
  Future<void> writeMemory(bool value) async {
    await (await _instance())?.setBool(memoryKey, value);
  }

  @override
  Future<void> writeWeb(bool value) async {
    await (await _instance())?.setBool(webKey, value);
  }
}

/// The app-wide pair of toggles.
class ComposerSettings extends ChangeNotifier {
  ComposerSettings({
    ComposerSettingsStore? store,
    bool memoryEnabled = true,
    bool webSearchEnabled = false,
  }) : _store = store ?? PrefsComposerSettingsStore(),
       _memory = memoryEnabled,
       _web = webSearchEnabled;

  /// Test seam, in the shape the rest of the app uses.
  @visibleForTesting
  static ComposerSettings Function()? override;

  static ComposerSettings? _instance;

  static ComposerSettings get instance =>
      override?.call() ?? (_instance ??= ComposerSettings());

  @visibleForTesting
  static void debugReset() => _instance = null;

  final ComposerSettingsStore _store;
  bool _memory;
  bool _web;
  Future<void>? _loading;

  /// Whether remembered facts are put in front of the model. Off means the
  /// model is told nothing this device remembers, for this and every later
  /// answer, until the switch goes back on.
  bool get memoryEnabled => _memory;

  /// Whether a question may be looked up on the web before it is answered.
  bool get webSearchEnabled => _web;

  /// Reads both switches once. Idempotent, like every other attach() here.
  Future<void> attach() => _loading ??= _load();

  Future<void> _load() async {
    final bool? memory = await _store.readMemory();
    final bool? web = await _store.readWeb();
    bool changed = false;
    if (memory != null && memory != _memory) {
      _memory = memory;
      changed = true;
    }
    if (web != null && web != _web) {
      _web = web;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  /// Flips memory. The notification comes first: the sheet is waiting on it.
  Future<void> setMemoryEnabled(bool value) async {
    if (value == _memory) return;
    _memory = value;
    notifyListeners();
    await _store.writeMemory(value);
  }

  /// Flips web search, and says so in the log — this is the one switch that
  /// changes where a question goes, and a quiet change of that is a surprise
  /// waiting to happen.
  Future<void> setWebSearchEnabled(bool value) async {
    if (value == _web) return;
    _web = value;
    debugPrint(
      'COMPOSER: web search ${value ? 'enabled' : 'disabled'} by the user',
    );
    notifyListeners();
    await _store.writeWeb(value);
  }
}
