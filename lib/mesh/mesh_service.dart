import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ChangeNotifier, debugPrint;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:path_provider/path_provider.dart' show getApplicationDocumentsDirectory;

import '../core/crypto.dart';
import '../core/identity.dart';
import '../core/network_info.dart';
import '../core/pair_payload.dart';
import '../core/protocol.dart';
import '../core/store.dart';
import 'discovery.dart';

/// A device that has been paired with us. "Paired" means we share a secret
/// (the pairing code) and can talk to each other encrypted.
class PairedDevice {
  final String id;
  String name;
  final String platform;

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
  const PairingSession({required this.code, required this.qrPayload, required this.expiresAt});
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
  RandomAccessFile? sink;
  String savedPath = '';
  int received = 0;
  int total = 0;
  Timer? watchdog;
  Future<void> chain = Future.value();

  _FilePush({required this.name, required this.dir, required this.peerName});
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
  Future<void> writeText(String text) => Clipboard.setData(ClipboardData(text: text));
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

  final Map<String, Completer<List<FileEntry>?>> _pendingLists = {}; // req -> list
  final Map<String, _FilePull> _pendingPulls = {}; // req -> download state
  final Map<String, _FilePush> _incomingPushes = {}; // req -> upload state
  final Map<String, Completer<String?>> _outgoingPushes = {}; // req -> saved path on peer

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
  String? _lastClipboard;
  bool _started = false;

  int get port => store.port;

  List<PairedDevice> get pairedDevices => _paired.values.toList();

  /// Devices heard from recently. Anything older than [nearbyWindow] is
  /// dropped — a device that stopped announcing is gone, not a ghost.
  List<DiscoveredDevice> get nearbyDevices {
    final cutoff = DateTime.now().subtract(nearbyWindow);
    _nearby.removeWhere((_, d) => d.lastSeen.isBefore(cutoff));
    final list = _nearby.values.toList()..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
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
    _clipboardTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) => _checkClipboard());
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
      lastNotice = 'Port $defaultPort was busy — Nexus is using port ${_server!.port}.';
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
    if (existing == null || device.port != existing.port || device.name != existing.name) {
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
        !known.any((k) => k.address == device.address && k.port == device.port)) {
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
      msg = NexusMessage.fromJson(jsonDecode(utf8.decode(clear)) as Map<String, dynamic>);
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
      msg = NexusMessage.fromJson(jsonDecode(utf8.decode(clear)) as Map<String, dynamic>);
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
        final socket = await Socket.connect(address, peer.port, timeout: connectTimeout);
        _outbound[peer.id] = socket;
        _inboundPeer[socket] = peer.id; // so replies on this socket are attributed
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

  Future<void> _handleMessage(NexusMessage msg, Socket socket, {required bool encrypted}) async {
    _remember(msg.id);

    switch (msg.type) {
      case NexusMessage.ping:
        // A ping proves reachability and tells us who is talking; attribute
        // the socket so later encrypted frames on it are recognized.
        if (_paired.containsKey(msg.from)) {
          _inboundPeer[socket] = msg.from;
        }
        final payload = msg.payload;
        final name = payload['name'] as String? ?? 'Unknown device';
        final port = (payload['port'] as num?)?.toInt();
        final ips = (payload['ips'] as List?)?.whereType<String>().toList();
        _noteSeen(msg.from, verified: true);
        debugPrint('NEXUS mesh: ping <- ${msg.from} from ${socket.remoteAddress.address}');
        if (port != null) {
          await _learnAddress(msg.from, socket.remoteAddress.address, port, name, payload['platform'] as String? ?? 'other', ips: ips);
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
              'port': store.port,
              'ips': await _myIps(),
            },
            id: _newId(),
            ts: DateTime.now().millisecondsSinceEpoch,
          ),
        );

      case NexusMessage.pong:
        _noteSeen(msg.from, verified: true);
        debugPrint('NEXUS mesh: pong <- ${msg.from}');
        final payload = msg.payload;
        final name = payload['name'] as String?;
        final port = (payload['port'] as num?)?.toInt();
        final ips = (payload['ips'] as List?)?.whereType<String>().toList();
        if (port != null && name != null) {
          await _learnAddress(msg.from, socket.remoteAddress.address, port, name, payload['platform'] as String? ?? 'other', ips: ips);
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

      case NexusMessage.fileError:
        if (!encrypted) return;
        await _handleFileError(msg);
    }
  }

  // ---------------------------------------------------------------------
  // Remote file access (encrypted, served from this device's home folder)
  // ---------------------------------------------------------------------

  /// The folder this device serves. Desktop: the home directory. Android:
  /// the app's documents dir (the interesting files live on the PC anyway).
  /// Tests inject their own root.
  Future<String> _servedRoot() async {
    if (fileRoot != null) return fileRoot!;
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) return home;
    final profile = Platform.environment['USERPROFILE'];
    if (profile != null && profile.isNotEmpty) return profile;
    final dir = await getApplicationDocumentsDirectory();
    return dir.path;
  }

  /// Maps a peer-supplied path onto the served root, collapsing `.`/`..` and
  /// refusing anything that escapes the root. Returns null = access denied.
  String? _resolveServedPath(String path, String root) {
    final clean = _normalizePath(path);
    if (clean.isEmpty || clean == '/') return root;
    if (clean != root && !clean.startsWith('$root${Platform.pathSeparator}')) {
      return null;
    }
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
    final prefix = path.startsWith(Platform.pathSeparator) ? Platform.pathSeparator : '';
    return prefix + parts.join(Platform.pathSeparator);
  }

  Future<void> _handleFileListRequest(NexusMessage msg) async {
    final req = msg.payload['req'];
    final peer = _paired[msg.from];
    if (peer == null || req is! String) return;
    final path = msg.payload['path'] as String? ?? '';
    final root = await _servedRoot();
    final resolved = _resolveServedPath(path, root);
    if (resolved == null) {
      await _sendFileError(peer, req, 'Access denied — that folder is outside your home directory.');
      return;
    }
    final entries = await _listDir(resolved);
    if (entries == null) {
      await _sendFileError(peer, req, lastFileError ?? 'Could not read that folder.');
      return;
    }
    await _sendEnc(peer, NexusMessage(
      type: NexusMessage.fileListResult,
      from: identity.id,
      to: peer.id,
      payload: {
        'req': req,
        'entries': entries
            .map((e) => {
                  'name': e.name,
                  'path': e.path,
                  'size': e.size,
                  'dir': e.isDir,
                  'modified': e.modified.toIso8601String(),
                })
            .toList(),
      },
      id: _newId(),
      ts: DateTime.now().millisecondsSinceEpoch,
    ));
  }

  /// Lists [resolved] (a path already validated against the served root),
  /// skipping unreadable entries. Returns null on failure — [lastFileError]
  /// says why. Shared by remote list requests and local "This device" browsing.
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
          final segments =
              child.path.split(Platform.pathSeparator).where((s) => s.isNotEmpty).toList();
          listed.add(FileEntry(
            name: segments.isEmpty ? child.path : segments.last,
            path: child.path,
            size: isDir ? 0 : stat.size,
            isDir: isDir,
            modified: stat.modified,
          ));
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
    if (resolved == null) {
      await _sendFileError(peer, req, 'Access denied — that file is outside your home directory.');
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
      // Stream in 256 KiB chunks — small enough to stay well under the 1 MiB
      // frame guard, large enough that big files don't become a message zoo.
      const chunkSize = 256 * 1024;
      var offset = 0;
      while (true) {
        final data = await raf.read(chunkSize);
        final done = offset + data.length >= total;
        final ok = await _sendEnc(peer, NexusMessage(
          type: NexusMessage.fileChunk,
          from: identity.id,
          to: peer.id,
          payload: {
            'req': req,
            'offset': offset,
            'data': base64Encode(data),
            'total': total,
            'done': done,
          },
          id: _newId(),
          ts: DateTime.now().millisecondsSinceEpoch,
        ));
        if (!ok) break; // peer went away mid-transfer
        offset += data.length;
        if (done) break;
      }
    } catch (_) {
      await _sendFileError(peer, req, 'The file changed while reading it.');
    } finally {
      await raf.close();
    }
  }

  Future<void> _sendFileError(PairedDevice peer, String req, String message) async {
    lastFileError = message;
    await _sendEnc(peer, NexusMessage(
      type: NexusMessage.fileError,
      from: identity.id,
      to: peer.id,
      payload: {'req': req, 'message': message},
      id: _newId(),
      ts: DateTime.now().millisecondsSinceEpoch,
    ));
  }

  Future<void> _handleFileListResult(NexusMessage msg) async {
    final req = msg.payload['req'];
    final completer = req is String ? _pendingLists.remove(req) : null;
    if (completer == null) return;
    final raw = (msg.payload['entries'] as List?) ?? const [];
    final entries = raw.whereType<Map<String, dynamic>>().map((e) => FileEntry(
          name: e['name'] as String? ?? '?',
          path: e['path'] as String? ?? '',
          size: (e['size'] as num?)?.toInt() ?? 0,
          isDir: e['dir'] == true,
          modified: DateTime.tryParse(e['modified'] as String? ?? '') ??
              DateTime.fromMillisecondsSinceEpoch(0),
        )).toList();
    if (!completer.isCompleted) completer.complete(entries);
  }

  Future<void> _handleFileChunk(NexusMessage msg) async {
    final req = msg.payload['req'];
    final pull = req is String ? _pendingPulls[req] : null;
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
        _failPull(req, 'The transfer stalled — the connection to ${pull.peerName} was lost.');
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
    final req = msg.payload['req'];
    final peer = _paired[msg.from];
    if (peer == null || req is! String) return;
    var push = _incomingPushes[req];
    if (push == null) {
      final name = (msg.payload['name'] as String?) ?? '';
      if (!_safeIncomingName(name)) {
        await _sendFileError(peer, req, 'Refused file with an invalid name.');
        return;
      }
      final root = await _servedRoot();
      final dir = '$root${Platform.pathSeparator}Nexus Incoming';
      push = _FilePush(name: name, dir: dir, peerName: peer.name);
      _incomingPushes[req] = push;
    }
    final active = push;
    active.chain = active.chain.then((_) => _applyPushChunk(active, peer, req, msg));
    await active.chain.catchError((_) {});
  }

  Future<void> _applyPushChunk(
      _FilePush push, PairedDevice peer, String req, NexusMessage msg) async {
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
        _failPush(peer, req, 'The transfer stalled — the connection to ${push.peerName} was lost.');
      });
      if (done) {
        await push.sink!.flush();
        await push.sink!.close();
        push.sink = null;
        push.watchdog?.cancel();
        _incomingPushes.remove(req);
        await _sendEnc(peer, NexusMessage(
          type: NexusMessage.filePushAck,
          from: identity.id,
          to: peer.id,
          payload: {'req': req, 'path': push.savedPath},
          id: _newId(),
          ts: DateTime.now().millisecondsSinceEpoch,
        ));
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
    var path = '${push.dir}${Platform.pathSeparator}${push.name}';
    var n = 1;
    while (File(path).existsSync()) {
      path = '${push.dir}${Platform.pathSeparator}'
          '${push.name.replaceFirst(RegExp(r'(\.[^.]*)?$'), ' ($n)\$1')}';
      n++;
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
    final message = (msg.payload['message'] as String?) ?? 'The device refused the request.';
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
  }

  Future<void> _handleFilePushAck(NexusMessage msg) async {
    final req = msg.payload['req'];
    final completer = req is String ? _outgoingPushes.remove(req) : null;
    if (completer == null) return;
    final saved = msg.payload['path'] as String?;
    if (!completer.isCompleted) completer.complete(saved);
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
  Future<List<FileEntry>?> listRemoteFiles(PairedDevice peer, String path) async {
    final req = _newId();
    final completer = Completer<List<FileEntry>?>();
    _pendingLists[req] = completer;
    final sent = await _sendEnc(peer, NexusMessage(
      type: NexusMessage.fileList,
      from: identity.id,
      to: peer.id,
      payload: {'req': req, 'path': path},
      id: _newId(),
      ts: DateTime.now().millisecondsSinceEpoch,
    ));
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
    final pull = _FilePull(savePath: savePath, onProgress: onProgress, peerName: peer.name);
    _pendingPulls[req] = pull;
    // Watchdog covers the whole transfer: waiting for the first chunk counts
    // too, and any chunk resets it.
    pull.watchdog = Timer(const Duration(seconds: 15), () {
      _failPull(req, 'Timed out waiting for ${peer.name}.');
    });
    final sent = await _sendEnc(peer, NexusMessage(
      type: NexusMessage.fileGet,
      from: identity.id,
      to: peer.id,
      payload: {'req': req, 'path': path},
      id: _newId(),
      ts: DateTime.now().millisecondsSinceEpoch,
    ));
    if (!sent) {
      _failPull(req, 'Could not reach ${peer.name}.');
    }
    return pull.done.future;
  }

  /// Lists a folder on this device's own served root — what the Files tab
  /// shows when browsing "This device". Same sandbox rules as remote requests.
  Future<List<FileEntry>?> listLocalFiles(String path) async {
    final root = await _servedRoot();
    final resolved = _resolveServedPath(path, root);
    if (resolved == null) {
      lastFileError = 'Access denied — that folder is outside your home directory.';
      return null;
    }
    return _listDir(resolved);
  }

  /// Streams a local file (browsed via [listLocalFiles]) to [peer] over the
  /// encrypted mesh. The peer writes it into its "Nexus Incoming" folder and
  /// acks when every chunk has landed; returns the path it was saved to on
  /// the peer, or null on failure — [lastFileError] says why.
  Future<String?> pushLocalFile(
    PairedDevice peer,
    String localPath, {
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
        final ok = await _sendEnc(peer, NexusMessage(
          type: NexusMessage.filePush,
          from: identity.id,
          to: peer.id,
          payload: {
            'req': req,
            if (first) 'name': name,
            'offset': offset,
            'data': base64Encode(data),
            'total': total,
            'done': done,
          },
          id: _newId(),
          ts: DateTime.now().millisecondsSinceEpoch,
        ));
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
      if (peer.name != name) {
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
        targets.putIfAbsent(device.id, () => PairedDevice(
              id: device.id,
              name: device.name,
              platform: device.platform,
              address: device.address,
              port: device.port,
              pairingSecret: '',
            ));
      }
      for (final peer in targets.values) {
        final msg = NexusMessage(
          type: NexusMessage.ping,
          from: identity.id,
          to: peer.id,
          payload: {
            'name': identity.name,
            'platform': identity.platform,
            'port': store.port,
            'ips': await _myIps(),
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
    return pendingCode != null && expiry != null && DateTime.now().isBefore(expiry);
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
      payload: {'name': identity.name, 'platform': identity.platform, 'port': store.port},
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
      socket = await Socket.connect(address, port, timeout: const Duration(seconds: 6));
    } catch (_) {
      return PairResult.failure('Could not reach $address:$port. Is that device on and on the same network?');
    }

    final completer = Completer<PairResult>();
    final request = NexusMessage(
      type: NexusMessage.pairRequest,
      from: identity.id,
      payload: {'name': identity.name, 'platform': identity.platform, 'port': store.port},
      id: _newId(),
      ts: DateTime.now().millisecondsSinceEpoch,
    );

    String? pendingEnc;
    try {
      pendingEnc = await encryptToB64(encodeJson(request.toJson()), key);
    } catch (e) {
      socket.destroy();
      return PairResult.failure('Something went wrong preparing the pairing request.');
    }

    final decoder = FrameDecoder();
    final timeout = Timer(const Duration(seconds: 12), () {
      if (!completer.isCompleted) {
        completer.complete(PairResult.failure('No answer from the device. Double-check the code and that it is still showing.'));
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
          final msg = NexusMessage.fromJson(jsonDecode(utf8.decode(clear)) as Map<String, dynamic>);
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
              completer.complete(PairResult.failure((msg.payload['reason'] as String?) ?? 'The device rejected the pairing.'));
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
        if (!completer.isCompleted) completer.complete(PairResult.failure('Connection was lost during pairing.'));
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete(PairResult.failure('Connection closed before pairing finished.'));
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

  // ---------------------------------------------------------------------
  // Clipboard everywhere
  // ---------------------------------------------------------------------

  Future<void> _checkClipboard() async {
    if (!store.clipboardSync) return;
    final text = await clipboard.readText();
    if (text == null) return;
    if (text == _lastClipboard) return;
    _lastClipboard = text;
    await broadcastClipboard(text);
  }

  /// Share [text] to every paired device that is reachable.
  Future<int> broadcastClipboard(String text) async {
    var sent = 0;
    for (final peer in _paired.values.toList()) {
      final msg = NexusMessage(
        type: NexusMessage.clipboard,
        from: identity.id,
        to: peer.id,
        payload: {'text': text, 'fromName': identity.name},
        id: _newId(),
        ts: DateTime.now().millisecondsSinceEpoch,
      );
      if (await _sendEnc(peer, msg)) {
        sent++;
        debugPrint('NEXUS mesh: clipboard -> ${peer.id}');
      } else {
        debugPrint('NEXUS mesh: clipboard FAILED -> ${peer.id} (${peer.address}:${peer.port})');
      }
    }
    notifyListeners();
    return sent;
  }

  Future<void> _handleIncomingClip(NexusMessage msg) async {
    final text = msg.payload['text'];
    if (text is! String || text.isEmpty) return;
    // Ignore echoes of something this device already copied.
    if (text == _lastClipboard) return;

    debugPrint('NEXUS mesh: clipboard <- ${msg.from}');

    if (store.clipboardSync) {
      _lastClipboard = text;
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
    await _saveChain; // flush any pending write before we return
  }
}
