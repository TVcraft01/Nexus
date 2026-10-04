// Two-process rehearsal — requester side.
//
// Run as its own `flutter test` invocation, in a different OS process from
// the peer. This process is the "phone": it pairs with the peer over real
// loopback sockets, drives the REAL production pipeline
// (CommandService -> file_fetch core seam -> MeshService adapter ->
// DeviceExecutor) with the literal sentence `get report.pdf from my pc`,
// saves the bytes, and reports what happened.
//
// Not part of the normal suite (leading underscore is not a test glob).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent_contract.dart';
import 'package:nexus/core/capability.dart';
import 'package:nexus/core/command_service.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/mesh/mesh_service.dart';
import 'package:nexus/ui/device_executor.dart';

const _dir = '/tmp/nexus_rehearsal';
const _port = 53401;
const _sentence = 'get report.pdf from my pc';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('requester: pair with the peer process and fetch report.pdf',
      () async {
    final home = Directory(_dir);
    final prime = File('${home.path}/peer.json');
    expect(prime.existsSync(), isTrue,
        reason: 'start the peer process first (peer.json missing)');
    final peer =
        jsonDecode(prime.readAsStringSync()) as Map<String, dynamic>;

    final downloads = Directory('${home.path}/downloads')
      ..createSync(recursive: true);
    for (final e in downloads.listSync()) {
      e.deleteSync(recursive: true);
    }

    final store = NexusStore(explicitPath: '${home.path}/req_store.json')
      ..port = _port;
    await store.save();

    final mesh = MeshService(
      identity: DeviceInfo(
        id: 'req-phone',
        name: 'Rehearsal Phone',
        platform: 'android',
      ),
      store: store,
      onlineWindow: const Duration(seconds: 5),
      visibleWindow: const Duration(seconds: 5),
      heartbeatInterval: const Duration(seconds: 2),
      connectTimeout: const Duration(milliseconds: 300),
    );
    await mesh.start();

    try {
      final paired = await mesh.pairWith(
        address: '127.0.0.1',
        port: (peer['port'] as num).toInt(),
        code: peer['code'] as String,
      );
      expect(paired.ok, isTrue, reason: paired.error);

      final peerId = peer['id'] as String;
      // The paired list is populated from the handshake; give it a moment and
      // show exactly what the service will be handed.
      final waitForPair = DateTime.now().add(const Duration(seconds: 10));
      while (mesh.pairedDevices.isEmpty &&
          DateTime.now().isBefore(waitForPair)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      for (final d in mesh.pairedDevices) {
        // ignore: avoid_print
        print('PAIRED id=${d.id} name=${d.name} platform=${d.platform} '
            'online=${mesh.isOnline(d.id)}');
      }
      expect(mesh.pairedDevices, isNotEmpty, reason: 'peer not in list');
      // Wait for the peer to read as online (a real heartbeat round-trip).
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!mesh.isOnline(peerId) && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(mesh.isOnline(peerId), isTrue,
          reason: 'peer never read as online');

      // Exactly the wiring the app builds on the requesting side.
      final service = CommandService(
        devices: () => [
          for (final d in mesh.pairedDevices)
            AgentDeviceSnapshot(
              id: d.id,
              name: d.name,
              platform: d.platform,
              online: mesh.isOnline(d.id),
              capabilities: defaultCapabilitiesFor(d.platform),
            ),
        ],
        local: const AgentDeviceSnapshot(
          id: 'req-phone',
          name: 'Rehearsal Phone',
          online: true,
          platform: 'android',
        ),
      );

      final parsed = service.execute(_sentence);
      expect(parsed.status, AgentResultStatus.succeeded,
          reason: parsed.message);
      final message = parsed.dispatch! as AgentMessage;
      expect(message.action, AgentActions.fileFetch);
      expect(message.arguments!['peerId'], peerId);
      expect(message.arguments!['filename'], 'report.pdf');

      final executor = DeviceExecutor(
        fileMesh: mesh,
        fileDownloadsDir: downloads.path,
      );
      final outcome = await executor.run(
        AgentRequest(
          requestId: 'rehearsal',
          target: mesh.identity.id,
          action: AgentActions.fileFetch,
          arguments: message.arguments!,
        ),
      );

      final savedPath =
          '${downloads.path}${Platform.pathSeparator}report.pdf';
      final saved = File(savedPath);
      final served = File('${peer['served']}/report.pdf');
      final identical = saved.existsSync() &&
          served.existsSync() &&
          _sameBytes(saved.readAsBytesSync(), served.readAsBytesSync());

      File('${home.path}/result.json').writeAsStringSync(jsonEncode({
          'inFlight': message.text,
          'fetched': parsed.message,
          'outcomeOk': outcome.ok,
          'outcomeMessage': outcome.message,
          'savedPath': savedPath,
          'savedExists': saved.existsSync(),
          'savedBytes': saved.existsSync() ? saved.lengthSync() : 0,
          'sourceBytes': served.existsSync() ? served.lengthSync() : 0,
        'bytesIdentical': identical,
      }));
      File('${home.path}/done').writeAsStringSync('ok');

      expect(outcome.ok, isTrue, reason: outcome.message);
      expect(outcome.message, contains(savedPath));
      expect(identical, isTrue, reason: 'received bytes differ from source');
    } finally {
      await mesh.stop();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
