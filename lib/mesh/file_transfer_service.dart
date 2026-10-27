// Files between two phones on the same Wi-Fi, without a server in the middle.
//
// Each device runs a small HTTP listener and dials the other's directly. A
// transfer is three steps that the rest of the app can describe in one
// sentence:
//
//   1. `GET /nexus/hello` asks "are you there?" and gets a fresh nonce back.
//   2. The sender signs `sender|nonce|filename|size` with the receiver's
//      pairing token (the secret on its QR, stored when it was scanned) and
//      POSTs the bytes with that signature.
//   3. The receiver verifies the signature against the token it knows it
//      owns, consumes the nonce, writes the file, and answers.
//
// The token itself never crosses the wire: the signature is an HMAC, the nonce
// is single-use and short-lived, and a request with no valid signature is
// refused before a byte of its body is read. A stranger on the same Wi-Fi can
// find the server — `hello` is deliberately public so devices can see each
// other — but cannot make it accept a file.
//
// This is the transport the "Send to…" sheet has been waiting for. It is
// deliberately not the mesh's TCP protocol: that protocol is a framed,
// encrypted session between MeshService instances, and these endpoints are
// plain HTTP so a request can be read, signed and answered in one round trip.
// What both sides do share is the pairing record, which is the only thing a
// transfer needs to be allowed.
//
// The launched app now runs a mesh as well, which is why this link listens on
// 51821 rather than the mesh's 51820 — see [kFileTransferPort].
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random;

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart'
    show ChangeNotifier, debugPrint, visibleForTesting;
import 'package:path_provider/path_provider.dart'
    show getApplicationDocumentsDirectory;

import '../core/crypto.dart' show constantTimeEquals;
import '../core/file_link.dart' show FileSendResult, FileTransport;
import '../core/pair_invite.dart' show PairIdentity;
import '../core/pair_token.dart' show PairToken;
import '../core/paired_devices.dart' show PairedDevice, PairedDevices;

/// The port the listener answers on, and the one a pairing code advertises.
///
/// It used to be 51820 — the mesh's default port — because on a build with no
/// mesh the HTTP listener was the only thing that could answer there. Now the
/// mesh owns 51820 on the launched path, so the link lives one port up and a
/// scanning device learns it from the pairing code's own `port` field.
const int kFileTransferPort = 51821;

/// The port this link used before the mesh owned the launched path.
///
/// Still tried first when binding (see [FileTransferService.start]): a build
/// with no mesh listening on 51820 keeps answering where existing pairings
/// expect it, and a build whose mesh took 51820 lands on [kFileTransferPort].
/// It is also the port older pairing records carry, which is why dialling has
/// to ask rather than assume — see `FileTransferService._portToDial`.
const int kLegacyFileTransferPort = 51820;

/// Where liveness and the transfer nonce are asked for.
const String kNexusHelloPath = '/nexus/hello';

/// Where bytes are posted.
const String kNexusFilePath = '/nexus/file';

/// The two control nudges a paired device may send: a ping, and one trackpad
/// movement. Both are deliberately small, body-only requests — no file access,
/// no state that outlives the notification or the pointer movement.
const String kNexusPingPath = '/nexus/ping';
const String kNexusMousePath = '/nexus/mouse';

/// How much a mouse body may be. A movement is two numbers; anything larger is
/// not one, and a server that read it would be reading an attack.
const int kMaxMouseBody = 4096;

/// Header names, spelled once. A test asserts on these rather than on strings
/// repeated in the client and the server.
const String kHeaderDevice = 'x-nexus-device';
const String kHeaderName = 'x-nexus-name';
const String kHeaderNonce = 'x-nexus-nonce';
const String kHeaderSignature = 'x-nexus-signature';
const String kHeaderFilename = 'x-nexus-filename';
const String kHeaderSize = 'x-nexus-size';

/// When the sender minted the control request, in milliseconds since the
/// epoch — the same unit the mesh's own frames use. A request outside
/// [kControlClockWindow] of now is refused, so a captured one cannot be
/// replayed tomorrow.
const String kHeaderTimestamp = 'x-nexus-ts';

/// How far a control request's timestamp may be from this device's clock.
///
/// Two minutes is wide enough for two phones whose clocks disagree by a
/// minute and narrow enough that a captured ping is worthless by the time
/// anybody reads the log. The nonce cache closes the window inside it.
const Duration kControlClockWindow = Duration(seconds: 120);

/// How many spent control nonces are remembered before the oldest is dropped.
/// Expiry already bounds this; the cap keeps a token-holding peer from growing
/// it without limit.
const int kMaxControlNonces = 4096;

/// How long an offered nonce is worth. Long enough for a photo's body to start
/// on a slow phone, short enough that a captured request cannot be replayed
/// tomorrow.
const Duration kTransferNonceValidity = Duration(seconds: 45);

/// How long the liveness question may take. A device that has not answered in
/// this window is not one the sheet should keep a user waiting for.
const Duration kTransferProbeTimeout = Duration(milliseconds: 1400);

/// The canonical string the signature covers. One function, so the sender and
/// the receiver cannot sign different things.
String transferSignaturePayload({
  required String senderId,
  required String nonce,
  required String filename,
  required int size,
}) => 'nexus/transfer/v1|$senderId|$nonce|$filename|$size';

/// The canonical string a ping signs.
///
/// A ping has no body, so the kind is the whole payload — but it is still in
/// the string: a signature over `…|mouse|…` must never verify for a ping, or
/// a captured movement could be replayed as a nudge (or the reverse).
String pingSignaturePayload({
  required String senderId,
  required String nonce,
  required int ts,
}) => 'nexus/control/v1|$senderId|$nonce|$ts|ping';

/// The canonical string a trackpad movement signs, body included.
///
/// The coordinates are in the string because otherwise the body would be the
/// one part of a signed request an attacker could change: the nonce still
/// blocks an outright replay, but signing the movement costs one line and
/// removes the question.
String mouseSignaturePayload({
  required String senderId,
  required String nonce,
  required int ts,
  required double dx,
  required double dy,
  required bool click,
}) =>
    'nexus/control/v1|$senderId|$nonce|$ts|mouse|'
    '${wireNumber(dx)}|${wireNumber(dy)}|${click ? 1 : 0}';

/// The one spelling of a coordinate on the wire, for both the signer and the
/// verifier.
///
/// `double.toString()` is stable for the same double, but a JSON round trip
/// and a fixed format cannot disagree about rounding, and four decimals is far
/// finer than a gesture. One function so the two sides can never sign
/// different strings from the same movement.
String wireNumber(double value) => value.toStringAsFixed(4);

/// One file that arrived here.
class ReceivedFile {
  const ReceivedFile({
    required this.path,
    required this.name,
    required this.fromId,
    required this.fromName,
    required this.at,
  });

  /// Where it was saved, inside this app's own received folder.
  final String path;

  /// The name the sender's device gave it, tidied of any path.
  final String name;

  /// Who sent it, as the request said. The token proves they saw this device's
  /// QR; the name is their claim, shown so the bubble can say who it was.
  final String fromId;
  final String fromName;

  final DateTime at;

  /// Whether the thread should draw it as a picture rather than a file chip.
  bool get isImage => isImageName(name);

  @override
  String toString() => 'ReceivedFile($name from $fromName)';
}

/// What `hello` answers: who is there, and the nonce for one transfer.
class FileTransferHello {
  const FileTransferHello({
    required this.deviceId,
    required this.deviceName,
    required this.nonce,
  });

  final String deviceId;
  final String deviceName;
  final String nonce;
}

/// A ping that arrived from another device.
class NexusPing {
  const NexusPing({
    required this.deviceId,
    required this.deviceName,
    required this.at,
    this.verified = false,
  });

  final String deviceId;

  /// The name the sender claimed. It is shown, not trusted: a ping carries no
  /// data and changes nothing, so the worst a false name can do is mislabel a
  /// notification.
  final String deviceName;
  final DateTime at;

  /// Whether the sender proved it holds this device's transfer token.
  ///
  /// False is the one-way-pairing case: a device that this shell scanned holds
  /// only its *own* token, so it has nothing to sign with, and the request is
  /// accepted because the sender is a device this shell knows — with the name
  /// taken from that record rather than from the request. The badge the shell
  /// adds says so; there is no state here that needs trusting beyond a label.
  final bool verified;

  @override
  String toString() => 'NexusPing($deviceName${verified ? '' : ', unverified'})';
}

/// One movement from the phone's trackpad.
///
/// [dx] and [dy] are relative CSS pixels since the last frame; [click] marks a
/// tap rather than a move. The receiver logs and republishes this today — the
/// platform pointer bridge is deliberately not invented here.
class NexusMouseEvent {
  const NexusMouseEvent({
    required this.dx,
    required this.dy,
    this.click = false,
  });

  final double dx;
  final double dy;
  final bool click;

  @override
  String toString() => 'NexusMouseEvent($dx, $dy, click: $click)';
}

/// What sending a control request concluded, in the one sentence the card shows.
class NexusRequestResult {
  const NexusRequestResult({required this.ok, required this.message});

  final bool ok;
  final String message;
}

/// Whether [name] is a picture the thread can show.
bool isImageName(String name) {
  final String lower = name.toLowerCase();
  for (final String extension in const <String>[
    '.png',
    '.jpg',
    '.jpeg',
    '.webp',
    '.gif',
    '.bmp',
    '.heic',
    '.heif',
  ]) {
    if (lower.endsWith(extension)) return true;
  }
  return false;
}

/// What one control request earned: a proof, a known sender, or nothing.
class _ControlGate {
  const _ControlGate({required this.verified, required this.name})
    : rejected = false;

  const _ControlGate.refused()
    : verified = false,
      name = '',
      rejected = true;

  /// True when the signature verified against this device's token.
  final bool verified;

  /// The name to show: this shell's own name for a known device, or the
  /// claimed one for a proved sender it has no record of.
  final String name;

  /// True when the request must be answered with 401.
  final bool rejected;
}

/// The listener, the sender, and the list of what arrived.
class FileTransferService extends ChangeNotifier implements FileTransport {
  FileTransferService({
    int? port,
    Future<Directory?> Function()? directory,
    String? token,
    @visibleForTesting List<int>? bindLadder,
  }) : port = port ?? kFileTransferPort,
       _explicitPort = port != null,
       _debugBindLadder = bindLadder,
       _directory = directory ?? _defaultDirectory,
       _tokenOverride = token;

  /// Test seam, in the same shape as the rest of the app: a widget test states
  /// a service rather than opening a socket. The app never sets it.
  ///
  /// Named `debugOverride` rather than `override` because a static field with
  /// that name shadows the `@override` annotation inside this class.
  @visibleForTesting
  static FileTransferService Function()? debugOverride;

  static FileTransferService? _instance;

  /// The app-wide service.
  static FileTransferService get instance =>
      debugOverride?.call() ?? (_instance ??= FileTransferService());

  /// Forgets the app-wide service. Tests use it; the app never does.
  @visibleForTesting
  static void debugReset() => _instance = null;

  /// The port asked for — and, when this is the app's own service, the port a
  /// peer that carries no port of its own is expected to answer on.
  ///
  /// [boundPort] is the one actually listening, which can differ: the app's
  /// service walks the ladder in [start], and a test may ask for port 0.
  final int port;

  /// True when a port was stated explicitly, which replaces the ladder with
  /// that one port. A test that binds its own ephemeral port must not be
  /// surprised by the app's ladder trying 51820 first.
  final bool _explicitPort;

  /// A ladder a test states, over the one this build would use.
  ///
  /// The shipped ladder names two fixed ports, and a test that occupies them to
  /// watch the walk would be competing with every other test isolate on the
  /// machine — the port lottery this suite has been bitten by before. A stated
  /// ladder exercises the walk on ports the test itself holds.
  final List<int>? _debugBindLadder;

  int get boundPort => _server?.port ?? _boundPort;
  int _boundPort = 0;

  /// The port each device answered [kNexusHelloPath] on, for this session.
  ///
  /// Dialling is the one place a stale pairing record costs a round trip
  /// instead of being visible, so the first answer is kept: a ping loop or a
  /// second transfer should not re-probe.
  final Map<String, int> _dialPorts = <String, int>{};

  final Future<Directory?> Function() _directory;
  final String? _tokenOverride;

  HttpServer? _server;
  bool _running = false;
  bool _starting = false;
  String? _problem;
  String? _token;

  /// Nonces offered by [start]-time, with the moment they stop being valid.
  final Map<String, DateTime> _nonces = <String, DateTime>{};

  /// Control-request nonces already spent, keyed `sender|nonce` with the
  /// moment the clock window closes. See [_rememberControlNonce].
  final Map<String, DateTime> _controlNonces = <String, DateTime>{};

  /// Senders that have proved the transfer token at least once this process.
  ///
  /// Once a device has shown it can sign, it never gets the unsigned path
  /// again: otherwise an attacker who can strip a header would get the weaker
  /// branch for a peer that had already demonstrated the stronger one. The set
  /// is per process on purpose — a restart forgets, and the badge is what the
  /// user sees either way.
  final Set<String> _signingPeers = <String>{};

  /// How the control endpoints find the name this shell stores for a paired
  /// device — and therefore whether the sender is paired at all.
  ///
  /// Set once by `main()`, which is the only place that holds both the shell's
  /// list and the mesh. Null is a service built on its own (every test, and any
  /// caller before the bootstrap runs), which falls back to the shell list
  /// alone. Returning null means "not a device this shell knows", and an
  /// unsigned request from one is refused.
  String? Function(String id)? peerNameLookup;

  final StreamController<ReceivedFile> _incoming =
      StreamController<ReceivedFile>.broadcast();

  /// Pings that arrived here. The shell listens once, at the app root, so a
  /// ping is seen whichever tab happens to be open.
  final StreamController<NexusPing> _pings =
      StreamController<NexusPing>.broadcast();

  /// Trackpad movements that arrived here, for the desktop pointer bridge (and
  /// for the test that proves a movement crossed the wire intact).
  final StreamController<NexusMouseEvent> _mouse =
      StreamController<NexusMouseEvent>.broadcast();

  /// Kept alive between movements: a trackpad sends tens of requests a second,
  /// and a fresh TCP connection for each would be felt as lag on the glass.
  HttpClient? _mouseClient;

  /// Files that arrived here, newest first — what a screen can list without
  /// remembering the stream.
  final List<ReceivedFile> _received = <ReceivedFile>[];

  /// Arrivals, for the thread to put a bubble up as they land.
  Stream<ReceivedFile> get incoming => _incoming.stream;

  /// Pings from paired devices. One subscription at the root of the app.
  Stream<NexusPing> get pings => _pings.stream;

  /// Trackpad movements from paired devices. Empty until a pointer bridge
  /// consumes it; the endpoint is real even while the bridge is a log line.
  Stream<NexusMouseEvent> get mouse => _mouse.stream;

  /// What has arrived this run, newest first.
  List<ReceivedFile> get received => List<ReceivedFile>.unmodifiable(_received);

  /// The token this device checks against. Empty until [start] has read it.
  String get token => _tokenOverride ?? _token ?? '';

  bool get running => _running;

  /// Why the listener could not open, or null. Like discovery's, this is a
  /// sentence for a screen, not an exception for a crash.
  String? get problem => _problem;

  /// Opens the listener. Safe to call twice, and safe to call when a previous
  /// attempt failed (the next call tries again).
  /// The ports to try, in the order that keeps both directions working.
  ///
  /// The legacy port comes first because a build with no mesh on 51820 is a
  /// build whose existing pairings dial 51820 — this service has to be there.
  /// On the launched path the mesh holds 51820, so the bind fails and the next
  /// rung ([port], 51821) wins; a host where both are busy still gets a socket
  /// rather than a dead link.
  List<int> get _bindLadder {
    final List<int>? stated = _debugBindLadder;
    if (stated != null && stated.isNotEmpty) return stated;
    return _explicitPort ? <int>[port] : <int>[kLegacyFileTransferPort, port, 0];
  }

  /// The ladder this service would walk, for a test that pins the order rather
  /// than occupying the ports.
  @visibleForTesting
  List<int> get debugBindLadder => _bindLadder;

  Future<void> start() async {
    if (_running || _starting) return;
    _starting = true;
    _problem = null;
    Object? lastError;
    try {
      _token = _tokenOverride ?? await PairToken.current();
      for (final int candidate in _bindLadder) {
        try {
          final HttpServer server = await HttpServer.bind(
            InternetAddress.anyIPv4,
            candidate,
          );
          _server = server;
          _boundPort = server.port;
          break;
        } catch (error) {
          lastError = error;
        }
      }
      final HttpServer? server = _server;
      if (server == null) {
        _running = false;
        _problem =
            'File transfer could not open a port (tried '
            '${_bindLadder.join(', ')}) — $lastError';
        return;
      }
      _running = true;
      server.listen(
        (HttpRequest request) => unawaited(_serve(request)),
        onError: (Object error) =>
            debugPrint('FILE LINK: listener error $error'),
        cancelOnError: false,
      );
      debugPrint('FILE LINK: listening on ${server.port}');
    } catch (error) {
      _running = false;
      _problem = 'File transfer could not start on port $port — $error';
      debugPrint('FILE LINK: $error');
    } finally {
      _starting = false;
      notifyListeners();
    }
  }

  /// Closes the listener. Tests call it; the app's process owns its server for
  /// as long as it lives.
  Future<void> stop() async {
    final HttpServer? server = _server;
    _server = null;
    final bool wasRunning = _running;
    _running = false;
    _nonces.clear();
    // A port decided in this session is not a promise for the next one: a peer
    // that updates, or a network that changes under us, should be asked again.
    _dialPorts.clear();
    _mouseClient?.close(force: true);
    _mouseClient = null;
    try {
      await server?.close(force: true);
    } catch (_) {
      // A listener that is already gone is closed.
    }
    if (wasRunning) notifyListeners();
  }

  @override
  void dispose() {
    unawaited(stop());
    unawaited(_incoming.close());
    unawaited(_pings.close());
    unawaited(_mouse.close());
    super.dispose();
  }

  /// Whether [device] answers on its file port right now.
  ///
  /// Best-effort and bounded: the sheet asks this before offering a row as
  /// online, and the send itself asks again, because a device can go to sleep
  /// between the list and the tap.
  Future<bool> probe(PairedDevice device) async => await hello(device) != null;

  /// The `hello` answer, or null when the device does not answer within
  /// [kTransferProbeTimeout].
  Future<FileTransferHello?> hello(PairedDevice device) async {
    final String? address = _addressOf(device);
    if (address == null) return null;
    final int port = await _portToDial(device);
    final HttpClient client = HttpClient()
      ..connectionTimeout = kTransferProbeTimeout;
    try {
      final HttpClientRequest request = await client
          .getUrl(
            Uri(
              scheme: 'http',
              host: address,
              port: port,
              path: kNexusHelloPath,
            ),
          )
          .timeout(kTransferProbeTimeout);
      final HttpClientResponse response = await request.close().timeout(
        kTransferProbeTimeout,
      );
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return null;
      }
      final String body = await utf8.decodeStream(response);
      final Object? decoded = jsonDecode(body);
      if (decoded is! Map) return null;
      final String nonce = decoded['nonce']?.toString() ?? '';
      if (nonce.isEmpty) return null;
      return FileTransferHello(
        deviceId: decoded['id']?.toString() ?? '',
        deviceName: decoded['name']?.toString() ?? '',
        nonce: nonce,
      );
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Sends a ping to [device] — a POST to `/nexus/ping` carrying this device's
  /// id and name, signed when the pairing gave it something to sign with.
  ///
  /// [PairedDevice.code] is the receiver's transfer token as its QR carried it,
  /// so a device that scanned this one can prove the ping came from a holder of
  /// that token. A device this shell scanned holds only its *own* token and has
  /// nothing to sign with — the request goes unsigned, and the receiver accepts
  /// it only because it knows this device, with a badge that says so.
  Future<NexusRequestResult> ping(PairedDevice device) async {
    final String? address = _addressOf(device);
    if (address == null) {
      return NexusRequestResult(
        ok: false,
        message: '${device.name} hasn\'t shared an address yet.',
      );
    }
    final PairIdentity me = PairIdentity.current;
    final int port = await _portToDial(device);
    final HttpClient client = HttpClient()
      ..connectionTimeout = kTransferProbeTimeout;
    try {
      final HttpClientRequest request = await client
          .postUrl(
            Uri(
              scheme: 'http',
              host: address,
              port: port,
              path: kNexusPingPath,
            ),
          )
          .timeout(kTransferProbeTimeout);
      final Map<String, String> headers = await _controlHeaders(
        key: device.code.trim(),
        senderId: me.id,
        senderName: me.name,
        canonical: (String nonce, int ts) => pingSignaturePayload(
          senderId: me.id,
          nonce: nonce,
          ts: ts,
        ),
      );
      request.headers
        ..set(kHeaderDevice, headers[kHeaderDevice]!)
        ..set(kHeaderName, headers[kHeaderName]!);
      request.contentLength = 0;
      for (final MapEntry<String, String> header in headers.entries) {
        if (header.key != kHeaderDevice && header.key != kHeaderName) {
          request.headers.set(header.key, header.value);
        }
      }
      final HttpClientResponse response = await request.close().timeout(
        kTransferProbeTimeout,
      );
      await response.drain<void>();
      if (response.statusCode == HttpStatus.ok) {
        return NexusRequestResult(
          ok: true,
          message: 'Ping sent to ${device.name}.',
        );
      }
      return NexusRequestResult(
        ok: false,
        message:
            '${device.name} refused the ping (HTTP ${response.statusCode}).',
      );
    } catch (error) {
      debugPrint('NEXUS ping: $error');
      return NexusRequestResult(
        ok: false,
        message:
            '${device.name} isn\'t reachable — check it is on this network '
            'and Nexus is open there.',
      );
    } finally {
      client.close(force: true);
    }
  }

  /// Sends one trackpad movement (or a tap) to [device]. Returns false when the
  /// peer cannot be reached or answers with an error.
  ///
  /// This is a best-effort stream of small requests, so failures are not thrown
  /// at the caller on every frame; the trackpad reports the first one and keeps
  /// trying, exactly as a remote would.
  Future<bool> sendMouse(
    PairedDevice device, {
    required double dx,
    required double dy,
    bool click = false,
  }) async {
    final String? address = _addressOf(device);
    if (address == null) return false;
    final PairIdentity me = PairIdentity.current;
    final int port = await _portToDial(device);
    final HttpClient client = _mouseClient ??= (HttpClient()
      ..connectionTimeout = kTransferProbeTimeout);
    try {
      final HttpClientRequest request = await client
          .postUrl(
            Uri(
              scheme: 'http',
              host: address,
              port: port,
              path: kNexusMousePath,
            ),
          )
          .timeout(kTransferProbeTimeout);
      final Map<String, String> headers = await _controlHeaders(
        key: device.code.trim(),
        senderId: me.id,
        senderName: me.name,
        canonical: (String nonce, int ts) => mouseSignaturePayload(
          senderId: me.id,
          nonce: nonce,
          ts: ts,
          dx: dx,
          dy: dy,
          click: click,
        ),
      );
      request.headers
        ..contentType = ContentType.json
        ..set(kHeaderDevice, headers[kHeaderDevice]!)
        ..set(kHeaderName, headers[kHeaderName]!);
      for (final MapEntry<String, String> header in headers.entries) {
        if (header.key != kHeaderDevice && header.key != kHeaderName) {
          request.headers.set(header.key, header.value);
        }
      }
      request.write(
        jsonEncode(<String, Object>{
          'x': dx,
          'y': dy,
          if (click) 'click': true,
        }),
      );
      final HttpClientResponse response = await request.close().timeout(
        kTransferProbeTimeout,
      );
      await response.drain<void>();
      if (response.statusCode == HttpStatus.ok) return true;
    } catch (error) {
      debugPrint('NEXUS mouse: $error');
      // A kept-alive connection can be stale after the peer sleeps. Drop it so
      // the next movement opens a fresh one instead of failing forever.
      _mouseClient?.close(force: true);
      _mouseClient = null;
      return false;
    }
    return false;
  }

  /// Sends [path] to [device], reporting the fraction of the body written.
  @override
  Future<FileSendResult> send({
    required String path,
    required PairedDevice device,
    void Function(double progress)? onProgress,
  }) async {
    final String key = device.code.trim();
    if (key.isEmpty) {
      return FileSendResult(
        ok: false,
        message:
            'This pairing has no transfer token yet — scan '
            '${device.name}\'s QR code again to enable file transfer.',
      );
    }
    final String? address = _addressOf(device);
    if (address == null) {
      return FileSendResult(
        ok: false,
        message:
            '${device.name} hasn\'t said where it is — pair it again by '
            'scanning its QR code.',
      );
    }
    final File source = File(path);
    if (!await source.exists()) {
      return const FileSendResult(
        ok: false,
        message: 'That file is no longer on this device.',
      );
    }
    final int size = await source.length();
    final String name = _safeName(path.split(RegExp(r'[/\\]')).last);
    final FileTransferHello? helloAnswer = await hello(device);
    if (helloAnswer == null) {
      return FileSendResult(
        ok: false,
        message:
            '${device.name} isn\'t reachable — check it is on this network '
            'and Nexus is open there.',
      );
    }
    final PairIdentity me = PairIdentity.current;
    final String signature = await _sign(
      key: key,
      senderId: me.id,
      nonce: helloAnswer.nonce,
      filename: name,
      size: size,
    );
    // [hello] just resolved this — and cached it — so on a legacy record the
    // body goes to the port that answered rather than to a guess.
    final int port = await _portToDial(device);
    final HttpClient client = HttpClient()
      ..connectionTimeout = kTransferProbeTimeout;
    try {
      final HttpClientRequest request = await client
          .postUrl(
            Uri(
              scheme: 'http',
              host: address,
              port: port,
              path: kNexusFilePath,
            ),
          )
          .timeout(kTransferProbeTimeout);
      request.headers
        ..set(kHeaderDevice, me.id)
        ..set(kHeaderName, me.name)
        ..set(kHeaderNonce, helloAnswer.nonce)
        ..set(kHeaderSignature, signature)
        ..set(kHeaderFilename, name)
        ..set(kHeaderSize, '$size');
      request.contentLength = size;
      final RandomAccessFile reader = await source.open();
      int sent = 0;
      double last = -1;
      try {
        while (true) {
          final List<int> chunk = await reader.read(64 * 1024);
          if (chunk.isEmpty) break;
          request.add(chunk);
          sent += chunk.length;
          final double progress = size <= 0 ? 1 : sent / size;
          if (progress - last >= 0.01 || progress >= 1) {
            last = progress;
            onProgress?.call(progress);
          }
          await request.flush().timeout(const Duration(seconds: 5));
        }
      } finally {
        await reader.close();
      }
      final HttpClientResponse response = await request.close();
      await response.drain<void>();
      if (response.statusCode == HttpStatus.ok) {
        onProgress?.call(1);
        return FileSendResult(
          ok: true,
          message: 'Sent $name to ${device.name} (${_size(sent)}).',
          path: path,
        );
      }
      if (response.statusCode == HttpStatus.unauthorized) {
        return FileSendResult(
          ok: false,
          message:
              '${device.name} refused the file — its pairing token no longer '
              'matches. Scan its QR code again to re-pair.',
        );
      }
      return FileSendResult(
        ok: false,
        message:
            '${device.name} refused the file (HTTP ${response.statusCode})',
      );
    } catch (error) {
      debugPrint('FILE LINK: send failed ($error)');
      return FileSendResult(
        ok: false,
        message:
            'The file stopped partway to ${device.name} — check the '
            'connection and try again.',
      );
    } finally {
      client.close(force: true);
    }
  }

  // --- the listener -----------------------------------------------------

  Future<void> _serve(HttpRequest request) async {
    try {
      if (request.method == 'GET' && request.uri.path == kNexusHelloPath) {
        await _answerHello(request);
        return;
      }
      if (request.method == 'POST' && request.uri.path == kNexusFilePath) {
        await _acceptFile(request);
        return;
      }
      if (request.method == 'POST' && request.uri.path == kNexusPingPath) {
        await _acceptPing(request);
        return;
      }
      if (request.method == 'POST' && request.uri.path == kNexusMousePath) {
        await _acceptMouse(request);
        return;
      }
      await _json(request, HttpStatus.notFound, <String, Object?>{
        'ok': false,
        'error': 'not found',
      });
    } catch (error) {
      debugPrint('FILE LINK: request failed ($error)');
      try {
        await _json(request, HttpStatus.internalServerError, <String, Object?>{
          'ok': false,
          'error': 'server',
        });
      } catch (_) {
        // The connection may already be gone; the client will time out.
      }
    }
  }

  /// A ping is a nudge, not a transfer: gate it, then publish it.
  ///
  /// The gate is [_controlGate]: a signature that verifies against this
  /// device's token is proof; a request with no signature is accepted only from
  /// a device this shell has paired, and is marked unverified. A stranger on
  /// the network is refused with 401, which is what closes the surface
  /// `docs/notes/known-surfaces.md` recorded.
  Future<void> _acceptPing(HttpRequest request) async {
    final String senderId = request.headers.value(kHeaderDevice)?.trim() ?? '';
    final String senderName = request.headers.value(kHeaderName)?.trim() ?? '';
    if (senderId.isEmpty) {
      await _json(request, HttpStatus.badRequest, <String, Object?>{
        'ok': false,
        'error': 'missing device',
      });
      return;
    }
    // Drain an empty body so a keep-alive connection is reusable.
    await request.drain<void>();
    final _ControlGate gate = await _controlGate(
      request,
      senderId: senderId,
      claimedName: senderName,
      canonical: (String nonce, int ts) =>
          pingSignaturePayload(senderId: senderId, nonce: nonce, ts: ts),
    );
    if (gate.rejected) {
      await _json(request, HttpStatus.unauthorized, <String, Object?>{
        'ok': false,
        'error': 'control request not verified',
      });
      return;
    }
    final NexusPing ping = NexusPing(
      deviceId: senderId,
      deviceName: gate.name,
      at: DateTime.now(),
      verified: gate.verified,
    );
    _pings.add(ping);
    debugPrint(
      'NEXUS ping: ${ping.deviceName} <- $senderId'
      '${ping.verified ? '' : ' (unverified)'}',
    );
    await _json(request, HttpStatus.ok, <String, Object?>{'ok': true});
  }

  /// One trackpad movement. The endpoint is real; the pointer bridge that will
  /// consume [mouse] is not built yet, so this publishes the event and logs it
  /// rather than pretending to move a cursor.
  ///
  /// Refused unless the sender proved the token. A name is a label; a cursor is
  /// an effect on the machine, and the unsigned path exists only for a build
  /// that predates signing.
  Future<void> _acceptMouse(HttpRequest request) async {
    final String senderId = request.headers.value(kHeaderDevice)?.trim() ?? '';
    final String senderName = request.headers.value(kHeaderName)?.trim() ?? '';
    if (senderId.isEmpty) {
      await _json(request, HttpStatus.badRequest, <String, Object?>{
        'ok': false,
        'error': 'missing device',
      });
      return;
    }
    final List<int> body = <int>[];
    await for (final List<int> chunk in request) {
      if (body.length + chunk.length > kMaxMouseBody) {
        await _json(request, HttpStatus.badRequest, <String, Object?>{
          'ok': false,
          'error': 'body too large',
        });
        return;
      }
      body.addAll(chunk);
    }
    if (body.isEmpty) {
      await _json(request, HttpStatus.badRequest, <String, Object?>{
        'ok': false,
        'error': 'missing movement',
      });
      return;
    }
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(body));
    } catch (_) {
      decoded = null;
    }
    if (decoded is! Map) {
      await _json(request, HttpStatus.badRequest, <String, Object?>{
        'ok': false,
        'error': 'not json',
      });
      return;
    }
    final double? dx = (decoded['x'] as num?)?.toDouble();
    final double? dy = (decoded['y'] as num?)?.toDouble();
    if (dx == null || dy == null || !dx.isFinite || !dy.isFinite) {
      await _json(request, HttpStatus.badRequest, <String, Object?>{
        'ok': false,
        'error': 'x and y must be numbers',
      });
      return;
    }
    final bool click = decoded['click'] == true;
    final _ControlGate gate = await _controlGate(
      request,
      senderId: senderId,
      claimedName: senderName,
      canonical: (String nonce, int ts) => mouseSignaturePayload(
        senderId: senderId,
        nonce: nonce,
        ts: ts,
        dx: dx,
        dy: dy,
        click: click,
      ),
    );
    if (!gate.verified) {
      await _json(request, HttpStatus.unauthorized, <String, Object?>{
        'ok': false,
        'error': 'mouse needs a verified peer',
      });
      return;
    }
    final NexusMouseEvent event = NexusMouseEvent(
      dx: dx,
      dy: dy,
      click: click,
    );
    _mouse.add(event);
    debugPrint('NEXUS mouse: $event');
    await _json(request, HttpStatus.ok, <String, Object?>{'ok': true});
  }

  /// The one decision both control endpoints make: may this request be shown,
  /// and was it proved?
  ///
  /// Three outcomes, in the order the security value runs:
  ///
  /// - **verified** — the signature verifies against this device's own token,
  ///   the timestamp is inside [kControlClockWindow], and the nonce is fresh.
  /// - **unverified** — no signature, but the sender is a device this shell has
  ///   paired. That is the one-way-pairing case: the peer holds its own token,
  ///   not ours, so it has nothing to sign with. The name shown is the one this
  ///   shell stores for it, never the claimed one, so a forged `x-nexus-name`
  ///   has nowhere to surface.
  /// - **refused** — everything else. A deliberately signed request that does
  ///   not verify is never downgraded to the unverified path: a device that has
  ///   signed once is locked to signing for the life of the process.
  ///
  /// On a fresh install with no token of its own there is nothing to verify
  /// against, so every signed request is refused — and an unsigned one from a
  /// known device is accepted with the badge. That keeps a device usable before
  /// it has ever shown a QR.
  Future<_ControlGate> _controlGate(
    HttpRequest request, {
    required String senderId,
    required String claimedName,
    required String Function(String nonce, int ts) canonical,
  }) async {
    final String nonce = request.headers.value(kHeaderNonce)?.trim() ?? '';
    final String signature =
        request.headers.value(kHeaderSignature)?.trim() ?? '';
    final String rawTs = request.headers.value(kHeaderTimestamp)?.trim() ?? '';
    final String ownToken = token;
    final bool presentedSignature =
        nonce.isNotEmpty || signature.isNotEmpty || rawTs.isNotEmpty;

    if (presentedSignature) {
      final int? ts = int.tryParse(rawTs);
      // The clock check first: it is cheap, and it is the one refusal that does
      // not need the secret.
      if (nonce.isEmpty || signature.isEmpty || ts == null) {
        return const _ControlGate.refused();
      }
      final DateTime at = DateTime.fromMillisecondsSinceEpoch(ts);
      if (DateTime.now().difference(at).abs() > kControlClockWindow) {
        return const _ControlGate.refused();
      }
      if (ownToken.isEmpty) {
        // Nothing to verify against: a signed request on a device that has no
        // token is a claim this build cannot check, so it is not accepted.
        return const _ControlGate.refused();
      }
      final String wanted = await _signRaw(ownToken, canonical(nonce, ts));
      if (!constantTimeEquals(wanted, signature)) {
        return const _ControlGate.refused();
      }
      // Only a verified request is allowed to spend a nonce, so garbage cannot
      // fill the cache.
      if (!_rememberControlNonce(senderId, nonce)) {
        return const _ControlGate.refused();
      }
      _signingPeers.add(senderId);
      final String? stored = _storedNameOf(senderId);
      return _ControlGate(
        verified: true,
        name: stored ??
            (claimedName.isEmpty ? 'a paired device' : claimedName),
      );
    }

    // No signature at all. A peer that has proved the token before is not
    // allowed back onto this path — that is the downgrade.
    if (_signingPeers.contains(senderId)) {
      return const _ControlGate.refused();
    }
    final String? stored = _storedNameOf(senderId);
    if (stored == null) return const _ControlGate.refused();
    return _ControlGate(verified: false, name: stored);
  }

  /// The name this shell stores for [id], or null when it is not a device this
  /// shell has paired.
  ///
  /// The lookup is the pairing check as well as the name: on this path the name
  /// is the only thing the answer decides, so one function keeps them from
  /// disagreeing.
  String? _storedNameOf(String id) {
    final String? Function(String id)? lookup = peerNameLookup;
    if (lookup != null) return lookup(id);
    for (final PairedDevice device in PairedDevices.instance.devices) {
      if (device.id == id) return device.name;
    }
    return null;
  }

  /// Records [nonce] as spent for [senderId], or answers false when it was
  /// already seen inside the window.
  bool _rememberControlNonce(String senderId, String nonce) {
    final DateTime now = DateTime.now();
    _controlNonces.removeWhere(
      (String _, DateTime expiry) => !expiry.isAfter(now),
    );
    final String key = '$senderId|$nonce';
    if (_controlNonces.containsKey(key)) return false;
    if (_controlNonces.length >= kMaxControlNonces) {
      // Evict the entry closest to expiring: dropping it only widens the window
      // for a request older than everything we remember, which the clock check
      // already bounds.
      String oldest = '';
      DateTime? oldestAt;
      for (final MapEntry<String, DateTime> entry in _controlNonces.entries) {
        if (oldestAt == null || entry.value.isBefore(oldestAt)) {
          oldestAt = entry.value;
          oldest = entry.key;
        }
      }
      _controlNonces.remove(oldest);
    }
    _controlNonces[key] = now.add(kControlClockWindow);
    return true;
  }

  Future<void> _answerHello(HttpRequest request) async {
    _pruneNonces();
    final String nonce = _nonce();
    _nonces[nonce] = DateTime.now().add(kTransferNonceValidity);
    final PairIdentity me = PairIdentity.current;
    await _json(request, HttpStatus.ok, <String, Object?>{
      'ok': true,
      'app': 'nexus',
      'version': 1,
      'id': me.id,
      'name': me.name,
      'nonce': nonce,
    });
  }

  Future<void> _acceptFile(HttpRequest request) async {
    final HttpHeaders headers = request.headers;
    final String senderId = headers.value(kHeaderDevice)?.trim() ?? '';
    final String senderName = headers.value(kHeaderName)?.trim() ?? '';
    final String nonce = headers.value(kHeaderNonce)?.trim() ?? '';
    final String signature = headers.value(kHeaderSignature)?.trim() ?? '';
    final String rawName = headers.value(kHeaderFilename)?.trim() ?? '';
    final int? size = int.tryParse(headers.value(kHeaderSize)?.trim() ?? '');
    final String expected = _tokenOverride ?? _token ?? '';

    bool authorised = false;
    if (senderId.isNotEmpty &&
        nonce.isNotEmpty &&
        signature.isNotEmpty &&
        rawName.isNotEmpty &&
        size != null &&
        size >= 0 &&
        expected.isNotEmpty) {
      final DateTime? expiry = _nonces.remove(nonce);
      if (expiry != null && expiry.isAfter(DateTime.now())) {
        final String name = _safeName(rawName);
        final String wanted = await _sign(
          key: expected,
          senderId: senderId,
          nonce: nonce,
          filename: name,
          size: size,
        );
        authorised = constantTimeEquals(wanted, signature);
      }
    }
    if (!authorised) {
      await _json(request, HttpStatus.unauthorized, <String, Object?>{
        'ok': false,
        'error': 'pairing token not verified',
      });
      return;
    }

    final String name = _safeName(rawName);
    final int length = size!;
    if (request.contentLength >= 0 && request.contentLength != length) {
      await _json(request, HttpStatus.badRequest, <String, Object?>{
        'ok': false,
        'error': 'size does not match',
      });
      return;
    }
    final Directory? folder = await _directory();
    if (folder == null) {
      await _json(request, HttpStatus.internalServerError, <String, Object?>{
        'ok': false,
        'error': 'nowhere to save',
      });
      return;
    }
    final File target = File(
      '${folder.path}${Platform.pathSeparator}${_stamp()}-$name',
    );
    final File temp = File('${target.path}.part');
    int written = 0;
    try {
      final IOSink sink = temp.openWrite();
      try {
        await for (final List<int> chunk in request) {
          written += chunk.length;
          if (written > length) break;
          sink.add(chunk);
        }
      } finally {
        await sink.flush();
        await sink.close();
      }
      if (written != length) {
        await _deleteQuietly(temp);
        await _json(request, HttpStatus.badRequest, <String, Object?>{
          'ok': false,
          'error': 'truncated',
        });
        return;
      }
      await temp.rename(target.path);
    } catch (error) {
      await _deleteQuietly(temp);
      debugPrint('FILE LINK: could not save ($error)');
      await _json(request, HttpStatus.internalServerError, <String, Object?>{
        'ok': false,
        'error': 'could not save',
      });
      return;
    }

    final ReceivedFile received = ReceivedFile(
      path: target.path,
      name: name,
      fromId: senderId,
      fromName: senderName.isEmpty ? 'a paired device' : senderName,
      at: DateTime.now(),
    );
    _received.insert(0, received);
    notifyListeners();
    _incoming.add(received);
    debugPrint('FILE LINK: received $name from $senderName ($written bytes)');
    await _json(request, HttpStatus.ok, <String, Object?>{
      'ok': true,
      'saved': name,
    });
  }

  Future<void> _json(
    HttpRequest request,
    int status,
    Map<String, Object?> body,
  ) async {
    final HttpResponse response = request.response;
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    await response.close();
  }

  Future<String> _sign({
    required String key,
    required String senderId,
    required String nonce,
    required String filename,
    required int size,
  }) => _signRaw(
    key,
    transferSignaturePayload(
      senderId: senderId,
      nonce: nonce,
      filename: filename,
      size: size,
    ),
  );

  /// HMAC-SHA256 of [canonical] under [key], base64 — the one primitive every
  /// signature in this service is made and checked with.
  Future<String> _signRaw(String key, String canonical) async {
    final Mac mac = await Hmac.sha256().calculateMac(
      utf8.encode(canonical),
      secretKey: SecretKey(utf8.encode(key)),
    );
    return base64Encode(mac.bytes);
  }

  /// The headers a control request carries.
  ///
  /// Signed when [key] is a token this device holds for the receiver — which is
  /// what a pairing code carries, and only in the scanning direction. An empty
  /// key means the peer never gave us one, so the request goes unsigned and the
  /// receiver decides whether it knows us well enough to show it.
  Future<Map<String, String>> _controlHeaders({
    required String key,
    required String senderId,
    required String senderName,
    required String Function(String nonce, int ts) canonical,
  }) async {
    final Map<String, String> headers = <String, String>{
      kHeaderDevice: senderId,
      kHeaderName: senderName,
    };
    if (key.isEmpty) return headers;
    final String nonce = _nonce();
    final int ts = DateTime.now().millisecondsSinceEpoch;
    headers[kHeaderNonce] = nonce;
    headers[kHeaderTimestamp] = '$ts';
    headers[kHeaderSignature] = await _signRaw(key, canonical(nonce, ts));
    return headers;
  }

  String _nonce() {
    final Random rng = Random.secure();
    final List<int> bytes = List<int>.generate(18, (_) => rng.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  void _pruneNonces() {
    final DateTime now = DateTime.now();
    _nonces.removeWhere((String _, DateTime expiry) => expiry.isBefore(now));
  }

  String? _addressOf(PairedDevice device) {
    for (final String address in device.addresses) {
      if (address.trim().isNotEmpty) return address.trim();
    }
    return null;
  }

  /// The port [device]'s file link answers on, decided by asking it.
  ///
  /// A pairing record says what the *other* device was listening on when the
  /// code was shown. Records written before the mesh owned 51820 say 51820,
  /// and that number now means two different things depending on the peer: an
  /// older build answers the file link there, a newer one has its mesh on it
  /// and its link on [kFileTransferPort]. A mapping would be wrong half the
  /// time, so the link is asked directly — `hello` is the cheapest honest
  /// test, because the mesh's framed TCP listener cannot answer it. The answer
  /// is kept for the session so a ping loop pays for it once.
  Future<int> _portToDial(PairedDevice device) async {
    final String? address = _addressOf(device);
    final int stored = device.port > 0 ? device.port : port;
    if (address == null || stored == port) return stored;
    final String key = '${device.id}@$address';
    final int? known = _dialPorts[key];
    if (known != null) return known;
    for (final int candidate in <int>[stored, port]) {
      if (await _answersHello(address, candidate)) {
        _dialPorts[key] = candidate;
        return candidate;
      }
    }
    // Nothing answered the question; the stored port is the best guess left,
    // and the caller's own error message is the honest one to show.
    return stored;
  }

  /// Whether [candidate] on [address] answers the file link's `hello`.
  Future<bool> _answersHello(String address, int candidate) async {
    final HttpClient client = HttpClient()
      ..connectionTimeout = kTransferProbeTimeout;
    try {
      final HttpClientRequest request = await client
          .getUrl(
            Uri(
              scheme: 'http',
              host: address,
              port: candidate,
              path: kNexusHelloPath,
            ),
          )
          .timeout(kTransferProbeTimeout);
      final HttpClientResponse response = await request.close().timeout(
        kTransferProbeTimeout,
      );
      await response.drain<void>();
      return response.statusCode == HttpStatus.ok;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  static String _safeName(String raw) {
    String name = raw.split(RegExp(r'[/\\]')).last.trim();
    name = name.replaceAll(RegExp(r'[\x00-\x1f<>:"|?*]'), '_');
    if (name.startsWith('.')) name = '_$name';
    if (name.isEmpty) name = 'file';
    if (name.length > 120) {
      name = name.substring(name.length - 120);
    }
    return name;
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // A leftover `.part` is not worse than a lost transfer.
    }
  }

  static String _stamp() {
    final DateTime now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }

  static String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// `<documents>/received`, created on first use.
  static Future<Directory?> _defaultDirectory() async {
    try {
      final Directory documents = await getApplicationDocumentsDirectory();
      return await Directory(
        '${documents.path}${Platform.pathSeparator}received',
      ).create(recursive: true);
    } catch (error) {
      debugPrint('FILE LINK: no received folder ($error)');
      return null;
    }
  }
}
