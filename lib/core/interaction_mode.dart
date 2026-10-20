// How this user wants to talk to Nexus.
//
// The app has always been two things at once: a command runner that can turn
// the torch on without asking a model, and a conversational assistant. Which
// one the user *reaches for* changes how the same sentence should be answered,
// and it is the one question worth asking on the first run — before a thread,
// before a model, before any of the vocabulary the rest of the app uses.
//
// The answer is stored as it is read: null means "not chosen yet", which is the
// only value that shows the screen. A missing store is not an error, and it
// does not re-ask forever either — [attach] then leaves the choice null for
// this session but the app treats a missing store as "chosen conversational",
// because a first-run screen that cannot save must not block the app.
import 'package:flutter/foundation.dart'
    show ChangeNotifier, debugPrint, visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

/// The two ways in, said the way the first-run screen says them.
enum InteractionMode {
  /// Siri: short, instant, commands first.
  instant,

  /// ChatGPT: full sentences, explanations, conversation.
  conversational,
}

/// The words on the first-run card and on the mode's own line.
extension InteractionModeCopy on InteractionMode {
  String get label => switch (this) {
    InteractionMode.instant => 'Instant Commands',
    InteractionMode.conversational => 'Conversational',
  };

  /// The example under the title — one sentence, in the user's own terms.
  String get example => switch (this) {
    InteractionMode.instant =>
      '“Turn on the flashlight.” One line back, done before you look up.',
    InteractionMode.conversational =>
      '“Why is the sky blue?” A real answer, with room to explain.',
  };

  /// What the answer style asks the model for. Appended to whatever custom
  /// instructions the user wrote in Settings, never replacing them.
  String get instruction => switch (this) {
    InteractionMode.instant =>
      'Reply in one short sentence whenever the question allows it, and lead '
          'with the action or the answer. Do not add follow-up questions.',
    InteractionMode.conversational =>
      'Answer conversationally and explain your reasoning when it helps, in '
          'as many sentences as the question deserves.',
  };

  /// The mode a stored string stands for, or null.
  static InteractionMode? byId(String? id) => switch (id) {
    'instant' => InteractionMode.instant,
    'conversational' => InteractionMode.conversational,
    _ => null,
  };
}

/// The mode, and the one place that changes it.
class InteractionModeSetting extends ChangeNotifier {
  /// [initial] is for tests and for the live setting the shell already holds;
  /// production reads the stored choice through [load]. The constructor starts
  /// unloaded so nothing can ask the mode question before the store answers.
  InteractionModeSetting({InteractionMode? initial}) : _mode = initial;

  @visibleForTesting
  static InteractionModeSetting Function()? override;

  static InteractionModeSetting? _instance;

  static InteractionModeSetting get instance =>
      override?.call() ?? (_instance ??= InteractionModeSetting());

  @visibleForTesting
  static void debugReset() => _instance = null;

  /// The key the choice is stored under. Named once, because the first-run
  /// gate and the tests both need to agree with it.
  static const String key = 'interaction_mode';

  InteractionMode? _mode;
  bool _loaded = false;
  Future<void>? _loading;

  /// The chosen mode, or null before the user has chosen.
  InteractionMode? get mode => _mode;

  /// True once the store has answered (or failed to).
  bool get loaded => _loaded;

  /// True while the question should be asked: the store has answered and it
  /// has no answer. A store that cannot be reached counts as answered, with
  /// [InteractionMode.conversational] as the default — see the note at the top
  /// of this file.
  bool get needsChoice => _loaded && _mode == null;

  /// The mode in force for answering. Conversational until the user says
  /// otherwise, because a real answer is the safer default.
  InteractionMode get effective => _mode ?? InteractionMode.conversational;

  /// Reads the stored choice once. Every caller may await it.
  Future<void> attach() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      _mode = InteractionModeCopy.byId(prefs.getString(key));
    } catch (error) {
      debugPrint('MODE: no preferences store ($error)');
      // No store means no place to keep an answer, so the question is not
      // asked: a first-run screen the user cannot get past is worse than
      // starting conversational and offering the choice in Settings.
      _mode ??= InteractionMode.conversational;
    }
    _loaded = true;
    notifyListeners();
  }

  /// Chooses [mode], now and after a restart.
  Future<void> select(InteractionMode mode) async {
    _mode = mode;
    _loaded = true;
    notifyListeners();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, mode.name);
    } catch (error) {
      debugPrint('MODE: could not store the choice ($error)');
    }
  }

  /// Forgets the choice. Settings' "Ask me again" uses it; the app never does.
  Future<void> reset() async {
    _mode = null;
    _loaded = true;
    notifyListeners();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.remove(key);
    } catch (error) {
      debugPrint('MODE: could not clear the choice ($error)');
    }
  }
}
