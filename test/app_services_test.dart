// The bootstrap: who this device is, where it is kept, and that the mesh is
// really running on the launched path.
//
// These are the promises pass 1 makes. Before it, `main_ui.dart` started no
// mesh and `PairIdentity` invented a new id each launch, so a peer that had
// scanned this device's QR was holding an id this process would never answer
// to again. Every assertion below is about that ending: one id, kept in the
// store, spoken by the QR and the mesh, and a listening socket that is given
// back when the app stops.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/app_services.dart';
import 'package:nexus/core/pair_invite.dart';
import 'package:nexus/mesh/mesh_service.dart' show ClipboardBackend;

/// A clipboard that lives in memory — no platform channel in a test.
class _FakeClipboard implements ClipboardBackend {
  String? value;

  @override
  Future<String?> readText() async => value;

  @override
  Future<void> writeText(String text) async => value = text;
}

void main() {
  late Directory dataDir;

  setUp(() {
    dataDir = Directory.systemTemp.createTempSync('nexus-bootstrap-');
  });

  tearDown(() {
    if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
  });

  test('keeps this device\'s id across two launches', () async {
    final AppServices first = await startAppServices(
      dataDir: dataDir.path,
      clipboard: _FakeClipboard(),
    );
    final String id = first.identity.id;
    expect(id, isNotEmpty);
    expect(id, isNot('unknown'));

    // A second launch is a second process: nothing is memoised any more, so
    // the only way the id comes back is out of the store.
    await stopAppServices(first);
    PairIdentity.debugReset();

    final AppServices second = await startAppServices(
      dataDir: dataDir.path,
      clipboard: _FakeClipboard(),
    );
    addTearDown(() => stopAppServices(second));

    expect(second.identity.id, id);
    expect(second.identity.name, first.identity.name);
    // And the identity the QR and the announcements speak is the stored one,
    // not a freshly generated answer.
    expect(PairIdentity.current.id, id);
    expect(PairIdentity.current.invite.deviceId, id);
  });

  test('starts a mesh that owns a listening socket', () async {
    final AppServices services = await startAppServices(
      dataDir: dataDir.path,
      clipboard: _FakeClipboard(),
    );
    addTearDown(() => stopAppServices(services));

    expect(services.mesh.port, greaterThan(0));
    expect(services.mesh.supervisor, isNotNull);
    expect(services.mesh.supervisor!.running, isTrue);
  });

  test('stopping the app gives the port back', () async {
    final AppServices services = await startAppServices(
      dataDir: dataDir.path,
      clipboard: _FakeClipboard(),
    );
    final int port = services.mesh.port;
    expect(port, greaterThan(0));

    await stopAppServices(services);

    // The listener is gone, so the port binds for whoever asks next — which is
    // what a recreated engine has to be able to do.
    final ServerSocket again = await ServerSocket.bind(
      InternetAddress.anyIPv4,
      port,
    );
    await again.close();
  });
}
