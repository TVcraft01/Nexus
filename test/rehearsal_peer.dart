// Two-process rehearsal — peer side.
//
// Run as its own `flutter test` invocation (a separate OS process / Dart VM)
// from the requester. This process is the "PC": it serves report.pdf over a
// real MeshService, publishes its one-time pairing code to a handoff file,
// and stays alive until the requester writes `done`.
//
// Not part of the normal suite (leading underscore is not a test glob).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/mesh/mesh_service.dart';

const _dir = '/tmp/nexus_rehearsal';
const _port = 53400;

/// Opens the peer's store: read what is already there, then point it at
/// [_port].
///
/// The order is the whole point. `save()` writes the map the store holds, and
/// a store that has never loaded holds only defaults — so saving *before*
/// loading overwrites the file and forgets every device this peer was paired
/// with. That is what happened on the 2026-10-07 device run: the peer was
/// restarted to prove the phone reconnects, came back paired with nobody, and
/// never dialled the phone, which read as a reconnect bug in the product and
/// was not one. Guards: test/rehearsal_peer_store_test.dart.
Future<NexusStore> openPeerStore(String path) async {
  final store = NexusStore(explicitPath: path);
  await store.load();
  store.port = _port;
  await store.save();
  return store;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('peer: serve report.pdf and hold the mesh open for the requester',
      () async {
    final home = Directory(_dir)..createSync(recursive: true);
    // Clear any stale handoff from a previous run.
    for (final name in ['peer.json', 'done', 'result.json']) {
      final f = File('${home.path}/$name');
      if (f.existsSync()) f.deleteSync();
    }
    final served = Directory('${home.path}/served')..createSync(recursive: true);
    final bytes = List<int>.generate(4096, (i) => (i * 7) % 256);
    File('${served.path}/report.pdf').writeAsBytesSync(bytes);

    final store = await openPeerStore('${home.path}/peer_store.json');

    final mesh = MeshService(
      identity: DeviceInfo(
        id: 'peer-pc',
        name: 'Rehearsal PC',
        platform: 'linux',
      ),
      store: store,
      fileRoot: served.path,
      onlineWindow: const Duration(seconds: 5),
      visibleWindow: const Duration(seconds: 5),
      heartbeatInterval: const Duration(seconds: 2),
      connectTimeout: const Duration(milliseconds: 300),
    );
    await mesh.start();
    final session = mesh.beginPairing();
    File('${home.path}/peer.json').writeAsStringSync(jsonEncode({
      'code': session.code,
      'port': mesh.port,
      'id': 'peer-pc',
      'name': 'Rehearsal PC',
      'served': served.path,
      'bytes': bytes.length,
    }));
    // ignore: avoid_print
    print('PEER-READY code=${session.code} port=${mesh.port}');

    final deadline = DateTime.now().add(const Duration(minutes: 3));
    while (!File('${home.path}/done').existsSync()) {
      if (DateTime.now().isAfter(deadline)) {
        await mesh.stop();
        fail('requester never finished');
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    await mesh.stop();
  }, timeout: const Timeout(Duration(minutes: 4)));
}
