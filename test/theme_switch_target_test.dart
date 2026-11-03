// What the Dark mode row actually accepts, measured rather than guessed.
//
// The switch is `onChanged: followSystem ? null : _toggleDark` and the row's
// `onTap` is null in the same state, so while the system setting is in charge
// the row is inert by construction. §9 asks for a control that says why it is
// inert rather than one that looks broken, so the locked row carries a hint
// line, and these tests hold both facts: the hint, and the hit area.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/onboarding.dart';
import 'package:nexus/core/paired_devices.dart';
import 'package:nexus/main_ui.dart';

void main() {
  setUp(() {
    PairedDevices.override = () => PairedDevices(seed: <PairedDevice>[]);
    Onboarding.debugOverride = true;
  });
  tearDown(() {
    PairedDevices.override = null;
    Onboarding.debugOverride = null;
  });

  Future<void> openSettings(WidgetTester tester) async {
    tester.view.physicalSize = const Size(880, 1000);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.pumpWidget(const NexusUiApp());
    await tester.pumpAndSettle();
    final Finder inNav = find.descendant(
      of: find.byWidgetPredicate((Widget w) =>
          w is NavigationBar || w is NavigationRail || w is NexusTabBar),
      matching: find.text('Settings'),
    );
    await tester.tap(inNav.evaluate().isNotEmpty
        ? inNav.first
        : find.text('Settings').last);
    await tester.pumpAndSettle();
  }

  Finder darkSwitch() => find.descendant(
        of: find.byKey(const Key('nexus-dark-mode-row')),
        matching: find.byType(Switch),
      );

  /// Read below the app, not at it: `Theme.of` on the MaterialApp element sees
  /// whatever is above the app (nothing), which is always light.
  Brightness shellBrightness(WidgetTester tester) =>
      Theme.of(tester.element(find.byType(Scaffold).first)).brightness;

  /// The one line the locked row shows instead of leaving a dead switch.
  const String lockedHint = 'Turn off the row above to choose.';

  testWidgets('records the Dark mode switch hit area', (WidgetTester tester) async {
    await openSettings(tester);
    final Size size = tester.getSize(darkSwitch());
    final Rect rect = tester.getRect(darkSwitch());
    debugPrint('AUDIT dark switch box: ${size.width} x ${size.height} at $rect');
    expect(size.width, greaterThanOrEqualTo(24));
    expect(size.height, greaterThanOrEqualTo(24));
  });

  testWidgets('a locked switch does not change the theme',
      (WidgetTester tester) async {
    await openSettings(tester);
    expect(shellBrightness(tester), Brightness.light);
    await tester.tap(darkSwitch());
    await tester.pumpAndSettle();
    expect(shellBrightness(tester), Brightness.light,
        reason: 'the switch is locked while the system setting is in charge');
  });

  testWidgets('the locked row says how to unlock it',
      (WidgetTester tester) async {
    await openSettings(tester);
    expect(find.text(lockedHint), findsOneWidget,
        reason: 'a disabled switch with no explanation reads as a bug');
    // Releasing the row above hands the choice over, and the hint goes away
    // with the reason for it.
    await tester.tap(find.textContaining('light or dark setting'));
    await tester.pumpAndSettle();
    expect(find.text(lockedHint), findsNothing);
  });

  testWidgets('a click on the switch toggles once the row above is released',
      (WidgetTester tester) async {
    await openSettings(tester);
    await tester.tap(find.textContaining('light or dark setting'));
    await tester.pumpAndSettle();
    final Size size = tester.getSize(darkSwitch());
    debugPrint('AUDIT dark switch box (unlocked): ${size.width} x ${size.height}');
    await tester.tap(darkSwitch());
    await tester.pumpAndSettle();
    expect(shellBrightness(tester), Brightness.dark);
  });
}
