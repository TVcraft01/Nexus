import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ChangeNotifier, debugPrint;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../core/crypto.dart';
import '../core/identity.dart';
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
  String address;
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
    this.lastVerified,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'platform': platform,
        'address': address,
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

/// One entry in the clipboard tray.
class ClipEntry {
  final String id;
  final String text;
  final String? fromName; // null = copied on this device
  final DateTime ts;
  const ClipEntry({required this.id, required this.text, required this.fromName, required this.ts});

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'fromName': fromName,
        'ts': ts.toIso8601String(),
      };

  factory ClipEntry.fromJson(Map<String, dynamic> json) => ClipEntry(
        id: json['id'] as String,
        text: json['text'] as String,
        fromName: json['fromName'] as String?,
        ts: DateTime.tryParse(json['ts'] as String? ?? '') ?? DateTime.now(),
      );
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
  }) : clipboard = clipboard ?? _RealClipboard();

  /// How old a verified contact may be before a device is shown offline.
  /// Configurable so tests can use short windows instead of waiting 25s.
  final Duration onlineWindow;
  final Duration visibleWindow;
  final Duration heartbeatInterval;

  final Map<String, PairedDevice> _paired = {};
  final Map<String, DiscoveredDevice> _nearby = {};
  final Map<String, DateTime> _verified = {}; // TCP-verified, by device id
  final Map<String, DateTime> _lastSeen = {}; // any hello/ping, by device id

  final Map<String, Socket> _outbound = {}; // peerId -> send socket
  final Map<Socket, String> _inboundPeer = {}; // socket -> peerId
  final Map<String, Uint8List> _sessionKeys = {}; // peerId -> cached key
  final Set<String> _recentMessageIds = {}; // dedupe across multi-hop relays

  final List<ClipEntry> clipTray = [];
  ClipEntry? lastIncomingClip;

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

  List<DiscoveredDevice> get nearbyDevices {
    final list = _nearby.values.toList()..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    return list;
  }

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
    _loadPaired();
    _loadClipTray();
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

  void _loadClipTray() {
    clipTray
      ..clear()
      ..addAll(store.clipTray.map(ClipEntry.fromJson));
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
    try {
      final socket = await Socket.connect(peer.address, peer.port, timeout: const Duration(seconds: 4));
      _outbound[peer.id] = socket;
      _inboundPeer[socket] = peer.id; // so replies on this socket are attributed
      _onClientSocket(socket);
      return socket;
    } catch (_) {
      return null;
    }
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
        _noteSeen(msg.from, verified: true);
        debugPrint('NEXUS mesh: ping <- ${msg.from} from ${socket.remoteAddress.address}');
        if (port != null) {
          await _learnAddress(msg.from, socket.remoteAddress.address, port, name, payload['platform'] as String? ?? 'other');
        }
        _sendPlain(
          socket,
          NexusMessage(
            type: NexusMessage.pong,
            from: identity.id,
            to: msg.from,
            payload: {'name': identity.name, 'platform': identity.platform, 'port': store.port},
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
        if (port != null && name != null) {
          await _learnAddress(msg.from, socket.remoteAddress.address, port, name, payload['platform'] as String? ?? 'other');
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
    }
  }

  void _noteSeen(String id, {required bool verified}) {
    final now = DateTime.now();
    _lastSeen[id] = now;
    if (verified) _verified[id] = now;
  }

  Future<void> _learnAddress(String id, String address, int port, String name, String platform) async {
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
          payload: {'name': identity.name, 'platform': identity.platform, 'port': store.port},
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
    store.removePaired(id);
    await store.save();
    notifyListeners();
  }

  Future<void> renameDevice(String name) async {
    store.setIdentity(identity.copyWith(name: sanitizeDeviceName(name)));
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

  /// Share [text] to every paired device that is reachable, and record it
  /// in this device's own tray.
  Future<int> broadcastClipboard(String text) async {
    final entry = ClipEntry(
      id: _newId(),
      text: text,
      fromName: null,
      ts: DateTime.now(),
    );
    clipTray.insert(0, entry);
    store.addClip(entry.toJson());
    await store.save();

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
    final fromName = (msg.payload['fromName'] as String?) ?? 'Another device';
    final entry = ClipEntry(id: _newId(), text: text, fromName: fromName, ts: DateTime.now());
    clipTray.insert(0, entry);
    store.addClip(entry.toJson());
    await store.save();

    if (store.autoApplyClipboard) {
      _lastClipboard = text;
      await clipboard.writeText(text);
    }
    lastIncomingClip = entry;
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
