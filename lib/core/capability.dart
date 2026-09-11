// The capability registry — one owner for "what Nexus can do".
//
// Before this file, a single fact about an action lived in five places: the id
// in `agent_contract.dart`, its label and canonical example in `skills.dart`,
// the phrasing that parses it in `command_interpreter.dart`, whether a
// platform's executor can run it in `agent_contract`'s two hand-listed
// defaults, and the wording in `answers.dart`. Five partial owners meant a
// suggestion chip could name an action no device could run, and a platform
// list could silently drift from the executor that backs it.
//
// Now the facts live here once and every consumer reads them:
//
//   skills.dart       -> [skillCatalog]      (what shapes the ranking)
//   assistant_view    -> [suggestionExamples] (the one-tap fallback chips)
//   agent_contract    -> [defaultCapabilitiesFor] (what this platform offers)
//
// `AgentActions` stays the vocabulary — the ids themselves are not duplicated
// here, they are referenced, so a rename breaks the build instead of silently
// orphaning a capability. two invariants are enforced by
// `test/capability_test.dart`: every `AgentActions` id has exactly one entry
// here, and every [Capability.example] really parses back to its own action.
import 'agent_contract.dart';

/// What one action is in user terms, and where it can actually run.
///
/// [platforms] is the set of platforms whose *executor* can run this action.
/// An empty set means the action never reaches a device backend — it is
/// answered locally by the catalog (math, the time, memory, jokes), so it is
/// not something this device advertises to peers.
class Capability {
  /// One of the [AgentActions] id constants.
  final String id;

  /// How the assistant names it (skill rankings, suggestions).
  final String label;

  /// The canonical one-tap phrase, or null when none has been verified yet.
  /// Every non-null example is asserted to parse to [id].
  final String? example;

  /// A different phrase for the fallback suggestion row, when the canonical
  /// example is not the one worth showing a brand-new user. Falls back to
  /// [example] when null.
  final String? suggestExample;

  /// True for the everyday skills that shape rankings and can be suggested.
  final bool everyday;

  /// Platforms whose executor can run this; empty = answered locally.
  final Set<String> platforms;

  const Capability(
    this.id,
    this.label, {
    this.example,
    this.suggestExample,
    this.everyday = false,
    this.platforms = const {},
  });

  /// True when some device backend runs this, rather than the catalog alone.
  bool get isDeviceExecutable => platforms.isNotEmpty;
}

const Set<String> _phone = {'android'};
const Set<String> _desktop = {'linux', 'windows', 'macos'};
const Set<String> _anyDevice = {'android', 'linux', 'windows', 'macos'};

/// Every action Nexus knows, with its label, verified example and reach.
/// Declaration order is the order [defaultCapabilitiesFor] reports, grouped
/// the way the assistant talks about them.
const List<Capability> kCapabilities = [
  // --- Core: answered by the catalog, runs anywhere ---------------------
  // Not offered to peers: listing devices is a local answer, not a backend.
  Capability(AgentActions.deviceList, 'Devices',
      example: 'show my devices', everyday: true),
  Capability(AgentActions.ledBlink, 'Blink', platforms: _anyDevice),
  Capability(AgentActions.greet, 'Greeting'),
  Capability(AgentActions.timeGet, 'Time',
      example: 'what time is it', suggestExample: 'what time is it'),
  Capability(AgentActions.mathCalc, 'Math'),
  Capability(AgentActions.helpGet, 'Help',
      example: 'what can you do', suggestExample: 'what can you do'),
  Capability(AgentActions.clipboardWrite, 'Clipboard'),
  Capability(AgentActions.webSearch, 'Search',
      example: 'search for cats', everyday: true, platforms: _anyDevice),
  Capability(AgentActions.noteCreate, 'Notes',
      example: 'note that buy milk', everyday: true, platforms: _anyDevice),
  Capability(AgentActions.timerSet, 'Timers',
      example: 'set a timer for 5 minutes',
      everyday: true,
      platforms: _anyDevice),
  Capability(AgentActions.openUrl, 'Open',
      example: 'open github.com', everyday: true, platforms: _anyDevice),
  Capability(AgentActions.systemInfo, 'System info',
      example: 'system info', everyday: true, platforms: _anyDevice),
  Capability(AgentActions.volumeSet, 'Volume',
      example: 'volume up', everyday: true, platforms: _anyDevice),

  // --- System ----------------------------------------------------------
  Capability(AgentActions.appOpen, 'Apps',
      example: 'open youtube', everyday: true, platforms: _anyDevice),
  Capability(AgentActions.appClose, 'Close app', platforms: _phone),
  Capability(AgentActions.screenshot, 'Screenshot', platforms: _anyDevice),
  Capability(AgentActions.batteryGet, 'Battery', platforms: _anyDevice),
  Capability(AgentActions.brightnessSet, 'Brightness', platforms: _phone),
  Capability(AgentActions.flashlightToggle, 'Flashlight',
      example: 'flashlight on', everyday: true, platforms: _phone),
  Capability(AgentActions.airplaneModeSet, 'Airplane mode'),
  Capability(AgentActions.wifiToggle, 'Wi-Fi', platforms: _phone),
  Capability(AgentActions.bluetoothToggle, 'Bluetooth', platforms: _phone),
  Capability(AgentActions.lockScreen, 'Lock', platforms: _phone),
  Capability(AgentActions.deviceRestart, 'Restart'),

  // --- Communication ---------------------------------------------------
  Capability(AgentActions.callPlace, 'Calls',
      example: 'call mom', everyday: true, platforms: _phone),
  Capability(AgentActions.messageSend, 'Texts',
      example: 'text mom saying hi', everyday: true, platforms: _phone),
  Capability(AgentActions.emailSend, 'Email',
      example: 'email mom saying hi',
      suggestExample: 'email mom',
      everyday: true,
      platforms: _anyDevice),

  // --- Media -----------------------------------------------------------
  Capability(AgentActions.mediaPlay, 'Music',
      example: 'play music',
      suggestExample: 'play my playlist',
      everyday: true,
      platforms: _anyDevice),
  Capability(AgentActions.mediaPause, 'Pause', platforms: _anyDevice),
  Capability(AgentActions.mediaNext, 'Next track', platforms: _anyDevice),
  Capability(AgentActions.mediaPrev, 'Previous track', platforms: _anyDevice),
  Capability(AgentActions.mediaShuffle, 'Shuffle', platforms: _phone),
  Capability(AgentActions.mediaRepeat, 'Repeat', platforms: _phone),

  // --- Productivity ----------------------------------------------------
  Capability(AgentActions.alarmSet, 'Alarms',
      example: 'set an alarm for 7am', everyday: true, platforms: _phone),
  Capability(AgentActions.alarmDismiss, 'Dismiss alarm', platforms: _phone),
  Capability(AgentActions.timerStatus, 'Timer status', platforms: _anyDevice),
  Capability(AgentActions.timerCancel, 'Cancel timer', platforms: _anyDevice),
  Capability(AgentActions.reminderSet, 'Reminders',
      example: 'remind me to buy milk', everyday: true, platforms: _phone),
  Capability(AgentActions.weatherGet, 'Weather',
      example: 'what is the weather',
      suggestExample: 'what is the weather in paris',
      everyday: true,
      platforms: _anyDevice),
  Capability(AgentActions.navOpen, 'Navigate',
      example: 'take me home', platforms: _anyDevice),
  Capability(AgentActions.locationGet, 'Location'),
  Capability(AgentActions.intro, 'Introduction'),
  Capability(AgentActions.musicSearch, 'Music search'),
  Capability(AgentActions.currencyGet, 'Currency'),
  Capability(AgentActions.timezoneGet, 'Time zone'),
  Capability(AgentActions.calendarAdd, 'Calendar', platforms: _phone),
  Capability(AgentActions.calendarRead, 'Calendar read', platforms: _phone),
  Capability(AgentActions.appDefault, 'App defaults'),
  Capability(AgentActions.profileSet, 'Profile'),
  Capability(AgentActions.profileGet, 'Profile recall'),
  Capability(AgentActions.shoppingListAdd, 'Shopping list',
      example: 'add milk to my shopping list', everyday: true),
  Capability(AgentActions.shoppingListGet, 'Shopping list read'),
  Capability(AgentActions.darkModeSet, 'Dark mode', platforms: _anyDevice),
  Capability(AgentActions.defineWord, 'Definitions'),
  Capability(AgentActions.translateText, 'Translate'),
  Capability(AgentActions.unitConvert, 'Convert'),

  // --- Fun -------------------------------------------------------------
  Capability(AgentActions.randomDice, 'Dice'),
  Capability(AgentActions.randomCoin, 'Coin flip'),
  Capability(AgentActions.randomNumber, 'Random number'),
  Capability(AgentActions.tellJoke, 'Jokes'),

  // --- Memory ----------------------------------------------------------
  Capability(AgentActions.memoryRemember, 'Remember'),
  Capability(AgentActions.memoryRecall, 'Recall',
      example: 'what do you know about me',
      suggestExample: 'what do you know about me'),
  Capability(AgentActions.memoryForget, 'Forget'),
  Capability(AgentActions.memoryQuestion, 'What it knows', example: 'who is mom'),

  // --- Finding devices -------------------------------------------------
  Capability(AgentActions.findDevice, 'Find device'),
  Capability(AgentActions.ringDevice, 'Ring device'),
];

/// The action ids worth showing a brand-new user, in order. The phrase shown
/// is the capability's own [Capability.suggestExample] (or [Capability.example]),
/// so a suggestion can never name something no device can run — the id is the
/// only way to add one.
const List<String> kSuggestionIds = [
  AgentActions.helpGet,
  AgentActions.timeGet,
  AgentActions.memoryRecall,
  AgentActions.weatherGet,
  AgentActions.navOpen,
  AgentActions.mediaPlay,
  AgentActions.appOpen,
  AgentActions.callPlace,
  AgentActions.emailSend,
  AgentActions.flashlightToggle,
];

final Map<String, Capability> _byId = {
  for (final capability in kCapabilities) capability.id: capability,
};

/// The registry entry for [id], or null for an id nobody has declared.
Capability? capabilityFor(String id) => _byId[id];

/// Every declared action id.
Iterable<String> get capabilityIds => _byId.keys;

/// The everyday skills the ranking counts and talks about, keyed by action id.
/// Derived, so it can never disagree with the registry.
Map<String, ({String label, String example})> skillCatalog() => {
  for (final capability in kCapabilities)
    if (capability.everyday && capability.example != null)
      capability.id: (label: capability.label, example: capability.example!),
};

/// The one-tap fallback phrases, in [kSuggestionIds] order. Ids without a
/// verified example are skipped rather than guessed at.
List<String> suggestionExamples() => [
  for (final id in kSuggestionIds)
    if (capabilityFor(id) case final c?)
      c.suggestExample ?? c.example ?? '',
].where((phrase) => phrase.isNotEmpty).toList();

/// The capabilities a device of [platform] advertises by default — a phone
/// can make calls and send texts, a desktop usually cannot. Devices that
/// announce richer capabilities later simply replace this default; the ids
/// are the same [AgentActions] strings so one check serves both.
///
/// Any platform that is not Android is treated as a desktop, which is how
/// this behaved when the two lists were hand-written.
List<DeviceCapability> defaultCapabilitiesFor(String platform) {
  final here = platform == 'android' ? 'android' : 'linux';
  return [
    for (final capability in kCapabilities)
      if (capability.platforms.contains(here)) DeviceCapability(capability.id),
  ];
}
