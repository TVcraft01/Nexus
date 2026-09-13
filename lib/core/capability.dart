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
//   answers.dart      -> the help answer, built from [helpGroup],
//                        [Capability.helpPhrases] and [Capability.helpNote]
//
// `AgentActions` stays the vocabulary — the ids themselves are not duplicated
// here, they are referenced, so a rename breaks the build instead of silently
// orphaning a capability. Invariants are enforced by `test/capability_test.dart`:
// every `AgentActions` id has exactly one entry here, every [Capability.example]
// and every [Capability.helpPhrases] entry resolves back to its own capability,
// and a capability that offers phrasing says which section it belongs to.
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

  /// The section the help answer prints this capability under, one of
  /// [kHelpGroups], or null when the answer does not offer it.
  ///
  /// A capability that offers phrasing must name a section: an advertised
  /// phrase with nowhere to be advertised would otherwise be hidden silently,
  /// which is exactly how the old hand-written help text fell behind the
  /// registry. `test/capability_test.dart` asserts it.
  final String? helpGroup;

  /// Phrasings the help answer offers *beside* [example]. Every one resolves
  /// back to this capability, so the answer can never offer a phrase that
  /// means something else — or nothing at all.
  final List<String> helpPhrases;

  /// The short human clause the help answer adds after this capability's
  /// phrases ("launch any app"). Never a claim about what Nexus can do: just
  /// how the thing behaves. Must not contain a double quote, because the
  /// answer's offered phrases are exactly its double-quoted spans.
  final String? helpNote;

  const Capability(
    this.id,
    this.label, {
    this.example,
    this.suggestExample,
    this.everyday = false,
    this.platforms = const {},
    this.helpGroup,
    this.helpPhrases = const [],
    this.helpNote,
  });

  /// True when some device backend runs this, rather than the catalog alone.
  bool get isDeviceExecutable => platforms.isNotEmpty;
}

const Set<String> _phone = {'android'};
const Set<String> _anyDevice = {'android', 'linux', 'windows', 'macos'};

/// The sections the help answer prints, in the order it prints them. Each is
/// somebody's deliberate choice about how the catalogue reads, not a derived
/// grouping — the registry is the *owner* of the answer, not its typographer.
const List<String> kHelpGroups = [
  'Nexus',
  'Time & Math',
  'System',
  'Communication',
  'Media',
  'Productivity',
  'Weather & Getting Around',
  'Email',
  'Fun',
  'Clipboard & Devices',
  'Web',
  'Memory',
];

/// Every action Nexus knows, with its label, verified examples and reach.
/// Declaration order is the order [defaultCapabilitiesFor] reports and the
/// order the help answer offers capabilities within a section.
const List<Capability> kCapabilities = [
  // --- Core: answered by the catalog, runs anywhere ---------------------
  // Not offered to peers: listing devices is a local answer, not a backend.
  Capability(AgentActions.deviceList, 'Devices',
      example: 'show my devices',
      everyday: true,
      helpGroup: 'Clipboard & Devices'),
  Capability(AgentActions.ledBlink, 'Blink',
      platforms: _anyDevice,
      helpGroup: 'Clipboard & Devices',
      helpPhrases: ['blink the ESP32']),
  Capability(AgentActions.greet, 'Greeting'),
  Capability(AgentActions.timeGet, 'Time',
      example: 'what time is it',
      suggestExample: 'what time is it',
      helpGroup: 'Time & Math',
      helpPhrases: ['what is the date']),
  Capability(AgentActions.mathCalc, 'Math',
      helpGroup: 'Time & Math',
      helpPhrases: ['what is 12 times 8', '2 + 3', 'what is 15% of 80']),
  Capability(AgentActions.helpGet, 'Help',
      example: 'what can you do',
      suggestExample: 'what can you do',
      helpGroup: 'Nexus',
      helpNote: 'this list'),
  Capability(AgentActions.clipboardWrite, 'Clipboard',
      helpGroup: 'Clipboard & Devices',
      helpPhrases: ['copy hello to my devices']),
  Capability(AgentActions.webSearch, 'Search',
      example: 'search for cats',
      everyday: true,
      platforms: _anyDevice,
      helpGroup: 'Web',
      helpPhrases: ['search for flutter']),
  Capability(AgentActions.noteCreate, 'Notes',
      example: 'note that buy milk',
      everyday: true,
      platforms: _anyDevice,
      helpGroup: 'Web'),
  Capability(AgentActions.timerSet, 'Timers',
      example: 'set a timer for 5 minutes',
      everyday: true,
      platforms: _anyDevice,
      helpGroup: 'Productivity'),
  Capability(AgentActions.openUrl, 'Open',
      example: 'open github.com',
      everyday: true,
      platforms: _anyDevice,
      helpGroup: 'Web'),
  Capability(AgentActions.systemInfo, 'System info',
      example: 'system info',
      everyday: true,
      platforms: _anyDevice,
      helpGroup: 'System',
      helpNote: 'your computer\'s specs'),
  Capability(AgentActions.volumeSet, 'Volume',
      example: 'volume up',
      everyday: true,
      platforms: _anyDevice,
      helpGroup: 'System',
      helpPhrases: ['volume down', 'mute', 'set volume to 50']),

  // --- System ----------------------------------------------------------
  Capability(AgentActions.appOpen, 'Apps',
      example: 'open youtube',
      everyday: true,
      platforms: _anyDevice,
      helpGroup: 'System',
      helpNote: 'launch any app'),
  Capability(AgentActions.appClose, 'Close app', platforms: _phone),
  Capability(AgentActions.screenshot, 'Screenshot',
      platforms: _anyDevice,
      helpGroup: 'System',
      helpPhrases: ['screenshot']),
  Capability(AgentActions.batteryGet, 'Battery',
      platforms: _anyDevice,
      helpGroup: 'System',
      helpPhrases: ['battery']),
  Capability(AgentActions.brightnessSet, 'Brightness',
      platforms: _phone,
      helpGroup: 'System',
      helpPhrases: ['brightness 50']),
  Capability(AgentActions.flashlightToggle, 'Flashlight',
      example: 'flashlight on',
      everyday: true,
      platforms: _phone,
      helpGroup: 'System',
      helpPhrases: ['flashlight off']),
  Capability(AgentActions.airplaneModeSet, 'Airplane mode'),
  Capability(AgentActions.wifiToggle, 'Wi-Fi',
      platforms: _phone,
      helpGroup: 'System',
      helpPhrases: ['wifi on']),
  Capability(AgentActions.bluetoothToggle, 'Bluetooth',
      platforms: _phone,
      helpGroup: 'System',
      helpPhrases: ['bluetooth off']),
  Capability(AgentActions.lockScreen, 'Lock',
      platforms: _phone,
      helpGroup: 'System',
      helpPhrases: ['lock screen']),
  Capability(AgentActions.deviceRestart, 'Restart'),

  // --- Communication ---------------------------------------------------
  Capability(AgentActions.callPlace, 'Calls',
      example: 'call mom',
      everyday: true,
      platforms: _phone,
      helpGroup: 'Communication',
      helpNote: 'open dialer'),
  Capability(AgentActions.messageSend, 'Texts',
      example: 'text mom saying hi',
      everyday: true,
      platforms: _phone,
      helpGroup: 'Communication',
      helpPhrases: ['text dad saying hello'],
      helpNote: 'send SMS'),
  Capability(AgentActions.emailSend, 'Email',
      example: 'email mom saying hi',
      suggestExample: 'email mom',
      everyday: true,
      platforms: _anyDevice,
      helpGroup: 'Email',
      helpPhrases: ['email mom saying hello'],
      helpNote: 'opens your mail app'),

  // --- Media -----------------------------------------------------------
  Capability(AgentActions.mediaPlay, 'Music',
      example: 'play music',
      suggestExample: 'play my playlist',
      everyday: true,
      platforms: _anyDevice,
      helpGroup: 'Media',
      helpPhrases: ['play']),
  Capability(AgentActions.mediaPause, 'Pause',
      platforms: _anyDevice, helpGroup: 'Media', helpPhrases: ['pause']),
  Capability(AgentActions.mediaNext, 'Next track',
      platforms: _anyDevice, helpGroup: 'Media', helpPhrases: ['next']),
  Capability(AgentActions.mediaPrev, 'Previous track',
      platforms: _anyDevice, helpGroup: 'Media', helpPhrases: ['previous']),
  Capability(AgentActions.mediaShuffle, 'Shuffle',
      platforms: _phone, helpGroup: 'Media', helpPhrases: ['shuffle']),
  Capability(AgentActions.mediaRepeat, 'Repeat',
      platforms: _phone, helpGroup: 'Media', helpPhrases: ['repeat']),

  // --- Productivity ----------------------------------------------------
  Capability(AgentActions.alarmSet, 'Alarms',
      example: 'set an alarm for 7am',
      everyday: true,
      platforms: _phone,
      helpGroup: 'Productivity',
      helpPhrases: ['alarm for 7am']),
  Capability(AgentActions.alarmDismiss, 'Dismiss alarm', platforms: _phone),
  Capability(AgentActions.timerStatus, 'Timer status', platforms: _anyDevice),
  Capability(AgentActions.timerCancel, 'Cancel timer', platforms: _anyDevice),
  Capability(AgentActions.reminderSet, 'Reminders',
      example: 'remind me to buy milk',
      everyday: true,
      platforms: _phone,
      helpGroup: 'Productivity'),
  Capability(AgentActions.weatherGet, 'Weather',
      example: 'what is the weather',
      suggestExample: 'what is the weather in paris',
      everyday: true,
      platforms: _anyDevice,
      helpGroup: 'Weather & Getting Around',
      helpPhrases: ['what is the weather in paris'],
      helpNote: 'live forecast, no city needed'),
  Capability(AgentActions.navOpen, 'Navigate',
      example: 'take me home',
      platforms: _anyDevice,
      helpGroup: 'Weather & Getting Around',
      helpPhrases: ['navigate to the office'],
      helpNote: 'maps'),
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
      example: 'add milk to my shopping list',
      everyday: true,
      helpGroup: 'Productivity'),
  Capability(AgentActions.shoppingListGet, 'Shopping list read'),
  Capability(AgentActions.darkModeSet, 'Dark mode', platforms: _anyDevice),
  Capability(AgentActions.defineWord, 'Definitions',
      helpGroup: 'Productivity', helpPhrases: ['define serendipity']),
  Capability(AgentActions.translateText, 'Translate',
      helpGroup: 'Productivity', helpPhrases: ['translate hello to French']),
  Capability(AgentActions.unitConvert, 'Convert',
      helpGroup: 'Productivity',
      helpPhrases: ['convert 5 miles to km', 'convert 100 usd to eur']),

  // --- Fun -------------------------------------------------------------
  Capability(AgentActions.randomDice, 'Dice',
      helpGroup: 'Fun', helpPhrases: ['roll a dice']),
  Capability(AgentActions.randomCoin, 'Coin flip',
      helpGroup: 'Fun', helpPhrases: ['flip a coin']),
  Capability(AgentActions.randomNumber, 'Random number',
      helpGroup: 'Fun', helpPhrases: ['random 1 to 100']),
  Capability(AgentActions.tellJoke, 'Jokes',
      helpGroup: 'Fun', helpPhrases: ['tell me a joke']),

  // --- Memory ----------------------------------------------------------
  Capability(AgentActions.memoryRemember, 'Remember',
      helpGroup: 'Memory',
      helpPhrases: [
        'remember that my bike code is 4321',
        'remember that mom is 0612345678',
      ],
      helpNote: 'calls and texts to that name use the number'),
  Capability(AgentActions.memoryRecall, 'Recall',
      example: 'what do you know about me',
      suggestExample: 'what do you know about me',
      helpGroup: 'Memory'),
  Capability(AgentActions.memoryForget, 'Forget',
      helpGroup: 'Memory', helpPhrases: ['forget my bike code']),
  Capability(AgentActions.memoryQuestion, 'What it knows',
      example: 'who is mom',
      helpGroup: 'Memory',
      helpPhrases: ['what is my wifi password'],
      helpNote: 'I answer from memory'),

  // --- Finding devices -------------------------------------------------
  Capability(AgentActions.findDevice, 'Find device'),
  Capability(AgentActions.ringDevice, 'Ring device'),
];

/// The phrasings Nexus offers for [capability]: its verified example first,
/// then the extra ones. The help answer offers exactly these and nothing else,
/// so what it advertises cannot drift from what Nexus understands.
List<String> phrasesOf(Capability capability) => [
  if (capability.example != null) capability.example!,
  ...capability.helpPhrases,
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

/// The capabilities the help answer offers in [group], in registry order:
/// every one that names this section *and* has a phrase to offer.
List<Capability> helpCapabilitiesIn(String group) => [
  for (final capability in kCapabilities)
    if (capability.helpGroup == group && phrasesOf(capability).isNotEmpty)
      capability,
];

/// Every capability the help answer offers, across all sections. Derived, so
/// "what the registry advertises" has one definition.
List<Capability> get helpCapabilities => [
  for (final group in kHelpGroups) ...helpCapabilitiesIn(group),
];

/// The capabilities a device of [platform] advertises by default — a phone
/// can make calls and send texts, a desktop usually cannot. Devices that
/// announce richer capabilities later simply replace this default; the ids
/// are the same [AgentActions] strings so one check serves both.
///
/// Any platform that is not Android is treated as a desktop, which is how
/// this behaved when the two lists were hand-written.
List<DeviceCapability> defaultCapabilitiesFor(String platform) {
  // 'linux' stands in for every desktop: each desktop capability above
  // declares the whole desktop set, so any member of it answers for all.
  final here = platform == 'android' ? 'android' : 'linux';
  return [
    for (final capability in kCapabilities)
      if (capability.platforms.contains(here)) DeviceCapability(capability.id),
  ];
}
