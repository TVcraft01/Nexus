import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/mesh/mesh_service.dart';

/// Live probe: pairs with whatever mesh is listening on the given address
/// using the code passed via --dart-define=PAIR_CODE=... .
///
/// Used to check the running desktop app (127.0.0.1:51820) accepts a
/// pairing from the current source — isolates app-version mismatch from
/// phone/tunnel issues. Not part of the normal suite.
void main() {
  test('pairs with a live mesh on the given address', () async {
    const code = String.fromEnvironment('PAIR_CODE');
    const address = String.fromEnvironment('PAIR_ADDRESS', defaultValue: '127.0.0.1');
    const port = int.fromEnvironment('PAIR_PORT', defaultValue: 51820);
    if (code.isEmpty) {
      markTestSkipped('PAIR_CODE not provided');
      return;
    }
    final store = NexusStore(explicitPath: '/tmp/live_pair_probe.json');
    final mesh = MeshService(
      identity: DeviceInfo(
        id: 'live-pair-probe',
        name: 'Live Pair Probe',
        platform: 'linux',
      ),
      store: store,
    );
    final result = await mesh.pairWith(address: address, port: port, code: code);
    debugPrint('LIVE-PAIR-RESULT ok=${result.ok} ${result.error}');
    expect(result.ok, isTrue, reason: result.error);
  });
}
