// The devices this one has paired with, and the one place that list is kept.
//
// The shell has shown a mock device list since it existed: three rows, two
// dots, and a "Pair a device" row that said pairing was not wired up. This is
// the store that row was always missing — a small, honest list with three
// operations (add, forget, read back after a restart) and a seam, because the
// mesh service owns the real one and this front end must not pretend to be it.
//
// Everything here is deliberately local: the list is a *record* of pairings
// that happened, not a connection to anything. Whether a device is reachable is
// the mesh's question and the answer changes every few seconds; what the row
// shows is what was true when the pairing was made (a device you just scanned
// is in the room) plus nothing invented after that.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart'
    show ChangeNotifier, debugPrint, visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

import 'pair_invite.dart';

/// One device in the paired list.
class PairedDevice {
  const PairedDevice({
    required this.id,
    required this.name,
    required this.publicKey,
    this.detail = '',
    this.online = false,
    this.isThisDevice = false,
  });

  /// The mesh id from the pairing code — the key the list is unique on, so the
  /// same device scanned twice is one row rather than two.
  final String id;

  /// What the row says, and what the success notice says.
  final String name;

  /// The key from the pairing code. Kept because a pairing is only as useful as
  /// the key it produced, and because a row that silently dropped it would make
  /// the stored list a different thing from the list in memory.
  final String publicKey;

  /// The second line of the row, when the device came with one: what kind of
  /// machine it is, or when it was paired. Empty means the row says the one
  /// thing that is always true of a paired device instead.
  final String detail;

  /// Whether the device was reachable when this row was written. See the note
  /// at the top of this file: nothing here pretends to know it live.
  final bool online;

  /// True for the row that is this phone itself. It is in the list because the
  /// list is "your devices", not "other devices" — and it can never be
  /// forgotten, because a device cannot unpair from itself.
  final bool isThisDevice;

  PairedDevice copyWith({
    String? name,
    bool? online,
    String? publicKey,
    String? detail,
  }) => PairedDevice(
    id: id,
    name: name ?? this.name,
    publicKey: publicKey ?? this.publicKey,
    detail: detail ?? this.detail,
    online: online ?? this.online,
    isThisDevice: isThisDevice,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'public_key': publicKey,
    'detail': detail,
    'online': online,
    'is_this_device': isThisDevice,
  };

  /// Reads one row back, or null when it is not a row any more — a value
  /// written by another build, or a line that lost a field. Dropping a broken
  /// row is the honest repair: the alternative is a device called `null` that
  /// can never be forgotten.
  static PairedDevice? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['id'];
    final Object? name = raw['name'];
    if (id is! String || name is! String || id.isEmpty || name.isEmpty) {
      return null;
    }
    return PairedDevice(
      id: id,
      name: name,
      publicKey: raw['public_key'] is String ? raw['public_key'] as String : '',
      detail: raw['detail'] is String ? raw['detail'] as String : '',
      online: raw['online'] == true,
      isThisDevice: raw['is_this_device'] == true,
    );
  }

  /// The device a scanned invite describes. It is online when it is written:
  /// somebody is holding it a few centimetres from the camera — which is also
  /// the only time this app has ever *seen* it.
  factory PairedDevice.fromInvite(PairInvite invite) => PairedDevice(
    id: invite.deviceId,
    name: invite.deviceName,
    publicKey: invite.publicKey,
    detail: 'Paired just now',
    online: true,
  );

  @override
  String toString() => 'PairedDevice($name, $id, online: $online)';
}

/// Storage behind the paired list — injectable so tests use an in-memory
/// implementation and production persists across restarts. The same shape as
/// [IconModeStore], including the refusal to fail in an environment without the
/// plugin: reads answer null (the seed list is simply used) and writes no-op.
abstract class PairedDevicesStore {
  Future<List<PairedDevice>?> read();

  Future<void> write(List<PairedDevice> devices);
}

/// In-memory implementation for tests.
class MemoryPairedDevicesStore implements PairedDevicesStore {
  MemoryPairedDevicesStore([List<PairedDevice>? initial])
    : _devices = initial == null ? null : List<PairedDevice>.of(initial);

  List<PairedDevice>? _devices;

  @override
  Future<List<PairedDevice>?> read() async =>
      _devices == null ? null : List<PairedDevice>.of(_devices!);

  @override
  Future<void> write(List<PairedDevice> devices) async {
    _devices = List<PairedDevice>.of(devices);
  }
}

/// SharedPreferences-backed store used in production: one JSON list under one
/// key, which is the whole of what a pairing record needs.
class SharedPrefsPairedDevicesStore implements PairedDevicesStore {
  /// The key the list is stored under.
  static const String key = 'paired_devices';

  SharedPreferences? _prefs;

  Future<SharedPreferences?> _instance() async {
    try {
      return _prefs ??= await SharedPreferences.getInstance();
    } catch (error) {
      // No plugin (a desktop run, a widget test): the list lives for the
      // session, and nothing about the screen breaks.
      debugPrint('PAIR: no preferences store ($error)');
      return null;
    }
  }

  @override
  Future<List<PairedDevice>?> read() async {
    final String? raw = (await _instance())?.getString(key);
    if (raw == null) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return null;
    }
    if (decoded is! List) return null;
    final devices = <PairedDevice>[];
    for (final Object? row in decoded) {
      final PairedDevice? device = PairedDevice.fromJson(row);
      if (device != null) devices.add(device);
    }
    return devices;
  }

  @override
  Future<void> write(List<PairedDevice> devices) async {
    final SharedPreferences? prefs = await _instance();
    if (prefs == null) return;
    await prefs.setString(
      key,
      jsonEncode(devices.map((PairedDevice d) => d.toJson()).toList()),
    );
  }
}

/// The shell's paired list, as one object the Devices tab listens to.
class PairedDevices extends ChangeNotifier {
  PairedDevices({
    PairedDevicesStore? store,
    List<PairedDevice>? seed,
  }) : _store = store ?? SharedPrefsPairedDevicesStore(),
       _devices = List<PairedDevice>.of(seed ?? kSeedPairedDevices);

  /// Test seam, in the same shape as [SpeechInput.override]: a widget test
  /// states what is paired instead of touching the preferences plugin. The app
  /// never sets it.
  @visibleForTesting
  static PairedDevices Function()? override;

  static PairedDevices? _instance;

  /// The app-wide list. Built once: a second instance would be a second answer
  /// to "what is paired", and the row the user just added would be missing from
  /// whichever one the screen happens to be reading.
  static PairedDevices get instance => override?.call() ?? (_instance ??= PairedDevices());

  /// Forgets the app-wide instance. Tests use it; the app never does.
  @visibleForTesting
  static void debugReset() => _instance = null;

  final PairedDevicesStore _store;
  List<PairedDevice> _devices;
  bool _attached = false;

  /// The list, in the order rows are drawn: this device first, then the peers
  /// in the order they were paired.
  List<PairedDevice> get devices => List<PairedDevice>.unmodifiable(_devices);

  /// True while a device with [id] is paired.
  bool contains(String id) => _devices.any((PairedDevice d) => d.id == id);

  /// Reads the stored list, once. Called when the Devices tab comes up; safe to
  /// call again, and safe to call when there is no store at all (the seed list
  /// stays).
  Future<void> attach() async {
    if (_attached) return;
    _attached = true;
    final List<PairedDevice>? stored = await _store.read();
    if (stored == null) return;
    // A stored list that lost this device (an older build, a wiped row) gets it
    // back: the row is not a pairing, it is the list saying who is reading it.
    final PairedDevice? local = _thisDevice;
    if (local != null && !stored.any((PairedDevice d) => d.isThisDevice)) {
      stored.insert(0, local);
    }
    _devices = stored;
    notifyListeners();
  }

  /// Adds a scanned invite. Answers false when that device is already paired,
  /// which is the one case the screen has to say something different about.
  bool add(PairInvite invite) {
    if (contains(invite.deviceId)) return false;
    _devices = <PairedDevice>[
      ..._devices,
      PairedDevice.fromInvite(invite),
    ];
    notifyListeners();
    _persist();
    return true;
  }

  /// Removes a device from the list. Forgetting this device itself is refused,
  /// and answers false: a device cannot unpair from itself, and a row that
  /// disappeared would come back on the next start anyway.
  bool forget(String id) {
    final List<PairedDevice> next = _devices
        .where((PairedDevice d) => d.id != id || d.isThisDevice)
        .toList();
    if (next.length == _devices.length) return false;
    _devices = next;
    notifyListeners();
    _persist();
    return true;
  }

  PairedDevice? get _thisDevice {
    for (final PairedDevice device in _devices) {
      if (device.isThisDevice) return device;
    }
    return null;
  }

  /// Writes the list back. Deliberately not awaited by callers: the screen has
  /// already changed, and a preference write that is slow is not a reason to
  /// hold the frame the user is looking at.
  void _persist() {
    final List<PairedDevice> snapshot = List<PairedDevice>.of(_devices);
    _store.write(snapshot).catchError((Object error) {
      debugPrint('PAIR: could not store the paired list ($error)');
    });
  }
}

/// What the shell shows before anything has ever been paired: this device, and
/// the two example peers the Devices tab has always drawn.
///
/// They are examples and they are seeded rather than faked per build, so the
/// screen is never empty on a fresh install — and so the first pair the user
/// makes is *added* to something rather than creating the list. A real mesh
/// replaces this seed with the devices it knows about; [`PairedDevices.attach`]
/// is where that would happen.
const List<PairedDevice> kSeedPairedDevices = <PairedDevice>[
  PairedDevice(
    id: 'this-device',
    name: 'This Phone',
    publicKey: '',
    detail: 'This device · Android',
    online: true,
    isThisDevice: true,
  ),
  PairedDevice(
    id: 'example-pc',
    name: 'My PC',
    publicKey: '',
    detail: 'Desktop · this room',
    online: true,
  ),
  PairedDevice(
    id: 'example-mac',
    name: 'Studio Mac',
    publicKey: '',
    detail: 'Laptop · last seen Oct 9',
  ),
];
