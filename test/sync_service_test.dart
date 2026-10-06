import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/mesh/mesh_service.dart';
import 'package:nexus/mesh/sync_service.dart';

/// A clipboard that lives in memory — no platform channels needed in tests.
class _FakeClipboard implements ClipboardBackend {
  String? value;
  @override
  Future<String?> readText() async => value;
  @override
  Future<void> writeText(String text) async => value = text;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The channel the foreground service is reached over (see
  // lib/mesh/sync_service.dart and NexusSyncService.kt).
  const channel = MethodChannel('dev.nexus.nexus/network');
  late List<String> calls;

  void mockChannel() {
    calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return true;
    });
  }

  setUp(() async {
    // The mesh's platform checks (and SyncService's) follow the target
    // platform; pose as a phone so the Android path is the one exercised.
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    mockChannel();
    // SyncService keeps process-wide state; clear it before each test.
    await SyncService.stop();
    calls.clear();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('starting the sync service asks Android to run it in foreground', () async {
    expect(await SyncService.start(), isTrue);
    expect(calls, ['startSyncService']);
    expect(SyncService.running, isTrue);

    await SyncService.stop();
    expect(calls, ['startSyncService', 'stopSyncService']);
    expect(SyncService.running, isFalse);
  });

  test('off Android the sync service is never asked for', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    expect(await SyncService.start(), isFalse);
    await SyncService.stop();
    expect(calls, isEmpty);
  });

  test('the mesh starts the service on start and stops it on stop', () async {
    final tmp = await Directory.systemTemp.createTemp('nexus_sync');
    addTearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });
    final store = NexusStore(explicitPath: '${tmp.path}/state.json')
      ..port = 0; // an ephemeral port: never a lottery with another test
    await store.save();

    final mesh = MeshService(
      identity: DeviceInfo(
        id: 'device-sync',
        name: 'Test Phone',
        platform: 'android',
      ),
      store: store,
      clipboard: _FakeClipboard(),
      heartbeatInterval: const Duration(seconds: 5),
    );

    await mesh.start();
    expect(
      calls,
      contains('startSyncService'),
      reason: 'the mesh must claim its background life when it comes up',
    );

    await mesh.stop();
    expect(
      calls,
      contains('stopSyncService'),
      reason: 'stopping the mesh must release the foreground service',
    );
  });
}
