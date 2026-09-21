// The shell: the assistant is where the app opens, the navigation is one
// system on both layouts, a wide window gets an extra surface beside the
// conversation, and the keyboard owns the bottom edge.
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
import 'package:nexus/ui/nexus_v2/assistant_controller.dart';
import 'package:nexus/ui/nexus_v2/assistant_view.dart';
import 'package:nexus/ui/nexus_v2/design_system.dart';
import 'package:nexus/ui/nexus_v2/desktop_panel.dart';
import 'package:nexus/ui/nexus_v2/home_shell.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A mesh whose links the test decides, so the panel's device rows are driven
/// by a real mesh API rather than by a mock of the panel.
class _LinkedMesh extends MeshService {
  _LinkedMesh({required this.links})
      : super(
          identity: DeviceInfo(
            id: 'test-phone',
            name: 'Test Phone',
            platform: 'linux',
          ),
          store: NexusStore(
            explicitPath:
                '${Directory.systemTemp.createTempSync('v2_links').path}/s.json',
          )..autoUpdate = false,
        );

  final Map<String, bool> links;

  @override
  List<PairedDevice> get pairedDevices => [
        for (final entry in links.entries)
          PairedDevice(
            id: entry.key,
            name: entry.key,
            platform: 'linux',
            address: '192.168.1.9',
            port: 51823,
            pairingSecret: 'secret',
          ),
      ];

  @override
  bool isOnline(String id) => links[id] ?? false;

  /// A link really coming up, announced the way the mesh announces it.
  void setLink(String id, bool online) {
    links[id] = online;
    notifyListeners();
  }
}

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
  double textScale = 1.0,
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
      // Accessibility sizes the text up, and no layout here may overflow
      // because of it.
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
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

  testWidgets('the status panel appears only where there is room for it',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      for (final width in const [411.0, 900.0, 1079.0]) {
        final mesh = await _mesh();
        await _pumpShell(tester, mesh: mesh, width: width, height: 800);
        expect(find.byType(NexusV2DesktopPanel), findsNothing,
            reason: 'no room for the panel at $width');
        expect(tester.takeException(), isNull, reason: 'at $width');
        await mesh.stop();
      }

      for (final width in const [1080.0, 1280.0]) {
        final mesh = await _mesh();
        await _pumpShell(tester, mesh: mesh, width: width, height: 800);
        expect(find.byType(NexusV2DesktopPanel), findsOneWidget,
            reason: 'room for the panel at $width');
        expect(
          tester.widget<NavigationRail>(find.byType(NavigationRail)).extended,
          isTrue,
          reason: 'the panel and the extended rail arrive together at $width',
        );
        expect(tester.takeException(), isNull, reason: 'at $width');
        await mesh.stop();
      }
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('the panel sits beside the conversation, never squeezing it',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      for (final width in const [900.0, 1280.0]) {
        final mesh = await _mesh();
        await _pumpShell(tester, mesh: mesh, width: width, height: 800);

        // An ask, so the thread is on screen rather than the empty state.
        await tester.enterText(find.byType(TextField), 'what time is it');
        await tester.testTextInput.receiveAction(TextInputAction.send);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));

        // The thread, not the panel's own list: both are ListViews.
        final thread = tester.getRect(find.descendant(
          of: find.byType(NexusV2AssistantView),
          matching: find.byType(ListView),
        ));
        expect(thread.width, NexusV2Layout.readableColumn,
            reason: 'the conversation keeps its readable band at $width');
        if (find.byType(NexusV2DesktopPanel).evaluate().isNotEmpty) {
          final panel = tester.getRect(find.byType(NexusV2DesktopPanel));
          expect(panel.width, NexusV2DesktopPanel.width);
          expect(thread.right, lessThanOrEqualTo(panel.left),
              reason: 'the panel is beside the thread, not over it');
        }
        expect(tester.takeException(), isNull, reason: 'at $width');
        await mesh.stop();
      }
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('the panel reports the real link state and the last action',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      final mesh = _LinkedMesh(links: {'PC': true, 'Laptop': false});
      addTearDown(mesh.stop);
      await _pumpShell(tester, mesh: mesh, width: 1280, height: 800);

      // The links, from the mesh's own answers.
      expect(find.text('1 of 2 connected'), findsOneWidget);
      expect(find.text('PC · Connected'), findsOneWidget);
      expect(find.text('Laptop · Offline'), findsOneWidget);
      // And nothing has happened yet, which the panel says rather than fills.
      expect(find.text('Nothing yet — ask something.'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'what time is it');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      Finder inPanel(Finder matching) => find.descendant(
            of: find.byType(NexusV2DesktopPanel),
            matching: matching,
          );
      expect(inPanel(find.text('Done')), findsOneWidget);
      expect(inPanel(find.text('what time is it')), findsOneWidget);
      expect(find.text('Nothing yet — ask something.'), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('the panel follows the links as the mesh really changes',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      final mesh = _LinkedMesh(links: {'PC': true, 'Laptop': false});
      addTearDown(mesh.stop);
      await _pumpShell(tester, mesh: mesh, width: 1280, height: 800);

      expect(find.text('1 of 2 connected'), findsOneWidget);
      expect(find.text('Laptop · Offline'), findsOneWidget);

      // The mesh's own notification, not a rebuild the test forced on it.
      mesh.setLink('Laptop', true);
      await tester.pump();

      expect(find.text('2 of 2 connected'), findsOneWidget);
      expect(find.text('Laptop · Connected'), findsOneWidget);
      expect(find.text('Laptop · Offline'), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('the panel reports a real failure, not only a real success',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      final mesh = _LinkedMesh(links: {'PC': true});
      addTearDown(mesh.stop);
      await _pumpShell(tester, mesh: mesh, width: 1280, height: 800);

      // Core really refuses this one: the only linked device does not do it.
      await tester.enterText(find.byType(TextField), 'blink the ESP32');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      Finder inPanel(Finder matching) => find.descendant(
            of: find.byType(NexusV2DesktopPanel),
            matching: matching,
          );
      expect(inPanel(find.text('That did not work')), findsOneWidget);
      expect(inPanel(find.byIcon(Icons.error_outline)), findsOneWidget);
      expect(inPanel(find.text('blink the ESP32')), findsOneWidget);
      expect(inPanel(find.textContaining('does not support')), findsOneWidget);
      expect(find.text('Nothing yet — ask something.'), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('the wide layout survives a large accessibility text scale',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      for (final scale in const [2.0, 3.0]) {
        final mesh = _LinkedMesh(links: {'PC': true, 'Laptop': false});
        await _pumpShell(
          tester,
          mesh: mesh,
          width: 1280,
          height: 800,
          textScale: scale,
        );

        // A failure, so the panel holds its longest real line.
        await tester.enterText(find.byType(TextField), 'blink the ESP32');
        await tester.testTextInput.receiveAction(TextInputAction.send);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));

        expect(find.text('That did not work'), findsWidgets, reason: 'at $scale');
        expect(tester.takeException(), isNull, reason: 'at ${scale}x');
        await mesh.stop();
      }
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('a device that is paired but not reachable says so',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      final mesh = _LinkedMesh(links: {'Laptop': false});
      addTearDown(mesh.stop);
      await _pumpShell(tester, mesh: mesh, width: 1280, height: 800);

      expect(find.text('0 of 1 connected'), findsOneWidget);
      expect(find.text('Laptop · Offline'), findsOneWidget);
      // The presence line's own sentence, here explaining the list.
      expect(
        find.text(NexusAssistantController.offlineLine),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
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
