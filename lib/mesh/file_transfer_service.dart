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
// encrypted session between MeshService instances, and this front end runs no
// MeshService. What both sides do share is the pairing record, which is the
// only thing a transfer needs to be allowed.
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
import '../core/paired_devices.dart' show PairedDevice;

/// The port the listener answers on, and the one a pairing code advertises.
///
/// 51820 is the mesh's default port, which discovery already announces; making
/// the HTTP listener answer there is what turns that announcement into a fact
/// rather than a hint about a port nothing listens on.
const int kFileTransferPort = 51820;

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
  });

  final String deviceId;

  /// The name the sender claimed. It is shown, not trusted: a ping carries no
  /// data and changes nothing, so the worst a false name can do is mislabel a
  /// notification.
  final String deviceName;
  final DateTime at;

  @override
  String toString() => 'NexusPing($deviceName)';
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

/// The listener, the sender, and the list of what arrived.
class FileTransferService extends ChangeNotifier implements FileTransport {
  FileTransferService({
    this.port = kFileTransferPort,
    Future<Directory?> Function()? directory,
    String? token,
  }) : _directory = directory ?? _defaultDirectory,
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

  /// The port asked for. [boundPort] is the one actually listening, which
  /// differs when this was constructed with port 0.
  final int port;
  int get boundPort => _server?.port ?? _boundPort;
  int _boundPort = 0;

  final Future<Directory?> Function() _directory;
  final String? _tokenOverride;

  HttpServer? _server;
  bool _running = false;
  bool _starting = false;
  String? _problem;
  String? _token;

  /// Nonces offered by [start]-time, with the moment they stop being valid.
  final Map<String, DateTime> _nonces = <String, DateTime>{};

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
  Future<void> start() async {
    if (_running || _starting) return;
    _starting = true;
    _problem = null;
    try {
      _token = _tokenOverride ?? await PairToken.current();
      final HttpServer server = await HttpServer.bind(
        InternetAddress.anyIPv4,
        port,
      );
      _server = server;
      _boundPort = server.port;
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
    final int port = _portOf(device);
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

  /// Sends a ping to [device] — a POST to `/nexus/ping` carrying only this
  /// device's id and name.
  ///
  /// Deliberately not authenticated with the transfer token. Pairing in this
  /// shell is one-way (only the scanner learns the shower's token), so a signed
  /// ping would work in one direction and silently fail in the other. A ping
  /// reads nothing and changes nothing; the receiver rate-limits by the fact
  /// that showing a notification is cheap, and the LAN is already the trust
  /// boundary for this feature.
  Future<NexusRequestResult> ping(PairedDevice device) async {
    final String? address = _addressOf(device);
    if (address == null) {
      return NexusRequestResult(
        ok: false,
        message: '${device.name} hasn\'t shared an address yet.',
      );
    }
    final PairIdentity me = PairIdentity.current;
    final HttpClient client = HttpClient()
      ..connectionTimeout = kTransferProbeTimeout;
    try {
      final HttpClientRequest request = await client
          .postUrl(
            Uri(
              scheme: 'http',
              host: address,
              port: _portOf(device),
              path: kNexusPingPath,
            ),
          )
          .timeout(kTransferProbeTimeout);
      request.headers
        ..set(kHeaderDevice, me.id)
        ..set(kHeaderName, me.name);
      request.contentLength = 0;
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
    final HttpClient client = _mouseClient ??= (HttpClient()
      ..connectionTimeout = kTransferProbeTimeout);
    try {
      final HttpClientRequest request = await client
          .postUrl(
            Uri(
              scheme: 'http',
              host: address,
              port: _portOf(device),
              path: kNexusMousePath,
            ),
          )
          .timeout(kTransferProbeTimeout);
      request.headers
        ..contentType = ContentType.json
        ..set(kHeaderDevice, me.id)
        ..set(kHeaderName, me.name);
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
    final HttpClient client = HttpClient()
      ..connectionTimeout = kTransferProbeTimeout;
    try {
      final HttpClientRequest request = await client
          .postUrl(
            Uri(
              scheme: 'http',
              host: address,
              port: _portOf(device),
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

  /// A ping is a nudge, not a transfer: read the two headers and publish it.
  ///
  /// No token check, because this shell's pairing is one-way and the side that
  /// did not scan has no token to sign with. The request carries no file, no
  /// command and no persisted state; its whole effect is a notification.
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
    final NexusPing ping = NexusPing(
      deviceId: senderId,
      deviceName: senderName.isEmpty ? 'a paired device' : senderName,
      at: DateTime.now(),
    );
    _pings.add(ping);
    debugPrint('NEXUS ping: ${ping.deviceName} <- $senderId');
    await _json(request, HttpStatus.ok, <String, Object?>{'ok': true});
  }

  /// One trackpad movement. The endpoint is real; the pointer bridge that will
  /// consume [mouse] is not built yet, so this publishes the event and logs it
  /// rather than pretending to move a cursor.
  Future<void> _acceptMouse(HttpRequest request) async {
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
    final NexusMouseEvent event = NexusMouseEvent(
      dx: dx,
      dy: dy,
      click: decoded['click'] == true,
    );
    _mouse.add(event);
    debugPrint('NEXUS mouse: $event');
    await _json(request, HttpStatus.ok, <String, Object?>{'ok': true});
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
  }) async {
    final Mac mac = await Hmac.sha256().calculateMac(
      utf8.encode(
        transferSignaturePayload(
          senderId: senderId,
          nonce: nonce,
          filename: filename,
          size: size,
        ),
      ),
      secretKey: SecretKey(utf8.encode(key)),
    );
    return base64Encode(mac.bytes);
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

  int _portOf(PairedDevice device) =>
      device.port > 0 ? device.port : kFileTransferPort;

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
