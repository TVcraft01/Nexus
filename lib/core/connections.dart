// What Nexus is allowed to touch, and the one switch that takes it back.
//
// The app has always been honest about *what* it can do (the gap sentences in
// [device_actions.dart]) and about *why* it did something (the bubble beside an
// action). This file is the missing third fact: **whether it is still allowed
// to**. A connector is a bundle of the phone's own surfaces — playback keys, the
// torch, the clock — and a permission is one sentence a person can read and say
// no to. Saying no is not a preference: it is a refusal the executor obeys
// ([blockedReason] is consulted before anything runs), so a revoked music player
// cannot be un-revoked by a model writing JSON, by a fast-path phrase, or by a
// paired device.
//
// Two rules keep the catalog from becoming decoration:
//
//   * every action in it is a name the executor really runs. A permission that
//     covers nothing is a promise the screen cannot keep, and a test walks the
//     list to prove each one is reachable from the action vocabulary;
//   * the refusal is a sentence, not a shrug. "Music Player access is off —
//     turn it back on in Settings → Connections." names the connector, the
//     place, and the way back.
//
// Storage is a list of revoked connector ids: the stored state is what the user
// turned *off*, so a new connector added in a later version starts granted
// rather than needing a migration.
library;

import 'package:flutter/foundation.dart'
    show ChangeNotifier, debugPrint, immutable, setEquals, visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

/// One thing a connector may do, in the words the screen shows.
///
/// [actions] are [SystemActionCall] names — the closed vocabulary the executor
/// runs. A permission with none is still listed (the user should see everything
/// a connector is given), but it refuses nothing.
@immutable
class ConnectorPermission {
  const ConnectorPermission(this.label, this.actions);

  /// What is granted, as a phrase a person reads: "Play and pause media".
  final String label;

  /// The action names this permission covers.
  final List<String> actions;
}

/// One system Nexus talks to, and everything it is allowed to ask of it.
@immutable
class Connector {
  const Connector({
    required this.id,
    required this.name,
    required this.summary,
    required this.permissions,
  });

  /// Stable, stored id (`music_player`). Never the display name: a rename in a
  /// later version must not silently un-revoke a connector.
  final String id;

  /// What the screen calls it: "Music Player".
  final String name;

  /// One line under the name — what this connector is, not what it does.
  final String summary;

  final List<ConnectorPermission> permissions;

  /// Every action name this connector covers.
  Iterable<String> get actions =>
      permissions.expand((ConnectorPermission p) => p.actions);

  /// Whether [action] is one of this connector's.
  bool covers(String action) => actions.contains(action);
}

/// The three systems on this phone, and the sentences that grant them.
///
/// Deliberately small. A connector per installed app would be a settings page
/// nobody finishes reading, and the app's own promise is that it reaches three
/// things: the player, the phone, and the model's eyes.
const List<Connector> kConnectors = <Connector>[
  Connector(
    id: 'music_player',
    name: 'Music Player',
    summary: 'The playback keys, sent to whatever is playing',
    permissions: <ConnectorPermission>[
      ConnectorPermission('Play and pause media', <String>[
        'play_music',
        'pause_music',
      ]),
      ConnectorPermission('Skip tracks', <String>[
        'next_song',
        'previous_song',
      ]),
      ConnectorPermission('Restart the current song', <String>['restart_song']),
    ],
  ),
  Connector(
    id: 'phone_system',
    name: 'Phone System',
    summary: 'The torch, the clock, the radios and the dialer',
    permissions: <ConnectorPermission>[
      ConnectorPermission('Torch and brightness', <String>[
        'set_flashlight',
        'set_brightness',
      ]),
      ConnectorPermission('Set alarms and timers', <String>[
        'set_alarm',
        'cancel_alarms',
        'show_alarms',
        'set_timer',
        'cancel_timers',
      ]),
      ConnectorPermission('Read battery, switch radios', <String>[
        'get_battery_level',
        'set_wifi',
        'set_bluetooth',
      ]),
      ConnectorPermission('Volume', <String>['set_volume']),
      ConnectorPermission('Calls, texts and email', <String>[
        'call_number',
        'send_sms',
        'send_email',
      ]),
      ConnectorPermission('Open apps and settings', <String>[
        'open_app',
        'navigate_to',
      ]),
    ],
  ),
  Connector(
    id: 'ai_model',
    name: 'AI Model',
    summary: 'What the on-device model is shown of your phone',
    permissions: <ConnectorPermission>[
      // A screenshot is taken so a model can look at it. It lives here rather
      // than with the phone because the reason it exists is the reading, not
      // the capture — and revoking this connector is how a user stops Nexus
      // photographing the screen at all.
      ConnectorPermission('Read the screen', <String>['screenshot']),
    ],
  ),
];

/// The connector that owns [action], or null when nothing does.
Connector? connectorForAction(String action) {
  for (final Connector connector in kConnectors) {
    if (connector.covers(action)) return connector;
  }
  return null;
}

/// Where the revocations live. Injectable for the reason every other preference
/// store in the app is: a widget test must not need a plugin.
abstract class ConnectionsStore {
  /// The connectors the user has turned off, or null when nothing was stored.
  Future<List<String>?> readRevoked();

  Future<void> writeRevoked(List<String> ids);
}

/// In-memory store, for tests and for a platform with no preferences.
class MemoryConnectionsStore implements ConnectionsStore {
  MemoryConnectionsStore([this.revoked]);

  List<String>? revoked;

  @override
  Future<List<String>?> readRevoked() async => revoked;

  @override
  Future<void> writeRevoked(List<String> ids) async => revoked = ids;
}

/// SharedPreferences behind [Connections].
class PrefsConnectionsStore implements ConnectionsStore {
  /// One key, one list. Named here because the tests read it back.
  static const String key = 'connections_revoked';

  SharedPreferences? _prefs;

  Future<SharedPreferences?> _instance() async {
    try {
      return _prefs ??= await SharedPreferences.getInstance();
    } catch (error) {
      debugPrint('CONNECTIONS: no preferences store ($error)');
      return null;
    }
  }

  @override
  Future<List<String>?> readRevoked() async =>
      (await _instance())?.getStringList(key);

  @override
  Future<void> writeRevoked(List<String> ids) async {
    await (await _instance())?.setStringList(key, ids);
  }
}

/// Which connectors are on, and the refusal that follows from the ones that
/// are not.
class Connections extends ChangeNotifier {
  Connections({
    ConnectionsStore? store,
    Iterable<String> revoked = const <String>[],
  }) : _store = store ?? PrefsConnectionsStore(),
       _revoked = <String>{...revoked};

  /// Test seam, in the shape the rest of the app uses.
  @visibleForTesting
  static Connections Function()? override;

  static Connections? _instance;

  static Connections get instance =>
      override?.call() ?? (_instance ??= Connections());

  @visibleForTesting
  static void debugReset() => _instance = null;

  final ConnectionsStore _store;
  final Set<String> _revoked;
  Future<void>? _loading;

  /// The catalog, in the order the screen lists it.
  List<Connector> get connectors => kConnectors;

  /// The ids the user has turned off.
  Set<String> get revoked => Set<String>.unmodifiable(_revoked);

  /// Whether [id] is turned off.
  bool isRevoked(String id) => _revoked.contains(id);

  /// Whether [id] may act. An id the catalog does not know is not a connector
  /// the user could have revoked, so it answers true rather than silently
  /// refusing an action nobody granted.
  bool isEnabled(String id) => !_revoked.contains(id);

  /// Reads the stored revocations once. Idempotent, like every attach() here.
  Future<void> attach() => _loading ??= _load();

  Future<void> _load() async {
    final List<String>? stored = await _store.readRevoked();
    if (stored == null) return;
    final Set<String> ids = stored.toSet();
    if (setEquals(ids, _revoked)) return;
    _revoked
      ..clear()
      ..addAll(ids);
    notifyListeners();
  }

  /// Turns a connector off. The notification comes first: the switch is
  /// waiting on it, and the write must not decide whether the screen moves.
  Future<void> revoke(String id) => setEnabled(id, false);

  /// Turns it back on.
  Future<void> restore(String id) => setEnabled(id, true);

  /// The one setter both of the above go through.
  Future<void> setEnabled(String id, bool enabled) async {
    final bool changed = enabled ? _revoked.remove(id) : _revoked.add(id);
    if (!changed) return;
    debugPrint('CONNECTIONS: $id ${enabled ? 'restored' : 'revoked'}');
    notifyListeners();
    await _store.writeRevoked(_revoked.toList());
  }

  /// Why [action] may not run, or null when it may.
  ///
  /// The sentence names the connector the user turned off and the place it can
  /// be turned back on. It never blames the model, the phone or a permission —
  /// those are different refusals with different ways out.
  String? blockedReason(String action) {
    final Connector? connector = connectorForAction(action);
    if (connector == null || !_revoked.contains(connector.id)) return null;
    return '${connector.name} access is off — turn it back on in '
        'Settings → Connections.';
  }
}
