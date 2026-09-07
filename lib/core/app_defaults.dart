// Persisted assistant-level defaults: "always use deezer (from now on)".
// Android's chooser remembers its own per-intent "Always" pick deep in
// system settings — with no voice access. This store is the Nexus-level
// escape hatch: the assistant can set AND clear a favorite per domain, and
// bare phrases ("play music", "navigate home") honor it Siri-style until
// cleared. A phrase that names an app explicitly still wins for that one
// command; the store only fills the "no app mentioned" gap.
import 'package:shared_preferences/shared_preferences.dart';

/// Where the remembered per-domain default apps live. One key per domain,
/// shared by the interpreter (payload domain token) and the executor (key).
abstract final class AppDefaultDomain {
  static const music = 'nexus.appDefault.music';
  static const navigation = 'nexus.appDefault.navigation';
  static const calendar = 'nexus.appDefault.calendar';
}

/// Storage behind remembered app defaults — injectable so tests use an
/// in-memory fake and production persists across restarts.
abstract class AppDefaultsStore {
  Future<String?> read(String domainKey);

  Future<void> write(String domainKey, String appId);

  Future<void> clear(String domainKey);
}

/// In-memory implementation for tests (and any place a real store is not
/// ready yet — reads simply return null, so defaults are inert).
class MemoryAppDefaultsStore implements AppDefaultsStore {
  final Map<String, String> _values = {};

  @override
  Future<String?> read(String domainKey) async => _values[domainKey];

  @override
  Future<void> write(String domainKey, String appId) async {
    _values[domainKey] = appId;
  }

  @override
  Future<void> clear(String domainKey) async {
    _values.remove(domainKey);
  }
}

/// SharedPreferences-backed store used in production. Instance resolution
/// is lazy and awaited inside each call, so constructing the executor early
/// in the widget tree triggers no I/O until the first read or write.
/// Every call degrades gracefully when the plugin is unavailable entirely
/// (tests without platform channels, desktop builds before registration,
/// first run): reads return null — defaults are simply inert — and writes
/// no-op, so the feature can never crash an environment without prefs.
class SharedPrefsAppDefaultsStore implements AppDefaultsStore {
  SharedPreferences? _prefs;

  Future<SharedPreferences?> _instance() async {
    try {
      return _prefs ??= await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String?> read(String domainKey) async =>
      (await _instance())?.getString(domainKey);

  @override
  Future<void> write(String domainKey, String appId) async {
    final prefs = await _instance();
    if (prefs != null) {
      await prefs.setString(domainKey, appId);
    }
  }

  @override
  Future<void> clear(String domainKey) async {
    final prefs = await _instance();
    if (prefs != null) {
      await prefs.remove(domainKey);
    }
  }
}