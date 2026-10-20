// The language voice listens and speaks in, stored once and applied to both
// halves of the platform seam.
//
// Android's recognizer and its text-to-speech engine each keep their own
// language, and a user who picks French in Settings expects both to move. One
// setting here writes both, which is the only way the transcript and the reply
// cannot end up in different languages.
//
// The list is deliberately short. A dropdown that offered every BCP-47 tag
// would be offering languages the phone may not have a recognizer model for;
// these are the ones the app's own copy is written for, and a device that lacks
// one falls back to its system language honestly.
library;

import 'dart:async';

import 'package:flutter/foundation.dart'
    show ChangeNotifier, debugPrint, visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

import 'speech.dart';

/// One choice in the Voice settings dropdown.
class VoiceLanguage {
  const VoiceLanguage(this.tag, this.label);

  /// BCP-47, which is what Android's recognizer and TTS both accept.
  final String tag;

  /// What the user reads. Endonyms, because a language is the one setting a
  /// person should be able to recognise without already speaking the app's
  /// language.
  final String label;

  @override
  String toString() => '$label ($tag)';
}

/// The languages the dropdown offers.
const List<VoiceLanguage> kVoiceLanguages = <VoiceLanguage>[
  VoiceLanguage('en-US', 'English (US)'),
  VoiceLanguage('en-GB', 'English (UK)'),
  VoiceLanguage('fr-FR', 'Français'),
  VoiceLanguage('es-ES', 'Español'),
  VoiceLanguage('de-DE', 'Deutsch'),
  VoiceLanguage('it-IT', 'Italiano'),
  VoiceLanguage('pt-BR', 'Português (Brasil)'),
  VoiceLanguage('hi-IN', 'हिन्दी'),
  VoiceLanguage('ar-SA', 'العربية'),
  VoiceLanguage('zh-CN', '中文 (简体)'),
  VoiceLanguage('ja-JP', '日本語'),
];

/// The stored language, and the one both speech seams are currently using.
class VoiceSettings extends ChangeNotifier {
  VoiceSettings({String? initial}) : _language = initial ?? 'en-US';

  @visibleForTesting
  static VoiceSettings Function()? override;

  static VoiceSettings? _instance;

  static VoiceSettings get instance =>
      override?.call() ?? (_instance ??= VoiceSettings());

  @visibleForTesting
  static void debugReset() => _instance = null;

  static const String key = 'nexus.voice.language';

  /// The preference that says whether replies may be read aloud.
  ///
  /// It is a *permission* for the speaker, not a mode of listening: a reply to
  /// a spoken turn is read aloud only while this is true. Defaults to true so
  /// the voice conversation the app already had keeps working on an install
  /// that has never opened Settings.
  static const String speakRepliesKey = 'nexus.voice.speakReplies';

  String _language;
  bool _speakReplies = true;
  bool _attached = false;

  String get language => _language;

  /// Whether chat may speak an answer out loud.
  bool get speakReplies => _speakReplies;

  set speakReplies(bool value) {
    if (value == _speakReplies) return;
    _speakReplies = value;
    notifyListeners();
    unawaited(_storeSpeakReplies(value));
  }

  Future<void> _storeSpeakReplies(bool value) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setBool(speakRepliesKey, value);
    } catch (error) {
      debugPrint('VOICE: could not store the spoken-reply choice ($error)');
    }
  }

  VoiceLanguage get choice {
    for (final VoiceLanguage language in kVoiceLanguages) {
      if (language.tag == _language) return language;
    }
    return kVoiceLanguages.first;
  }

  /// Reads the stored choice and applies it to both speech seams. Idempotent;
  /// a device with no preference keeps its own locale.
  Future<void> attach() async {
    if (_attached) return;
    _attached = true;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? stored = prefs.getString(key);
      if (stored != null && stored.trim().isNotEmpty) {
        _language = stored.trim();
        notifyListeners();
      }
      _speakReplies = prefs.getBool(speakRepliesKey) ?? true;
    } catch (error) {
      debugPrint('VOICE: no language preference ($error)');
    }
    await _apply();
  }

  /// Changes the language for both recognition and speech, and remembers it.
  Future<void> setLanguage(String tag) async {
    final String next = tag.trim();
    if (next.isEmpty || next == _language) return;
    _language = next;
    notifyListeners();
    await _apply();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, next);
    } catch (error) {
      debugPrint('VOICE: could not store the language ($error)');
    }
  }

  Future<void> _apply() async {
    // Both halves are always told, even when only one seam is available on
    // this platform: a desktop that grows a recognizer later must not inherit
    // a language that was never sent to it.
    await SpeechInput.current.setLanguage(_language);
    await SpeechOutput.current.setLanguage(_language);
  }
}
