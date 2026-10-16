// TEMPORARY device-run driver — not part of the suite, deleted after use.
//
// A "Rehearsal PC" peer for the on-phone clipboard check: real MeshService
// with an in-memory clipboard the run controls through a command file, so
// "copy on the PC" travels the production poll path (1.5 s clipboard poll
// -> push to all paired peers) exactly like a user copy.
//
// Protocol, all files under $NEXUS_PEER_DIR (default /tmp/nexus_clipboard):
//   peer writes peer.json {code, port, id, name} when pairing is open.
//   controller writes cmd.txt with one line: COPY <text> | STATUS | DONE
//   peer answers by writing ack.txt and deleting cmd.txt.
//     COPY -> ack "ok" once the fake clipboard holds the text.
//     STATUS -> ack "paired:<id,...>" (empty when nobody paired yet).
//     DONE -> ack "bye", peer stops.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/mesh/mesh_service.dart';

class _FakeClipboard implements ClipboardBackend {
  String? value;
  @override
  Future<String?> readText() async => value;
  @override
  Future<void> writeText(String text) async => value = text;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('clipboard probe peer', () async {
    final dirPath =
        Platform.environment['NEXUS_PEER_DIR'] ?? '/tmp/nexus_clipboard';
    final port =
        int.tryParse(Platform.environment['NEXUS_PEER_PORT'] ?? '') ?? 51820;
    final home = Directory(dirPath)..createSync(recursive: true);
    for (final name in ['peer.json', 'cmd.txt', 'ack.txt', 'done']) {
      final f = File('${home.path}/$name');
      if (f.existsSync()) f.deleteSync();
    }

    final store = NexusStore(explicitPath: '${home.path}/peer_store.json');
    await store.load();
    store.port = port;
    store.clipboardSync = true;
    await store.save();

    final clip = _FakeClipboard();
    final mesh = MeshService(
      identity: DeviceInfo(
        id: 'peer-pc-clip',
        name: 'Rehearsal PC',
        platform: 'linux',
      ),
      store: store,
      clipboard: clip,
      heartbeatInterval: const Duration(seconds: 2),
      connectTimeout: const Duration(milliseconds: 300),
    );
    await mesh.start();
    final session = mesh.beginPairing();
    File('${home.path}/peer.json').writeAsStringSync(
      jsonEncode({
        'code': session.code,
        'port': mesh.port,
        'id': 'peer-pc-clip',
        'name': 'Rehearsal PC',
      }),
    );
    // ignore: avoid_print
    print('PROBE-READY code=${session.code} port=${mesh.port}');

    final deadline = DateTime.now().add(const Duration(minutes: 30));
    while (true) {
      if (DateTime.now().isAfter(deadline)) {
        await mesh.stop();
        fail('controller never finished');
      }
      final cmd = File('${home.path}/cmd.txt');
      if (cmd.existsSync()) {
        final line = cmd.readAsStringSync();
        cmd.deleteSync();
        if (line.startsWith('COPY ')) {
          clip.value = line.substring(5);
          File('${home.path}/ack.txt').writeAsStringSync('ok');
        } else if (line == 'STATUS') {
          File('${home.path}/ack.txt').writeAsStringSync(
            'paired:${mesh.pairedDevices.map((d) => d.id).join(',')}',
          );
        } else if (line == 'DONE') {
          File('${home.path}/ack.txt').writeAsStringSync('bye');
          break;
        } else {
          File('${home.path}/ack.txt').writeAsStringSync('unknown-command');
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    await mesh.stop();
  }, timeout: const Timeout(Duration(minutes: 40)));
}
