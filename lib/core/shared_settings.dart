// Which settings a paired device may change on this one.
//
// The `agent.setting` frame carries a key and a value, and this file is the
// whole security boundary in front of it: a key that is not listed here is
// refused before anything is written, so a peer cannot reach pairing, file
// sharing, clipboard sync, the agent policy or the wake word by naming them.
//
// The test for membership is not "would it be convenient to sync" but "does it
// mean the same thing on both devices, and does getting it wrong cost a
// preference rather than a permission". A system prompt and a clipboard-send
// policy pass. A switch that lets someone read this disk does not, and no
// amount of convenience changes that.
library;

/// One setting that travels, with the name a person reads.
///
/// The [key] is the wire string, so it is part of the protocol: renaming one is
/// a migration for every device that already stored it as a scope choice.
enum SharedSetting {
  /// The standing instruction appended to every chat turn.
  systemPrompt('systemPrompt', 'System prompt'),

  /// Whether a copied clip is pushed immediately and to every paired device,
  /// rather than after the delay and only to devices in use.
  alwaysMerge('alwaysMerge', 'Clipboard sending');

  const SharedSetting(this.key, this.label);

  /// The name on the wire and in the store's scope table.
  final String key;

  /// What the sheet and the notice call it.
  final String label;

  /// The setting [key] names, or null for anything else — including every key
  /// a future build might send, which is why an unknown key is refused rather
  /// than guessed at.
  static SharedSetting? byKey(String key) {
    for (final SharedSetting setting in SharedSetting.values) {
      if (setting.key == key) return setting;
    }
    return null;
  }

  /// Whether [value] is the shape this setting stores. A string where a bool
  /// belongs is a frame from a build that disagrees about the key, and writing
  /// it would corrupt a preference rather than sync one.
  bool accepts(Object? value) => switch (this) {
    SharedSetting.systemPrompt => value is String,
    SharedSetting.alwaysMerge => value is bool,
  };
}

/// What "remember my choice" stores: send to this device only, or to all of
/// them. Absent means ask every time, which is the default.
abstract final class SettingScope {
  static const String local = 'local';
  static const String all = 'all';
}
