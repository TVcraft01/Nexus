// Phone-only mode: the app is complete with zero peers paired.
//
// With nothing paired there is no mesh to imply — the greeting invites,
// the Devices tab shows this phone, and the status line names this device.
// Detection is automatic (pairedDevices.isEmpty); no settings, no toggle.
// One or more peers restores the mesh greeting and wording.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/brain.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/query_log.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/mesh/mesh_service.dart';
import 'package:nexus/ui/assistant_view.dart';
import 'package:nexus/ui/devices_view.dart';
import 'package:nexus/ui/theme.dart';

/// A mesh that reports nothing paired without opening any sockets.
MeshService _soloMesh() {
  final store = NexusStore(
    explicitPath: '${Directory.systemTemp.createTempSync('po_solo').path}/s.json',
  );
  return MeshService(
    identity: DeviceInfo(id: 'solo-phone', name: 'Solo Phone', platform: 'android'),
    store: store,
  );
}

/// A mesh that reports one paired PC without opening any sockets.
class _OnePeerMesh extends MeshService {
  _OnePeerMesh({required super.store})
    : super(
        identity: DeviceInfo(
          id: 'solo-phone',
          name: 'Solo Phone',
          platform: 'android',
        ),
      );

  static final _pc = PairedDevice(
    id: 'pc1',
    name: 'My PC',
    platform: 'linux',
    address: '127.0.0.1',
    port: 1,
    pairingSecret: 'test-secret',
  );

  @override
  List<PairedDevice> get pairedDevices => [_pc];
}

/// A brain with a model installed on this phone.
class _LocalModelBrain extends LocalBrain {
  @override
  Future<String?> availableModel({bool refresh = false}) async =>
      'llama3.2:3b';

  @override
  Future<BrainReply> reply({
    required String system,
    required List<ChatTurn> history,
    double temperature = 0.7,
    int maxTokens = 300,
  }) async => (text: 'answered on this phone', reachable: true);
}

Future<void> _pumpAssistant(WidgetTester tester, MeshService mesh,
    {LocalBrain? brain}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildNexusTheme(),
      home: Scaffold(body: AssistantView(mesh: mesh, brain: brain)),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('greeting: 0 peers shows Ask me anything and phone-only pills',
      (tester) async {
    final mesh = _soloMesh();
    try {
      await _pumpAssistant(tester, mesh);

      expect(find.text('Ask me anything'), findsOneWidget);
      expect(find.text('Set a timer'), findsOneWidget);
      expect(find.text('12 times 5'), findsOneWidget);
      expect(find.text('Remember something'), findsOneWidget);
      // Cut before v0.2.0: it answered from memory instead of listing
      // anything, and a pill that does nothing is worse than a missing one.
      expect(find.text("What's in my Downloads"), findsNothing);
      // The solo greeting implies no mesh at all.
      expect(find.textContaining('Hello! I am Nexus.'), findsNothing);
      expect(find.textContaining('your PC'), findsNothing);
      expect(find.textContaining('Pair your devices'), findsNothing);
      expect(find.textContaining('from my pc'), findsNothing);
    } finally {
      QueryLog.i.resetForTest();
      await mesh.stop();
    }
  });

  testWidgets('greeting: 1 peer keeps the mesh greeting', (tester) async {
    final store = NexusStore(
      explicitPath:
          '${Directory.systemTemp.createTempSync('po_peer').path}/s.json',
    );
    final mesh = _OnePeerMesh(store: store);
    try {
      await _pumpAssistant(tester, mesh);

      // The mesh greeting stays exactly as it was: the empty-chat invite
      // with the registry's own suggestion chips, not the phone-only set.
      expect(
        find.text('Ask me anything — I listen and do.'),
        findsOneWidget,
      );
      expect(find.text('Set a timer'), findsNothing);
      expect(find.text('12 times 5'), findsNothing);
      expect(find.text('Remember something'), findsNothing);
    } finally {
      QueryLog.i.resetForTest();
      await mesh.stop();
    }
  });

  testWidgets('devices: 0 peers shows this phone and one pair button',
      (tester) async {
    final mesh = _soloMesh();
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildNexusTheme(),
          home: DevicesView(mesh: mesh),
        ),
      );
      await tester.pump();

      expect(find.text('This phone'), findsOneWidget);
      expect(find.text('Pair another device'), findsOneWidget);
      expect(find.text('No devices yet'), findsNothing);
      expect(find.text('Add device'), findsNothing);
      expect(find.textContaining('reachable right now'), findsNothing);
    } finally {
      await mesh.stop();
    }
  });

  testWidgets('status: 0 peers with a model says On this device',
      (tester) async {
    final mesh = _soloMesh();
    try {
      await _pumpAssistant(tester, mesh, brain: _LocalModelBrain());

      expect(find.textContaining('On this device'), findsOneWidget);
      expect(find.textContaining('your PC (via mesh)'), findsNothing);
    } finally {
      QueryLog.i.resetForTest();
      await mesh.stop();
    }
  });
}
