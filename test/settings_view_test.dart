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

import 'package:flutter/cupertino.dart' show CupertinoSwitch;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/services/icon_service.dart';
import 'package:nexus/core/version.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/mesh/mesh_service.dart';
import 'package:nexus/mesh/updater.dart';
import 'package:nexus/ui/components/nexus_ui.dart';
import 'package:nexus/ui/settings_view.dart';
import 'package:nexus/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Every switch on the settings screen, by the name a user reads.
///
/// "Location reminders" is deliberately absent: its row asks the system
/// for permission first, so tapping the name does not always flip it —
/// that row is walked in capabilities_test.dart instead, denied and
/// granted.
const _toggles = [
  'Clipboard sync',
  'Voice input',
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
        // The screen scrolls and the list builds lazily, so a row below the
        // fold is not in the tree at all until it is scrolled to — exactly
        // what a user does before they can tap it. The walk stays in document
        // order, so it only ever scrolls downward.
        await tester.scrollUntilVisible(name, 120);
        await tester.pump();
        expect(name, findsOneWidget, reason: '"$label" is on the screen');

        final row = find.ancestor(of: name, matching: find.byType(Row)).first;
        // The control is the iOS switch now, and the assertion follows it: the
        // row's words must still toggle the setting itself.
        CupertinoSwitch current() => tester.widget<CupertinoSwitch>(
              find.descendant(of: row, matching: find.byType(CupertinoSwitch)),
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
      // user reaches it, rather than assuming it is already built. The row is
      // the action — the tinted "Check now" button it used to carry is gone,
      // and the row still reaches the same handler with the same sentences.
      final row = find.text('Check for updates now');
      await tester.scrollUntilVisible(row, 200,
          scrollable: find.byType(Scrollable).first);
      await tester.ensureVisible(row);
      await tester.pump();
      await tester.tap(row);
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

  // The list used to explain Nexus inside itself: "Local-first, no account",
  // "Reachability is honest", "Understands what you teach it", "Actions need
  // your approval", the encryption line. Those sentences are not settings, so
  // they moved to a detail route — this is the guard that they moved rather
  // than vanished, and that the list itself is a list of settings only.
  testWidgets('the words that left the list are on About, not gone',
      (tester) async {
    late MeshService mesh;
    await tester.runAsync(() async {
      final store = NexusStore(
        explicitPath:
            '${Directory.systemTemp.createTempSync('settings-about').path}/s.json',
      );
      store.broadcastDiscovery = false;
      await store.save();
      mesh = MeshService(
        identity:
            DeviceInfo(id: 'settings-3', name: 'Settings PC', platform: 'linux'),
        store: store,
      );
    });

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

      // Not in place any more.
      for (final sentence in ['Local-first', 'Reachability is honest']) {
        expect(find.text(sentence), findsNothing,
            reason: '"$sentence" is not a setting and does not sit in the '
                'list');
      }

      final about = find.text('About Nexus');
      await tester.scrollUntilVisible(about, 200,
          scrollable: find.byType(Scrollable).first);
      await tester.ensureVisible(about);
      await tester.pump();
      await tester.tap(about);
      await tester.pumpAndSettle();

      // Every fact, one tap away, each still a row.
      for (final fact in [
        'Version',
        'Encryption',
        'Account',
        'Local-first',
        'Reachability is honest',
        'Understands what you teach it',
        'Actions need your approval',
      ]) {
        expect(find.text(fact), findsOneWidget,
            reason: '"$fact" moved to About, it was not dropped');
      }
    } finally {
      await tester.runAsync(mesh.stop);
    }
  });

  // The App icon row was built in the standalone preview shell, where only the
  // people running `flutter run -t lib/main_ui.dart` could ever see it: the
  // manifest carried three launcher aliases and the switch that flips them, and
  // the shipping settings screen had no row to flip them from. The row lives
  // here now, and this is the guard that it did not slide back into the shell:
  // the choice is stored, the row says so, and Android is told which alias to
  // enable.
  testWidgets('the App icon row picks one of three marks and tells Android', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    const MethodChannel iconChannel =
        MethodChannel('dev.nexus.nexus/app_icon');
    final List<MethodCall> calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(iconChannel, (MethodCall call) async {
      calls.add(call);
      return switch (call.method) {
        'currentIcon' => 'light',
        'setIcon' => true,
        _ => null,
      };
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(iconChannel, null),
    );
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    // The service is a singleton that outlives a test, so this one states where
    // it starts instead of inheriting whatever ran before it.
    await IconService.instance.setMode(IconMode.light);

    late MeshService mesh;
    await tester.runAsync(() async {
      final store = NexusStore(
        explicitPath:
            '${Directory.systemTemp.createTempSync('settings-icon').path}/s.json',
      );
      store.broadcastDiscovery = false;
      await store.save();
      mesh = MeshService(
        identity: DeviceInfo(
          id: 'settings-5',
          name: 'Settings Phone',
          platform: 'android',
        ),
        store: store,
      );
    });

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

      final rowName = find.text('App icon');
      await tester.scrollUntilVisible(
        rowName,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump();
      expect(rowName, findsOneWidget);

      Finder iconRow() => find.ancestor(
            of: find.text('App icon'),
            matching: find.byType(NexusRow),
          );
      expect(
        find.descendant(of: iconRow(), matching: find.text('Light')),
        findsOneWidget,
        reason: 'the row reports the mode the launcher is wearing',
      );

      await tester.tap(rowName);
      await tester.pumpAndSettle();

      // Three choices, each with the sentence that says what it means, and the
      // one in force wearing the check. Everything is scoped to the open sheet:
      // the row behind it still carries the sentence for the mode now in force,
      // so a bare find.text matches twice.
      Finder inSheet(Finder finder) => find.descendant(
            of: find.byType(NexusSheetSurface),
            matching: finder,
          );
      for (final String meaning in <String>[
        'Always the light mark.',
        'Always the dark mark.',
        'Follows the system theme.',
      ]) {
        expect(
          inSheet(find.text(meaning)),
          findsOneWidget,
          reason: 'the sheet offers "$meaning"',
        );
      }
      expect(inSheet(find.byIcon(Icons.check_rounded)), findsOneWidget,
          reason: 'the check marks the mode in force');

      await tester.tap(inSheet(find.text('Always the dark mark.')));
      await tester.pumpAndSettle();

      // The sheet is gone, the row reports the choice, the choice is stored, and
      // Android was told which alias to enable.
      expect(find.byType(NexusSheetSurface), findsNothing);
      expect(find.text('Follows the system theme.'), findsNothing);
      expect(
        find.descendant(of: iconRow(), matching: find.text('Dark')),
        findsOneWidget,
      );
      expect(find.text('Always the dark mark.'), findsOneWidget,
          reason: 'the row now describes the mode it is wearing');
      expect(IconService.instance.mode, IconMode.dark);
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(SharedPrefsIconModeStore.key), 'dark');
      expect(
        calls
            .where((MethodCall call) => call.method == 'setIcon')
            .map(
              (MethodCall call) =>
                  (call.arguments as Map<Object?, Object?>)['mode'],
            ),
        contains('dark'),
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
      await tester.runAsync(mesh.stop);
    }
  });

  // The screen carried two tinted buttons — "Manage" beside the files row and
  // "Check now" beside the updates row — and the design system allows the
  // accent for state and action, never as a background wash. Both are values
  // now; this is the guard that no chrome-button comes back.
  testWidgets('the settings screen is rows and values, never buttons',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    late MeshService mesh;
    await tester.runAsync(() async {
      final store = NexusStore(
        explicitPath:
            '${Directory.systemTemp.createTempSync('settings-droid').path}/s.json',
      );
      store.broadcastDiscovery = false;
      await store.save();
      mesh = MeshService(
        identity:
            DeviceInfo(id: 'settings-4', name: 'Settings Phone', platform: 'android'),
        store: store,
      );
    });

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildNexusTheme(),
          home: Scaffold(body: SettingsView(mesh: mesh)),
        ),
      );
      await tester.pump();

      // The one Android-only row is here, as a setting among settings.
      // The Capabilities section grew the list, so the row sits below the
      // fold until reached the way a user reaches it — the list builds
      // lazily, exactly like the toggle walk above assumes.
      final filesRow = find.text('Show your files to paired devices');
      await tester.scrollUntilVisible(
        filesRow,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump();
      expect(filesRow, findsOneWidget);
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
      expect(find.byType(TextButton), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      await tester.runAsync(mesh.stop);
    }
  });
}
