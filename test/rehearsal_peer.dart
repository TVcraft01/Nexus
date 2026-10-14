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

const _defaultDir = '/tmp/nexus_rehearsal';
const _defaultPort = 53400;

/// Where this run works. A second peer — the device run wants more than one
/// reachable link to draw a mesh with — starts with its own directory, so the
/// two do not fight over one store or one handoff file.
String get _dir => Platform.environment['NEXUS_PEER_DIR'] ?? _defaultDir;

/// The port the peer listens on.
///
/// Defaults to the one `tool/rehearsal.sh` expects. A device run reaches the
/// peer through `adb reverse tcp:51999 tcp:51820`, which lands on the PC's
/// 51820 — so that run starts the peer with `NEXUS_PEER_PORT=51820` rather
/// than moving the tunnel, because the tunnel's ports are the ones the
/// product's own cable pairing opens.
int get _port =>
    int.tryParse(Platform.environment['NEXUS_PEER_PORT'] ?? '') ??
    _defaultPort;

/// How long the peer waits for the requester's `done` file before giving up.
/// The two-process rehearsal finishes in seconds; a device run keeps the peer
/// up for as long as the phone needs it.
Duration get _life => Duration(
  minutes:
      int.tryParse(Platform.environment['NEXUS_PEER_MINUTES'] ?? '') ?? 3,
);

/// Who this peer says it is.
///
/// Two peers on one machine must not share a device id: a device run pairs
/// with both, and the phone keeps its pairings in a map keyed by id — the
/// second peer would overwrite the first, and the mesh would look like one
/// link no matter how many are up.
String get _peerId => Platform.environment['NEXUS_PEER_ID'] ?? 'peer-pc';
String get _peerName =>
    Platform.environment['NEXUS_PEER_NAME'] ?? 'Rehearsal PC';

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
  store.pairingEnabled = true;
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
    _writeFixtures(served);

    final store = await openPeerStore('${home.path}/peer_store.json');

    final mesh = MeshService(
      identity: DeviceInfo(id: _peerId, name: _peerName, platform: 'linux'),
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
      'id': _peerId,
      'name': _peerName,
      'served': served.path,
      'bytes': bytes.length,
    }));
    // ignore: avoid_print
    print('PEER-READY code=${session.code} port=${mesh.port}');

    final deadline = DateTime.now().add(_life);
    while (!File('${home.path}/done').existsSync()) {
      if (DateTime.now().isAfter(deadline)) {
        await mesh.stop();
        fail('requester never finished');
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    await mesh.stop();
  }, timeout: const Timeout(Duration(minutes: 90)));
}

/// Plants the files a device run browses.
///
/// The two-process rehearsal only ever asks for `report.pdf`, but the phone's
/// Files screen is a real browser: it needs folders to walk into and real
/// image files to draw thumbnails from, or the thumbnails would be measured
/// against a directory with no images in it. The PNGs are the app's own
/// launcher icons, copied rather than invented — real image data, no new
/// dependency, and two genuinely different sizes to prove the decode path
/// scales the picture down instead of trusting the source.
void _writeFixtures(Directory served) {
  final photos = Directory('${served.path}/photos')..createSync(recursive: true);
  Directory('${served.path}/notes').createSync(recursive: true);

  const icons = {
    'sunset.png': 'android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png',
    'wall.png': 'android/app/src/main/res/mipmap-mdpi/ic_launcher.png',
    'badge.png': 'assets/tray_icon.png',
  };
  icons.forEach((name, source) {
    final file = File(source);
    if (file.existsSync()) {
      file.copySync('${photos.path}/$name');
    }
  });

  File('${served.path}/notes/todo.txt').writeAsStringSync(
    'buy milk\nfind the charger\ncall the landlord\n',
  );
  File('${served.path}/notes/ideas.txt').writeAsStringSync(
    'move the assistant greeting to the middle of the screen\n',
  );
}
