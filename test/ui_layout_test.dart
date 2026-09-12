// Layout guarantees, measured rather than assumed.
//
// Two things every screen owes the user, on every device:
//
//  1. Nothing paints under the status bar, the notch or the camera. On a real
//     phone that band is not ours, and content that drifts into it is clipped
//     or unreadable — the one layout bug a user cannot work around.
//  2. Nothing overflows. The shell has to survive a 320dp phone and a
//     half-screen desktop window, because that is what people actually use.
//
// Both are asserted against the real `HomeShell` at real geometries, on both
// platform layouts, so a future change to padding or a new chart can't
// quietly break them. Widget geometry is exact here in a way eyeballing a
// screenshot is not: these are the actual layout rects.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/mesh/mesh_service.dart';
import 'package:nexus/ui/assistant_view.dart';
import 'package:nexus/ui/home_shell.dart';
import 'package:nexus/ui/nexus_core.dart';
import 'package:nexus/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A modern phone: 360x800dp with a 47dp status-bar/notch band and a 24dp
/// gesture bar — the geometry that started this.
const _phone = (size: Size(360, 800), inset: EdgeInsets.only(top: 47, bottom: 24));

/// A small/older phone, where everything is tightest.
const _smallPhone =
    (size: Size(320, 568), inset: EdgeInsets.only(top: 24, bottom: 16));

/// A desktop window, and half of one — the narrow case people really use.
const _desktop = (size: Size(1280, 800), inset: EdgeInsets.zero);
const _narrowDesktop = (size: Size(560, 700), inset: EdgeInsets.zero);

const _tabs = ['Devices', 'Files', 'Assistant', 'Settings'];

Future<MeshService> _makeMesh(int port) async {
  final store = NexusStore(
    explicitPath: '${Directory.systemTemp.createTempSync('layout').path}/s.json',
  );
  store.autoUpdate = false; // a layout test must not reach the network
  store.port = port;
  await store.save();
  final mesh = MeshService(
    identity:
        DeviceInfo(id: 'layout-device', name: 'Layout PC', platform: 'linux'),
    store: store,
    heartbeatInterval: const Duration(seconds: 30),
  );
  await mesh.start();
  return mesh;
}

/// Runs [body] as [platform], always restoring the platform afterwards.
///
/// This cannot be left to `addTearDown`: the framework asserts that no debug
/// variable was left changed at the end of the test *body*, before tear-downs
/// run, and would fail every test here for the harness's own bookkeeping.
Future<void> _on(TargetPlatform platform, Future<void> Function() body) async {
  debugDefaultTargetPlatformOverride = platform;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

/// Pumps the real shell at [geometry] on the current platform. The mesh is
/// built inside `runAsync` by the caller: it opens real sockets, which never
/// complete under the fake async a widget test runs in.
Future<void> _pumpShell(
  WidgetTester tester, {
  required ({Size size, EdgeInsets inset}) geometry,
  required MeshService mesh,
}) async {
  tester.view.physicalSize = geometry.size;
  tester.view.devicePixelRatio = 1.0;
  tester.view.padding = FakeViewPadding(
    top: geometry.inset.top,
    bottom: geometry.inset.bottom,
  );
  tester.view.viewPadding = tester.view.padding;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(theme: buildNexusTheme(), home: HomeShell(mesh: mesh)),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 60));
}

Future<void> _openTab(WidgetTester tester, String tab) async {
  await tester.tap(find.text(tab).last);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 60));
}

/// The topmost edge of anything painted, and the bottom-most, across the tree.
({double top, double bottom}) _paintedVerticalBounds(WidgetTester tester) {
  var top = double.infinity;
  var bottom = 0.0;
  for (final element in find.byType(Text).evaluate()) {
    final rect = tester.getRect(find.byWidget(element.widget));
    if (rect.top < top) top = rect.top;
    if (rect.bottom > bottom) bottom = rect.bottom;
  }
  return (top: top, bottom: bottom);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({
    'nexus.profile.onboarded': true,
  }));

  testWidgets('every tab clears the status-bar band on a phone',
      (tester) async {
    final mesh = (await tester.runAsync(() => _makeMesh(53510)))!;
    await _on(TargetPlatform.android, () async {
      await _pumpShell(tester, geometry: _phone, mesh: mesh);

      // The shell is the touch layout: bottom navigation, no rail.
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);

      for (final tab in _tabs) {
        await _openTab(tester, tab);
        expect(
          tester.takeException(),
          isNull,
          reason: '$tab threw while laying out at ${_phone.size}',
        );
        expect(
          _paintedVerticalBounds(tester).top,
          greaterThanOrEqualTo(_phone.inset.top),
          reason: '$tab paints under the status bar / notch '
              '(${_phone.inset.top}dp reserved, screen ${_phone.size})',
        );
      }
    });

    await tester.runAsync(mesh.stop);
  });

  testWidgets('a small phone and a narrow desktop window never overflow',
      (tester) async {
    final mesh = (await tester.runAsync(() => _makeMesh(53511)))!;

    for (final (platform, geometry) in [
      (TargetPlatform.android, _smallPhone),
      (TargetPlatform.linux, _desktop),
      (TargetPlatform.linux, _narrowDesktop),
    ]) {
      await _on(platform, () async {
        await _pumpShell(tester, geometry: geometry, mesh: mesh);

        // Desktop is the pointer layout: a rail that gives its space back,
        // rather than the phone's layout stretched.
        if (platform == TargetPlatform.linux) {
          expect(find.byType(NavigationRail), findsOneWidget);
          expect(find.byType(NavigationBar), findsNothing);
        }

        for (final tab in _tabs) {
          await _openTab(tester, tab);
          expect(
            tester.takeException(),
            isNull,
            reason: '$tab threw at ${geometry.size} ($platform)',
          );
          expect(
            _paintedVerticalBounds(tester).top,
            greaterThanOrEqualTo(geometry.inset.top),
            reason: '$tab paints under the inset at ${geometry.size}',
          );
          // The header is tightest where the window is narrowest, and the core
          // is the newest thing competing for that row.
          if (tab == 'Assistant') {
            final core = tester.getRect(find.byType(NexusCore));
            final screen = Offset.zero & geometry.size;
            expect(
              screen.contains(core.topLeft) && screen.contains(core.bottomRight),
              isTrue,
              reason: 'the Nexus core ($core) must fit in $screen',
            );
            expect(
              core.top,
              greaterThanOrEqualTo(geometry.inset.top),
              reason: 'the Nexus core must clear the inset',
            );
          }
        }
      });
    }

    await tester.runAsync(mesh.stop);
  });

  testWidgets('the assistant keeps its composer and chips fully on screen',
      (tester) async {
    final mesh = (await tester.runAsync(() => _makeMesh(53512)))!;
    await _on(TargetPlatform.android, () async {
      await _pumpShell(tester, geometry: _phone, mesh: mesh);
      await _openTab(tester, 'Assistant');

      final assistant = find.byType(AssistantView);
      final composer = find.descendant(
        of: assistant,
        matching: find.byType(TextField),
      );
      final chips = find.descendant(
        of: assistant,
        matching: find.byType(ActionChip),
      );

      expect(composer, findsOneWidget, reason: 'the composer must be present');
      expect(
        chips,
        findsAtLeastNWidgets(1),
        reason: 'suggestions must be present',
      );

      // The Nexus core lives in the header, which is the tightest spot in the
      // app: a title, a subtitle, two actions and a sphere on one row. It must
      // clear the status bar and stay fully on screen like everything else —
      // a clipped core is the one bug the user cannot work around.
      final core = find.byType(NexusCore);
      expect(core, findsOneWidget, reason: 'the assistant shows the core');

      final screen = Offset.zero & _phone.size;
      for (final (name, rect) in [
        ('composer', tester.getRect(composer)),
        ('suggestion chips', tester.getRect(chips.first)),
        ('Nexus core', tester.getRect(core)),
      ]) {
        expect(
          screen.contains(rect.topLeft) && screen.contains(rect.bottomRight),
          isTrue,
          reason: 'the $name ($rect) must sit inside the $screen screen',
        );
        expect(
          rect.top,
          greaterThanOrEqualTo(_phone.inset.top),
          reason: 'the $name must clear the status bar',
        );
      }
    });

    await tester.runAsync(mesh.stop);
  });
}
