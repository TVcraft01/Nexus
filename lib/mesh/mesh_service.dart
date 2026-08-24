import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show ChangeNotifier, TargetPlatform, debugPrint, defaultTargetPlatform;
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, MethodChannel;
import 'package:path_provider/path_provider.dart'
    show getApplicationDocumentsDirectory, getExternalStorageDirectory;

import '../core/crypto.dart';
import '../core/identity.dart';
import '../core/network_info.dart';
import '../core/pair_payload.dart';
import '../core/protocol.dart';
import '../core/serial_transport.dart';
import '../core/store.dart';
import '../core/version.dart';
import 'discovery.dart';
import 'serial_bridge.dart';

/// Local channel to the Android side (see MainActivity): "All files access"
/// state and the real shared-storage root, which the mesh serves to peers.
const _storageChannel = MethodChannel('dev.nexus.nexus/storage');

/// A device that has been paired with us. "Paired" means we share a secret
/// (the pairing code) and can talk to each other encrypted.
class PairedDevice {
  final String id;
  String name;
  final String platform;
  bool localName;

  /// The address that worked most recently (the source address of the last
  /// real connection). Tried first when connecting.
  String address;

  /// Every address this device has announced — LAN, VPN, Tailscale (100.x).
  /// The mesh tries them in order, so a device paired at home still works
  /// from far away via its Tailscale address. Defaults to [address] for
  /// devices paired before this existed.
  List<String> addresses;
  int port;
  final String pairingSecret;
  DateTime? lastVerified;

  PairedDevice({
    required this.id,
    required this.name,
    required this.platform,
    this.localName = false,
    required this.address,
    required this.port,
    required this.pairingSecret,
    List<String>? addresses,
    this.lastVerified,
  }) : addresses = addresses ?? [address];

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'platform': platform,
    'localName': localName,
    'address': address,
    'addresses': addresses,
    'port': port,
    'pairingSecret': pairingSecret,
    'lastVerified': lastVerified?.toIso8601String(),
  };

  factory PairedDevice.fromJson(Map<String, dynamic> json) => PairedDevice(
    id: json['id'] as String,
    name: json['name'] as String,
    platform: json['platform'] as String? ?? 'other',
    localName: json['localName'] == true,
    address: json['address'] as String,
    port: (json['port'] as num).toInt(),
    pairingSecret: json['pairingSecret'] as String,
    addresses: (json['addresses'] as List?)
        ?.whereType<String>()
        .where((a) => a.isNotEmpty)
        .toList(),
    lastVerified: json['lastVerified'] != null
        ? DateTime.tryParse(json['lastVerified'] as String)
        : null,
  );
}

/// Result of an attempted pairing.
class PairResult {
  final bool ok;
  final String? error;
  final String? peerName;
  const PairResult.ok(this.peerName) : ok = true, error = null;
  const PairResult.failure(this.error) : ok = false, peerName = null;
}

/// A pairing session started by "Show my code".
class PairingSession {
  final String code;
  final String qrPayload;
  final DateTime expiresAt;
  const PairingSession({
    required this.code,
    required this.qrPayload,
    required this.expiresAt,
  });
}

/// A clipboard message that arrived from another device — used only for the
/// transient "Copied on …" notification. The device's own clipboard is the
/// single source of truth; nothing is stored.
class ClipEntry {
  final String text;
  final String? fromName;
  const ClipEntry({required this.text, required this.fromName});
}

/// One entry in a remote directory listing.
class FileEntry {
  final String name;
  final String path; // absolute path on the peer device
  final int size; // bytes; 0 for directories
  final bool isDir;
  final DateTime modified;

  const FileEntry({
    required this.name,
    required this.path,
    required this.size,
    required this.isDir,
    required this.modified,
  });
}

/// State of one in-flight file download on the requesting side.
class _FilePull {
  final String savePath;
  final String peerName;
  final void Function(int received, int total)? onProgress;
  final Completer<File?> done = Completer<File?>();
  RandomAccessFile? sink;
  int received = 0;
  int total = 0;
  Timer? watchdog;

  /// Chunks arrive as separately-dispatched frames and can overlap; all disk
  /// writes go through this chain so a second write never starts mid-write.
  Future<void> chain = Future.value();

  _FilePull({required this.savePath, required this.peerName, this.onProgress});
}

/// State of one in-flight file transfer arriving on this device. Mirrors
/// [_FilePull] on the receiving side: chunks overlap, so all writes go
/// through [chain]; on the final chunk the file is closed and an ack is sent
/// back so the sender knows it landed.
class _FilePush {
  final String name; // sanitized basename, safe to write under [dir]
  final String dir; // the "Nexus Incoming" folder under the served root
  final String peerName;
  final bool overwrite;
  RandomAccessFile? sink;
  String savedPath = '';
  int received = 0;
  int total = 0;
  Timer? watchdog;
  Future<void> chain = Future.value();

  _FilePush({
    required this.name,
    required this.dir,
    required this.peerName,
    this.overwrite = false,
  });
}

/// Small abstraction over the platform clipboard so the mesh logic can be
/// unit-tested without a device.
abstract class ClipboardBackend {
  Future<String?> readText();
  Future<void> writeText(String text);
}

class _RealClipboard implements ClipboardBackend {
  @override
  Future<String?> readText() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim();
      return (text == null || text.isEmpty) ? null : text;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> writeText(String text) =>
      Clipboard.setData(ClipboardData(text: text));
}

/// The mesh: one service per device that owns the TCP server, discovery,
/// presence, pairing, and encrypted messaging.
///
/// Honest-presence rule: a device is "online" only when we have received a
/// direct, verified message from it over TCP within the last 25 seconds.
/// Discovery announcements are never enough — they only make a device
/// *visible*, and the UI says so.
class MeshService extends ChangeNotifier {
  final DeviceInfo identity;
  final NexusStore store;
  final ClipboardBackend clipboard;

  MeshService({
    required this.identity,
    required this.store,
    ClipboardBackend? clipboard,
    this.onlineWindow = const Duration(seconds: 25),
    this.visibleWindow = const Duration(seconds: 12),
    this.heartbeatInterval = const Duration(seconds: 8),
    this.nearbyWindow = const Duration(seconds: 60),
    this.connectTimeout = const Duration(seconds: 3),
    this.fileRoot,
  }) : clipboard = clipboard ?? _RealClipboard();

  /// How long to wait per address before falling back to the next one.
  /// Configurable so tests can exercise address fallback quickly.
  final Duration connectTimeout;

  /// The folder this device serves to paired devices (the "Files" tab browses
  /// it). Defaults to the home directory on desktop; tests pass a temp dir.
  final String? fileRoot;

  /// How old a verified contact may be before a device is shown offline.
  /// Configurable so tests can use short windows instead of waiting 25s.
  final Duration onlineWindow;
  final Duration visibleWindow;
  final Duration heartbeatInterval;

  /// How old a discovery announcement may be before the device disappears
  /// from the Nearby list. Discovery announces every few seconds, so a
  /// device that stopped announcing drops out within this window instead of
  /// lingering as a ghost forever.
  final Duration nearbyWindow;

  final Map<String, PairedDevice> _paired = {};
  final Map<String, DiscoveredDevice> _nearby = {};
  final Map<String, DateTime> _verified = {}; // TCP-verified, by device id
  final Map<String, DateTime> _lastSeen = {}; // any hello/ping, by device id

  final Map<String, Socket> _outbound = {}; // peerId -> send socket
  final Map<Socket, String> _inboundPeer = {}; // socket -> peerId
  final Map<String, Uint8List> _sessionKeys = {}; // peerId -> cached key
  final Set<String> _recentMessageIds = {}; // dedupe across multi-hop relays

  ClipEntry? lastIncomingClip;

  /// Why the last file request failed ("could not reach", "access denied",
  /// timeouts). Read by the Files UI to show an honest error.
  String? lastFileError;

  final Map<String, Completer<List<FileEntry>?>> _pendingLists =
      {}; // req -> list
  final Map<String, _FilePull> _pendingPulls = {}; // req -> download state
  final Map<String, _FilePush> _incomingPushes = {}; // req -> upload state
  Future<void> _filePushChain = Future.value();
  final Map<String, Completer<String?>> _outgoingPushes =
      {}; // req -> saved path on peer
  final Map<String, Completer<Uint8List?>> _pendingRanges =
      {}; // req -> byte range read
  final Map<String, Completer<bool>> _pendingDeletes = {}; // req -> deleted ok?
  final Map<String, Completer<String?>> _pendingOperations =
      {}; // req -> result path

  List<String>? _ipsCache;
  DateTime? _ipsCacheAt;

  String? pendingCode;
  DateTime? pendingCodeExpiry;
  String? lastNotice; // honest operational notices ("port was busy, using X")

  ServerSocket? _server;
  DiscoveryService? _discovery;
  Timer? _heartbeatTimer;
  Timer? _clipboardTimer;
  bool _heartbeatRunning = false;
  bool _clipboardSending = false;
  String? _lastClipboard;
  String? _pendingClipboard;
  final Set<String> _clipboardDeliveredTo = {};
  final Map<String, Completer<bool>> _pendingClipboardAcks = {};

  /// Text held during the post-copy delay. When the timer fires, if the
  /// local clipboard still matches this text the user hasn't pasted locally
  /// and we sync it; otherwise we cancel.
  String? _clipboardHoldText;
  Timer? _clipboardDelayTimer;

  String? _latestPeerUpdateVersion;
  bool _started = false;

  /// Devices plugged into this machine over a USB cable (ESP32, …). Created
  /// lazily the first time the cable-pairing flow asks for it, so a plain
  /// mesh session never scans serial ports.
  SerialBridge? _serial;
  SerialBridge? get serial => _serial;

  /// Serial nodes currently visible over the cable (alive within the last
  /// 15 s). These are mesh-visible but only offer what the node advertises.
  List<SerialDevice> get serialDevices => _serial?.devices ?? const [];

  /// Serial nodes that live on *another* paired device's cable, learned from
  /// that device's ping/pong announcements. Other devices can message them
  /// through the host — multi-hop relay.
  final Map<String, String> _serialHosts = {}; // serialId -> host peer id
  final Map<String, String> _serialNames = {}; // serialId -> name
  final Map<String, List<String>> _serialCaps = {}; // serialId -> caps
  final Map<String, String> _serialRequesters = {}; // serialId -> last peer to ask

  /// The last `up` payload relayed from a remote (or local) cable node:
  /// `{from, name, data}`. Read by the UI to show what a node reported.
  Map<String, dynamic>? lastSerialUp;

  List<SerialDevice> get remoteSerialDevices {
    final now = DateTime.now();
    final out = <SerialDevice>[];
    for (final entry in _serialHosts.entries) {
      final host = _paired[entry.value];
      if (host == null) continue; // host forgotten — drop the relay
      out.add(SerialDevice(
        id: entry.key,
        name: _serialNames[entry.key] ?? entry.key,
        port: 'remote:${entry.value}',
        caps: _serialCaps[entry.key] ?? const ['ping', 'msg'],
        lastSeen: now,
      ));
    }
    return out;
  }

  /// The serial node with [id], wherever it lives: on our own cable, or on a
  /// paired device's cable (relay). Null when nowhere.
  SerialDevice? serialDeviceById(String id) {
    final local = _serial?.byId(id);
    if (local != null) return local;
    final hostId = _serialHosts[id];
    if (hostId != null && _paired.containsKey(hostId)) {
      return SerialDevice(
        id: id,
        name: _serialNames[id] ?? id,
        port: 'remote:$hostId',
        caps: _serialCaps[id] ?? const ['ping', 'msg'],
        lastSeen: DateTime.now(),
      );
    }
    return null;
  }

  /// Ensures the serial bridge exists and starts scanning the cable. Uses the
  /// platform-appropriate transport (USB-OTG on Android, /dev/ttyUSB* on
  /// Linux). No-op where neither exists.
  Future<SerialBridge?> ensureSerialBridge() async {
    if (_serial != null) {
      await _serial!.startScan();
      return _serial;
    }
    SerialTransport? transport;
    if (defaultTargetPlatform == TargetPlatform.android) {
      transport = AndroidUsbSerialTransport.defaultInstance();
    } else if (defaultTargetPlatform == TargetPlatform.linux) {
      transport = LinuxSerialTransport();
    }
    if (transport == null) return null;
    final bridge = SerialBridge(
      transport: transport,
      onChanged: notifyListeners,
      // A node on our cable reported something — relay it to whichever peer
      // asked (multi-hop), or note it locally.
      onUp: _relaySerialUp,
    );
    _serial = bridge;
    await bridge.startScan();
    notifyListeners();
    return bridge;
  }

  /// Attaches an existing serial bridge (used by tests with a fake
  /// transport; production goes through [ensureSerialBridge]).
  Future<void> attachSerialBridge(SerialBridge bridge) async {
    _serial = bridge;
    bridge.onUp ??= _relaySerialUp;
    await bridge.startScan();
    notifyListeners();
  }

  /// A node on our cable reported something — relay it to whichever peer
  /// asked (multi-hop), or note it locally.
  void _relaySerialUp(String deviceId, Map<String, dynamic> data) {
    final requester = _serialRequesters[deviceId];
    if (requester != null && _paired.containsKey(requester)) {
      unawaited(_sendEnc(
        _paired[requester]!,
        NexusMessage(
          type: NexusMessage.serialUp,
          from: deviceId,
          to: requester,
          payload: {'data': data, 'name': _serial?.byId(deviceId)?.name ?? deviceId},
          id: _newId(),
          ts: DateTime.now().millisecondsSinceEpoch,
        ),
      ));
    }
    lastSerialUp = {
      'from': deviceId,
      'name': _serial?.byId(deviceId)?.name ?? deviceId,
      'data': data,
    };
    notifyListeners();
  }

  /// Confirms a serial node as paired (persists its state on the node).
  Future<void> pairSerialDevice(String id) async {
    await _serial?.pair(id);
  }

  /// Sends a small command payload to a serial node — over our own cable, or
  /// through whichever paired device hosts it (multi-hop relay).
  Future<bool> sendSerialMessage(String id, Map<String, dynamic> data) async {
    final local = _serial?.byId(id);
    if (local != null) {
      return await _serial!.sendMessage(id, data);
    }
    final hostId = _serialHosts[id];
    final host = hostId == null ? null : _paired[hostId];
    if (host == null) return false;
    _serialRequesters[id] = identity.id;
    return await _sendEnc(
      host,
      NexusMessage(
        type: NexusMessage.serialMsg,
        from: identity.id,
        to: id,
        payload: {'data': data},
        id: _newId(),
        ts: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  /// The serial devices on our cable, as announced to peers in ping/pong.
  List<Map<String, dynamic>> _serialAnnouncement() {
    return (_serial?.devices ?? const [])
        .map((d) => {'id': d.id, 'name': d.name, 'caps': d.caps})
        .toList();
  }

  /// Remembers which serial nodes a peer has on its cable. Anything not
  /// announced anymore is forgotten.
  void _noteSerialHosts(String peerId, Object? raw) {
    final list = raw is List ? raw.whereType<Map>().toList() : const [];
    final seen = <String>{};
    for (final item in list) {
      final id = item['id']?.toString();
      if (id == null || id.isEmpty) continue;
      seen.add(id);
      _serialHosts[id] = peerId;
      _serialNames[id] = item['name']?.toString() ?? id;
      _serialCaps[id] =
          (item['caps'] as List?)?.whereType<String>().toList() ??
          const ['ping', 'msg'];
    }
    final stale = _serialHosts.entries
        .where((e) => e.value == peerId && !seen.contains(e.key))
        .map((e) => e.key)
        .toList();
    for (final id in stale) {
      _serialHosts.remove(id);
      _serialNames.remove(id);
      _serialCaps.remove(id);
    }
  }

  int get port => store.port;

  String? get latestPeerUpdateVersion => _latestPeerUpdateVersion;

  List<PairedDevice> get pairedDevices => _paired.values.toList();

  /// Devices heard from recently. Anything older than [nearbyWindow] is
  /// dropped — a device that stopped announcing is gone, not a ghost.
  List<DiscoveredDevice> get nearbyDevices {
    final cutoff = DateTime.now().subtract(nearbyWindow);
    _nearby.removeWhere((_, d) => d.lastSeen.isBefore(cutoff));
    final list = _nearby.values.toList()
      ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    return list;
  }

  /// When [id] was last heard from over the mesh (TCP or discovery), if ever.
  DateTime? lastSeenAt(String id) => _lastSeen[id];

  bool isPaired(String id) => _paired.containsKey(id);

  bool isOnline(String id) {
    final v = _verified[id];
    return v != null && DateTime.now().difference(v) <= onlineWindow;
  }

  bool isVisible(String id) {
    final s = _lastSeen[id];
    return s != null && DateTime.now().difference(s) <= visibleWindow;
  }

  /// How many paired devices are verified-online right now.
  int get onlineCount => _paired.keys.where(isOnline).length;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    await store.load();
    store.pruneStaleNeighbors(); // ghosts from an earlier session must not come back
    _loadPaired();
    await _bindServer();
    _startDiscovery();
    _heartbeatTimer = Timer.periodic(heartbeatInterval, (_) => _heartbeat());
    _clipboardTimer = Timer.periodic(
      const Duration(milliseconds: 1500),
      (_) => _checkClipboard(),
    );
    unawaited(_heartbeat());
    notifyListeners();
  }

  void _loadPaired() {
    for (final raw in store.pairedDevices) {
      try {
        final device = PairedDevice.fromJson(raw);
        _paired[device.id] = device;
      } catch (_) {}
    }
  }

  /// All of this device's non-loopback IPv4 addresses (LAN + Tailscale +
  /// VPN), cached briefly so heartbeats don't re-scan interfaces every 8s.
  Future<List<String>> _myIps() async {
    final cached = _ipsCache;
    final at = _ipsCacheAt;
    if (cached != null &&
        at != null &&
        DateTime.now().difference(at) < const Duration(minutes: 2)) {
      return cached;
    }
    final ips = await detectAllIpv4s();
    _ipsCache = ips;
    _ipsCacheAt = DateTime.now();
    return ips;
  }

  static const int defaultPort = 51820;

  Future<void> _bindServer() async {
    // Try the canonical port first, then the last-used port, then an
    // ephemeral one. This self-heals the case where an old ephemeral port
    // got persisted while the canonical port was temporarily busy.
    final attempts = <int>[defaultPort, store.port];
    var bound = false;
    for (final port in attempts) {
      if (port <= 0 || port > 65535) continue;
      try {
        _server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
        if (store.port != port) {
          store.port = port;
          await store.save();
        }
        bound = true;
        break;
      } catch (_) {
        // try the next candidate
      }
    }
    if (!bound) {
      // Everything busy (e.g. a second instance on this machine). Bind an
      // ephemeral port and say so — silently "working" while unreachable is
      // exactly what we refuse to do.
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
      store.port = _server!.port;
      await store.save();
      lastNotice =
          'Port $defaultPort was busy — Nexus is using port ${_server!.port}.';
    }
    _server!.listen(_onClientSocket);
    debugPrint('NEXUS mesh: listening on 0.0.0.0:${_server!.port}');
  }

  void _startDiscovery() {
    // Load the addresses we have seen before so we can say hello directly to
    // them, even before multicast delivers anything (flaky home routers).
    final known = <({String address, int port})>[];
    for (final n in store.neighbors) {
      final address = n['address'];
      final port = n['port'];
      if (address is String && port is int && port > 0) {
        known.add((address: address, port: port));
      }
    }
    final discovery = DiscoveryService(
      identity: identity,
      onDiscovered: _onDiscovered,
      canBroadcast: identity.platform == 'android',
    )..tcpPort = store.port;
    discovery.knownAddresses.addAll(known);
    _discovery = discovery;
    unawaited(discovery.start());
  }

  // ---------------------------------------------------------------------
  // Discovery
  // ---------------------------------------------------------------------

  void _onDiscovered(DiscoveredDevice device) {
    final existing = _nearby[device.id];
    if (existing == null ||
        device.port != existing.port ||
        device.name != existing.name) {
      _nearby[device.id] = device;
      notifyListeners();
    } else {
      _nearby[device.id] = device.withSeen(device.lastSeen);
    }
    _lastSeen[device.id] = device.lastSeen;

    // Remember where this device lives so we can greet it directly next time
    // even if the router stops forwarding multicast. Persistence is debounced
    // (hellos arrive in bursts) and flushed on shutdown.
    store.upsertNeighbor(device.id, device.address, device.port, device.name);
    _neighborsDirty = true;
    _neighborSaveTimer ??= Timer(const Duration(seconds: 5), () {
      _neighborSaveTimer = null;
      if (_neighborsDirty) {
        _neighborsDirty = false;
        _queueSave();
      }
    });
    final known = _discovery?.knownAddresses;
    if (known != null &&
        !known.any(
          (k) => k.address == device.address && k.port == device.port,
        )) {
      known.add((address: device.address, port: device.port));
    }
  }

  bool _neighborsDirty = false;
  Timer? _neighborSaveTimer;
  Future<void>? _saveChain;

  /// Serialized persistence: every queued save completes before [stop]
  /// returns, so tests never race a pending write against teardown.
  void _queueSave() {
    _saveChain = (_saveChain ?? Future.value()).then((_) => store.save());
  }

  // ---------------------------------------------------------------------
  // TCP connections
  // ---------------------------------------------------------------------

  void _onClientSocket(Socket socket) {
    final decoder = FrameDecoder();
    socket.listen(
      (chunk) {
        decoder.add(chunk);
        final frames = decoder.takeFrames();
        if (frames == null) return;
        for (final frame in frames) {
          unawaited(_dispatchFrame(socket, frame));
        }
      },
      onError: (_) => _dropSocket(socket),
      onDone: () => _dropSocket(socket),
    );
  }

  Future<void> _dispatchFrame(Socket socket, Uint8List frameBytes) async {
    Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(utf8.decode(frameBytes));
      if (decoded is! Map<String, dynamic>) return;
      json = decoded;
    } catch (_) {
      return;
    }

    final enc = json['enc'];
    if (enc is String) {
      await _handleEncFrame(socket, enc);
    } else {
      NexusMessage msg;
      try {
        msg = NexusMessage.fromJson(json);
      } catch (_) {
        return;
      }
      await _handleMessage(msg, socket, encrypted: false);
    }
  }

  /// Handles an encrypted frame. The sending peer is identified from the
  /// socket when known, otherwise by trying each paired device's key — so a
  /// device that connects to us and speaks encrypted is attributed correctly
  /// even on its very first message. If no paired device matches, the frame
  /// might be a pairing handshake encrypted with our pending code.
  Future<void> _handleEncFrame(Socket socket, String enc) async {
    var peerId = _peerIdForSocket(socket);
    if (peerId == null || !_paired.containsKey(peerId)) {
      peerId = await _identifySender(socket, enc);
      if (peerId == null) {
        await _tryPairingFrame(socket, enc);
        return;
      }
    }
    final peer = _paired[peerId]!;
    final key = await _sessionKeyFor(peer);
    Uint8List clear;
    try {
      clear = await decryptFromB64(enc, key);
    } catch (_) {
      return; // wrong key or tampered — drop, never trust it
    }
    NexusMessage msg;
    try {
      msg = NexusMessage.fromJson(
        jsonDecode(utf8.decode(clear)) as Map<String, dynamic>,
      );
    } catch (_) {
      return;
    }
    await _handleMessage(msg, socket, encrypted: true);
  }

  /// A frame we could not decrypt with any paired device's key might be a
  /// pairing request encrypted with the code we are currently showing. If it
  /// decrypts and is a pair-request, accept it.
  Future<void> _tryPairingFrame(Socket socket, String enc) async {
    if (!pendingCodeActive) return;
    final key = await derivePairingKey(pendingCode!);
    Uint8List clear;
    try {
      clear = await decryptFromB64(enc, key);
    } catch (_) {
      return;
    }
    NexusMessage msg;
    try {
      msg = NexusMessage.fromJson(
        jsonDecode(utf8.decode(clear)) as Map<String, dynamic>,
      );
    } catch (_) {
      return;
    }
    if (msg.type == NexusMessage.pairRequest) {
      debugPrint('NEXUS mesh: pair-request <- ${msg.from} (code matched)');
      await _handlePairRequest(msg, socket);
    }
  }

  Future<String?> _identifySender(Socket socket, String enc) async {
    for (final peer in _paired.values.toList()) {
      try {
        final key = await _sessionKeyFor(peer);
        final clear = await decryptFromB64(enc, key);
        final decoded = jsonDecode(utf8.decode(clear));
        if (decoded is Map<String, dynamic> && decoded['from'] == peer.id) {
          _inboundPeer[socket] = peer.id;
          return peer.id;
        }
      } catch (_) {
        // wrong key for this peer — try the next one
      }
    }
    return null;
  }

  String? _peerIdForSocket(Socket socket) {
    for (final entry in _outbound.entries) {
      if (identical(entry.value, socket)) return entry.key;
    }
    return _inboundPeer[socket];
  }

  void _dropSocket(Socket socket) {
    _inboundPeer.remove(socket);
    for (final entry in _outbound.entries.toList()) {
      if (identical(entry.value, socket)) {
        _outbound.remove(entry.key);
      }
    }
    try {
      socket.destroy();
    } catch (_) {}
  }

  Future<Socket?> _outboundSocket(PairedDevice peer) async {
    final existing = _outbound[peer.id];
    // If the socket died, _dropSocket will have removed it from _outbound;
    // anything still registered is usable (a send that races a close is
    // caught and dropped below).
    if (existing != null) return existing;
    // Try every address we know for this peer. The one that worked most
    // recently (peer.address) goes first, so LAN at home and Tailscale when
    // far away both work without any reconfiguration.
    final candidates = <String>[];
    void add(String a) {
      if (a.isNotEmpty && !candidates.contains(a)) candidates.add(a);
    }

    add(peer.address);
    for (final a in peer.addresses) {
      add(a);
    }
    for (final address in candidates) {
      try {
        final socket = await Socket.connect(
          address,
          peer.port,
          timeout: connectTimeout,
        );
        _outbound[peer.id] = socket;
        _inboundPeer[socket] =
            peer.id; // so replies on this socket are attributed
        _onClientSocket(socket);
        return socket;
      } catch (_) {
        // Unreachable via this address — try the next one.
      }
    }
    return null;
  }

  Future<Uint8List> _sessionKeyFor(PairedDevice peer) async {
    final cached = _sessionKeys[peer.id];
    if (cached != null) return cached;
    final key = await deriveSessionKey(
      pairingSecret: peer.pairingSecret,
      myId: identity.id,
      peerId: peer.id,
    );
    _sessionKeys[peer.id] = key;
    return key;
  }

  // ---------------------------------------------------------------------
  // Messaging
  // ---------------------------------------------------------------------

  Future<void> _handleMessage(
    NexusMessage msg,
    Socket socket, {
    required bool encrypted,
  }) async {
    _remember(msg.id);

    switch (msg.type) {
      case NexusMessage.ping:
        // A ping proves reachability and tells us who is talking; attribute
        // the socket so later encrypted frames on it are recognized.
        if (_paired.containsKey(msg.from)) {
          _inboundPeer[socket] = msg.from;
        }
        final payload = msg.payload;
        if (_paired.containsKey(msg.from)) {
          _notePeerVersion(msg.from, payload['appVersion']);
          _noteSerialHosts(msg.from, payload['serial']);
        }
        final name = payload['name'] as String? ?? 'Unknown device';
        final port = (payload['port'] as num?)?.toInt();
        final ips = (payload['ips'] as List?)?.whereType<String>().toList();
        _noteSeen(msg.from, verified: true);
        debugPrint(
          'NEXUS mesh: ping <- ${msg.from} from ${socket.remoteAddress.address}',
        );
        if (port != null) {
          await _learnAddress(
            msg.from,
            socket.remoteAddress.address,
            port,
            name,
            payload['platform'] as String? ?? 'other',
            ips: ips,
          );
        }
        _sendPlain(
          socket,
          NexusMessage(
            type: NexusMessage.pong,
            from: identity.id,
            to: msg.from,
            payload: {
              'name': identity.name,
              'platform': identity.platform,
              'appVersion': appVersion,
              'port': store.port,
              'ips': await _myIps(),
              'serial': _serialAnnouncement(),
            },
            id: _newId(),
            ts: DateTime.now().millisecondsSinceEpoch,
          ),
        );

      case NexusMessage.pong:
        _noteSeen(msg.from, verified: true);
        debugPrint('NEXUS mesh: pong <- ${msg.from}');
        final payload = msg.payload;
        if (_paired.containsKey(msg.from)) {
          _notePeerVersion(msg.from, payload['appVersion']);
          _noteSerialHosts(msg.from, payload['serial']);
        }
        final name = payload['name'] as String?;
        final port = (payload['port'] as num?)?.toInt();
        final ips = (payload['ips'] as List?)?.whereType<String>().toList();
        if (port != null && name != null) {
          await _learnAddress(
            msg.from,
            socket.remoteAddress.address,
            port,
            name,
            payload['platform'] as String? ?? 'other',
            ips: ips,
          );
        }

      case NexusMessage.pairRequest:
        await _handlePairRequest(msg, socket);

      case NexusMessage.pairAccept:
        // Handled inside pairWith's own flow; reaching here means an
        // unexpected duplicate — ignore.
        break;

      case NexusMessage.pairReject:
        break;

      case NexusMessage.clipboard:
        if (!encrypted) return; // clipboard text must never ride in plaintext
        await _handleIncomingClip(msg);

      case NexusMessage.clipboardAck:
        if (!encrypted) return;
        final req = msg.payload['req'];
        final ack = req is String ? _pendingClipboardAcks.remove(req) : null;
        if (ack != null && !ack.isCompleted) ack.complete(true);

      case NexusMessage.clipboardNotify:
        // No longer used — kept for backward compatibility with older peers.
        break;

      case NexusMessage.clipboardPull:
        // No longer used — kept for backward compatibility with older peers.
        break;

      case NexusMessage.fileList:
        if (!encrypted) return; // file paths are private — never in plaintext
        await _handleFileListRequest(msg);

      case NexusMessage.fileGet:
        if (!encrypted) return;
        await _handleFileGetRequest(msg);

      case NexusMessage.fileListResult:
        if (!encrypted) return;
        await _handleFileListResult(msg);

      case NexusMessage.fileChunk:
        if (!encrypted) return;
        await _handleFileChunk(msg);

      case NexusMessage.filePush:
        if (!encrypted) return;
        await _handleFilePush(msg);

      case NexusMessage.filePushAck:
        if (!encrypted) return;
        await _handleFilePushAck(msg);

      case NexusMessage.fileDelete:
        if (!encrypted) return;
        await _handleFileDelete(msg);

      case NexusMessage.fileDeleteAck:
        if (!encrypted) return;
        await _handleFileDeleteAck(msg);

      case NexusMessage.fileOperation:
        if (!encrypted) return;
        await _handleFileOperation(msg);

      case NexusMessage.fileOperationAck:
        if (!encrypted) return;
        await _handleFileOperationAck(msg);

      case NexusMessage.fileError:
        if (!encrypted) return;
        await _handleFileError(msg);

      case NexusMessage.serialMsg:
        // Multi-hop: a peer wants us to forward a payload to a node on our
        // cable. The node replies with `up`, relayed back to this peer.
        if (!encrypted) return;
        final target = msg.to;
        final data = msg.payload['data'];
        if (target == null || data is! Map<String, dynamic>) break;
        if (_serial?.byId(target) == null) break;
        _serialRequesters[target] = msg.from;
        await _serial!.sendMessage(target, data);

      case NexusMessage.serialUp:
        // A node on a peer's cable answered — remember the payload so the UI
        // can show it.
        if (!encrypted) return;
        final data = msg.payload['data'];
        if (data is Map<String, dynamic>) {
          lastSerialUp = {
            'from': msg.from,
            'name': msg.payload['name'] ?? msg.from,
            'data': data,
          };
          notifyListeners();
        }
    }
  }

  // ---------------------------------------------------------------------
  // Remote file access (encrypted, served from this device's home folder)
  // ---------------------------------------------------------------------

  /// The folder this device serves. Desktop: the home directory. Android:
  /// the real shared storage when the user granted "All files access" (so the
  /// PC file manager sees every photo, download and music file), otherwise
  /// the app's own external dir. Tests inject their own root.
  Future<String> _servedRoot() async {
    if (fileRoot != null) return fileRoot!;
    if (Platform.isAndroid) {
      if (await hasAllFilesAccess()) {
        final shared = await androidSharedRoot();
        if (shared != null && shared.isNotEmpty) return shared;
      }
      try {
        final external = await getExternalStorageDirectory();
        if (external != null) return external.path;
      } catch (_) {
        // No external storage (emulator, weird device) — fall back below.
      }
      final dir = await getApplicationDocumentsDirectory();
      return dir.path;
    }
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) return home;
    final profile = Platform.environment['USERPROFILE'];
    if (profile != null && profile.isNotEmpty) return profile;
    final dir = await getApplicationDocumentsDirectory();
    return dir.path;
  }

  /// On Android, whether the app may read the whole shared storage (the
  /// "All files access" toggle). Always true on other platforms.
  static Future<bool> hasAllFilesAccess() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _storageChannel.invokeMethod<bool>('allFilesAccess') ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// On Android, the real shared storage root (e.g. /storage/emulated/0) —
  /// only readable once [hasAllFilesAccess] is granted.
  static Future<String?> androidSharedRoot() async {
    if (!Platform.isAndroid) return null;
    try {
      return await _storageChannel.invokeMethod<String>('sharedRoot');
    } catch (_) {
      return null;
    }
  }

  /// Opens the system "All files access" settings screen for this app.
  static Future<void> openAllFilesAccessSettings() async {
    if (!Platform.isAndroid) return;
    try {
      await _storageChannel.invokeMethod<void>('openAllFilesAccessSettings');
    } catch (_) {
      // Channel unavailable (tests) — nothing to open.
    }
  }

  /// Maps a peer-supplied path onto the served root, collapsing `.`/`..` and
  /// refusing anything that escapes the root. Returns null = access denied.
  String? _resolveServedPath(String path, String root) {
    final separator = Platform.pathSeparator;
    final requested = path.replaceAll(separator == '/' ? '\\' : '/', separator);
    if (requested.isEmpty || requested == separator) return root;
    // Relative destinations are rooted in the shared folder. Normalize after
    // anchoring so `../` cannot be used to escape it.
    final candidate = requested.startsWith(separator)
        ? requested
        : '$root$separator$requested';
    final clean = _normalizePath(candidate);
    if (clean != root && !clean.startsWith('$root$separator')) return null;
    return clean;
  }

  static String _normalizePath(String path) {
    final parts = <String>[];
    for (final seg in path.split(Platform.pathSeparator)) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') {
        if (parts.isNotEmpty) parts.removeLast();
      } else {
        parts.add(seg);
      }
    }
    final prefix = path.startsWith(Platform.pathSeparator)
        ? Platform.pathSeparator
        : '';
    return prefix + parts.join(Platform.pathSeparator);
  }

  /// Lexical containment is not enough when a user-created symlink points
  /// outside the shared root. Existing path segments must resolve inside it;
  /// a missing leaf is checked through its nearest existing parent.
  Future<bool> _isInsideServedRoot(String path, String root) async {
    try {
      final realRoot = await Directory(root).resolveSymbolicLinks();
      var candidate = path;
      while (FileSystemEntity.typeSync(candidate) ==
          FileSystemEntityType.notFound) {
        final parent = Directory(candidate).parent.path;
        if (parent == candidate) return false;
        candidate = parent;
      }
      final realCandidate =
          FileSystemEntity.typeSync(candidate) == FileSystemEntityType.directory
          ? await Directory(candidate).resolveSymbolicLinks()
          : await File(candidate).resolveSymbolicLinks();
      return realCandidate == realRoot ||
          realCandidate.startsWith('$realRoot${Platform.pathSeparator}');
    } catch (_) {
      return false;
    }
  }

  Future<void> _handleFileListRequest(NexusMessage msg) async {
    final req = msg.payload['req'];
    final peer = _paired[msg.from];
    if (peer == null || req is! String) return;
    final path = msg.payload['path'] as String? ?? '';
    final root = await _servedRoot();
    final resolved = _resolveServedPath(path, root);
    if (resolved == null || !await _isInsideServedRoot(resolved, root)) {
      await _sendFileError(
        peer,
        req,
        'Access denied — that folder is outside your home directory.',
      );
      return;
    }
    final entries = await _listDir(resolved);
    if (entries == null) {
      await _sendFileError(
        peer,
        req,
        lastFileError ?? 'Could not read that folder.',
      );
      return;
    }
    await _sendEnc(
      peer,
      NexusMessage(
        type: NexusMessage.fileListResult,
        from: identity.id,
        to: peer.id,
        payload: {
          'req': req,
          'entries': entries
              .map(
                (e) => {
                  'name': e.name,
                  'path': e.path,
                  'size': e.size,
                  'dir': e.isDir,
                  'modified': e.modified.toIso8601String(),
                },
              )
              .toList(),
        },
        id: _newId(),
        ts: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  /// Lists [resolved] (a path already validated against the served root),
  /// skipping unreadable entries. Returns null on failure — [lastFileError]
  /// says why.
  Future<List<FileEntry>?> _listDir(String resolved) async {
    try {
      final dir = Directory(resolved);
      if (!await dir.exists()) {
        lastFileError = 'That folder does not exist on this device.';
        return null;
      }
      final children = await dir.list().toList();
      final listed = <FileEntry>[];
      for (final child in children) {
        try {
          final isDir = child is Directory;
          final stat = await child.stat();
          final segments = child.path
              .split(Platform.pathSeparator)
              .where((s) => s.isNotEmpty)
              .toList();
          listed.add(
            FileEntry(
              name: segments.isEmpty ? child.path : segments.last,
              path: child.path,
              size: isDir ? 0 : stat.size,
              isDir: isDir,
              modified: stat.modified,
            ),
          );
        } catch (_) {
          // Unreadable entry (permission, vanished mid-listing) — skip it.
        }
      }
      listed.sort((a, b) {
        if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      return listed;
    } catch (_) {
      lastFileError = 'Could not read that folder.';
      return null;
    }
  }

  Future<void> _handleFileGetRequest(NexusMessage msg) async {
    final req = msg.payload['req'];
    final peer = _paired[msg.from];
    if (peer == null || req is! String) return;
    final path = msg.payload['path'] as String? ?? '';
    final root = await _servedRoot();
    final resolved = _resolveServedPath(path, root);
    if (resolved == null || !await _isInsideServedRoot(resolved, root)) {
      await _sendFileError(
        peer,
        req,
        'Access denied — that file is outside your home directory.',
      );
      return;
    }
    RandomAccessFile raf;
    try {
      raf = await File(resolved).open();
    } catch (_) {
      await _sendFileError(peer, req, 'Could not open that file.');
      return;
    }
    try {
      final total = await raf.length();
      final offset = (msg.payload['offset'] as num?)?.toInt() ?? 0;
      final length = (msg.payload['length'] as num?)?.toInt() ?? 0;
      if (offset < 0 || length < 0) {
        await _sendFileError(peer, req, 'That byte range is not valid.');
        return;
      }
      if (length > 0) {
        // Range read (the FUSE gateway asks for exact byte ranges when the
        // file manager reads a file): one seeked chunk, done — no stream.
        try {
          if (offset > 0) await raf.setPosition(offset);
          final data = await raf.read(length);
          await _sendEnc(
            peer,
            NexusMessage(
              type: NexusMessage.fileChunk,
              from: identity.id,
              to: peer.id,
              payload: {
                'req': req,
                'offset': offset,
                'data': base64Encode(data),
                'total': length,
                'done': true,
              },
              id: _newId(),
              ts: DateTime.now().millisecondsSinceEpoch,
            ),
          );
        } catch (_) {
          await _sendFileError(peer, req, 'Could not read that range.');
        }
        return;
      }
      // Whole-file stream in 256 KiB chunks — small enough to stay well under
      // the 1 MiB frame guard, large enough that big files don't become a
      // message zoo.
      const chunkSize = 256 * 1024;
      var sent = 0;
      while (true) {
        final data = await raf.read(chunkSize);
        final done = sent + data.length >= total;
        final ok = await _sendEnc(
          peer,
          NexusMessage(
            type: NexusMessage.fileChunk,
            from: identity.id,
            to: peer.id,
            payload: {
              'req': req,
              'offset': sent,
              'data': base64Encode(data),
              'total': total,
              'done': done,
            },
            id: _newId(),
            ts: DateTime.now().millisecondsSinceEpoch,
          ),
        );
        if (!ok) break; // peer went away mid-transfer
        sent += data.length;
        if (done) break;
      }
    } catch (_) {
      await _sendFileError(peer, req, 'The file changed while reading it.');
    } finally {
      await raf.close();
    }
  }

  Future<void> _sendFileError(
    PairedDevice peer,
    String req,
    String message,
  ) async {
    lastFileError = message;
    await _sendEnc(
      peer,
      NexusMessage(
        type: NexusMessage.fileError,
        from: identity.id,
        to: peer.id,
        payload: {'req': req, 'message': message},
        id: _newId(),
        ts: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  Future<void> _handleFileListResult(NexusMessage msg) async {
    final req = msg.payload['req'];
    final completer = req is String ? _pendingLists.remove(req) : null;
    if (completer == null) return;
    final raw = (msg.payload['entries'] as List?) ?? const [];
    final entries = raw
        .whereType<Map<String, dynamic>>()
        .map(
          (e) => FileEntry(
            name: e['name'] as String? ?? '?',
            path: e['path'] as String? ?? '',
            size: (e['size'] as num?)?.toInt() ?? 0,
            isDir: e['dir'] == true,
            modified:
                DateTime.tryParse(e['modified'] as String? ?? '') ??
                DateTime.fromMillisecondsSinceEpoch(0),
          ),
        )
        .toList();
    if (!completer.isCompleted) completer.complete(entries);
  }

  Future<void> _handleFileChunk(NexusMessage msg) async {
    final req = msg.payload['req'];
    if (req is! String) return;
    // A range request gets exactly one chunk — hand it straight to the
    // caller (the FUSE gateway) instead of a pull state machine.
    final range = _pendingRanges.remove(req);
    if (range != null) {
      final data = base64Decode(msg.payload['data'] as String? ?? '');
      if (!range.isCompleted) range.complete(data);
      return;
    }
    final pull = _pendingPulls[req];
    if (pull == null) return;
    pull.chain = pull.chain.then((_) => _applyChunk(pull, req, msg));
    await pull.chain.catchError((_) {});
  }

  Future<void> _applyChunk(_FilePull pull, String req, NexusMessage msg) async {
    final data = base64Decode(msg.payload['data'] as String? ?? '');
    final total = (msg.payload['total'] as num?)?.toInt() ?? 0;
    final done = msg.payload['done'] == true;
    try {
      pull.sink ??= await File(pull.savePath).open(mode: FileMode.write);
      if (data.isNotEmpty) {
        await pull.sink!.writeFrom(data);
        pull.received += data.length;
      }
      if (pull.total == 0) pull.total = total;
      pull.onProgress?.call(pull.received, pull.total);
      // Any chunk proves the peer is alive — reset the watchdog.
      pull.watchdog?.cancel();
      pull.watchdog = Timer(const Duration(seconds: 15), () {
        _failPull(
          req,
          'The transfer stalled — the connection to ${pull.peerName} was lost.',
        );
      });
      if (done) {
        await pull.sink!.flush();
        await pull.sink!.close();
        pull.sink = null;
        pull.watchdog?.cancel();
        _pendingPulls.remove(req);
        if (!pull.done.isCompleted) pull.done.complete(File(pull.savePath));
      }
    } catch (e) {
      _failPull(req, 'Could not save the file: $e');
    }
  }

  /// First frame of an incoming push carries the file name; every frame
  /// carries data. Frames are dispatched concurrently, so all disk writes
  /// chain onto the push's [chain] — the same serialization that fixed the
  /// pull-side overlap bug.
  Future<void> _handleFilePush(NexusMessage msg) async {
    _filePushChain = _filePushChain.then((_) => _handleFilePushNow(msg));
    await _filePushChain.catchError((_) {});
  }

  Future<void> _handleFilePushNow(NexusMessage msg) async {
    final req = msg.payload['req'];
    final peer = _paired[msg.from];
    if (peer == null || req is! String) return;
    var push = _incomingPushes[req];
    if (push == null) {
      final name = (msg.payload['name'] as String?) ?? '';
      final root = await _servedRoot();
      final requestedDestination = msg.payload['destination'] as String?;
      final destination = requestedDestination == null
          ? '$root${Platform.pathSeparator}Nexus Incoming${Platform.pathSeparator}$name'
          : _resolveServedPath(requestedDestination, root);
      if (destination == null ||
          destination == root ||
          (requestedDestination == null && !_safeIncomingName(name))) {
        await _sendFileError(
          peer,
          req,
          'Access denied — invalid destination path.',
        );
        return;
      }
      final incomingDirectory = Directory(
        '$root${Platform.pathSeparator}Nexus Incoming',
      );
      final containmentPath = requestedDestination == null
          ? incomingDirectory
          : FileSystemEntity.typeSync(destination) !=
                FileSystemEntityType.notFound
          ? File(destination)
          : Directory(destination).parent;
      if (await containmentPath.exists() &&
          !await _isInsideServedRoot(containmentPath.path, root)) {
        await _sendFileError(
          peer,
          req,
          'Access denied — invalid destination path.',
        );
        return;
      }
      final destinationName = destination.split(Platform.pathSeparator).last;
      if (!_safeIncomingName(destinationName)) {
        await _sendFileError(peer, req, 'Refused file with an invalid name.');
        return;
      }
      push = _FilePush(
        name: destinationName,
        dir: Directory(destination).parent.path,
        peerName: peer.name,
        overwrite: msg.payload['overwrite'] == true,
      );
      _incomingPushes[req] = push;
    }
    final active = push;
    active.chain = active.chain.then(
      (_) => _applyPushChunk(active, peer, req, msg),
    );
    await active.chain.catchError((_) {});
  }

  Future<void> _applyPushChunk(
    _FilePush push,
    PairedDevice peer,
    String req,
    NexusMessage msg,
  ) async {
    final data = base64Decode(msg.payload['data'] as String? ?? '');
    final total = (msg.payload['total'] as num?)?.toInt() ?? 0;
    final done = msg.payload['done'] == true;
    try {
      push.sink ??= await _openIncoming(push);
      if (data.isNotEmpty) {
        await push.sink!.writeFrom(data);
        push.received += data.length;
      }
      if (push.total == 0) push.total = total;
      // Any chunk proves the sender is alive — reset the watchdog.
      push.watchdog?.cancel();
      push.watchdog = Timer(const Duration(seconds: 15), () {
        _failPush(
          peer,
          req,
          'The transfer stalled — the connection to ${push.peerName} was lost.',
        );
      });
      if (done) {
        await push.sink!.flush();
        await push.sink!.close();
        push.sink = null;
        push.watchdog?.cancel();
        _incomingPushes.remove(req);
        await _sendEnc(
          peer,
          NexusMessage(
            type: NexusMessage.filePushAck,
            from: identity.id,
            to: peer.id,
            payload: {'req': req, 'path': push.savedPath},
            id: _newId(),
            ts: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      }
    } catch (e) {
      _failPush(peer, req, 'Could not save the file: $e');
    }
  }

  /// A file name may only be a plain basename — anything with path separators
  /// or dot-dots is refused so a push can never escape the incoming folder.
  static bool _safeIncomingName(String name) {
    if (name.isEmpty || name == '.' || name == '..') return false;
    if (name.contains('/') || name.contains('\\')) return false;
    return true;
  }

  /// Opens the destination file under the incoming folder, creating the
  /// folder if needed and giving collisions a `(n)` suffix (like downloads).
  Future<RandomAccessFile> _openIncoming(_FilePush push) async {
    await Directory(push.dir).create(recursive: true);
    final path = '${push.dir}${Platform.pathSeparator}${push.name}';
    final existing = FileSystemEntity.typeSync(path);
    if (existing != FileSystemEntityType.notFound) {
      if (!push.overwrite || existing == FileSystemEntityType.directory) {
        throw StateError('A file with that name already exists.');
      }
      await File(path).delete();
    }
    push.savedPath = path;
    return File(path).open(mode: FileMode.write);
  }

  void _failPush(PairedDevice peer, String req, String message) {
    final push = _incomingPushes.remove(req);
    if (push == null) return;
    push.watchdog?.cancel();
    push.sink?.close().catchError((_) {});
    push.sink = null;
    unawaited(_sendFileError(peer, req, message));
  }

  Future<void> _handleFileError(NexusMessage msg) async {
    final req = msg.payload['req'];
    final message =
        (msg.payload['message'] as String?) ??
        'The device refused the request.';
    final pull = req is String ? _pendingPulls.remove(req) : null;
    if (pull != null) {
      pull.watchdog?.cancel();
      pull.sink?.close().catchError((_) {});
      pull.sink = null;
      lastFileError = message;
      if (!pull.done.isCompleted) pull.done.complete(null);
      return;
    }
    final push = req is String ? _outgoingPushes.remove(req) : null;
    if (push != null) {
      lastFileError = message;
      if (!push.isCompleted) push.complete(null);
      return;
    }
    final completer = req is String ? _pendingLists.remove(req) : null;
    if (completer != null) {
      lastFileError = message;
      if (!completer.isCompleted) completer.complete(null);
    }
    final del = req is String ? _pendingDeletes.remove(req) : null;
    if (del != null) {
      lastFileError = message;
      if (!del.isCompleted) del.complete(false);
      return;
    }
    final operation = req is String ? _pendingOperations.remove(req) : null;
    if (operation != null) {
      lastFileError = message;
      if (!operation.isCompleted) operation.complete(null);
    }
  }

  Future<void> _handleFilePushAck(NexusMessage msg) async {
    final req = msg.payload['req'];
    final completer = req is String ? _outgoingPushes.remove(req) : null;
    if (completer == null) return;
    final saved = msg.payload['path'] as String?;
    if (!completer.isCompleted) completer.complete(saved);
  }

  /// Deletes a file (or empty folder) on this device at the peer's request.
  /// The path must resolve inside the served root — the same sandbox that
  /// governs listing and reading — and the root itself is never deletable.
  Future<void> _handleFileOperation(NexusMessage msg) async {
    final req = msg.payload['req'];
    final peer = _paired[msg.from];
    if (peer == null || req is! String) return;
    final operation = msg.payload['operation'] as String?;
    final source = msg.payload['source'] as String? ?? '';
    final destination = msg.payload['destination'] as String? ?? '';
    final root = await _servedRoot();
    final sourcePath = _resolveServedPath(source, root);
    final destinationPath = _resolveServedPath(destination, root);
    final destinationName =
        destinationPath?.split(Platform.pathSeparator).last ?? '';
    if (destinationPath == null ||
        destinationPath == root ||
        !_safeIncomingName(destinationName) ||
        (operation != 'mkdir' && (sourcePath == null || sourcePath == root))) {
      await _sendFileError(
        peer,
        req,
        'Access denied — the path is outside the shared folder.',
      );
      return;
    }
    if (!await _isInsideServedRoot(destinationPath, root) ||
        operation != 'mkdir' && !await _isInsideServedRoot(sourcePath!, root)) {
      await _sendFileError(
        peer,
        req,
        'Access denied — the path is outside the shared folder.',
      );
      return;
    }
    try {
      if (operation == 'mkdir') {
        if (FileSystemEntity.typeSync(destinationPath) !=
            FileSystemEntityType.notFound) {
          await _sendFileError(
            peer,
            req,
            'A file with that name already exists.',
          );
          return;
        }
        await Directory(destinationPath).create(recursive: true);
      } else {
        final sourcePathValue = sourcePath!;
        final sourceType = FileSystemEntity.typeSync(sourcePathValue);
        if (sourceType == FileSystemEntityType.notFound) {
          await _sendFileError(peer, req, 'That file no longer exists.');
          return;
        }
        if (operation == 'rename' || operation == 'move') {
          if (FileSystemEntity.typeSync(destinationPath) !=
              FileSystemEntityType.notFound) {
            await _sendFileError(
              peer,
              req,
              'A file with that name already exists.',
            );
            return;
          }
          if (sourceType == FileSystemEntityType.directory &&
              (destinationPath == sourcePathValue ||
                  destinationPath.startsWith(
                    '$sourcePathValue${Platform.pathSeparator}',
                  ))) {
            await _sendFileError(
              peer,
              req,
              'A folder cannot be moved inside itself.',
            );
            return;
          }
          await Directory(destinationPath).parent.create(recursive: true);
          if (sourceType == FileSystemEntityType.directory) {
            await Directory(sourcePathValue).rename(destinationPath);
          } else {
            await File(sourcePathValue).rename(destinationPath);
          }
        } else if (operation == 'copy') {
          if (FileSystemEntity.typeSync(destinationPath) !=
              FileSystemEntityType.notFound) {
            await _sendFileError(
              peer,
              req,
              'A file with that name already exists.',
            );
            return;
          }
          await Directory(destinationPath).parent.create(recursive: true);
          if (sourceType == FileSystemEntityType.directory) {
            await _copyDirectory(
              Directory(sourcePathValue),
              Directory(destinationPath),
            );
          } else {
            await File(sourcePathValue).copy(destinationPath);
          }
        } else {
          await _sendFileError(peer, req, 'Unsupported file operation.');
          return;
        }
      }
    } catch (_) {
      await _sendFileError(
        peer,
        req,
        'Could not complete that file operation.',
      );
      return;
    }
    await _sendEnc(
      peer,
      NexusMessage(
        type: NexusMessage.fileOperationAck,
        from: identity.id,
        to: peer.id,
        payload: {'req': req, 'path': destinationPath},
        id: _newId(),
        ts: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  Future<void> _copyDirectory(Directory source, Directory destination) async {
    await destination.create(recursive: true);
    await for (final child in source.list()) {
      final name = child.path.split(Platform.pathSeparator).last;
      final target = '${destination.path}${Platform.pathSeparator}$name';
      if (child is Directory) {
        await _copyDirectory(child, Directory(target));
      } else if (child is File) {
        await child.copy(target);
      }
    }
  }

  Future<void> _handleFileDelete(NexusMessage msg) async {
    final req = msg.payload['req'];
    final peer = _paired[msg.from];
    if (peer == null || req is! String) return;
    final path = msg.payload['path'] as String? ?? '';
    final root = await _servedRoot();
    final resolved = _resolveServedPath(path, root);
    if (resolved == null ||
        resolved == root ||
        !await _isInsideServedRoot(resolved, root)) {
      await _sendFileError(
        peer,
        req,
        'Access denied — that is outside the shared folder.',
      );
      return;
    }
    try {
      final entity = FileSystemEntity.typeSync(resolved);
      if (entity == FileSystemEntityType.notFound) {
        await _sendFileError(peer, req, 'That file no longer exists.');
        return;
      }
      if (entity == FileSystemEntityType.directory) {
        if (Directory(resolved).listSync().isNotEmpty) {
          await _sendFileError(peer, req, 'The folder is not empty.');
          return;
        }
        await Directory(resolved).delete();
      } else {
        await File(resolved).delete();
      }
    } catch (_) {
      await _sendFileError(peer, req, 'Could not delete that file.');
      return;
    }
    await _sendEnc(
      peer,
      NexusMessage(
        type: NexusMessage.fileDeleteAck,
        from: identity.id,
        to: peer.id,
        payload: {'req': req},
        id: _newId(),
        ts: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  Future<void> _handleFileDeleteAck(NexusMessage msg) async {
    final req = msg.payload['req'];
    final completer = req is String ? _pendingDeletes.remove(req) : null;
    if (completer != null && !completer.isCompleted) completer.complete(true);
  }

  Future<void> _handleFileOperationAck(NexusMessage msg) async {
    final req = msg.payload['req'];
    final completer = req is String ? _pendingOperations.remove(req) : null;
    if (completer != null && !completer.isCompleted) {
      completer.complete(msg.payload['path'] as String?);
    }
  }

  /// Asks [peer] to perform a filesystem operation on its served root.
  /// [operation] is `rename`, `move`, `copy`, or `mkdir`; [source] is omitted
  /// for `mkdir`. Returns the resulting path or null on failure.
  Future<String?> operateRemoteFile(
    PairedDevice peer, {
    required String operation,
    String source = '',
    required String destination,
  }) async {
    final req = _newId();
    final completer = Completer<String?>();
    _pendingOperations[req] = completer;
    final sent = await _sendEnc(
      peer,
      NexusMessage(
        type: NexusMessage.fileOperation,
        from: identity.id,
        to: peer.id,
        payload: {
          'req': req,
          'operation': operation,
          'source': source,
          'destination': destination,
        },
        id: _newId(),
        ts: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    if (!sent) {
      _pendingOperations.remove(req);
      lastFileError = 'Could not reach ${peer.name}.';
      return null;
    }
    final timer = Timer(const Duration(seconds: 15), () {
      if (!completer.isCompleted) {
        _pendingOperations.remove(req);
        lastFileError = 'Timed out performing that file operation.';
        completer.complete(null);
      }
    });
    final result = await completer.future;
    timer.cancel();
    return result;
  }

  /// Copies or moves a remote file or directory between two paired devices.
  /// Directories are transferred recursively; a move removes the source only
  /// after every child has arrived at the destination.
  Future<String?> transferRemoteFile(
    PairedDevice source,
    String sourcePath,
    PairedDevice target,
    String destinationPath, {
    bool move = false,
  }) async {
    if (source.id == target.id) {
      return operateRemoteFile(
        target,
        operation: move ? 'move' : 'copy',
        source: sourcePath,
        destination: destinationPath,
      );
    }
    final temp = File(
      '${Directory.systemTemp.path}/nexus-transfer-${_newId()}',
    );
    try {
      final entries = await listRemoteFiles(source, sourcePath);
      if (entries != null) {
        final created = await operateRemoteFile(
          target,
          operation: 'mkdir',
          destination: destinationPath,
        );
        if (created == null) return null;
        for (final entry in entries) {
          final childDestination = _joinFilePath(destinationPath, entry.name);
          final copied = await transferRemoteFile(
            source,
            entry.path,
            target,
            childDestination,
            move: move,
          );
          if (copied == null) return null;
        }
        if (move && await deleteRemoteFile(source, sourcePath))
          return destinationPath;
        if (move) return null;
        return destinationPath;
      }
      final pulled = await pullRemoteFile(
        source,
        sourcePath,
        savePath: temp.path,
      );
      if (pulled == null) return null;
      final saved = await pushLocalFile(
        target,
        temp.path,
        destinationPath: destinationPath,
      );
      if (saved == null) return null;
      if (move && !await deleteRemoteFile(source, sourcePath)) return null;
      return saved;
    } finally {
      try {
        if (await temp.exists()) await temp.delete();
      } catch (_) {}
    }
  }

  static String _joinFilePath(String directory, String name) {
    if (directory.isEmpty) return name;
    final separator = Platform.pathSeparator;
    return '${directory.endsWith(separator) ? directory.substring(0, directory.length - 1) : directory}$separator$name';
  }

  /// Asks [peer] to delete the file at [path] on its served root. Returns
  /// false on failure — [lastFileError] says why (a folder that is not empty
  /// is refused, so a deleted folder is always an empty one).
  Future<bool> deleteRemoteFile(PairedDevice peer, String path) async {
    final req = _newId();
    final completer = Completer<bool>();
    _pendingDeletes[req] = completer;
    final sent = await _sendEnc(
      peer,
      NexusMessage(
        type: NexusMessage.fileDelete,
        from: identity.id,
        to: peer.id,
        payload: {'req': req, 'path': path},
        id: _newId(),
        ts: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    if (!sent) {
      _pendingDeletes.remove(req);
      lastFileError = 'Could not reach ${peer.name}.';
      return false;
    }
    final timer = Timer(const Duration(seconds: 15), () {
      if (!completer.isCompleted) {
        _pendingDeletes.remove(req);
        lastFileError =
            'Timed out deleting ${path.split(RegExp(r'[/\\]')).last}.';
        completer.complete(false);
      }
    });
    final ok = await completer.future;
    timer.cancel();
    return ok;
  }

  void _failPull(String req, String message) {
    final pull = _pendingPulls.remove(req);
    if (pull == null) return;
    pull.watchdog?.cancel();
    pull.sink?.close().catchError((_) {});
    pull.sink = null;
    lastFileError = message;
    if (!pull.done.isCompleted) pull.done.complete(null);
  }

  /// Requests a directory listing from [peer]. `path` is an absolute path on
  /// the peer ('' or '/' = its home). Returns null on failure — [lastFileError]
  /// says why.
  Future<List<FileEntry>?> listRemoteFiles(
    PairedDevice peer,
    String path,
  ) async {
    final req = _newId();
    final completer = Completer<List<FileEntry>?>();
    _pendingLists[req] = completer;
    final sent = await _sendEnc(
      peer,
      NexusMessage(
        type: NexusMessage.fileList,
        from: identity.id,
        to: peer.id,
        payload: {'req': req, 'path': path},
        id: _newId(),
        ts: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    if (!sent) {
      _pendingLists.remove(req);
      lastFileError = 'Could not reach ${peer.name}.';
      return null;
    }
    final timer = Timer(const Duration(seconds: 15), () {
      if (!completer.isCompleted) {
        _pendingLists.remove(req);
        lastFileError = 'Timed out reading ${path.isEmpty ? 'home' : path}.';
        completer.complete(null);
      }
    });
    final result = await completer.future;
    timer.cancel();
    return result;
  }

  /// Streams a file from [peer] into [savePath], reporting progress via
  /// [onProgress] (received, total). Returns the saved file, or null on
  /// failure — [lastFileError] says why.
  Future<File?> pullRemoteFile(
    PairedDevice peer,
    String path, {
    required String savePath,
    void Function(int received, int total)? onProgress,
  }) async {
    final req = _newId();
    final pull = _FilePull(
      savePath: savePath,
      onProgress: onProgress,
      peerName: peer.name,
    );
    _pendingPulls[req] = pull;
    // Watchdog covers the whole transfer: waiting for the first chunk counts
    // too, and any chunk resets it.
    pull.watchdog = Timer(const Duration(seconds: 15), () {
      _failPull(req, 'Timed out waiting for ${peer.name}.');
    });
    final sent = await _sendEnc(
      peer,
      NexusMessage(
        type: NexusMessage.fileGet,
        from: identity.id,
        to: peer.id,
        payload: {'req': req, 'path': path},
        id: _newId(),
        ts: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    if (!sent) {
      _failPull(req, 'Could not reach ${peer.name}.');
    }
    return pull.done.future;
  }

  /// Reads one exact byte range [offset, offset+length) from a file on
  /// [peer] — what the FUSE gateway needs for arbitrary file-manager reads.
  /// Returns the bytes (possibly shorter than requested near EOF, empty past
  /// it), or null on failure — [lastFileError] says why.
  Future<Uint8List?> pullRemoteRange(
    PairedDevice peer,
    String path, {
    required int offset,
    required int length,
  }) async {
    final req = _newId();
    final completer = Completer<Uint8List?>();
    _pendingRanges[req] = completer;
    final sent = await _sendEnc(
      peer,
      NexusMessage(
        type: NexusMessage.fileGet,
        from: identity.id,
        to: peer.id,
        payload: {'req': req, 'path': path, 'offset': offset, 'length': length},
        id: _newId(),
        ts: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    if (!sent) {
      _pendingRanges.remove(req);
      lastFileError = 'Could not reach ${peer.name}.';
      return null;
    }
    final timer = Timer(const Duration(seconds: 15), () {
      if (!completer.isCompleted) {
        _pendingRanges.remove(req);
        lastFileError = 'Timed out reading that range.';
        completer.complete(null);
      }
    });
    final result = await completer.future;
    timer.cancel();
    return result;
  }

  /// Streams a local file to [peer] over the
  /// encrypted mesh. The peer writes it into its "Nexus Incoming" folder and
  /// acks when every chunk has landed; returns the path it was saved to on
  /// the peer, or null on failure — [lastFileError] says why.
  Future<String?> pushLocalFile(
    PairedDevice peer,
    String localPath, {
    String? destinationPath,
    bool overwrite = false,
    void Function(int sent, int total)? onProgress,
  }) async {
    final req = _newId();
    final completer = Completer<String?>();
    _outgoingPushes[req] = completer;
    RandomAccessFile raf;
    try {
      raf = await File(localPath).open();
    } catch (_) {
      _failOutgoingPush(req, 'Could not open that file on this device.');
      return null;
    }
    var watchdog = Timer(const Duration(seconds: 15), () {
      _failOutgoingPush(req, 'Timed out sending to ${peer.name}.');
    });
    try {
      final total = await raf.length();
      final name = localPath.split(RegExp(r'[/\\]')).last;
      // Same chunk size as the pull side — well under the frame guard.
      const chunkSize = 256 * 1024;
      var offset = 0;
      var first = true;
      while (true) {
        final data = await raf.read(chunkSize);
        final done = offset + data.length >= total;
        final ok = await _sendEnc(
          peer,
          NexusMessage(
            type: NexusMessage.filePush,
            from: identity.id,
            to: peer.id,
            payload: {
              'req': req,
              if (first) 'name': name,
              if (first && destinationPath != null)
                'destination': destinationPath,
              if (first && destinationPath != null) 'overwrite': overwrite,
              'offset': offset,
              'data': base64Encode(data),
              'total': total,
              'done': done,
            },
            id: _newId(),
            ts: DateTime.now().millisecondsSinceEpoch,
          ),
        );
        if (!ok) {
          _failOutgoingPush(req, 'Could not reach ${peer.name}.');
          return null;
        }
        first = false;
        offset += data.length;
        onProgress?.call(offset, total);
        // Any sent chunk proves the connection is alive — reset the watchdog.
        watchdog.cancel();
        watchdog = Timer(const Duration(seconds: 15), () {
          _failOutgoingPush(req, 'Timed out sending to ${peer.name}.');
        });
        if (done) break;
      }
    } catch (_) {
      _failOutgoingPush(req, 'Could not read the file while sending.');
      return null;
    } finally {
      await raf.close();
    }
    final saved = await completer.future;
    watchdog.cancel();
    return saved;
  }

  void _failOutgoingPush(String req, String message) {
    final completer = _outgoingPushes.remove(req);
    if (completer == null) return;
    lastFileError = message;
    if (!completer.isCompleted) completer.complete(null);
  }

  void _notePeerVersion(String peerId, Object? rawVersion) {
    if (!_paired.containsKey(peerId) ||
        rawVersion is! String ||
        rawVersion.trim().isEmpty) {
      return;
    }
    final version = rawVersion.trim();
    final previous = _latestPeerUpdateVersion;
    if (version == previous) return;
    _latestPeerUpdateVersion = version;
    notifyListeners();
  }

  void _noteSeen(String id, {required bool verified}) {
    final now = DateTime.now();
    _lastSeen[id] = now;
    if (verified) _verified[id] = now;
  }

  Future<void> _learnAddress(
    String id,
    String address,
    int port,
    String name,
    String platform, {
    List<String>? ips,
  }) async {
    final peer = _paired[id];
    if (peer != null) {
      var changed = false;
      if (peer.address != address) {
        peer.address = address;
        changed = true;
      }
      if (peer.port != port) {
        peer.port = port;
        changed = true;
      }
      if (!peer.localName && peer.name != name) {
        peer.name = name;
        changed = true;
      }
      // Merge the announced address list: the connecting address first (it
      // just worked), then the announced ones, then anything we already had
      // — so a device that gained a Tailscale IP keeps all routes to it.
      final merged = <String>[address, ...?ips];
      final next = <String>[];
      for (final a in merged) {
        if (a.isNotEmpty && !next.contains(a)) next.add(a);
      }
      for (final a in peer.addresses) {
        if (!next.contains(a)) next.add(a);
      }
      if (!_sameList(peer.addresses, next)) {
        peer.addresses = next;
        changed = true;
      }
      if (changed) {
        store.upsertPaired(peer.toJson());
        await store.save();
      }
    } else {
      final existing = _nearby[id];
      if (existing == null || existing.port != port || existing.name != name) {
        _nearby[id] = DiscoveredDevice(
          id: id,
          name: name,
          platform: platform,
          address: address,
          port: port,
          lastSeen: DateTime.now(),
        );
      }
    }
    notifyListeners();
  }

  bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _sendPlain(Socket socket, NexusMessage msg) {
    try {
      socket.add(FrameDecoder.encodeFrame(encodeJson(msg.toJson())));
      unawaited(socket.flush());
    } catch (_) {
      _dropSocket(socket);
    }
  }

  Future<bool> _sendEnc(PairedDevice peer, NexusMessage msg) async {
    final key = await _sessionKeyFor(peer);
    final String enc;
    try {
      enc = await encryptToB64(encodeJson(msg.toJson()), key);
    } catch (_) {
      return false;
    }
    final socket = await _outboundSocket(peer);
    if (socket == null) return false;
    try {
      socket.add(FrameDecoder.encodeFrame(encodeJson({'enc': enc})));
      await socket.flush();
      return true;
    } catch (_) {
      _dropSocket(socket);
      return false;
    }
  }

  // ---------------------------------------------------------------------
  // Presence heartbeat
  // ---------------------------------------------------------------------

  Future<void> _heartbeat() async {
    if (_heartbeatRunning) return;
    _heartbeatRunning = true;
    try {
      // Drop devices that stopped announcing, so we never keep pinging ghosts.
      final cutoff = DateTime.now().subtract(nearbyWindow);
      _nearby.removeWhere((_, d) => d.lastSeen.isBefore(cutoff));
      final targets = <String, PairedDevice>{};
      for (final peer in _paired.values) {
        targets[peer.id] = peer;
      }
      for (final device in _nearby.values) {
        targets.putIfAbsent(
          device.id,
          () => PairedDevice(
            id: device.id,
            name: device.name,
            platform: device.platform,
            address: device.address,
            port: device.port,
            pairingSecret: '',
            localName: false,
          ),
        );
      }        for (final peer in targets.values) {
        final msg = NexusMessage(
          type: NexusMessage.ping,
          from: identity.id,
          to: peer.id,
          payload: {
            'name': identity.name,
            'platform': identity.platform,
            'appVersion': appVersion,
            'port': store.port,
            'ips': await _myIps(),
            'serial': _serialAnnouncement(),
          },
          id: _newId(),
          ts: DateTime.now().millisecondsSinceEpoch,
        );
        final socket = await _outboundSocket(peer);
        if (socket != null) {
          _sendPlain(socket, msg);
          _noteSeen(peer.id, verified: false);
        }
      }
      notifyListeners();
    } finally {
      _heartbeatRunning = false;
    }
  }

  // ---------------------------------------------------------------------
  // Pairing
  // ---------------------------------------------------------------------

  /// Start "show my code": returns a code + QR payload valid for 5 minutes.
  /// The QR includes the LAN IP when known, so a scanning device can connect
  /// straight away without typing an address.
  PairingSession beginPairing() {
    final code = generatePairingCode();
    pendingCode = code;
    pendingCodeExpiry = DateTime.now().add(const Duration(minutes: 5));
    return PairingSession(
      code: code,
      qrPayload: PairPayload.build(
        id: identity.id,
        name: identity.name,
        port: store.port,
        code: code,
      ),
      expiresAt: pendingCodeExpiry!,
    );
  }

  bool get pendingCodeActive {
    final expiry = pendingCodeExpiry;
    return pendingCode != null &&
        expiry != null &&
        DateTime.now().isBefore(expiry);
  }

  /// The other side: verify the pairing request and accept it.
  Future<void> _handlePairRequest(NexusMessage msg, Socket socket) async {
    if (!pendingCodeActive) {
      // We should not even be able to decrypt without a pending code, but
      // guard anyway.
      return;
    }
    final code = pendingCode!;
    final key = await derivePairingKey(code);
    final payload = msg.payload;
    final name = (payload['name'] as String?) ?? 'Unknown device';
    final platform = (payload['platform'] as String?) ?? 'other';
    final peerPort = (payload['port'] as num?)?.toInt();

    final peer = PairedDevice(
      id: msg.from,
      name: name,
      platform: platform,
      address: socket.remoteAddress.address,
      port: peerPort ?? store.port,
      pairingSecret: code,
      lastVerified: DateTime.now(),
    );
    _paired[peer.id] = peer;
    store.upsertPaired(peer.toJson());
    await store.save();
    pendingCode = null;
    pendingCodeExpiry = null;
    _noteSeen(peer.id, verified: true);

    // Reply on the same socket, encrypted with the same code-derived key.
    final reply = NexusMessage(
      type: NexusMessage.pairAccept,
      from: identity.id,
      to: msg.from,
      payload: {
        'name': identity.name,
        'platform': identity.platform,
        'port': store.port,
      },
      id: _newId(),
      ts: DateTime.now().millisecondsSinceEpoch,
    );
    try {
      final enc = await encryptToB64(encodeJson(reply.toJson()), key);
      socket.add(FrameDecoder.encodeFrame(encodeJson({'enc': enc})));
      await socket.flush();
    } catch (_) {
      _dropSocket(socket);
    }
    notifyListeners();
  }

  /// This side: connect to a device showing a code, prove we know the code
  /// by encrypting our request with it, and store the pair on acceptance.
  Future<PairResult> pairWith({
    required String address,
    required int port,
    required String code,
  }) async {
    final cleanCode = code.trim().toUpperCase();
    final key = await derivePairingKey(cleanCode);

    Socket socket;
    try {
      socket = await Socket.connect(
        address,
        port,
        timeout: const Duration(seconds: 6),
      );
    } catch (_) {
      return PairResult.failure(
        'Could not reach $address:$port. Is that device on and on the same network?',
      );
    }

    final completer = Completer<PairResult>();
    final request = NexusMessage(
      type: NexusMessage.pairRequest,
      from: identity.id,
      payload: {
        'name': identity.name,
        'platform': identity.platform,
        'port': store.port,
      },
      id: _newId(),
      ts: DateTime.now().millisecondsSinceEpoch,
    );

    String? pendingEnc;
    try {
      pendingEnc = await encryptToB64(encodeJson(request.toJson()), key);
    } catch (e) {
      socket.destroy();
      return PairResult.failure(
        'Something went wrong preparing the pairing request.',
      );
    }

    final decoder = FrameDecoder();
    final timeout = Timer(const Duration(seconds: 12), () {
      if (!completer.isCompleted) {
        completer.complete(
          PairResult.failure(
            'No answer from the device. Double-check the code and that it is still showing.',
          ),
        );
        socket.destroy();
      }
    });

    Future<void> handleChunk(List<int> chunk) async {
      decoder.add(chunk);
      final frames = decoder.takeFrames();
      if (frames == null) return;
      for (final frame in frames) {
        try {
          final json = jsonDecode(utf8.decode(frame));
          if (json is! Map<String, dynamic> || json['enc'] is! String) continue;
          final clear = await decryptFromB64(json['enc'] as String, key);
          final msg = NexusMessage.fromJson(
            jsonDecode(utf8.decode(clear)) as Map<String, dynamic>,
          );
          if (msg.type == NexusMessage.pairAccept) {
            debugPrint('NEXUS mesh: pair-accept <- ${msg.from}');
            if (!completer.isCompleted) {
              _paired[msg.from] = PairedDevice(
                id: msg.from,
                name: (msg.payload['name'] as String?) ?? 'Paired device',
                platform: (msg.payload['platform'] as String?) ?? 'other',
                address: address,
                port: (msg.payload['port'] as num?)?.toInt() ?? port,
                pairingSecret: cleanCode,
                lastVerified: DateTime.now(),
              );
              store.upsertPaired(_paired[msg.from]!.toJson());
              await store.save();
              _noteSeen(msg.from, verified: true);
              completer.complete(PairResult.ok(_paired[msg.from]!.name));
            }
            return;
          } else if (msg.type == NexusMessage.pairReject) {
            if (!completer.isCompleted) {
              completer.complete(
                PairResult.failure(
                  (msg.payload['reason'] as String?) ??
                      'The device rejected the pairing.',
                ),
              );
            }
            return;
          }
        } catch (_) {
          // A frame we cannot decrypt is not from the device showing the
          // code — ignore it and keep waiting for the real answer.
        }
      }
    }

    socket.listen(
      handleChunk,
      onError: (_) {
        if (!completer.isCompleted)
          completer.complete(
            PairResult.failure('Connection was lost during pairing.'),
          );
      },
      onDone: () {
        if (!completer.isCompleted)
          completer.complete(
            PairResult.failure('Connection closed before pairing finished.'),
          );
      },
    );

    try {
      socket.add(FrameDecoder.encodeFrame(encodeJson({'enc': pendingEnc})));
      await socket.flush();
    } catch (_) {
      timeout.cancel();
      socket.destroy();
      return PairResult.failure('Could not send the pairing request.');
    }

    final result = await completer.future;
    timeout.cancel();
    socket.destroy();
    debugPrint('NEXUS mesh: pairWith -> ${result.ok ? 'ok' : result.error}');
    notifyListeners();
    return result;
  }

  Future<void> forgetDevice(String id) async {
    _paired.remove(id);
    _sessionKeys.remove(id);
    _clipboardDeliveredTo.remove(id);
    _nearby.remove(id); // a forgotten device must not linger as a ghost
    _lastSeen.remove(id);
    _verified.remove(id);
    store.removePaired(id);
    await store.save();
    notifyListeners();
  }

  Future<void> renameDevice(String name) async {
    // Mutate the live identity (announcements and heartbeats read it every
    // few seconds) so the new name reaches every paired device without a
    // restart, then persist it.
    identity.name = sanitizeDeviceName(name);
    store.setIdentity(identity);
    await store.save();
    notifyListeners();
  }

  Future<void> renamePairedDevice(String id, String name) async {
    final device = _paired[id];
    if (device == null) return;
    device.name = sanitizeDeviceName(name);
    device.localName = true;
    store.upsertPaired(device.toJson());

    await store.save();
    notifyListeners();
  }

  // ---------------------------------------------------------------------
  // Clipboard — smart delayed sync
  // ---------------------------------------------------------------------
  //
  // When the user copies something, the text is held for a short delay
  // (3 s). If the local clipboard changes during that window (the user
  // pasted locally or copied something else), the sync is cancelled.
  // After the delay, only devices that are actively being used receive
  // the text — not every paired device.

  Future<void> _checkClipboard() async {
    if (!store.clipboardSync) return;
    final text = await clipboard.readText();
    if (text != null && text != _lastClipboard) {
      _lastClipboard = text;
      if (store.alwaysMerge) {
        // Push immediately to all paired devices.
        _pendingClipboard = text;
        _clipboardDeliveredTo.clear();
      } else {
        // Smart mode: hold for 3 s, then check if user pasted locally.
        _clipboardDelayTimer?.cancel();
        _clipboardHoldText = text;
        _clipboardDelayTimer = Timer(
          const Duration(seconds: 3),
          _onClipboardDelayExpired,
        );
      }
    }
    // Always flush any pending clipboard (retries for deliveries that
    // failed earlier).
    await _flushPendingClipboard();
  }

  /// Called when the post-copy delay expires. If the local clipboard still
  /// matches what we held, the user hasn't pasted locally — sync to active
  /// devices. If it changed, cancel.
  void _onClipboardDelayExpired() {
    final held = _clipboardHoldText;
    if (held == null) return;
    _clipboardHoldText = null;
    // The clipboard changed during the delay — user pasted or copied
    // something else. Don't sync.
    if (_lastClipboard != held) {
      debugPrint('NEXUS clipboard: local activity detected, skipping sync');
      return;
    }
    _pendingClipboard = held;
    _clipboardDeliveredTo.clear();
  }

  /// Whether a device is actively being used (not just reachable).
  /// A device counts as active if it was seen within the last [threshold].
  bool isActiveDevice(String id, {Duration threshold = const Duration(seconds: 10)}) {
    final seen = _lastSeen[id];
    if (seen == null) return false;
    return DateTime.now().difference(seen) <= threshold;
  }

  Future<int> broadcastClipboard(String text) async {
    _lastClipboard = text;
    _pendingClipboard = text;
    _clipboardDeliveredTo.clear();
    return _flushPendingClipboard();
  }

  Future<int> _flushPendingClipboard() async {
    if (_clipboardSending || _pendingClipboard == null) return 0;
    _clipboardSending = true;
    var sent = 0;
    try {
      final text = _pendingClipboard;
      if (text == null) return 0;
      for (final peer in _paired.values.toList()) {
        if (_clipboardDeliveredTo.contains(peer.id)) continue;
        // In smart mode, only send to actively-used devices.
        if (!store.alwaysMerge && !isActiveDevice(peer.id)) {
          debugPrint('NEXUS clipboard: skipping ${peer.id} (not active)');
          continue;
        }
        final req = _newId();
        final ack = Completer<bool>();
        _pendingClipboardAcks[req] = ack;
        final msg = NexusMessage(
          type: NexusMessage.clipboard,
          from: identity.id,
          to: peer.id,
          payload: {'req': req, 'text': text, 'fromName': identity.name},
          id: _newId(),
          ts: DateTime.now().millisecondsSinceEpoch,
        );
        if (await _sendEnc(peer, msg)) {
          try {
            if (await ack.future.timeout(const Duration(seconds: 5))) {
              _clipboardDeliveredTo.add(peer.id);
              sent++;
              debugPrint('NEXUS mesh: clipboard -> ${peer.id}');
            }
          } catch (_) {
            debugPrint('NEXUS mesh: clipboard ACK TIMEOUT -> ${peer.id}');
          } finally {
            _pendingClipboardAcks.remove(req);
          }
        } else {
          _pendingClipboardAcks.remove(req);
          debugPrint(
            'NEXUS mesh: clipboard FAILED -> ${peer.id} (${peer.address}:${peer.port})',
          );
        }
      }
      if (store.alwaysMerge && _paired.keys.every(_clipboardDeliveredTo.contains)) {
        // All devices delivered in always-merge mode — clear pending.
        _pendingClipboard = null;
        _clipboardDeliveredTo.clear();
      } else if (!store.alwaysMerge &&
          (_paired.keys.every(_clipboardDeliveredTo.contains) ||
          _paired.keys.every((id) => !isActiveDevice(id)))) {
        // Smart mode: all active devices delivered, or none are active — clear pending.
        _pendingClipboard = null;
        _clipboardDeliveredTo.clear();
      }
      notifyListeners();
      return sent;
    } finally {
      _clipboardSending = false;
    }
  }

  Future<void> _handleIncomingClip(NexusMessage msg) async {
    final text = msg.payload['text'];
    if (text is! String || text.isEmpty) return;
    final req = msg.payload['req'];
    final peer = _paired[msg.from];
    if (req is String && peer != null) {
      await _sendEnc(
        peer,
        NexusMessage(
          type: NexusMessage.clipboardAck,
          from: identity.id,
          to: peer.id,
          payload: {'req': req},
          id: _newId(),
          ts: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    }
    // Ignore echoes of something this device already copied, but acknowledge
    // them above so the sender does not retry forever.
    if (text == _lastClipboard) return;

    debugPrint('NEXUS mesh: clipboard <- ${msg.from}');

    if (store.clipboardSync) {
      _lastClipboard = text;
      _pendingClipboard = null;
      _clipboardDeliveredTo.clear();
      await clipboard.writeText(text);
    }

    lastIncomingClip = ClipEntry(
      text: text,
      fromName: (msg.payload['fromName'] as String?) ?? 'Another device',
    );
    notifyListeners();
  }

  Future<void> copyText(String text) async {
    _lastClipboard = text;
    await clipboard.writeText(text);
    await broadcastClipboard(text);
  }

  // ---------------------------------------------------------------------
  // Misc
  // ---------------------------------------------------------------------

  bool _remember(String id) {
    if (_recentMessageIds.contains(id)) return false;
    _recentMessageIds.add(id);
    if (_recentMessageIds.length > 300) {
      _recentMessageIds.remove(_recentMessageIds.first);
    }
    return true;
  }

  String _newId() {
    final rng = Random.secure();
    final buf = StringBuffer();
    const alphabet = '0123456789abcdef';
    for (var i = 0; i < 12; i++) {
      buf.write(alphabet[rng.nextInt(alphabet.length)]);
    }
    return buf.toString();
  }

  Future<void> stop() async {
    _started = false;
    _heartbeatTimer?.cancel();
    _clipboardTimer?.cancel();
    _neighborSaveTimer?.cancel();
    _neighborSaveTimer = null;
    await _discovery?.stop();
    _server?.close();
    for (final socket in _outbound.values.toList()) {
      try {
        socket.destroy();
      } catch (_) {}
    }
    _outbound.clear();
    if (_neighborsDirty) {
      _neighborsDirty = false;
      _queueSave();
    }
    await _serial?.dispose();
    _serial = null;
    await _saveChain; // flush any pending write before we return
  }
}
