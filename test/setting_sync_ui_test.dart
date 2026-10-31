// Synced settings, on screen.
//
// Two things the user must be able to answer, and one they must be told:
//
//  1. after changing a shared setting here, where does it go — this device
//     only, or the paired devices too (and how many are actually there)?
//  2. "remember my choice", so the answer is asked once;
//  3. when a peer's value arrives, which device sent it and how to undo it.
//
// The mesh is a recorder here: what is being pinned is the question, not the
// wire. The wire is pinned in setting_sync_mesh_test.dart.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/shared_settings.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/core/system_prompt.dart';
import 'package:nexus/main_ui.dart'
    show
        NexusSettingNoticeBar,
        NexusShell,
        NexusTheme,
        SettingsTab,
        kNexusAlwaysMergeToggle,
        kNexusSettingNotice,
        kNexusSettingNoticeUndo,
        kNexusSettingScopeAll,
        kNexusSettingScopeLocal,
        kNexusSettingScopeRemember,
        kNexusSettingScopeSheet;
import 'package:nexus/mesh/mesh_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A mesh that records what it was asked to send, and how many peers it would
/// have claimed to send to.
class _Mesh extends MeshService {
  _Mesh({required super.store})
    : super(
        identity: DeviceInfo(
          id: 'this-pc',
          name: 'Rehearsal PC',
          platform: 'linux',
        ),
      );

  final List<(SharedSetting, Object?)> sent = <(SharedSetting, Object?)>[];
  int online = 2;

  @override
  int get onlineCount => online;

  @override
  Future<int> broadcastSetting(SharedSetting setting, Object? value) async {
    sent.add((setting, value));
    return online;
  }
}

void main() {
  late Directory tmp;
  late NexusStore store;
  late _Mesh mesh;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SystemPrompt.debugReset();
    tmp = Directory.systemTemp.createTempSync('nexus_setting_ui');
    store = NexusStore(explicitPath: '${tmp.path}/store.json');
    await store.save();
    mesh = _Mesh(store: store);
    addTearDown(() {
      mesh.stop();
      SystemPrompt.debugReset();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
  });

  Future<void> pumpSettings(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: NexusTheme.light(),
        home: Scaffold(
          body: SettingsTab(
            darkMode: false,
            onDarkModeChanged: (bool _) {},
            mesh: mesh,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.scrollUntilVisible(
      find.byKey(kNexusAlwaysMergeToggle),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
  }

  Future<void> toggleAlwaysMerge(WidgetTester tester) async {
    await tester.tap(
      find.descendant(
        of: find.byKey(kNexusAlwaysMergeToggle),
        matching: find.byType(Switch),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('the sheet after a local change', () {
    testWidgets('offers this device or all of them, and says how many', (
      tester,
    ) async {
      await pumpSettings(tester);
      await toggleAlwaysMerge(tester);

      expect(find.byKey(kNexusSettingScopeSheet), findsOneWidget);
      expect(find.text('This device only'), findsOneWidget);
      expect(find.text('All devices (2 online)'), findsOneWidget);
      // The change itself already happened here; the sheet is about the wire.
      expect(store.alwaysMerge, isFalse);
    });

    testWidgets('All devices sends the value', (tester) async {
      await pumpSettings(tester);
      await toggleAlwaysMerge(tester);

      await tester.tap(find.byKey(kNexusSettingScopeAll));
      await tester.pumpAndSettle();

      expect(mesh.sent, <(SharedSetting, Object?)>[
        (SharedSetting.alwaysMerge, false),
      ]);
      expect(find.text('Sent to 2 devices.'), findsOneWidget);
    });

    testWidgets('This device only sends nothing', (tester) async {
      await pumpSettings(tester);
      await toggleAlwaysMerge(tester);

      await tester.tap(find.byKey(kNexusSettingScopeLocal));
      await tester.pumpAndSettle();

      expect(mesh.sent, isEmpty);
      expect(store.alwaysMerge, isFalse, reason: 'local still changed');
    });

    testWidgets('"Remember my choice" stops the question being asked again', (
      tester,
    ) async {
      await pumpSettings(tester);
      await toggleAlwaysMerge(tester);
      expect(find.byKey(kNexusSettingScopeSheet), findsOneWidget);

      await tester.tap(find.byKey(kNexusSettingScopeRemember));
      await tester.pump();
      await tester.tap(find.byKey(kNexusSettingScopeAll));
      await tester.pumpAndSettle();

      expect(store.settingScope(SharedSetting.alwaysMerge.key), 'all');

      // The second change: no sheet, and the remembered answer is applied.
      await toggleAlwaysMerge(tester);
      expect(find.byKey(kNexusSettingScopeSheet), findsNothing);
      expect(mesh.sent, <(SharedSetting, Object?)>[
        (SharedSetting.alwaysMerge, false),
        (SharedSetting.alwaysMerge, true),
      ]);
    });

    testWidgets('a remembered "this device only" is silent', (tester) async {
      store.setSettingScope(SharedSetting.alwaysMerge.key, SettingScope.local);
      await pumpSettings(tester);
      await toggleAlwaysMerge(tester);

      expect(find.byKey(kNexusSettingScopeSheet), findsNothing);
      expect(mesh.sent, isEmpty);
    });
  });

  group('the system prompt', () {
    testWidgets('asks where to send it when the field settles', (tester) async {
      await pumpSettings(tester);
      await tester.scrollUntilVisible(
        find.byKey(const Key('nexus-system-prompt')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(
        find.byKey(const Key('nexus-system-prompt')),
        'Answer in French',
      );
      await tester.pump();

      // Losing focus is what makes a keystroke stream a setting.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();

      expect(find.byKey(kNexusSettingScopeSheet), findsOneWidget);
      await tester.tap(find.byKey(kNexusSettingScopeAll));
      await tester.pumpAndSettle();

      expect(mesh.sent, <(SharedSetting, Object?)>[
        (SharedSetting.systemPrompt, 'Answer in French'),
      ]);
    });

    testWidgets('losing focus without an edit asks nothing', (tester) async {
      await pumpSettings(tester);
      await tester.scrollUntilVisible(
        find.byKey(const Key('nexus-system-prompt')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const Key('nexus-system-prompt')));
      await tester.pump();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();

      expect(find.byKey(kNexusSettingScopeSheet), findsNothing);
      expect(mesh.sent, isEmpty);
    });
  });

  group('the notice', () {
    void stageAdopted() {
      mesh.lastAdoptedSetting = const AdoptedSetting(
        setting: SharedSetting.systemPrompt,
        value: 'Answer in French',
        previous: 'Be brief',
        fromName: 'Kit',
      );
      mesh.notifyListeners();
    }

    testWidgets('names the device that changed it, and Undo puts it back', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: NexusTheme.light(),
          home: Scaffold(body: NexusSettingNoticeBar(mesh: mesh)),
        ),
      );
      await tester.pump();
      expect(find.byKey(kNexusSettingNotice), findsNothing);

      stageAdopted();
      await tester.pump();

      expect(find.byKey(kNexusSettingNotice), findsOneWidget);
      expect(
        find.text('System prompt updated from Kit'),
        findsOneWidget,
        reason: 'a change nobody can attribute is a change nobody trusts',
      );

      await tester.tap(find.byKey(kNexusSettingNoticeUndo));
      await tester.pumpAndSettle();

      expect(find.byKey(kNexusSettingNotice), findsNothing);
      expect(
        mesh.lastAdoptedSetting,
        isNull,
        reason: 'Undo consumed the notice it acted on',
      );
    });

    testWidgets('the shell draws it above the pages', (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: NexusTheme.light(),
          home: NexusShell(
            darkMode: false,
            onDarkModeChanged: (bool _) {},
            mesh: mesh,
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(kNexusSettingNotice), findsNothing);

      stageAdopted();
      await tester.pump();

      expect(find.byKey(kNexusSettingNotice), findsOneWidget);
      expect(find.text('System prompt updated from Kit'), findsOneWidget);
    });
  });
}
