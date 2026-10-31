// The accent as a preference.
//
// Three things have to hold, and each of them failed at least once on a phone:
// a stored seed opens the app in that colour, the shipped purple is answered by
// the shipped purple (not by a derived lookalike), and a store that cannot be
// reached costs the user their colour rather than an error.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/appearance.dart';
import 'package:nexus/core/onboarding.dart';
import 'package:nexus/main_ui.dart'
    show
        NexusAccent,
        NexusTheme,
        NexusUiApp,
        accentFromSeed,
        kNexusAccent,
        kNexusDarkModeRow;
import 'package:shared_preferences/shared_preferences.dart';

/// The green a wheel drag left on the A25 during the phone pass.
const int _green = 0xFF34DC00;

void main() {
  setUp(() {
    Appearance.debugOverride = null;
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() => Appearance.debugOverride = null);

  group('a stored seed', () {
    test('nothing stored is the shipped purple', () {
      expect(accentFromSeed(null), NexusAccent.purple);
    });

    test('the purple seed is the purple, not a derived lookalike', () {
      // The derived version lifts the colour for a dark page; the app's own
      // identity is painted exactly as the tokens name it.
      expect(accentFromSeed(kNexusAccent.toARGB32()), NexusAccent.purple);
      expect(
        accentFromSeed(kNexusAccent.toARGB32()).dark,
        NexusAccent.purple.dark,
      );
    });

    test('any other seed is the user\'s own colour', () {
      final NexusAccent accent = accentFromSeed(_green);
      expect(accent.seed, const Color(_green));
      expect(accent.isCustom, isTrue);
      expect(accent, NexusAccent.custom(const Color(_green)));
      expect(accent.seed, isNot(kNexusAccent));
    });
  });

  group('the store', () {
    test('starts empty, and round trips what it is given', () async {
      expect(await Appearance.accentSeed(), isNull);
      await Appearance.setAccentSeed(_green);
      expect(await Appearance.accentSeed(), _green);
    });

    test('an override answers before the store is asked', () async {
      Appearance.debugOverride = _green;
      expect(await Appearance.accentSeed(), _green);
    });

    test('is read under a stable key', () async {
      await Appearance.setAccentSeed(_green);
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(Appearance.accentKey), _green);
    });
  });

  group('brightness, across launches', () {
    test(
      'a fresh install follows the system, and is light if it must choose',
      () async {
        final ({bool dark, bool followSystem}) theme = await Appearance.theme();
        expect(theme.followSystem, isTrue);
        expect(theme.dark, isFalse);
      },
    );

    test('both switches round trip under their own keys', () async {
      await Appearance.setFollowSystem(false);
      await Appearance.setDarkMode(true);
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(Appearance.followSystemKey), isFalse);
      expect(prefs.getBool(Appearance.darkModeKey), isTrue);
      final ({bool dark, bool followSystem}) theme = await Appearance.theme();
      expect(theme.followSystem, isFalse);
      expect(theme.dark, isTrue);
    });

    test(
      'the two are stored apart, so turning Follow system off keeps the choice',
      () async {
        // The bug this design avoids: one derived "dark" would forget the
        // user's own pick while the phone was in charge.
        await Appearance.setDarkMode(true);
        await Appearance.setFollowSystem(true);
        await Appearance.setFollowSystem(false);
        expect((await Appearance.theme()).dark, isTrue);
      },
    );

    testWidgets('the app opens on the stored side, before any tap', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        Onboarding.key: true,
      });
      await tester.pumpWidget(
        const NexusUiApp(initialFollowSystem: false, initialDark: true),
      );
      await tester.pumpAndSettle();
      final MaterialApp app = tester.widget<MaterialApp>(
        find.byType(MaterialApp),
      );
      expect(app.themeMode, ThemeMode.dark);
    });

    testWidgets('flipping the switch in Settings stores it', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        Onboarding.key: true,
      });
      await tester.pumpWidget(const NexusUiApp(initialFollowSystem: false));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byKey(kNexusDarkModeRow),
          matching: find.byType(Switch),
        ),
      );
      await tester.pumpAndSettle();

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getBool(Appearance.darkModeKey),
        isTrue,
        reason: 'the preference a relaunch reads',
      );
    });
  });

  group('the app it opens', () {
    testWidgets('paints itself in the stored colour, before any tap', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        Onboarding.key: true,
      });
      await tester.pumpWidget(
        NexusUiApp(initialAccent: accentFromSeed(_green)),
      );
      await tester.pumpAndSettle();

      final MaterialApp app = tester.widget<MaterialApp>(
        find.byType(MaterialApp),
      );
      final ColorScheme custom = NexusTheme.light(
        accent: accentFromSeed(_green),
      ).colorScheme;
      final ColorScheme customDark = NexusTheme.dark(
        accent: accentFromSeed(_green),
      ).colorScheme;
      // The theme's own default *is* the shipped purple, which is the point:
      // an app with no stored seed must paint what `NexusTheme.light()` paints.
      final ColorScheme shipped = NexusTheme.light().colorScheme;

      expect(app.theme!.colorScheme.primary, custom.primary);
      expect(app.theme!.colorScheme.primary, isNot(shipped.primary));
      expect(app.darkTheme!.colorScheme.primary, customDark.primary);
    });

    testWidgets('without one paints the purple it ships with', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        Onboarding.key: true,
      });
      await tester.pumpWidget(const NexusUiApp());
      await tester.pumpAndSettle();

      final MaterialApp app = tester.widget<MaterialApp>(
        find.byType(MaterialApp),
      );
      expect(
        app.theme!.colorScheme.primary,
        NexusTheme.light().colorScheme.primary,
      );
      expect(NexusTheme.light().colorScheme.primary, isNot(Colors.transparent));
    });
  });
}
