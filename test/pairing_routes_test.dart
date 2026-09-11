import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/pairing_routes.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/mesh/mesh_service.dart';
import 'package:nexus/core/identity.dart';

void main() {
  test('duplicate and blank pairing routes are ignored', () async {
    final dir = await Directory.systemTemp.createTemp('nexus_routes_test');
    final store = NexusStore(explicitPath: '${dir.path}/state.json')..port = 0;
    final mesh = MeshService(
      identity: const DeviceInfo(
        id: 'test-device',
        name: 'Test device',
        platform: 'linux',
      ),
      store: store,
      connectTimeout: const Duration(milliseconds: 50),
    );

    try {
      final result = await pairThroughRoutes(
        mesh: mesh,
        addresses: const ['', '203.0.113.1', '203.0.113.1'],
        port: 9,
        code: 'AAAA-BBBB',
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('Could not reach'));
    } finally {
      await mesh.stop();
      await dir.delete(recursive: true);
    }
  });
}
