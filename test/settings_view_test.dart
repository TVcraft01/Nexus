// The settings screen, driven as a user drives it.
//
// A playtest found every toggle in Settings could only be flipped by its
// 40dp switch: tapping the setting's *name* — the words that are most of the
// row, and the thing people actually aim at — did nothing at all. That is
// the silent kind of dead end: the screen looks interactive, so the user
// concludes the tap failed rather than that they missed.
//
// One rule covers the class, so this walks every toggle row on the screen
// rather than pinning the one that was reported.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/version.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/mesh/mesh_service.dart';
import 'package:nexus/mesh/updater.dart';
import 'package:nexus/ui/settings_view.dart';
import 'package:nexus/ui/theme.dart';

/// Every switch on the settings screen, by the name a user reads.
const _toggles = [
  'Sync clipboard across devices',
  'Always merge clipboard',
  'Broadcast discovery',
  'Check for updates automatically',
];

void main() {
  testWidgets("tapping a setting's name toggles it, not just the switch", (
    tester,
  ) async {
    // The store is built on the far side of runAsync: its save chain is
    // created where it is constructed, so a store built under the test's fake
    // clock deadlocks on the first save.
    late MeshService mesh;
    await tester.runAsync(() async {
      final store = NexusStore(
        explicitPath:
            '${Directory.systemTemp.createTempSync('settings').path}/s.json',
      );
      store.autoUpdate = false;
      store.broadcastDiscovery = false; // never touch the network in a test
      await store.save();
      mesh = MeshService(
        identity:
            DeviceInfo(id: 'settings-1', name: 'Settings PC', platform: 'linux'),
        store: store,
      );
    });

    // A real phone, so the list actually scrolls and the walk has to scroll
    // to each row the way a user does.
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildNexusTheme(),
          home: Scaffold(body: SettingsView(mesh: mesh)),
        ),
      );
      await tester.pump();

      for (final label in _toggles) {
        final name = find.text(label);
        expect(name, findsOneWidget, reason: '"$label" is on the screen');
        await tester.ensureVisible(name);
        await tester.pump();

        final row = find.ancestor(of: name, matching: find.byType(Row)).first;
        Switch current() => tester.widget<Switch>(
              find.descendant(of: row, matching: find.byType(Switch)),
            );

        final before = current().value;
        await tester.tap(name);
        await tester.pump(const Duration(milliseconds: 150));
        expect(
          current().value,
          isNot(before),
          reason: 'tapping the name "$label" must toggle it — the words are '
              'most of the row and the part a finger aims at',
        );
      }
    } finally {
      await tester.runAsync(mesh.stop);
    }
  });

  // "Check for updates now" used to answer a question it never asked: a check
  // that could not be made at all (GitHub refusing to answer, no network) came
  // back as "Up to date — v0.1.53", so the user was told there was nothing to
  // update and stopped looking. Each answer is now its own sentence.
  testWidgets('checking for updates never claims up to date on a failed check',
      (tester) async {
    late MeshService mesh;
    await tester.runAsync(() async {
      final store = NexusStore(
        explicitPath:
            '${Directory.systemTemp.createTempSync('settings-up').path}/s.json',
      );
      store.autoUpdate = false;
      store.broadcastDiscovery = false;
      await store.save();
      mesh = MeshService(
        identity:
            DeviceInfo(id: 'settings-2', name: 'Settings PC', platform: 'linux'),
        store: store,
      );
    });

    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    Future<void> check(UpdateCheck answer) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildNexusTheme(),
          home: Scaffold(
            body: SettingsView(
              mesh: mesh,
              onCheckForUpdate: () async => answer,
            ),
          ),
        ),
      );
      await tester.pump();
      // The screen is a lazy list on a real phone: scroll to the row the way a
      // user reaches it, rather than assuming it is already built.
      final button = find.widgetWithText(FilledButton, 'Check now');
      await tester.scrollUntilVisible(button, 200,
          scrollable: find.byType(Scrollable).first);
      await tester.ensureVisible(button);
      await tester.pump();
      await tester.tap(button);
      await tester.pump();
    }

    try {
      await check(const UpdateCheck(
        null,
        failure: 'GitHub is rate-limiting this network',
      ));
      expect(
        find.text('Could not check — GitHub is rate-limiting this network'),
        findsOneWidget,
      );
      expect(find.textContaining('Up to date'), findsNothing,
          reason: 'a check that could not be made says so');

      await check(UpdateCheck.upToDate);
      expect(find.text('Up to date — v$appVersion'), findsOneWidget);

      await check(const UpdateCheck(UpdateInfo(version: '9.9.9')));
      expect(find.text('Update to v9.9.9 available'), findsOneWidget);
    } finally {
      await tester.runAsync(mesh.stop);
    }
  });
}
