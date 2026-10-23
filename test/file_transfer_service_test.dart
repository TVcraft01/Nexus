// The file link, with two real listeners and real bytes.
//
// Everything here is loopback: two [FileTransferService]s on ephemeral ports,
// a file in a temp folder, and the request actually crossing a socket. That is
// the point — the interesting failures (a token that does not match, a nonce
// used twice, a body that stops early) only exist once HTTP is involved.
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/file_link.dart' show FileSendResult;
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
}
