// The user's own standing instruction for the assistant, stored once and
// appended to every chat system turn.
//
// This is deliberately not a chat message and not a remembered fact: "call me
// TVCraft and answer in French" is a rule about every answer, not something the
// user said in one conversation. Keeping it in its own preference means it
// survives a cleared chat, can be edited in one field, and never turns into
// history the model reads back as something it said.
//
// Vision turns do not receive it. A sentence about the user's name or preferred
// language has nothing to do with describing a photograph, and the on-device
// model already has a small attention budget.
library;

import 'dart:async';

import 'package:flutter/foundation.dart'
    show ChangeNotifier, debugPrint, visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

/// The longest custom instruction kept. Long enough for a name, a language and
/// a tone; short enough that a pasted essay cannot crowd out the question on a
/// 0.5B model.
const int kSystemPromptLimit = 1200;

/// The one custom system instruction this device has.
class SystemPrompt extends ChangeNotifier {
  SystemPrompt({String initial = ''}) : _text = initial.trim();

  @visibleForTesting
  static SystemPrompt Function()? override;

  static SystemPrompt? _instance;

  static SystemPrompt get instance =>
      override?.call() ?? (_instance ??= SystemPrompt());

  @visibleForTesting
  static void debugReset() => _instance = null;

  static const String key = 'nexus.system.prompt';

  String _text;
  bool _attached = false;
  Future<void>? _loading;

  /// What the user typed, exactly as they typed it (trimmed at the ends).
  String get text => _text;

  /// The text the brain is given, or empty when the field is blank.
  String get context => _text.trim();

  bool get isEmpty => context.isEmpty;

  /// Reads the saved instruction, once. Idempotent and safe to await from every
  /// screen that shows the field.
  Future<void> attach() {
    if (_attached) return Future<void>.value();
    return _loading ??= _load();
  }

  Future<void> _load() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String stored = (prefs.getString(key) ?? '').trim();
      if (stored.isNotEmpty && stored != _text) {
        _text = stored.length <= kSystemPromptLimit
            ? stored
            : stored.substring(0, kSystemPromptLimit);
        notifyListeners();
      }
    } catch (error) {
      debugPrint('PROMPT: no saved instruction ($error)');
    } finally {
      _attached = true;
    }
  }

  /// Replaces the instruction and remembers it. A blank value removes it.
  Future<void> setText(String value) async {
    final String next = value.trim();
    final String limited = next.length <= kSystemPromptLimit
        ? next
        : next.substring(0, kSystemPromptLimit);
    if (limited == _text) return;
    _text = limited;
    notifyListeners();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      if (limited.isEmpty) {
        await prefs.remove(key);
      } else {
        await prefs.setString(key, limited);
      }
    } catch (error) {
      debugPrint('PROMPT: could not store the instruction ($error)');
    }
  }

  /// Forgets the instruction now and after a restart.
  Future<void> clear() => setText('');

  /// Stores on every keystroke without waiting: a text field must never block
  /// on a preference write, and the next answer reads the value in memory.
  void setTextSoon(String value) {
    unawaited(setText(value));
  }
}
