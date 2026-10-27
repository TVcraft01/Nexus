// What a 1.0 install shows before and after the first tap.
//
// The splash is the one screen every launch passes through, and the privacy
// policy is the one screen that makes a claim about the whole app; both are
// checked here through the widgets a user actually meets, not through the
// generated Android resources.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/main_ui.dart'
    show
        PrivacyPage,
        PrivacyPolicyPage,
        SplashFade,
        kNexusSplashFade,
        kSplashFade;
import 'package:nexus/mesh/mesh_service.dart';
import 'package:nexus/ui/privacy_policy_view.dart';
import 'package:nexus/ui/settings_view.dart';
import 'package:nexus/ui/theme.dart';

void main() {
  testWidgets('the splash covers the first frame, then fades out of the tree',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SplashFade(child: ColoredBox(color: Colors.black)),
      ),
    );

    // The frame that replaces the native splash is the splash again: without
    // that, the native window would cut straight to the app.
    expect(find.byKey(kNexusSplashFade), findsOneWidget);

    await tester.pump(kSplashFade ~/ 2);
    expect(
      find.byKey(kNexusSplashFade),
      findsOneWidget,
      reason: 'the overlay is still fading, not cut',
    );

    await tester.pumpAndSettle();
    expect(
      find.byKey(kNexusSplashFade),
      findsNothing,
      reason: 'once faded it must leave the tree, so it cannot cost a frame '
          'or hide a tap for the rest of the session',
    );
  });

  testWidgets('the policy is one unchanged paragraph', (tester) async {
    await tester.pumpWidget(
      MaterialApp(theme: buildNexusTheme(), home: const PrivacyPolicyView()),
    );
    await tester.pump();

    expect(find.text(PrivacyPolicyView.policy), findsOneWidget);
    expect(find.text('Privacy Policy'), findsWidgets);
  });

  test('the policy states the 1.0 promise verbatim', () {
    // Pinned word for word: this is the sentence the release notes point at, so
    // a rewrite has to be a decision rather than a drift.
    const String promise =
        'Nexus is 100% local. No data, audio, or images are ever sent to a '
        'cloud server. No accounts are required. All AI processing happens '
        'on-device or via your own paired local network.';
    expect(PrivacyPolicyPage.policy, contains(promise));
    expect(PrivacyPolicyView.policy, contains(promise));
  });

  testWidgets('the shipping Privacy page links to the same policy', (
    tester,
  ) async {
    expect(
      PrivacyPolicyPage.policy,
      PrivacyPolicyView.policy,
      reason: 'two shells, one promise — the wording cannot fork',
    );

    await tester.pumpWidget(const MaterialApp(home: PrivacyPage()));
    await tester.pump();

    final Finder row = find.text('Privacy Policy');
    await tester.scrollUntilVisible(row, 160);
    await tester.pump();
    expect(row, findsOneWidget);

    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.byType(PrivacyPolicyPage), findsOneWidget);
    expect(find.text(PrivacyPolicyPage.policy), findsOneWidget);
  });

  testWidgets('Settings puts the policy one tap from the Privacy section',
      (tester) async {
    late MeshService mesh;
    // Built away from the fake clock, as the rest of the settings tests do:
    // the store's save chain starts where it is constructed.
    await tester.runAsync(() async {
      final NexusStore store = NexusStore(
        explicitPath:
            '${Directory.systemTemp.createTempSync('privacy').path}/s.json',
      );
      store.broadcastDiscovery = false; // never touch the network in a test
      await store.save();
      mesh = MeshService(
        identity:
            DeviceInfo(id: 'privacy-1', name: 'Privacy PC', platform: 'linux'),
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

      final Finder row = find.text('Privacy Policy');
      await tester.scrollUntilVisible(row, 200);
      await tester.pump();
      expect(row, findsOneWidget);

      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.byType(PrivacyPolicyView), findsOneWidget);
      expect(find.text(PrivacyPolicyView.policy), findsOneWidget);
    } finally {
      await tester.runAsync(mesh.stop);
    }
  });
}
