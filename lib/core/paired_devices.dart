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
    this.addresses = const <String>[],
    this.port = 0,
    this.code = '',
    this.ramBytes,
    this.platform = '',
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

  /// The row's second line when discovery has just heard this device: its
  /// address, which is the one fact about it that is true right now.
  String get reachableDetail => addresses.isEmpty
      ? detail
      : 'Seen at ${addresses.first}${port > 0 ? ':$port' : ''}';

  /// Whether the device was reachable when this row was written. See the note
  /// at the top of this file: nothing here pretends to know it live.
  final bool online;

  /// True for the row that is this phone itself. It is in the list because the
  /// list is "your devices", not "other devices" — and it can never be
  /// forgotten, because a device cannot unpair from itself.
  final bool isThisDevice;

  /// Where the device said it lives, from the code it was paired with, best
  /// first. What discovery is compared against, and what a transfer would dial.
  final List<String> addresses;

  /// The mesh port from the code, 0 when the code did not carry one.
  final int port;

  /// The one-time code from a `nexus://pair` payload, empty for the shell's own
  /// invites. Kept, not used yet: it is the half of a pairing the mesh needs,
  /// and re-asking the user to scan a code they already scanned is not a repair
  /// anybody should have to make.
  final String code;

  /// The RAM the device shared when it paired, in bytes, or null when it did
  /// not say. This is what the Devices screen adds up into "Mesh Total RAM"
  /// and what decides whether the PC is strong enough for the 3B model.
  final int? ramBytes;

  /// The platform token the device named in its pairing code — `linux`,
  /// `android`, `macos`. Empty for an older code or a nearby row that only
  /// carried a discovery announcement; the card then says "Device" rather than
  /// inventing a machine.
  final String platform;

  PairedDevice copyWith({
    String? name,
    bool? online,
    String? publicKey,
    String? detail,
    List<String>? addresses,
    int? port,
    String? code,
    int? ramBytes,
    String? platform,
  }) => PairedDevice(
    id: id,
    name: name ?? this.name,
    publicKey: publicKey ?? this.publicKey,
    detail: detail ?? this.detail,
    online: online ?? this.online,
    isThisDevice: isThisDevice,
    addresses: addresses ?? this.addresses,
    port: port ?? this.port,
    code: code ?? this.code,
    ramBytes: ramBytes ?? this.ramBytes,
    platform: platform ?? this.platform,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'public_key': publicKey,
    'detail': detail,
    'online': online,
    'is_this_device': isThisDevice,
    if (addresses.isNotEmpty) 'addresses': addresses,
    if (port > 0) 'port': port,
    if (code.isNotEmpty) 'code': code,
    if (ramBytes != null) 'ram_bytes': ramBytes,
    if (platform.isNotEmpty) 'platform': platform,
  };

  /// Reads one address list back, dropping anything that is not a string.
  static List<String> _addressesFrom(Object? raw) {
    if (raw is! List) return const <String>[];
    final List<String> out = <String>[];
    for (final Object? entry in raw) {
      if (entry is String && entry.trim().isNotEmpty) out.add(entry.trim());
    }
    return out;
  }

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
      addresses: _addressesFrom(raw['addresses']),
      port: raw['port'] is int ? raw['port'] as int : 0,
      code: raw['code'] is String ? raw['code'] as String : '',
      ramBytes: raw['ram_bytes'] is int && (raw['ram_bytes'] as int) > 0
          ? raw['ram_bytes'] as int
          : null,
      platform: raw['platform'] is String ? raw['platform'] as String : '',
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
    addresses: invite.addresses,
    port: invite.port,
    code: invite.code,
    ramBytes: invite.ramBytes,
    platform: invite.platform,
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
  PairedDevices({PairedDevicesStore? store, List<PairedDevice>? seed})
    : _store = store ?? SharedPrefsPairedDevicesStore(),
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
  static PairedDevices get instance =>
      override?.call() ?? (_instance ??= PairedDevices());

  /// Forgets the app-wide instance. Tests use it; the app never does.
  @visibleForTesting
  static void debugReset() => _instance = null;

  final PairedDevicesStore _store;
  List<PairedDevice> _devices;
  bool _attached = false;

  /// Counts local changes, so a slow first read cannot undo one.
  ///
  /// [attach] is asynchronous: on a cold start it reads the stored list while
  /// the screen is already interactive. A Forget tapped during that read used to
  /// remove the row and then have the stale read assigned over it — the "deleted
  /// device comes back" bug. A revision taken before the read and compared after
  /// it makes the in-memory list win whenever the user has touched it.
  int _revision = 0;

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
    final int revision = _revision;
    final List<PairedDevice>? stored = await _store.read();
    if (stored == null) return;
    // The user changed the list while the store was being read. What they did
    // is newer than what was on disk, and applying the read would resurrect a
    // row they just forgot.
    if (revision != _revision) return;
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
    _devices = <PairedDevice>[..._devices, PairedDevice.fromInvite(invite)];
    _revision++;
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
    _revision++;
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
    platform: 'android',
  ),
  // The example PC carries a RAM figure because the shell's whole device list
  // is an example: a paired Windows desktop is the case the mesh's RAM total
  // and the "download the 3B model" banner exist for, and a demo build with no
  // number on any row could not show either. A real pairing replaces it with
  // the number the other device actually shared.
  PairedDevice(
    id: 'example-pc',
    name: 'My PC',
    publicKey: '',
    detail: 'Desktop · this room · 16 GB',
    online: true,
    ramBytes: 16 * 1024 * 1024 * 1024,
    platform: 'linux',
  ),
  PairedDevice(
    id: 'example-mac',
    name: 'Studio Mac',
    publicKey: '',
    detail: 'Laptop · last seen Oct 9',
    platform: 'macos',
  ),
];
