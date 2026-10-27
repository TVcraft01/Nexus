// Two builds, one port question.
//
// The file link used to own TCP 51820. On the launched path the mesh owns it
// now, and the link answers on 51821. That split has to keep three cases
// working at once: a new build talking to a new one (both on 51821), a new
// build talking to one that still answers on 51820, and this build on a host
// where the mesh is not running at all (the link keeps 51820, because that is
// where existing pairings dial).
//
// The bind ladder covers the first and third; the dial question covers the
// second. Both are exercised here against real sockets on loopback.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/paired_devices.dart';
import 'package:nexus/mesh/file_transfer_service.dart';

/// A port the system has just handed back, so it is certain to be closed.
Future<int> _closedPort() async {
  final ServerSocket probe = await ServerSocket.bind(
    InternetAddress.loopbackIPv4,
    0,
  );
  final int port = probe.port;
  await probe.close();
  return port;
}

void main() {
  late Directory folder;

  setUp(() {
    folder = Directory.systemTemp.createTempSync('nexus-link-');
  });

  tearDown(() {
    if (folder.existsSync()) folder.deleteSync(recursive: true);
  });

  test('walks the ladder until a port binds', () async {
    // Two ports this test holds, standing in for "the first rung is taken".
    // Occupying the real 51820 would be competing with every other test
    // isolate on the machine, so the walk is exercised on ports we own.
    final ServerSocket first = await ServerSocket.bind(
      InternetAddress.anyIPv4,
      0,
    );
    final ServerSocket second = await ServerSocket.bind(
      InternetAddress.anyIPv4,
      0,
    );
    addTearDown(first.close);
    addTearDown(second.close);

    final FileTransferService service = FileTransferService(
      directory: () async => folder,
      bindLadder: <int>[first.port, second.port, 0],
    );
    addTearDown(service.stop);
    await service.start();

    expect(service.problem, isNull);
    expect(service.boundPort, isNot(first.port));
    expect(service.boundPort, isNot(second.port));
    expect(service.boundPort, greaterThan(0));
  });

  test('the shipped ladder puts the mesh\'s port first, then the link\'s', () {
    // The order is the design: a build with no mesh on 51820 keeps answering
    // where existing pairings dial, and the launched path — whose mesh holds
    // 51820 — falls through to the link's own port.
    expect(
      FileTransferService().debugBindLadder,
      <int>[kLegacyFileTransferPort, kFileTransferPort, 0],
    );
    expect(kLegacyFileTransferPort, 51820);
    expect(kFileTransferPort, 51821);
  });

  test('a stated port is the only port tried', () async {
    // A test that asks for its own ephemeral port must not be walked up a
    // ladder that starts at the mesh's port.
    final FileTransferService service = FileTransferService(
      port: 0,
      directory: () async => folder,
    );
    addTearDown(service.stop);
    await service.start();

    expect(service.problem, isNull);
    expect(service.boundPort, greaterThan(0));
    expect(service.boundPort, isNot(kLegacyFileTransferPort));
  });

  test('a record written before the split is asked where it answers', () async {
    // The receiver is this build: it answers on an ephemeral port, which is
    // what `port` means to the sender below.
    final FileTransferService receiver = FileTransferService(
      port: 0,
      directory: () async => folder,
      token: 'token-both-sides-know',
    );
    addTearDown(receiver.stop);
    await receiver.start();

    // The sender's own link port is the receiver's, standing in for 51821.
    final FileTransferService sender = FileTransferService(
      port: receiver.boundPort,
    );
    addTearDown(sender.stop);

    // The pairing row says 51820 — nothing is listening there now.
    final int stalePort = await _closedPort();
    final PairedDevice legacy = PairedDevice(
      id: 'peer-from-an-older-build',
      name: 'Older phone',
      publicKey: 'key',
      addresses: const <String>['127.0.0.1'],
      port: stalePort,
      code: 'token-both-sides-know',
    );

    final NexusRequestResult result = await sender.ping(legacy);
    expect(
      result.ok,
      isTrue,
      reason: 'the link should have asked which port answers: ${result.message}',
    );
  });
}
