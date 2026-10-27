// The file link, with two real listeners and real bytes.
//
// Everything here is loopback: two [FileTransferService]s on ephemeral ports,
// a file in a temp folder, and the request actually crossing a socket. That is
// the point — the interesting failures (a token that does not match, a nonce
// used twice, a body that stops early) only exist once HTTP is involved.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/file_link.dart' show FileSendResult;
import 'package:nexus/core/pair_invite.dart' show PairIdentity;
import 'package:nexus/core/paired_devices.dart';
import 'package:nexus/mesh/file_transfer_service.dart';

/// One service, its folder, and the paired row that points at it.
class _Peer {
  _Peer(this.service, this.folder);

  final FileTransferService service;
  final Directory folder;

  int get port => service.boundPort;

  PairedDevice device({String? token, int? port}) => PairedDevice(
    id: 'study-laptop-0000000000000000000001',
    name: 'Study laptop',
    publicKey: 'key',
    addresses: const <String>['127.0.0.1'],
    port: port ?? this.port,
    code: token ?? service.token,
  );

  Future<void> dispose() async {
    await service.stop();
    if (folder.existsSync()) folder.deleteSync(recursive: true);
  }
}

Future<_Peer> _peer(String token) async {
  final Directory folder = Directory.systemTemp.createTempSync('nexus-rx-');
  final FileTransferService service = FileTransferService(
    port: 0,
    directory: () async => folder,
    token: token,
  );
  await service.start();
  expect(service.running, isTrue, reason: service.problem ?? 'no problem said');
  return _Peer(service, folder);
}

/// A deterministic file of [bytes] bytes.
File _source(Directory dir, int bytes) {
  final File file = File('${dir.path}/photo.png');
  file.writeAsBytesSync(List<int>.generate(bytes, (int i) => i % 251));
  return file;
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

/// HMAC of one canonical control string, so a test can forge every part of a
/// signed request rather than only the parts the service happens to build.
Future<String> _signRaw(String key, String canonical) async {
  final Mac mac = await Hmac.sha256().calculateMac(
    utf8.encode(canonical),
    secretKey: SecretKey(utf8.encode(key)),
  );
  return base64Encode(mac.bytes);
}

/// One hand-built POST, for the requests the client would never send: a bad
/// signature, a stale timestamp, a name nobody proved.
Future<int> _post(
  int port,
  String path, {
  Map<String, String> headers = const <String, String>{},
  Object? body,
}) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest request = await client.postUrl(
      Uri(scheme: 'http', host: '127.0.0.1', port: port, path: path),
    );
    headers.forEach(request.headers.set);
    if (body == null) {
      request.contentLength = 0;
    } else {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final HttpClientResponse response = await request.close();
    await response.drain<void>();
    return response.statusCode;
  } finally {
    client.close(force: true);
  }
}

void main() {
  late Directory root;
  late _Peer receiver;
  late _Peer sender;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('nexus-tx-');
    receiver = await _peer('receiver-token-0123456789');
    sender = await _peer('sender-token-0123456789');
  });

  tearDown(() async {
    await sender.dispose();
    await receiver.dispose();
    root.deleteSync(recursive: true);
  });

  test('sends the bytes, moves the bar, and lands the file', () async {
    final File source = _source(root, 300 * 1024);
    final List<double> progress = <double>[];
    final Future<ReceivedFile> arriving = receiver.service.incoming.first
        .timeout(const Duration(seconds: 10));

    final FileSendResult result = await sender.service.send(
      path: source.path,
      device: receiver.device(),
      onProgress: progress.add,
    );

    expect(result.ok, isTrue, reason: result.message);
    expect(result.message, contains('photo.png'));
    expect(result.message, contains('Study laptop'));

    final ReceivedFile arrived = await arriving;
    expect(arrived.name, 'photo.png');
    expect(arrived.fromName, isNotEmpty);
    expect(arrived.isImage, isTrue);
    expect(File(arrived.path).readAsBytesSync(), source.readAsBytesSync());
    // The sender's line and the receiver's list are the same transfer.
    expect(receiver.service.received.single.path, arrived.path);

    // Real fractions of a real body: monotonic, inside 0..1, finished.
    expect(progress, isNotEmpty);
    expect(progress.first, greaterThan(0));
    expect(progress.last, 1);
    for (int i = 1; i < progress.length; i++) {
      expect(progress[i], greaterThanOrEqualTo(progress[i - 1]));
    }
    expect(progress.every((double p) => p > 0 && p <= 1), isTrue);
  });

  test('a wrong pairing token is refused, and no file is written', () async {
    final File source = _source(root, 20 * 1024);
    final Future<ReceivedFile> nothing = receiver.service.incoming.first
        .timeout(const Duration(milliseconds: 400), onTimeout: () => throw 'none');

    final FileSendResult result = await sender.service.send(
      path: source.path,
      device: receiver.device(token: 'not-the-receivers-token'),
    );

    expect(result.ok, isFalse);
    expect(result.message, contains('refused'));
    expect(result.message, contains('QR'));
    await expectLater(nothing, throwsA('none'));
    expect(receiver.folder.listSync(), isEmpty);
    expect(receiver.service.received, isEmpty);
  });

  test('a pairing with no token is refused before the network', () async {
    final File source = _source(root, 1024);

    final FileSendResult result = await sender.service.send(
      path: source.path,
      device: receiver.device(token: ''),
    );

    expect(result.ok, isFalse);
    expect(result.message, contains('no transfer token'));
    expect(result.message, contains('QR'));
  });

  test('a device with no address says so instead of guessing', () async {
    final File source = _source(root, 1024);
    final PairedDevice nowhere = PairedDevice(
      id: 'nowhere-0000000000000000000000001',
      name: 'Study laptop',
      publicKey: 'key',
      code: receiver.service.token,
      port: receiver.port,
    );

    final FileSendResult result = await sender.service.send(
      path: source.path,
      device: nowhere,
    );

    expect(result.ok, isFalse);
    expect(result.message, contains("hasn't said where it is"));
  });

  test('probe answers while the listener is up, and not after it stops',
      () async {
    expect(await sender.service.probe(receiver.device()), isTrue);

    final int port = receiver.port;
    await receiver.service.stop();

    expect(await sender.service.probe(receiver.device(port: port)), isFalse);
  });

  test('hello names the device and offers a fresh nonce each time', () async {
    final FileTransferHello first = (await sender.service.hello(
      receiver.device(),
    ))!;
    final FileTransferHello second = (await sender.service.hello(
      receiver.device(),
    ))!;

    expect(first.deviceId, isNotEmpty);
    expect(first.deviceName, isNotEmpty);
    expect(first.nonce.length, greaterThan(8));
    expect(second.nonce, isNot(first.nonce));
  });

  test('a nonce is worth one request, not two', () async {
    final File source = _source(root, 4096);
    final int size = source.lengthSync();
    final FileTransferHello hello = (await sender.service.hello(
      receiver.device(),
    ))!;
    final String signature = await _sign(
      key: receiver.service.token,
      senderId: 'sender-device-0001',
      nonce: hello.nonce,
      filename: 'photo.png',
      size: size,
    );

    Future<int> post() async {
      final HttpClient client = HttpClient();
      try {
        final HttpClientRequest request = await client.postUrl(
          Uri(
            scheme: 'http',
            host: '127.0.0.1',
            port: receiver.port,
            path: kNexusFilePath,
          ),
        );
        request.headers
          ..set(kHeaderDevice, 'sender-device-0001')
          ..set(kHeaderName, 'Sender')
          ..set(kHeaderNonce, hello.nonce)
          ..set(kHeaderSignature, signature)
          ..set(kHeaderFilename, 'photo.png')
          ..set(kHeaderSize, '$size');
        request.contentLength = size;
        request.add(source.readAsBytesSync());
        final HttpClientResponse response = await request.close();
        await response.drain<void>();
        return response.statusCode;
      } finally {
        client.close(force: true);
      }
    }

    expect(await post(), HttpStatus.ok);
    expect(await post(), HttpStatus.unauthorized);
    expect(receiver.service.received, hasLength(1));
  });

  group('control requests are signed when the pairing gave a token', () {
    const String senderId = 'study-laptop-0000000000000000000001';

    /// The receiver knows one device by name — the sender — and nobody else.
    Future<_Peer> receiverKnowing(String name, {bool emptyToken = false}) async {
      final _Peer peer = await _peer(emptyToken ? '' : 'receiver-token-0123456789');
      peer.service.peerNameLookup = (String id) => id == senderId ? name : null;
      addTearDown(peer.dispose);
      return peer;
    }

    test('a ping from a token holder verifies, and is not badged', () async {
      final Future<NexusPing> arriving = receiver.service.pings.first;

      final NexusRequestResult result = await sender.service.ping(
        // The row carries the receiver's token — what a scan of its QR writes.
        receiver.device(token: receiver.service.token),
      );

      expect(result.ok, isTrue, reason: result.message);
      final NexusPing ping = await arriving.timeout(const Duration(seconds: 2));
      expect(ping.verified, isTrue);
      expect(ping.deviceId, PairIdentity.current.id);
    });

    test('a signature that does not verify is refused, never downgraded', () async {
      final List<NexusPing> seen = <NexusPing>[];
      final StreamSubscription<NexusPing> sub = receiver.service.pings.listen(
        seen.add,
      );
      addTearDown(sub.cancel);
      final int ts = DateTime.now().millisecondsSinceEpoch;
      final int status = await _post(
        receiver.port,
        kNexusPingPath,
        headers: <String, String>{
          kHeaderDevice: senderId,
          kHeaderName: 'Your bank',
          kHeaderNonce: 'nonce-1',
          kHeaderTimestamp: '$ts',
          kHeaderSignature: 'bm90LWEtc2lnbmF0dXJl',
        },
      );

      expect(status, HttpStatus.unauthorized);
      // A forged signature is a forged signature: it does not fall back to the
      // unsigned path, even though this id is one the receiver knows.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(seen, isEmpty);
    });

    test('an unsigned ping from an unknown device is refused', () async {
      // The attack `docs/notes/known-surfaces.md` recorded: anything on the LAN
      // posting two headers, one of them a bank's name.
      final int status = await _post(
        receiver.port,
        kNexusPingPath,
        headers: <String, String>{
          kHeaderDevice: 'stranger-on-the-wifi',
          kHeaderName: 'Your bank',
        },
      );

      expect(status, HttpStatus.unauthorized);
    });

    test('an unsigned ping from a paired device shows our name, badged', () async {
      final _Peer known = await receiverKnowing('Kitchen tablet');
      final Future<NexusPing> arriving = known.service.pings.first;

      final int status = await _post(
        known.port,
        kNexusPingPath,
        headers: <String, String>{
          kHeaderDevice: senderId,
          // The claimed name is the attack the badge does not have to stop:
          // it never reaches the screen.
          kHeaderName: 'Your bank',
        },
      );

      expect(status, HttpStatus.ok);
      final NexusPing ping = await arriving.timeout(const Duration(seconds: 2));
      expect(ping.verified, isFalse);
      expect(ping.deviceName, 'Kitchen tablet');
    });

    test('a device that signed once cannot fall back to unsigned', () async {
      final _Peer known = await receiverKnowing('Kitchen tablet');
      final Future<NexusPing> first = known.service.pings.first;
      final int ts = DateTime.now().millisecondsSinceEpoch;
      final String signature = await _signRaw(
        known.service.token,
        pingSignaturePayload(senderId: senderId, nonce: 'n-1', ts: ts),
      );

      expect(
        await _post(
          known.port,
          kNexusPingPath,
          headers: <String, String>{
            kHeaderDevice: senderId,
            kHeaderName: 'Kitchen tablet',
            kHeaderNonce: 'n-1',
            kHeaderTimestamp: '$ts',
            kHeaderSignature: signature,
          },
        ),
        HttpStatus.ok,
      );
      await first.timeout(const Duration(seconds: 2));

      // Same device, same pairing, signature stripped: refused, because it has
      // already proved it can sign.
      expect(
        await _post(
          known.port,
          kNexusPingPath,
          headers: <String, String>{
            kHeaderDevice: senderId,
            kHeaderName: 'Kitchen tablet',
          },
        ),
        HttpStatus.unauthorized,
      );
    });

    test('a ping minted outside the clock window is refused', () async {
      final _Peer known = await receiverKnowing('Kitchen tablet');
      final int stale =
          DateTime.now()
              .subtract(kControlClockWindow + const Duration(seconds: 10))
              .millisecondsSinceEpoch;
      final String signature = await _signRaw(
        known.service.token,
        pingSignaturePayload(senderId: senderId, nonce: 'old-nonce', ts: stale),
      );

      expect(
        await _post(
          known.port,
          kNexusPingPath,
          headers: <String, String>{
            kHeaderDevice: senderId,
            kHeaderName: 'Kitchen tablet',
            kHeaderNonce: 'old-nonce',
            kHeaderTimestamp: '$stale',
            kHeaderSignature: signature,
          },
        ),
        HttpStatus.unauthorized,
      );
    });

    test('the same nonce twice is refused, however valid the signature', () async {
      final _Peer known = await receiverKnowing('Kitchen tablet');
      final Future<NexusPing> first = known.service.pings.first;
      final int ts = DateTime.now().millisecondsSinceEpoch;
      final String signature = await _signRaw(
        known.service.token,
        pingSignaturePayload(senderId: senderId, nonce: 'reused', ts: ts),
      );
      final Map<String, String> headers = <String, String>{
        kHeaderDevice: senderId,
        kHeaderName: 'Kitchen tablet',
        kHeaderNonce: 'reused',
        kHeaderTimestamp: '$ts',
        kHeaderSignature: signature,
      };

      expect(
        await _post(known.port, kNexusPingPath, headers: headers),
        HttpStatus.ok,
      );
      await first.timeout(const Duration(seconds: 2));
      expect(
        await _post(known.port, kNexusPingPath, headers: headers),
        HttpStatus.unauthorized,
      );
    });

    test('a fresh install with no token accepts unsigned, refuses signed', () async {
      // Nothing to verify against yet: a signed request is a claim this build
      // cannot check, so it is refused — while an unsigned one from a device
      // the shell knows is shown, badged.
      final _Peer fresh = await receiverKnowing('Kitchen tablet', emptyToken: true);
      expect(fresh.service.token, isEmpty);
      final Future<NexusPing> arriving = fresh.service.pings.first;

      expect(
        await _post(
          fresh.port,
          kNexusPingPath,
          headers: <String, String>{
            kHeaderDevice: senderId,
            kHeaderName: 'Kitchen tablet',
          },
        ),
        HttpStatus.ok,
      );
      final NexusPing ping = await arriving.timeout(const Duration(seconds: 2));
      expect(ping.verified, isFalse);

      final int ts = DateTime.now().millisecondsSinceEpoch;
      expect(
        await _post(
          fresh.port,
          kNexusPingPath,
          headers: <String, String>{
            kHeaderDevice: senderId,
            kHeaderName: 'Kitchen tablet',
            kHeaderNonce: 'n-fresh',
            kHeaderTimestamp: '$ts',
            kHeaderSignature: await _signRaw(
              'whatever-it-claims',
              pingSignaturePayload(
                senderId: senderId,
                nonce: 'n-fresh',
                ts: ts,
              ),
            ),
          },
        ),
        HttpStatus.unauthorized,
      );
    });
  });

  group('the cursor needs a proved sender', () {
    test('a signed movement arrives, coordinates and all', () async {
      final Future<NexusMouseEvent> arriving = receiver.service.mouse.first;

      final bool sent = await sender.service.sendMouse(
        receiver.device(token: receiver.service.token),
        dx: 3.5,
        dy: -2.25,
        click: true,
      );

      expect(sent, isTrue);
      final NexusMouseEvent event = await arriving.timeout(
        const Duration(seconds: 2),
      );
      expect(event.dx, 3.5);
      expect(event.dy, -2.25);
      expect(event.click, isTrue);
    });

    test('an unsigned movement is refused outright', () async {
      final int status = await _post(
        receiver.port,
        kNexusMousePath,
        headers: <String, String>{
          kHeaderDevice: 'study-laptop-0000000000000000000001',
          kHeaderName: 'Study laptop',
        },
        body: <String, Object>{'x': 1.0, 'y': 2.0},
      );

      // Paired or not, a name is a label and a cursor is an effect.
      expect(status, HttpStatus.unauthorized);
    });
  });
}
