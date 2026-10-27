// Who else is running Nexus on this network, as the front end can see it.
//
// This is the mesh's own discovery — the same `DiscoveryService` the real app
// runs, not a second protocol: every device joins the Nexus multicast group on
// port 51822, announces itself every few seconds with its id, name, platform
// and TCP port, and replies by unicast to whoever it hears. Unicast replies are
// what make it work on home Wi-Fi, where routers routinely drop multicast.
//
// It is deliberately *only* discovery. Hearing a device makes it visible; it is
// not proof it is reachable, and it is not a pairing. That distinction is the
// mesh's own (`DiscoveryService`'s header says the same thing), and it is the
// reason this object can exist in a build that has no mesh sockets: it opens one
// UDP socket, listens, and says what it heard.
//
// A device that stops announcing ages out after [nearbyWindow], so a row that
// says "Seen at 192.168.1.9" stops saying it when it stops being true.
import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart'
    show
        ChangeNotifier,
        TargetPlatform,
        defaultTargetPlatform,
        visibleForTesting;

import '../core/device_memory.dart' show DeviceMemory;
import '../core/identity.dart' show DeviceInfo;
import '../core/pair_invite.dart' show PairIdentity;
import 'discovery.dart'
    show MeshNearbySource, DiscoveredDevice, DiscoveryService, DiscoveryStatus;

/// How long a device stays on the list after the last time it was heard.
///
/// The mesh's own `nearbyWindow` default is 60 seconds; a screen a person is
/// looking at wants the same answer, so this matches it rather than inventing a
/// second number.
const Duration kNearbyWindow = Duration(seconds: 60);

/// How often the list is re-checked for devices that have gone quiet.
const Duration _sweepInterval = Duration(seconds: 5);

/// The devices heard on this network, live.
///
/// One instance for the app, in the same shape as [PairedDevices]: a second one
/// would be a second socket and a second answer to "who is out there".
class NearbyDevices extends ChangeNotifier {
  NearbyDevices({
    DiscoveryService Function(void Function(DiscoveredDevice) onHeard)?
    discovery,
    this.window = kNearbyWindow,
  }) : _discoveryFactory = discovery ?? _defaultDiscovery;

  /// Test seam, in the same shape as [PairedDevices.override] — a widget test
  /// states what is out there instead of opening a socket. The app never sets
  /// it.
  ///
  /// Named `debugOverride` rather than `override` for one boring reason: this
  /// class overrides [dispose], and a static field called `override` in scope
  /// shadows the `@override` annotation itself. `ChatLog` and `PairedDevices`
  /// can get away with the shorter name because they override nothing.
  @visibleForTesting
  static NearbyDevices Function()? debugOverride;

  static NearbyDevices? _instance;

  /// The app-wide list.
  static NearbyDevices get instance =>
      debugOverride?.call() ?? (_instance ??= NearbyDevices());

  /// Forgets the app-wide instance. Tests use it; the app never does.
  @visibleForTesting
  static void debugReset() => _instance = null;

  final DiscoveryService Function(void Function(DiscoveredDevice) onHeard)
  _discoveryFactory;

  /// How long a device stays on the list after the last time it was heard.
  /// A parameter so a test does not have to wait a minute to watch one age out.
  final Duration window;

  DiscoveryService? _service;
  bool _running = false;
  String? _problem;
  Timer? _sweep;

  /// The mesh whose own discovery this screen is reading, when there is one.
  ///
  /// Null in a build with no mesh, which is when this object opens its own
  /// socket. The launched app always has a mesh, and two [DiscoveryService]s
  /// in one process is one too many: they announce the same device twice and
  /// the second one loses the discovery port to the first.
  MeshNearbySource? _mesh;

  /// True while this list is a view of the mesh's discovery rather than a
  /// socket of its own.
  bool get boundToMesh => _mesh != null;

  /// Reads the mesh's discovery from now on instead of opening a socket.
  ///
  /// Safe to call before or after [start], and idempotent for the same mesh.
  /// The list keeps its [ChangeNotifier] shape, so the Devices tab — which
  /// listens to this object and calls [start] and [stop] with its own life —
  /// needs no change at all.
  void bindTo(MeshNearbySource mesh) {
    if (identical(_mesh, mesh)) return;
    unbind();
    _mesh = mesh;
    mesh.addListener(_pullFromMesh);
    if (_running) _pullFromMesh();
    notifyListeners();
  }

  /// Goes back to owning a socket. Called when the mesh it was reading goes
  /// away, so this object never points at a stopped mesh.
  void unbind() {
    final MeshNearbySource? mesh = _mesh;
    _mesh = null;
    mesh?.removeListener(_pullFromMesh);
  }

  /// One change from the mesh, mirrored into what this screen shows.
  void _pullFromMesh() {
    final MeshNearbySource? mesh = _mesh;
    if (mesh == null || !_running) return;
    _heard
      ..clear()
      ..addEntries(<MapEntry<String, DiscoveredDevice>>[
        for (final DiscoveredDevice device in mesh.nearbyDevices)
          if (!_forgotten.contains(device.id))
            MapEntry<String, DiscoveredDevice>(device.id, device),
      ]);
    notifyListeners();
  }

  /// Everything heard recently, by device id — the latest announcement wins.
  final Map<String, DiscoveredDevice> _heard = <String, DiscoveredDevice>{};

  /// Devices the user has forgotten this session.
  ///
  /// Forget removes the paired row, and the very next announcement would put
  /// the same device back under "Nearby" — which is exactly the "deleted device
  /// is still showing up" report. A forgotten id stays out of discovery until
  /// the user pairs it again ([remember]); forgetting is about the list the user
  /// is reading, not about refusing to ever hear the device.
  final Set<String> _forgotten = <String>{};

  /// Drops [id] from everything this screen knows, and stops re-adding it from
  /// announcements. Called by Forget, after the paired row is gone.
  void forget(String id) {
    _forgotten.add(id);
    _heard.remove(id);
    notifyListeners();
  }

  /// Lets [id] back into discovery — what pairing it again means.
  void remember(String id) {
    if (_forgotten.remove(id)) notifyListeners();
  }

  /// True while the socket is open and announces are going out.
  bool get running => _running;

  /// What has been heard, most recently seen first.
  List<DiscoveredDevice> get devices {
    final List<DiscoveredDevice> out = _heard.values.toList();
    out.sort(
      (DiscoveredDevice a, DiscoveredDevice b) =>
          b.lastSeen.compareTo(a.lastSeen),
    );
    return out;
  }

  /// True when this device is being heard on the network right now — what makes
  /// a paired row say Online instead of what it said when it was paired.
  bool hasHeard(String id) => _heard.containsKey(id);

  /// What discovery is actually doing, in one sentence a user can act on. The
  /// empty case is the service's own honest summary rather than a cheerful
  /// "looking…" that never ends.
  String get status {
    if (!_running) return 'Not looking for devices.';
    if (_problem != null) return _problem!;
    if (_mesh != null) {
      final int count = _heard.length;
      if (count == 0) {
        return 'Listening with the mesh; no other Nexus device has been heard '
            'yet.';
      }
      return 'Heard $count Nexus ${count == 1 ? 'device' : 'devices'} on this '
          'network.';
    }
    if (_heard.isEmpty) {
      return _service?.status.describe() ??
          'Discovery is listening; no other Nexus device has been heard yet.';
    }
    final int count = _heard.length;
    return 'Heard $count Nexus ${count == 1 ? 'device' : 'devices'} on this '
        'network.';
  }

  /// The last thing heard from [id], if it is still recent.
  DiscoveredDevice? device(String id) => _heard[id];

  /// The service's own counters, for a screen or a log that wants the details.
  DiscoveryStatus? get discoveryStatus => _service?.status;

  /// Opens the socket and starts announcing — or, when bound to a mesh, starts
  /// reading the discovery the mesh already runs. Safe to call twice.
  Future<void> start() async {
    if (_running) return;
    _running = true;
    _problem = null;
    if (_mesh != null) {
      _pullFromMesh();
      notifyListeners();
      return;
    }
    // The RAM this device shares with the room. Read once per start rather
    // than per announcement, and allowed to fail: a device that will not say
    // simply does not advertise a number, which is better than advertising a
    // zero the other side would add up.
    try {
      DiscoveryService.ramBytes = await DeviceMemory.totalBytes();
    } catch (_) {
      DiscoveryService.ramBytes = null;
    }
    _service = _discoveryFactory(_note);
    _sweep = Timer.periodic(_sweepInterval, (_) => _dropQuietDevices());
    try {
      await _service!.start();
    } catch (error) {
      // A socket that cannot be opened is a sentence, not a crash: this screen
      // is the only place the user would ever see it.
      _problem =
          'Discovery could not open a network socket — check this device\'s '
          'Wi-Fi. ($error)';
    }
    notifyListeners();
  }

  /// Closes the socket. Called when the Devices tab goes away: announcing from
  /// a screen nobody is looking at is a battery cost with no reader.
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _sweep?.cancel();
    _sweep = null;
    if (_mesh != null) {
      // Nothing of this object's is open: the socket belongs to the mesh, and
      // stopping the mesh is the app's decision, not a tab's.
      notifyListeners();
      return;
    }
    final DiscoveryService? service = _service;
    _service = null;
    notifyListeners();
    try {
      await service?.stop();
    } catch (_) {
      // Closing a best-effort socket is allowed to fail quietly.
    }
  }

  /// One announcement, or one unicast reply, from [device].
  void _note(DiscoveredDevice device) {
    if (_forgotten.contains(device.id)) return;
    _heard[device.id] = device.withSeen(DateTime.now());
    notifyListeners();
  }

  /// Runs the sweep the timer runs, now. For a test that cannot wait a minute
  /// to watch a device age out. The app never calls it.
  @visibleForTesting
  void debugSweep() => _dropQuietDevices();

  /// Drops devices that have gone quiet for longer than the window.
  void _dropQuietDevices() {
    final DateTime cutoff = DateTime.now().subtract(window);
    final List<String> gone = <String>[
      for (final MapEntry<String, DiscoveredDevice> entry in _heard.entries)
        if (entry.value.lastSeen.isBefore(cutoff)) entry.key,
    ];
    if (gone.isEmpty) return;
    gone.forEach(_heard.remove);
    notifyListeners();
  }

  /// Forgets every heard device, keeping the socket open. For a test; the app
  /// lets them age out.
  @visibleForTesting
  void debugClear() {
    _heard.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _sweep?.cancel();
    _sweep = null;
    unbind();
    unawaited(stop());
    super.dispose();
  }
}

/// The real discovery, announcing under this device's own pairing identity.
///
/// The id and name are the ones the QR carries ([PairIdentity]), which is what
/// lets a device that scanned this code recognise this device when it hears it
/// on the network — one identity for the code and the announcements, rather
/// than two names for one phone.
///
/// The TCP port announced is the mesh's default (51820), which on the launched
/// path is now the mesh itself. The launched app does not call this at all — it
/// reads the mesh's discovery through [NearbyDevices.bindTo] — so this stays
/// for the build that has no mesh to read.
DiscoveryService _defaultDiscovery(void Function(DiscoveredDevice) onHeard) {
  final PairIdentity who = PairIdentity.current;
  return DiscoveryService(
    identity: DeviceInfo(id: who.id, name: who.name, platform: _platformToken),
    onDiscovered: onHeard,
    // Android permits UDP broadcasts and Linux refuses them without a socket
    // option dart:io does not expose, so this is the platform's fact.
    canBroadcast: Platform.isAndroid,
  );
}

/// The platform token the announce payload carries, spelled the way
/// `defaultDeviceName` and the mesh already spell it.
String get _platformToken => switch (defaultTargetPlatform) {
  TargetPlatform.android => 'android',
  TargetPlatform.iOS => 'ios',
  TargetPlatform.macOS => 'macos',
  TargetPlatform.windows => 'windows',
  TargetPlatform.linux => 'linux',
  _ => 'other',
};
