// The user's profile: what the assistant calls YOU, what YOU call the
// assistant, and whether first-run setup is done. This is what makes the
// assistant feel personal from the first launch instead of a stranger —
// greetings use the stored name, and the first-run card only appears once.
import 'package:shared_preferences/shared_preferences.dart';

/// Everything the assistant knows about its person, per device.
class UserProfile {
  /// What the assistant calls the user ("call me sam" → "Sam").
  final String? userName;

  /// What the user calls the assistant (renamed on first run, default Nexus).
  final String assistantName;

  /// Whether first-run setup (names + permissions) has been completed.
  final bool onboarded;

  const UserProfile({
    this.userName,
    this.assistantName = 'Nexus',
    this.onboarded = false,
  });

  UserProfile copyWith({
    String? userName,
    String? assistantName,
    bool? onboarded,
  }) => UserProfile(
    userName: userName ?? this.userName,
    assistantName: assistantName ?? this.assistantName,
    onboarded: onboarded ?? this.onboarded,
  );
}

/// Where the profile lives — injectable so tests use an in-memory fake and
/// production persists across restarts (SharedPreferences).
abstract class ProfileStore {
  Future<UserProfile> read();

  Future<void> save(UserProfile profile);
}

/// In-memory implementation for tests (and any place a real store is not
/// ready — reads return the untouched defaults, so nothing is assumed).
class MemoryProfileStore implements ProfileStore {
  UserProfile _profile = const UserProfile();

  @override
  Future<UserProfile> read() async => _profile;

  @override
  Future<void> save(UserProfile profile) async {
    _profile = profile;
  }
}

/// SharedPreferences-backed store used in production. Lazy instance
/// resolution, and every call degrades gracefully when the plugin is
/// unavailable (tests, desktop before registration): the profile stays the
/// untouched defaults — setup simply shows again, it never crashes.
class SharedPrefsProfileStore implements ProfileStore {
  static const _keyUser = 'nexus.profile.userName';
  static const _keyAssistant = 'nexus.profile.assistantName';
  static const _keyOnboarded = 'nexus.profile.onboarded';

  SharedPreferences? _prefs;

  Future<SharedPreferences?> _instance() async {
    try {
      return _prefs ??= await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<UserProfile> read() async {
    final prefs = await _instance();
    if (prefs == null) return const UserProfile();
    return UserProfile(
      userName: prefs.getString(_keyUser),
      assistantName: prefs.getString(_keyAssistant) ?? 'Nexus',
      onboarded: prefs.getBool(_keyOnboarded) ?? false,
    );
  }

  @override
  Future<void> save(UserProfile profile) async {
    final prefs = await _instance();
    if (prefs == null) return;
    if (profile.userName == null) {
      await prefs.remove(_keyUser);
    } else {
      await prefs.setString(_keyUser, profile.userName!);
    }
    await prefs.setString(_keyAssistant, profile.assistantName);
    await prefs.setBool(_keyOnboarded, profile.onboarded);
  }
}
