// The shell: the assistant is where the app opens, the navigation is one
// system on both layouts, and the keyboard owns the bottom edge.
import 'dart:io';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/query_log.dart';
import 'package:nexus/core/speech.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/mesh/mesh_service.dart';
import 'package:nexus/ui/nexus_v2/assistant_view.dart';
import 'package:nexus/ui/nexus_v2/design_system.dart';
import 'package:nexus/ui/nexus_v2/home_shell.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<MeshService> _mesh() async {
  SharedPreferences.setMockInitialValues({});
  final store = NexusStore(
    explicitPath:
        '${Directory.systemTemp.createTempSync('v2_shell').path}/s.json',
  )..autoUpdate = false; // a test never reaches for the network
  return MeshService(
    identity: DeviceInfo(id: 'test-phone', name: 'Test Phone', platform: 'android'),
    store: store,
  );
}

Future<void> _pumpShell(
  WidgetTester tester, {
  required MeshService mesh,
  required double width,
  double height = 891,
  double keyboardInset = 0,
}) async {
  tester.view.physicalSize = Size(width * 3, height * 3);
  tester.view.devicePixelRatio = 3;
  tester.view.viewInsets = FakeViewPadding(bottom: keyboardInset * 3);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.view.resetViewInsets();
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: buildNexusV2Theme(),
      home: NexusV2HomeShell(mesh: mesh),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 220));
}

void main() {
  setUp(() {
    QueryLog.readAllOverride = () async => const [];
    SpeechInput.override = null;
    SpeechOutput.override = null;
    SpeechPlayback.override = null;
  });

  tearDown(() {
    QueryLog.readAllOverride = null;
    SpeechInput.override = null;
    SpeechOutput.override = null;
    SpeechPlayback.override = null;
  });

  test('one destination list, with the four areas and a calm assistant glyph',
      () {
    expect(
      kNexusV2Destinations.map((destination) => destination.label).toList(),
      ['Devices', 'Files', 'Assistant', 'Settings'],
    );
    // The sparkle shouted even when another tab was selected; the assistant
    // is the one thing you talk to, so it reads as a conversation.
    expect(
      kNexusV2Destinations[kNexusV2AssistantIndex].selectedIcon,
      Icons.chat_bubble_rounded,
    );
    expect(
      kNexusV2Destinations[kNexusV2AssistantIndex].icon,
      Icons.chat_bubble_outline_rounded,
    );
    expect(kNexusV2Destinations[kNexusV2AssistantIndex].label, 'Assistant');
  });

  testWidgets('a phone opens on the assistant, with a bottom bar',
      (tester) async {
    final mesh = await _mesh();
    await _pumpShell(tester, mesh: mesh, width: 411);

    expect(find.byType(NexusV2AssistantView), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
    final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(bar.selectedIndex, kNexusV2AssistantIndex);
    await mesh.stop();
  });

  testWidgets('a narrow desktop window gets a rail, and it collapses',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      final mesh = await _mesh();
      await _pumpShell(tester, mesh: mesh, width: 900, height: 700);

      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(
        tester.widget<NavigationRail>(find.byType(NavigationRail)).extended,
        isFalse,
      );
      await mesh.stop();

      // A wide window may show the labels; a narrow one never squeezes them in.
      final wide = await _mesh();
      await _pumpShell(tester, mesh: wide, width: 1280, height: 800);
      expect(
        tester.widget<NavigationRail>(find.byType(NavigationRail)).extended,
        isTrue,
      );
      await wide.stop();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('the keyboard takes the bottom edge from the navigation bar',
      (tester) async {
    final mesh = await _mesh();
    await _pumpShell(tester, mesh: mesh, width: 411, keyboardInset: 300);

    expect(find.byType(NavigationBar), findsNothing);
    // And the composer is above the keys, where the thumb already is.
    final composer = tester.getRect(find.byType(TextField));
    expect(composer.bottom, lessThanOrEqualTo(891 - 300));
    await mesh.stop();
  });
}
