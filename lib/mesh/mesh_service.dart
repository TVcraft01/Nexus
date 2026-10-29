import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show
        ChangeNotifier,
        TargetPlatform,
        debugPrint,
        defaultTargetPlatform,
        visibleForTesting;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../core/agent_contract.dart';
import '../core/brain.dart';
import '../core/capability.dart' show defaultCapabilitiesFor;
import '../core/capability_probe.dart';
import '../core/command_interpreter.dart';
import '../core/relay_client.dart';
import '../core/crypto.dart';
import '../core/file_fetch.dart';
import '../core/identity.dart';
import '../core/memory.dart';
import '../core/network_info.dart';
import '../core/pair_payload.dart';
import '../core/qr_pairing.dart';
import '../core/protocol.dart';
import '../core/query_log.dart';
import '../core/serial_transport.dart';
import '../core/storage_roots.dart' as storage;
import '../core/store.dart';
import '../core/version.dart';
import '../core/watchdog_latch.dart';
import 'connection_supervisor.dart';
import 'connectivity_monitor.dart';
import 'discovery.dart';
import 'mesh_transport.dart';
import 'serial_bridge.dart';
import 'sync_service.dart';

part 'mesh_pairing.dart';
part 'mesh_relay.dart';

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

  /// Hardware and service claims received through mesh presence. Empty plus
  /// [capabilitiesAnnounced] distinguishes "the peer said none" from a legacy
  /// peer that has never sent a capability list.
  Set<String> announcedCaps;
  bool capabilitiesAnnounced;
  bool announcedCapsVerified;

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
    Set<String>? announcedCaps,
    this.capabilitiesAnnounced = false,
    this.announcedCapsVerified = false,
  }) : addresses = addresses ?? [address],
       announcedCaps = announcedCaps ?? <String>{};

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
    'announcedCaps': announcedCaps.toList()..sort(),
    'capabilitiesAnnounced': capabilitiesAnnounced,
    'announcedCapsVerified': announcedCapsVerified,
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
    announcedCaps:
        (json['announcedCaps'] as List?)
            ?.whereType<String>()
            .where((value) => value.isNotEmpty)
            .toSet() ??
        <String>{},
    capabilitiesAnnounced: json['capabilitiesAnnounced'] == true,
    announcedCapsVerified: json['announcedCapsVerified'] == true,
  );
}

/// Result of an attempted pairing.
class PairResult {
  final bool ok;
  final String? error;
  final String? peerName;

  /// True once the device answered the TCP connection — the address was
  /// right even if the handshake then failed (a wrong or expired code, say).
  /// No other advertised address can fix that, so callers stop trying them.
  final bool reached;

  const PairResult.ok(this.peerName) : ok = true, error = null, reached = true;
  const PairResult.failure(this.error, {this.reached = false})
    : ok = false,
      peerName = null;
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

/// A clipboard message that arrived from another device — the pending slot.
///
/// The safety rule is that a push never touches this device's clipboard on
/// its own: plain text waits here until the user taps paste, and only an
/// auto-accept payload ([isClipboardAutoAccept]) is applied immediately.
/// v1 is current-only — one slot, never persisted.
class ClipEntry {
  final String text;
  final String? fromName;
  final String? fromId;

  /// True when the payload matched an auto-accept pattern and was already
  /// written to the local clipboard — the UI toasts instead of showing the
  /// paste pill.
  final bool autoAccepted;
  const ClipEntry({
    required this.text,
    required this.fromName,
    this.fromId,
    this.autoAccepted = false,
  });
}

/// Whether a pushed clipboard payload may apply itself without a tap.
///
/// OTPs (6–8 digits) and URLs (http/https) are typed or opened on sight
/// anyway — holding a 2FA code for a tap is what lets it expire. Everything
/// else waits for the explicit gate ([MeshService.acceptPendingClipboard]).
bool isClipboardAutoAccept(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return false;
  if (RegExp(r'^\d{6,8}$').hasMatch(trimmed)) return true;
  final lower = trimmed.toLowerCase();
  return lower.startsWith('http://') || lower.startsWith('https://');
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

/// One action a paired peer asked this device to run, as it arrived.
///
/// The type exists to make the reply non-optional. The sender registers a
/// completer before it sends and waits fifteen seconds for `agent.result`, so a
/// receiver that handles a request and forgets to answer leaves the other
/// person's screen with nothing to say about a thing it may well have done. The
/// only ways to handle one — [resolveWith] and [refuse] — both end in a reply,
/// and [resolveWith] answers even when the body throws.
///
/// It carries the two decisions rather than leaving them to the caller, because
/// both are facts about this frame and this session that only the mesh knows:
/// [trusted] (it arrived encrypted, from a paired peer, on this session's key)
/// and [policy] (what the user has said this device accepts for this action).
class IncomingAgentAction {
  /// [reply] is the wire back to the sender, first and positional because
  /// nothing about this type is usable without it — the rest of the arguments
  /// say what the request *is*, and this one is what makes it answerable.
  IncomingAgentAction(
    this._reply, {
    required this.from,
    required this.request,
    required this.trusted,
    required this.policy,
  });

  /// The peer that sent it — the id the channel proved, never a claimed one.
  final String from;

  final AgentRequest request;

  /// True only for a frame that satisfied every condition in
  /// [MeshService.agentFrameProven]. 'auto' is refused without it.
  final bool trusted;

  /// What this device accepts for [request.action], as stored: `ask` unless the
  /// user said otherwise.
  final AgentPolicy policy;

  final Future<bool> Function(String requestId, AgentDispatchResult result)
  _reply;

  /// Runs [body] and answers the sender whatever happens.
  ///
  /// The reply is not a courtesy: it is what the sender's completer is waiting
  /// for, and the sender is a person looking at a screen. So a throw from the
  /// body becomes [AgentResultStatus.unavailable] with the reason in it rather
  /// than silence, and the reply is sent on every path out of here.
  Future<AgentDispatchResult> resolveWith(
    Future<AgentDispatchResult> Function() body,
  ) async {
    AgentDispatchResult result;
    try {
      result = await body();
    } catch (error) {
      result = AgentDispatchResult(
        status: AgentResultStatus.unavailable,
        message: 'This device could not run that: $error',
      );
    }
    await _reply(request.requestId, result);
    return result;
  }

  /// Answers without running anything, in [message]'s words.
  Future<AgentDispatchResult> refuse(String message) => resolveWith(
    () async =>
        AgentDispatchResult(status: AgentResultStatus.denied, message: message),
  );
}

/// The mesh: one service per device that owns the TCP server, discovery,
/// presence, pairing, and encrypted messaging.
///
/// Honest-presence rule: a device is "online" only when we have received a
/// direct, verified message from it over TCP within the last 25 seconds.
/// Discovery announcements are never enough — they only make a device
/// *visible*, and the UI says so.
abstract class _MeshBase extends ChangeNotifier
    implements FileFetchMesh, MeshTransport, MeshNearbySource {
  final DeviceInfo identity;
  final NexusStore store;
  final ClipboardBackend clipboard;
  final CapabilityProbe _capabilityProbe;
  Future<Set<String>>? _localCapsFuture;

  _MeshBase({
    required this.identity,
    required this.store,
    ClipboardBackend? clipboard,
    this.onlineWindow = const Duration(seconds: 25),
    this.visibleWindow = const Duration(seconds: 12),
    this.heartbeatInterval = const Duration(seconds: 8),
    this.nearbyWindow = const Duration(seconds: 60),
    this.connectTimeout = const Duration(seconds: 5),
    this.latchWatchdog = const Duration(seconds: 90),
    this.fileRoot,
    CapabilityProbe? capabilityProbe,
  }) : clipboard = clipboard ?? _RealClipboard(),
       _capabilityProbe = capabilityProbe ?? RealCapabilityProbe();

  /// How long to wait per address before falling back to the next one.
  /// Configurable so tests can exercise address fallback quickly.
  final Duration connectTimeout;

  /// How long a presence exchange or a clipboard flush may stay "in flight"
  /// before its latch lets go by itself (see [WatchdogLatch]). Must exceed the
  /// slowest healthy pass — walking every address a peer has at
  /// [connectTimeout] each is the slow one — and stay under the supervisor's
  /// own retry cadence, so a stuck exchange swallows at most one retry.
  /// Configurable so a test can watch the latch expire without waiting 90 s.
  final Duration latchWatchdog;

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
  final Map<String, String> _controlKeys = {}; // peerId -> cached control key
  final Set<String> _recentMessageIds = {}; // dedupe across multi-hop relays

  /// The one pending clipboard slot: a peer's push waiting for the user's
  /// tap, or an auto-accepted OTP/URL the UI toasts about. Null when
  /// nothing is waiting.
  ClipEntry? lastIncomingClip;

  /// Why the last file request failed ("could not reach", "access denied",
  /// timeouts). Read by the Files UI to show an honest error, and by the
  /// file-fetch seam ([FileFetchMesh]) to tell a local save failure apart
  /// from a transfer one.
  @override
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

  TailscaleInfo? _tailscale;
  // Relay integration is staged (see relay/); the client is wired once the
  // server is deployed. Kept as a field so wiring it up has one owner.
  // ignore: unused_field
  late final RelayClient _relay;


  String? lastNotice; // honest operational notices ("port was busy, using X")

  ServerSocket? _server;
  DiscoveryService? _discovery;
  Timer? _heartbeatTimer;
  Timer? _clipboardTimer;
  bool _foreground = true;
  // Both latches used to be plain booleans cleared in a `finally`. That is only
  // sound while every await between the two can finish: a dial blocked inside
  // the OS left the flag set and made the mesh stop dialling for the rest of
  // the process's life. See lib/core/watchdog_latch.dart.
  late final WatchdogLatch _heartbeatLatch = WatchdogLatch(latchWatchdog);
  late final WatchdogLatch _clipboardLatch = WatchdogLatch(latchWatchdog);
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

  /// The version each peer claimed in its last presence frame, by id.
  ///
  /// Separate from [_latestPeerUpdateVersion], which is one value for the
  /// whole mesh because the update banner only cares about the newest. The
  /// metering line for an unsigned control request needs to name *this* peer's
  /// version, and a single shared value would credit every peer with whichever
  /// one happened to speak last.
  final Map<String, String> _peerVersions = {};
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

  /// The last `up` payload relayed from a remote (or local) cable node:
  /// `{from, name, data}`. Read by the UI to show what a node reported.
  Map<String, dynamic>? lastSerialUp;



  /// Fired when a paired device teaches a phrase and syncs it here. The view
  /// wires this into the live [CommandService] so the learned meaning is
  /// usable immediately, not only after a restart. Receivers never re-broadcast
  /// — that would loop the mesh forever.
  /// [from] names the peer that sent it, so the memory keeps a real source
  /// ("this came from TVcraft's phone") instead of a vague "a device".
  void Function(String phrase, String meaning, [String from])?
  onLearnedPhraseReceived;

  /// Fired when a paired device tells the assistant a fact and syncs it here.
  /// The view wires this into the live [CommandService] so the fact is usable
  /// immediately. Receivers never re-broadcast — that would loop the mesh.
  ///
  /// Ownership rule: inbound knowledge is persisted by whoever claims it. When
  /// this (or [onLearnedPhraseReceived]) is attached, the mesh only delivers
  /// and the live assistant's own persistence funnel writes the store — never
  /// both. When nobody is listening (startup window, headless mesh), the mesh
  /// writes the store itself so the knowledge survives for the next boot.
  void Function(String fact, [String from])? onFactReceived;

  /// Fired when a paired device sets a reminder and syncs it here, so the
  /// assistant on THIS device reminds the user too — whoever they are near.
  /// Same ownership rule as [onFactReceived]: with a listener attached, the
  /// live assistant's own funnel writes the store; otherwise the mesh
  /// persists the reminder itself so it survives for the next boot.
  void Function(String line)? onReminderReceived;

  /// Fired when a paired device answers a "which …?" question and syncs the
  /// remembered default here. Same ownership rule as [onFactReceived]: with
  /// a listener attached, the live assistant's own funnel writes the store;
  /// otherwise the mesh persists it so it survives for the next boot.
  void Function(String key, dynamic value, [String from])? onDefaultReceived;

  /// Fired when a paired device renames the user or the assistant and syncs
  /// the profile here, so every device answers as one person. Same
  /// ownership rule as [onFactReceived].
  void Function(String? userName, String? assistantName)? onProfileReceived;


  List<SerialDevice> get remoteSerialDevices {
    final now = DateTime.now();
    final out = <SerialDevice>[];
    for (final entry in _serialHosts.entries) {
      final host = _paired[entry.value];
      if (host == null) continue; // host forgotten — drop the relay
      out.add(
        SerialDevice(
          id: entry.key,
          name: _serialNames[entry.key] ?? entry.key,
          port: 'remote:${entry.value}',
          caps: _serialCaps[entry.key] ?? const ['ping', 'msg'],
          lastSeen: now,
        ),
      );
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
  ///
  /// This is best-effort — Android's USB stack can be temperamental during
  /// cold starts. If it fails the app keeps running; the user can still open
  /// the cable pair page later to retry.
  Future<SerialBridge?> ensureSerialBridge() async {
    if (_serial != null) {
      try {
        await _serial!.startScan();
      } catch (_) {}
      return _serial;
    }
    SerialTransport? transport;
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        transport = AndroidUsbSerialTransport.defaultInstance();
      } else if (defaultTargetPlatform == TargetPlatform.linux) {
        transport = LinuxSerialTransport();
      }
    } catch (_) {
      return null;
    }
    if (transport == null) return null;
    final bridge = SerialBridge(
      transport: transport,
      onChanged: notifyListeners,
      // A node on our cable reported something — relay it to whichever peer
      // asked (multi-hop), or note it locally.
      onUp: _relaySerialUp,
      loadKnown: _knownSerialDevices,
      saveKnown: _saveKnownSerialDevices,
    );
    _serial = bridge;
    try {
      await bridge.startScan();
    } catch (_) {
      // startScan failed — the bridge is registered but has no open ports.
      // The cable pair page will re-try startScan when the user opens it.
    }
    notifyListeners();
    return bridge;
  }

  /// Attaches an existing serial bridge (used by tests with a fake
  /// transport; production goes through [ensureSerialBridge]).
  Future<void> attachSerialBridge(SerialBridge bridge) async {
    _serial = bridge;
    bridge.onUp ??= _relaySerialUp;
    bridge.saveKnown ??= _saveKnownSerialDevices;
    await bridge.startScan();
    notifyListeners();
  }

  /// Serial nodes remembered from earlier runs, so a board that is unplugged
  /// at startup still shows as Disconnected.
  List<SerialDevice> _knownSerialDevices() =>
      store.knownSerialDevices.map(SerialDevice.fromJson).toList();

  void _saveKnownSerialDevices(List<SerialDevice> devices) {
    store.setKnownSerialDevices(devices.map((d) => d.toJson()).toList());
    _queueSave();
  }


  /// Confirms a serial node as paired (persists its state on the node).
  Future<void> pairSerialDevice(String id) async {
    await _serial?.pair(id);
  }

  // ---------------------------------------------------------------------
  // The distributed brain
  // ---------------------------------------------------------------------

  /// The local brain this device answers delegated questions with — set on
  /// devices with their own strong model (desktops). Never a
  /// [DistributedBrain]: distributed brains ASK, strong local brains
  /// ANSWER, or a delegated question would bounce between devices forever.
  /// Also advertised in ping/pong, so peers can find who to escalate to.
  LocalBrain? brain;

  /// deviceId → whether it advertises a local brain of its own.
  final Map<String, bool> _peerHasBrain = {};

  /// Probed hardware/service facilities plus static action ids from the
  /// platform capability registry. Unknown platforms contribute no defaults.
  Future<Set<String>> _localCapabilities() => _localCapsFuture ??= () async {
    final probed = await _capabilityProbe.probe();
    try {
      final platformCapabilities = defaultCapabilitiesFor(identity.platform);
      return <String>{
        ...probed,
        for (final capability in platformCapabilities) capability.id,
      };
    } catch (_) {
      return Set<String>.of(probed);
    }
  }();

  /// The canonical string ids a peer is told about in every presence frame.
  Future<List<String>> _capabilityAnnouncement() async {
    final capabilities = await _localCapabilities();
    return capabilities.toList()..sort();
  }

  bool peerHasBrain(String id) => _peerHasBrain[id] ?? false;

  /// Whether a peer's capability list arrived authenticated by its pair key.
  @visibleForTesting
  bool peerCapsVerified(String id) =>
      _paired[id]?.announcedCapsVerified ?? false;

  /// Paired devices that advertise a local brain, in pairing order — the
  /// escalation targets for [DistributedBrain].
  List<String> get brainPeerIds => [
    for (final id in _paired.keys)
      if (peerHasBrain(id)) id,
  ];

  void _notePeerBrain(String peerId, bool hasBrain) {
    if (!_paired.containsKey(peerId)) return;
    final previous = _peerHasBrain[peerId];
    if (previous == hasBrain) return;
    _peerHasBrain[peerId] = hasBrain;
    notifyListeners();
  }

  /// Stores a capability list with its authentication provenance. A missing
  /// field leaves a peer legacy; an explicit empty list suppresses defaults.
  void _notePeerCapabilities(
    String peerId,
    Object? raw, {
    required bool proven,
  }) {
    final peer = _paired[peerId];
    if (peer == null) return;
    // A missing field is a legacy peer that has never announced capabilities;
    // leave it unannounced so ResourceMap can apply its assumed platform
    // fallback. An explicit empty list is different: it suppresses fallback.
    if (raw == null) return;
    final caps = raw is List
        ? raw.whereType<String>().where((value) => value.isNotEmpty).toSet()
        : <String>{};
    // A later unproven claim, including an empty one, cannot erase or downgrade
    // a claim already authenticated by the pair key.
    if (peer.capabilitiesAnnounced && peer.announcedCapsVerified && !proven) {
      return;
    }
    final unchanged =
        peer.capabilitiesAnnounced &&
        peer.announcedCapsVerified == proven &&
        peer.announcedCaps.length == caps.length &&
        peer.announcedCaps.containsAll(caps);
    if (unchanged) return;
    peer.announcedCaps = caps;
    peer.capabilitiesAnnounced = true;
    peer.announcedCapsVerified = proven;
    store.upsertPaired(peer.toJson());
    _queueSave();
    notifyListeners();
  }




  /// Tells every paired device that the user taught [phrase] to mean
  /// [meaning] (e.g. "call tvcraft" -> "call TVcraft01 〘✘ΔτΚ⑤⑦〙"), so one
  /// teaching works on all of them. Fire-and-forget: a peer that is offline
  /// simply misses this one — the phrase stays local until the next teach.
  Future<void> broadcastLearnedPhrase(String phrase, String meaning) async {
    final peers = _paired.values.toList();
    if (peers.isEmpty) return;
    await Future.wait(
      peers.map(
        (peer) => _sendEnc(
          peer,
          NexusMessage(
            type: NexusMessage.agentLearned,
            from: identity.id,
            to: peer.id,
            payload: {'phrase': phrase, 'meaning': meaning},
            id: _newId(),
            ts: DateTime.now().millisecondsSinceEpoch,
          ),
        ),
      ),
    );
  }

  /// Tells every paired device a fact the user just told the assistant
  /// ("remember that …"), so one telling is known on all of them.
  /// Fire-and-forget, like [broadcastLearnedPhrase]: a peer that is offline
  /// misses this one until the next telling.
  Future<void> broadcastFact(String fact) async {
    final peers = _paired.values.toList();
    if (peers.isEmpty) return;
    await Future.wait(
      peers.map(
        (peer) => _sendEnc(
          peer,
          NexusMessage(
            type: NexusMessage.agentFact,
            from: identity.id,
            to: peer.id,
            payload: {'text': fact},
            id: _newId(),
            ts: DateTime.now().millisecondsSinceEpoch,
          ),
        ),
      ),
    );
  }

  /// Tells every paired device a "which …?" answer the user just picked
  /// (e.g. timer length -> "5 minutes"), so one answer works on all of
  /// them. Fire-and-forget, like [broadcastFact].
  Future<void> broadcastDefault(String key, dynamic value) async {
    final peers = _paired.values.toList();
    if (peers.isEmpty) return;
    await Future.wait(
      peers.map(
        (peer) => _sendEnc(
          peer,
          NexusMessage(
            type: NexusMessage.agentDefault,
            from: identity.id,
            to: peer.id,
            payload: {'key': key, 'value': value},
            id: _newId(),
            ts: DateTime.now().millisecondsSinceEpoch,
          ),
        ),
      ),
    );
  }

  /// Tells every paired device the user's and the assistant's names after a
  /// rename ("call me sam", first-run setup), so every device knows the
  /// person. Fire-and-forget, like [broadcastFact].
  Future<void> broadcastProfile({
    String? userName,
    String? assistantName,
  }) async {
    final peers = _paired.values.toList();
    if (peers.isEmpty) return;
    await Future.wait(
      peers.map(
        (peer) => _sendEnc(
          peer,
          NexusMessage(
            type: NexusMessage.agentProfile,
            from: identity.id,
            to: peer.id,
            payload: {'userName': userName, 'assistantName': assistantName},
            id: _newId(),
            ts: DateTime.now().millisecondsSinceEpoch,
          ),
        ),
      ),
    );
  }

  /// Tells every paired device about a reminder the user just set, so it
  /// fires on whichever device they are near. Fire-and-forget: a peer that
  /// is offline misses this one until the next setting.
  Future<void> broadcastReminder(String line) async {
    final peers = _paired.values.toList();
    if (peers.isEmpty) return;
    await Future.wait(
      peers.map(
        (peer) => _sendEnc(
          peer,
          NexusMessage(
            type: NexusMessage.agentReminder,
            from: identity.id,
            to: peer.id,
            payload: {'reminder': line},
            id: _newId(),
            ts: DateTime.now().millisecondsSinceEpoch,
          ),
        ),
      ),
    );
  }



  /// Records a session key for [id] without a handshake, for the tests that ask
  /// about [agentFrameProven] one condition at a time.
  @visibleForTesting
  void debugNoteSessionKey(String id) {
    _sessionKeys[id] = Uint8List(32);
  }

  /// Records a pairing for [id] without a handshake, for the same reason: the
  /// trust gate has three conditions and a test has to be able to pose each of
  /// them on its own.
  @visibleForTesting
  void debugNotePairedForTest(String id, {String name = 'a device'}) {
    _paired[id] = PairedDevice(
      id: id,
      name: name,
      platform: 'android',
      address: '127.0.0.1',
      port: 51820,
      pairingSecret: 'debug-pair-ABCD-2345',
    );
  }






  int get port => store.port;

  /// Tailscale status for this device, or null if Tailscale is not running.
  /// Used by the UI to show cross-network pairing availability.
  TailscaleInfo? get tailscaleInfo => _tailscale;

  String? get latestPeerUpdateVersion => _latestPeerUpdateVersion;

  /// Fills the per-peer version map without a socket.
  ///
  /// Presence is what normally writes it, and a test that had to stand up two
  /// meshes to check a label would be testing the transport instead.
  @visibleForTesting
  void debugNotePeerVersion(String peerId, String version) =>
      _notePeerVersion(peerId, version);

  /// The version [peerId] said it was running, or null when it has never said.
  ///
  /// Claimed, not proven: presence frames carry it outside the proof check.
  /// That is enough for a metering label and would not be enough for a
  /// decision.
  String? peerAppVersion(String peerId) => _peerVersions[peerId];

  /// The key that signs control requests between this device and [peerId], or
  /// null when the mesh has no pairing to derive one from.
  ///
  /// Null is the legacy case, and it is not an error: a peer that paired only
  /// through the shell (a row written by a scan before mesh pairing, or a code
  /// that carried no mesh half) shares nothing but a transfer token, and the
  /// file link keeps verifying those against its own token exactly as it did
  /// before this existed.
  Future<String?> controlKeyFor(String peerId) async {
    final peer = _paired[peerId];
    if (peer == null || peer.pairingSecret.isEmpty) return null;
    final cached = _controlKeys[peerId];
    if (cached != null) return cached;
    final key = await deriveControlKeyString(
      pairingSecret: peer.pairingSecret,
      myId: identity.id,
      peerId: peerId,
    );
    _controlKeys[peerId] = key;
    return key;
  }

  List<PairedDevice> get pairedDevices => _paired.values.toList();

  /// Probed local and static platform capabilities for a device snapshot.
  @visibleForTesting
  Future<Set<String>> debugLocalCapabilities() => _localCapabilities();

  /// Devices heard from recently. Anything older than [nearbyWindow] is
  /// dropped — a device that stopped announcing is gone, not a ghost.
  @override
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

  // --- Transport seam (mesh/mesh_transport.dart) ---------------------------
  // The connection supervisor talks to the mesh only through these members,
  // so its retry policy never touches a socket, and a second transport (a
  // BLE presence channel, a relay) can be handed to it with no change there.
  // Same shape as the file-fetch seam above: the mesh adapts itself to a
  // narrow interface over primitives it already has — no second transport is
  // built here.

  /// The peers a link could be kept alive to: paired devices, never a device
  /// that is merely visible and would need the user to pair first.
  @override
  List<TransportPeer> peers() => [
    for (final peer in _paired.values)
      TransportPeer(id: peer.id, name: peer.name),
  ];

  /// When [peerId] last proved it was there — the last time we could attribute
  /// traffic to it rather than merely write to it. Deliberately not
  /// [lastSeenAt]: that one also moves when *we* send, so it stays fresh while
  /// a dead link is being dialled, and a supervisor watching it would never
  /// notice a silent drop. This is `_verified`, which only moves for a frame
  /// the peer actually sent over its authenticated connection.
  @override
  DateTime? lastHeardAt(String peerId) => _verified[peerId];

  /// Runs one presence exchange now instead of at the next heartbeat tick:
  /// pings every peer that could answer, which also re-dials any route that
  /// died. This is the mesh's existing heartbeat on demand, so it is the
  /// supervisor's retry and its network-change fast path. Idempotent: a call
  /// while one exchange is running does nothing.
  ///
  /// Ownership, in one line: the supervisor owns *when* a paired peer is
  /// dialled — every [heartbeatInterval] while the link is up, on its backoff
  /// while it is down, at once on a network change — and this is the hand it
  /// dials with. Nothing else retries a paired peer in the background (a send
  /// the user actually asked for still dials on demand through [_sendEnc]), so
  /// the countdown the UI shows is the schedule the wire follows.
  @override
  Future<void> beat() => _heartbeat();

  /// The mesh's own periodic sweep: presence for everything no supervisor is
  /// scheduling.
  ///
  /// A *paired* peer is the supervisor's to dial, so this sweep leaves those
  /// alone (see [beat] and mesh/connection_supervisor.dart). It used not to,
  /// and the wire was then dialled on a cadence the retry curve never chose:
  /// on the 2026-10-07 device run the phone dialled a dead peer every ~30 s
  /// no matter what the countdown said, which made a supervisor reconnect
  /// indistinguishable from this sweep's next tick — the measurement could not
  /// tell them apart because both were really happening.
  ///
  /// What is left is what the supervisor deliberately does not own: a device
  /// that is merely *visible* nearby, which is not reachable at all until the
  /// user pairs it. Ghosts are pruned here too, so a sweep with nothing to
  /// dial still expires devices that stopped announcing.
  ///
  /// While no supervisor is running the sweep dials paired peers as well —
  /// the moment between [start] and its supervisor's first tick, and any mesh
  /// started without one — so this can never leave a mesh silent, it only
  /// leaves the scheduling to whoever is scheduling.
  Future<void> _presenceSweep() => _heartbeat(includeSupervised: false);

  /// Keeps every paired link alive across sleep, roam and radio changes.
  /// Started and stopped with the mesh — which is what the Android foreground
  /// service keeps running, so it reconnects with the window closed.
  ConnectionSupervisor? _supervisor;
  ConnectionSupervisor? get supervisor => _supervisor;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    await store.load();
    store.pruneStaleNeighbors(); // ghosts from an earlier session must not come back
    _loadPaired();
    await _bindServer();
    // Keep the mesh usable with the window closed: Android runs it inside a
    // foreground service that owns the multicast lock and the notification.
    // A no-op off Android (and harmless if the platform refuses).
    await SyncService.start();
    _startDiscovery();
    _heartbeatTimer = Timer.periodic(
      heartbeatInterval,
      (_) => _presenceSweep(),
    );
    _clipboardTimer = Timer.periodic(
      const Duration(milliseconds: 1500),
      (_) => _checkClipboard(),
    );
    unawaited(_presenceSweep());
    // Keep the paired links alive: noticing silence, retrying with backoff and
    // reacting to a network change are the supervisor's job (see
    // mesh/connection_supervisor.dart). It starts with the mesh, so on Android
    // it lives inside the foreground service. One supervisor for the mesh's
    // lifetime, forwarding its changes through the mesh's own notifier — the
    // channel the UI already rebuilds on, so a drop the supervisor notices in
    // seconds reaches the device row that shows it without waiting for the
    // mesh's next unrelated notification.
    var supervisor = _supervisor;
    if (supervisor == null) {
      supervisor = ConnectionSupervisor(
        transport: this,
        networkChanges: ConnectivityMonitor.changes,
      );
      supervisor.addListener(notifyListeners);
      _supervisor = supervisor;
    }
    await supervisor.start();
    // Listen for cable nodes (ESP32, …) from the start so a board plugged
    // in shows up in Devices without opening the pairing page first. On
    // Android this lists USB devices immediately; the permission prompt only
    // appears when the user actually pairs (opens a device).
    // Best-effort: the cable is a nice-to-have, not a boot requirement.
    ensureSerialBridge().catchError((_) => null);
    notifyListeners();
  }

  /// Battery: poll the clipboard fast only while someone is using the app;
  /// back off when it is backgrounded. Clipboard sync still works in the
  /// background — just with up to ~15 s of extra latency.
  void setForeground(bool foreground) {
    if (_foreground == foreground || _clipboardTimer == null) return;
    _foreground = foreground;
    _clipboardTimer!.cancel();
    _clipboardTimer = Timer.periodic(
      foreground
          ? const Duration(milliseconds: 1500)
          : const Duration(seconds: 15),
      (_) => _checkClipboard(),
    );
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

  Future<void> _bindServer() async {
    // Try the canonical port first, then the last-used port, then an
    // ephemeral one. This self-heals the case where an old ephemeral port
    // got persisted while the canonical port was temporarily busy.
    final attempts = <int>[MeshService.defaultPort, store.port];
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
          'Port ${MeshService.defaultPort} was busy — Nexus is using port '
          '${_server!.port}.';
    }
    _server!.listen(_onClientSocket);
    debugPrint('NEXUS mesh: listening on 0.0.0.0:${_server!.port}');
    // Detect Tailscale in the background so it never blocks startup.
    detectTailscaleInfo().then((info) {
      _tailscale = info;
      if (info != null && info.online) {
        debugPrint(
          'NEXUS mesh: Tailscale detected — ${info.ipv4} (${info.hostname})',
        );
      }
    });
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
    // Discovery is best-effort, but a failure here is exactly what an empty
    // Nearby list looks like — say so out loud instead of leaving the user to
    // guess, and re-check once the socket has settled.
    unawaited(
      discovery
          .start()
          .then((_) {
            final notice = discoveryNotice;
            if (notice != null) debugPrint('NEXUS mesh: $notice');
          })
          .catchError((Object e) {
            debugPrint('NEXUS mesh: discovery could not start ($e)');
          }),
    );
  }

  /// A human-readable warning when discovery cannot do its job, or null when
  /// it is healthy. An empty Nearby list should never be unexplained: a
  /// socket on a fallback port, or one that cannot send at all, is invisible
  /// to every other device while looking perfectly fine in the UI.
  String? get discoveryNotice {
    final status = _discovery?.status;
    if (status == null || status.canReceive) return null;
    return status.describe();
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

  String? _sourceAddress(Socket socket) {
    try {
      return socket.remoteAddress.address;
    } on SocketException {
      return null;
    }
  }

  void _onClientSocket(Socket socket) {
    final sourceAddress = _sourceAddress(socket);
    final decoder = FrameDecoder();
    socket.listen(
      (chunk) {
        decoder.add(chunk);
        final frames = decoder.takeFrames();
        if (frames == null) return;
        for (final frame in frames) {
          unawaited(
            _dispatchFrame(socket, frame, sourceAddress: sourceAddress),
          );
        }
      },
      onError: (_) => _dropSocket(socket),
      onDone: () => _dropSocket(socket),
    );
  }

  Future<void> _dispatchFrame(
    Socket socket,
    Uint8List frameBytes, {
    String? sourceAddress,
  }) async {
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
      await _handleEncFrame(socket, enc, sourceAddress: sourceAddress);
    } else {
      NexusMessage msg;
      try {
        msg = NexusMessage.fromJson(json);
      } catch (_) {
        return;
      }
      // A plaintext frame has no authenticated identity yet: the only ones we
      // act on (ping/pong) carry their own proof, checked where they are read.
      await _handleMessage(
        msg,
        socket,
        encrypted: false,
        sourceAddress: sourceAddress,
      );
    }
  }

  /// Handles an encrypted frame. The sending peer is identified from the
  /// socket when known, otherwise by trying each paired device's key — so a
  /// device that connects to us and speaks encrypted is attributed correctly
  /// even on its very first message. If no paired device matches, the frame
  /// might be a pairing handshake encrypted with our pending code.
  Future<void> _handleEncFrame(
    Socket socket,
    String enc, {
    String? sourceAddress,
  }) async {
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
    // The identity is the one the channel proved: the key this frame actually
    // decrypted against, or the peer this socket already belongs to. It is
    // passed down so no later code has to believe what the payload says.
    await _handleMessage(
      msg,
      socket,
      encrypted: true,
      provenId: peerId,
      sourceAddress: sourceAddress,
    );
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
    peer.addresses.forEach(add);
    // Our own addresses, so we never dial ourselves: a peer's address list
    // can contain our own LAN IP (same-host instances share every interface
    // address), and the canonical-first order below would otherwise walk
    // straight into our own listener. Cached for minutes, like the payload
    // scan, so this costs nothing per dial.
    final ownIps = await _myIps();
    for (final address in candidates) {
      for (final port in MeshService.dialPortsFor(
        storedPort: peer.port,
        loopback: _isLoopback(address),
      )) {
        // A candidate on our own mesh port is a self-connection, not a route
        // to the peer — it happens after tunnel pairing (the peer's announced
        // port matches ours and its "address" was the tunnel's local
        // endpoint) and on shared LAN IPs (same-host instances). Skip it so
        // we fall through to a real route. Any OTHER port stays: on loopback
        // it is a genuine tunnel route (adb reverse).
        if (port == store.port &&
            (_isLoopback(address) || ownIps.contains(address))) {
          continue;
        }
        try {
          final socket = await Socket.connect(
            address,
            port,
            timeout: connectTimeout,
          );
          _outbound[peer.id] = socket;
          _inboundPeer[socket] =
              peer.id; // so replies on this socket are attributed
          _onClientSocket(socket);
          return socket;
        } catch (_) {
          // Unreachable via this address and port — try the next one.
        }
      }
    }
    return null;
  }

  /// Forgets the session key cached for [peerId], so the next frame derives
  /// from the secret pairing just wrote.
  ///
  /// The cache is keyed by peer id alone and lives as long as the service
  /// does, which is what makes a re-pair quietly wrong: the new secret is
  /// *stored* (the paired row is updated, `pairWith` answers ok, the code is
  /// accepted) while every frame on the wire is still sealed with the key
  /// derived from the old one. It stays invisible only while both ends carry
  /// the same stale entry — and one end restarting is enough to break that.
  /// Then the end with the fresh process derives from the new secret and the
  /// end with the long-lived cache keeps using the old key, so neither can
  /// prove presence to the other and encrypted frames are dropped as
  /// unreadable, until the stale end is restarted too. That is exactly what
  /// re-pairing a phone that had paired before does to the cable — a second
  /// scan of the QR, or a reconnect after the peer was restarted.
  /// Guards: test/mesh_repair_session_test.dart.
  void _forgetSessionKey(String peerId) {
    _sessionKeys.remove(peerId);
    // The control key is derived from the same secret, so a re-pair that
    // replaces the secret must not leave the old control key cached — that
    // would be the "old QR still signs after a re-pair" hole the derivation is
    // meant to close.
    _controlKeys.remove(peerId);
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


  // ---------------------------------------------------------------------
  // Remote file access (encrypted, served from this device's home folder)
  // ---------------------------------------------------------------------

  /// The folder this device serves. Desktop: the home directory. Android:
  /// the real shared storage when the user granted "All files access" (so the
  /// PC file manager sees every photo, download and music file), otherwise
  /// the app's own external dir. Tests inject their own root; a non-empty
  /// `NEXUS_SERVED_ROOT` env var overrides the default too, so an unattended
  /// harness can serve a scratch directory instead of the real home.
  Future<String> _servedRoot() async =>
      (await storage.serveRoot(override: fileRoot)).path;

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
    if (!store.fileShare) {
      await _sendFileError(peer, req, 'File sharing is off on this device.');
      return;
    }
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
    if (!store.fileShare) {
      await _sendFileError(peer, req, 'File sharing is off on this device.');
      return;
    }
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
    if (!store.fileShare) {
      await _sendFileError(peer, req, 'File sharing is off on this device.');
      return;
    }
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
    if (!store.fileShare) {
      await _sendFileError(peer, req, 'File sharing is off on this device.');
      return;
    }
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
    if (!store.fileShare) {
      await _sendFileError(peer, req, 'File sharing is off on this device.');
      return;
    }
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
        if (move && await deleteRemoteFile(source, sourcePath)) {
          return destinationPath;
        }
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

  // --- File-fetch seam (core/file_fetch.dart) ------------------------------
  // The assistant's `file.fetch` runs on the requesting device and pulls
  // through these two primitives, so the transfer is exactly the one the
  // Files tab already uses — same peer, same encryption, same chunking. The
  // adapter only maps core's vocabulary onto this class's; no new transport.

  @override
  Future<List<RemoteFile>?> filesOnDevice(String peerId, String dir) async {
    final peer = _paired[peerId];
    if (peer == null) return null;
    final entries = await listRemoteFiles(peer, dir);
    if (entries == null) return null;
    return [
      for (final entry in entries)
        RemoteFile(name: entry.name, path: entry.path, isDir: entry.isDir),
    ];
  }

  @override
  Future<String?> fetchFileFromDevice(
    String peerId,
    String remotePath, {
    required String savePath,
    void Function(int received, int total)? onProgress,
  }) async {
    final peer = _paired[peerId];
    if (peer == null) return null;
    final file = await pullRemoteFile(
      peer,
      remotePath,
      savePath: savePath,
      onProgress: onProgress,
    );
    return file?.path;
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
    _peerVersions[peerId] = version;
    final previous = _latestPeerUpdateVersion;
    if (version == previous) return;
    _latestPeerUpdateVersion = version;
    notifyListeners();
  }

  /// Adds this device's proof to a presence frame bound for a paired peer.
  ///
  /// Presence is not encrypted — a device has to be able to announce itself to
  /// a network of devices it shares no secret with — but it must not be
  /// *believed* without proof, because who is online and where a peer is
  /// reached are state we act on. An unpaired peer has nothing shared to prove
  /// anything with and no trusted state to update here, so its frame travels
  /// as it always did and is heard, not trusted.
  Future<NexusMessage> _signedPresence(NexusMessage msg) async {
    final peerId = msg.to;
    final peer = peerId == null ? null : _paired[peerId];
    if (peer == null) return msg;
    final tag = await presenceTag(
      key: await _sessionKeyFor(peer),
      kind: msg.type,
      from: msg.from,
      id: msg.id,
      ts: msg.ts,
    );
    return NexusMessage(
      type: msg.type,
      from: msg.from,
      to: msg.to,
      payload: {...msg.payload, 'auth': tag},
      id: msg.id,
      ts: msg.ts,
    );
  }

  /// Whether a presence frame may be believed.
  ///
  /// An encrypted frame was decrypted with the peer's session key, so it is
  /// proof by construction. A plaintext one has to carry a [presenceTag],
  /// which only a device holding that key could have produced — and which is
  /// bound to this exact frame, so it cannot be lifted onto another claim,
  /// another sender, or a retimed one.
  Future<bool> _presenceProven(
    NexusMessage msg, {
    required bool encrypted,
  }) async {
    if (encrypted) return true;
    final peer = _paired[msg.from];
    if (peer == null) return false; // nothing shared, nothing to trust
    final claimed = msg.payload['auth']?.toString() ?? '';
    if (claimed.isEmpty) return false;
    final expected = await presenceTag(
      key: await _sessionKeyFor(peer),
      kind: msg.type,
      from: msg.from,
      id: msg.id,
      ts: msg.ts,
    );
    return constantTimeEquals(expected, claimed);
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
    required bool trusted,
  }) async {
    final peer = _paired[id];
    // Where we reach a paired device is trusted state. Only a proven claim may
    // move it: otherwise anyone on the network can announce itself as that
    // device and quietly take over every later connection to it. An unknown
    // device still lands in the Nearby list below — hearing strangers is what
    // that list is for, and it grants nothing.
    if (peer != null && !trusted) return;
    if (peer != null) {
      var changed = false;
      if (peer.address != address) {
        peer.address = address;
        changed = true;
      }
      // A loopback source means the frame arrived through a local tunnel
      // (adb reverse): the announced port is the peer's real listening
      // port, which is NOT reachable from here — the route that works is
      // the tunnel endpoint pairWith stored. Keep that port; on a same-host
      // connection the announced port equals the stored one anyway.
      if (!_isLoopback(address) && peer.port != port) {
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

  bool _isLoopback(String address) =>
      address == '127.0.0.1' || address == '::1' || address == 'localhost';

  bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> _sendPlain(Socket socket, NexusMessage msg) async {
    try {
      socket.add(FrameDecoder.encodeFrame(encodeJson(msg.toJson())));
      await socket.flush();
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
    final frame = FrameDecoder.encodeFrame(encodeJson({'enc': enc}));
    final cached = _outbound[peer.id];
    if (cached != null) return _writeFrame(cached, frame);

    // Tunnel fallback: when the peer reached us through a one-way link
    // (adb reverse over a cable), only the peer holds an outbound socket —
    // our own dial to its announced address fails (loopback here, or no
    // route at all). The peer keeps its connection to us alive with its
    // heartbeats, so send on that inbound socket: the cable then works in
    // BOTH directions with no adb forward.
    // Snapshot: a failed write drops the socket (mutating the map) while we
    // are looking for another live one.
    for (final entry in _inboundPeer.entries.toList()) {
      if (entry.value == peer.id && await _writeFrame(entry.key, frame)) {
        return true;
      }
    }
    // No live socket from the peer (or it died mid-write) — dial it.
    final socket = await _outboundSocket(peer);
    if (socket == null) return false;
    return _writeFrame(socket, frame);
  }

  /// Adds [frame] to [socket]. On failure the socket is dropped and cleaned
  /// from both maps, so the next send picks a fresh route.
  Future<bool> _writeFrame(Socket socket, List<int> frame) async {
    try {
      socket.add(frame);
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

  /// [includeSupervised] is false for the mesh's own sweep, which must never
  /// dial a paired peer: those belong to the supervisor's schedule (see
  /// [_presenceSweep]). [beat] passes true — that call *is* the supervisor
  /// dialling, and it is the only thing that reaches a paired peer.
  Future<void> _heartbeat({bool includeSupervised = true}) async {
    if (!_heartbeatLatch.acquire()) return;
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
          ),
        );
      }
      for (final peer in targets.values) {
        // Not ours to dial: a paired peer's retries are the supervisor's, and
        // it asks for one through [beat]. Skipping here is what keeps one
        // schedule on the wire instead of two (see [_presenceSweep]).
        if (!includeSupervised &&
            _supervisor?.running == true &&
            _paired.containsKey(peer.id)) {
          continue;
        }
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
            NexusMessage.caps: await _capabilityAnnouncement(),
            'brain': brain != null,
            if (_tailscale != null)
              'tailscale': {
                'online': _tailscale!.online,
                if (_tailscale!.ipv4 != null) 'ipv4': _tailscale!.ipv4,
              },
          },
          id: _newId(),
          ts: DateTime.now().millisecondsSinceEpoch,
        );
        final socket = await _outboundSocket(peer);
        if (socket != null) {
          await _sendPlain(socket, await _signedPresence(msg));
          _noteSeen(peer.id, verified: false);
        }
      }
      notifyListeners();
    } finally {
      _heartbeatLatch.release();
    }
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
  bool isActiveDevice(
    String id, {
    Duration threshold = const Duration(seconds: 10),
  }) {
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
    if (_pendingClipboard == null || !_clipboardLatch.acquire()) return 0;
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
      if (store.alwaysMerge &&
          _paired.keys.every(_clipboardDeliveredTo.contains)) {
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
      _clipboardLatch.release();
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

    // Never silently overwrite the local clipboard: a push lands in the
    // pending slot and waits for the user's tap. Only an OTP or URL
    // applies itself — and even then only with sync enabled.
    final fromName = (msg.payload['fromName'] as String?) ?? 'Another device';
    if (store.clipboardSync && isClipboardAutoAccept(text)) {
      _lastClipboard = text;
      _pendingClipboard = null;
      _clipboardDeliveredTo.clear();
      await clipboard.writeText(text);
      lastIncomingClip = ClipEntry(
        text: text,
        fromName: fromName,
        fromId: msg.from,
        autoAccepted: true,
      );
    } else {
      lastIncomingClip = ClipEntry(
        text: text,
        fromName: fromName,
        fromId: msg.from,
      );
    }
    notifyListeners();
  }

  /// True while a peer's push is waiting for the explicit gate — the paste
  /// pill's visibility, in one place.
  bool get hasPendingClipboard =>
      lastIncomingClip != null && !lastIncomingClip!.autoAccepted;

  /// The user tapped the paste pill: the explicit gate. Writes the pending
  /// text to the local clipboard and dismisses the indicator. Marks the
  /// text seen first, so the clipboard poll does not echo it back to the
  /// peer that sent it.
  Future<void> acceptPendingClipboard() async {
    final pending = lastIncomingClip;
    lastIncomingClip = null;
    if (pending == null || pending.autoAccepted) {
      notifyListeners();
      return;
    }
    _lastClipboard = pending.text;
    _pendingClipboard = null;
    _clipboardDeliveredTo.clear();
    await clipboard.writeText(pending.text);
    notifyListeners();
  }

  /// The user swiped the paste pill away: forget the push without touching
  /// the local clipboard.
  void dismissPendingClipboard() {
    if (lastIncomingClip == null) return;
    lastIncomingClip = null;
    notifyListeners();
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
    // The listener goes first: on engine detach the isolate may not live
    // long enough to finish the whole teardown below, and the socket is the
    // one resource a recreated engine in this process cannot reclaim. (Close
    // is fire-and-forget, as before — it just happens before the awaits.)
    final server = _server;
    _server = null;
    server?.close();
    // Nothing may be redialled after the mesh has gone.
    await _supervisor?.stop();
    _heartbeatTimer?.cancel();
    _clipboardTimer?.cancel();
    // A pending smart-sync must not fire after the mesh is stopped.
    _clipboardDelayTimer?.cancel();
    _neighborSaveTimer?.cancel();
    _neighborSaveTimer = null;
    await _discovery?.stop();
    // With the mesh gone the foreground service has nothing left to keep
    // alive; stopping it releases the multicast lock and the notification.
    await SyncService.stop();
    for (final socket in _outbound.values.toList()) {
      try {
        socket.destroy();
      } catch (_) {}
    }
    _outbound.clear();
    // Accepted connections too. A mesh that has stopped must not keep
    // answering presence on a socket the other device opened: the peer would
    // go on seeing a healthy link to a device that is gone, and its connection
    // supervisor — which watches exactly that — would never notice the drop.
    for (final socket in _inboundPeer.keys.toList()) {
      try {
        socket.destroy();
      } catch (_) {}
    }
    _inboundPeer.clear();
    if (_neighborsDirty) {
      _neighborsDirty = false;
      _queueSave();
    }
    await _serial?.dispose();
    _serial = null;
    await _saveChain; // flush any pending write before we return
  }

  /// Dispatches one authenticated frame. Implemented by [_MeshRelay]: the
  /// transport decides who proved themselves, the relay decides what it means.
  Future<void> _handleMessage(
    NexusMessage msg,
    Socket socket, {
    required bool encrypted,
    String? provenId,
    String? sourceAddress,
  });

  /// A node on our own cable reported something; relay it to whichever peer
  /// asked. Implemented by [_MeshRelay].
  void _relaySerialUp(String deviceId, Map<String, dynamic> data);

  /// The serial nodes on our cable, as announced in ping/pong. Implemented by
  /// [_MeshRelay].
  List<Map<String, dynamic>> _serialAnnouncement();

  /// A frame that did not decrypt under any paired key may still be a pairing
  /// request (encrypted with the code being shown). The transport only knows
  /// that somebody must look; the pairing mixin owns what happens next.
  Future<void> _tryPairingFrame(Socket socket, String enc);
}

/// The mesh service the rest of the app sees. Its public API is exactly what
/// it was before the split; each concern lives in its own part file as a mixin
/// over the one state object above.
class MeshService extends _MeshBase with _MeshPairing, _MeshRelay {
  /// The canonical mesh port.
  static const int defaultPort = 51820;

  /// The ports to try, in order, when dialling one address of a peer: the
  /// canonical mesh port first, then the peer's announced (stored) port.
  ///
  /// A device that restarted reclaims the canonical port while our stored
  /// route can still name the ephemeral port it used while 51820 was held by
  /// a dead listener — dialling the stored port first would keep hitting that
  /// stale route. The announced port stays as the fallback for when 51820 on
  /// the peer is genuinely occupied by something else.
  ///
  /// A loopback address is a tunnel endpoint (adb reverse) or self: its
  /// stored port IS the whole route, and 51820 there is us or another local
  /// instance, so only the stored port is tried — exactly the old behaviour.
  @visibleForTesting
  static List<int> dialPortsFor({
    required int storedPort,
    required bool loopback,
  }) {
    final ports = <int>[];
    if (!loopback) ports.add(defaultPort);
    ports.add(storedPort);
    return ports.where((port) => port > 0 && port <= 65535).toSet().toList();
  }

  /// On Android, whether the app may read the whole shared storage (the
  /// "All files access" toggle). Always true on other platforms. Owned by
  /// [StorageRoots]; kept here because the settings screen already asks the
  /// mesh.
  static Future<bool> hasAllFilesAccess() => storage.allFilesAccess();

  /// On Android, the real shared storage root (e.g. /storage/emulated/0) —
  /// only readable once [hasAllFilesAccess] is granted.
  static Future<String?> androidSharedRoot() => storage.sharedStorageRoot();

  /// Opens the system "All files access" settings screen for this app.
  static Future<void> openAllFilesAccessSettings() =>
      storage.openAllFilesAccessSettings();

  /// Shared handshake secret for a QR token, known to shower (generated it)
  /// and scanner (read it) and nobody else.
  static String qrSecretFor(QrPairingToken token) =>
      'qr:${token.pairingId}:${token.nonce}';

  MeshService({
    required super.identity,
    required super.store,
    super.clipboard,
    super.onlineWindow = const Duration(seconds: 25),
    super.visibleWindow = const Duration(seconds: 12),
    super.heartbeatInterval = const Duration(seconds: 8),
    super.nearbyWindow = const Duration(seconds: 60),
    super.connectTimeout = const Duration(seconds: 5),
    super.latchWatchdog = const Duration(seconds: 90),
    super.fileRoot,
    super.capabilityProbe,
  });
}
