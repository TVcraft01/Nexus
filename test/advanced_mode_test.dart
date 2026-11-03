import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/advanced_mode.dart';
import 'package:nexus/core/onboarding.dart';
import 'package:nexus/main_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

// The File manager is a tab only once Settings → Advanced says so. It used to
// be one of four destinations on a fresh install, competing with the
// conversation for the same thumb, for a tree view of devices the Devices tab
// already lists. Sending a file never needed it: "send this to my PC" is an
// action in the chat. These tests pin both halves of that decision.
//
// The assertions are about the shell's stack index rather than about which
// widgets exist, because every page stays in the tree either way: that is what
// keeps a draft alive when the tab bar changes shape.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AdvancedMode.instance.resetForTest();
    Onboarding.debugOverride = true;
  });
  tearDown(() {
    Onboarding.debugOverride = null;
    AdvancedMode.instance.resetForTest();
  });

  /// A phone-shaped surface, the layout the shell is designed against.
  Future<void> pumpShell(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const NexusUiApp());
    await tester.pumpAndSettle();
  }

  Finder tabLabel(String label) => find.descendant(
    of: find.byType(NexusTabBar),
    matching: find.text(label),
  );

  /// Which page the shell is showing. The shell's stack is the outermost one.
  int shownPage(WidgetTester tester) =>
      tester.widget<IndexedStack>(find.byType(IndexedStack).first).index ?? -1;

  /// The Files page does work on the way in (it reads the library), so this
  /// waits a bounded number of frames rather than for everything to settle.
  Future<void> tapAndLand(WidgetTester tester, String label) async {
    await tester.tap(tabLabel(label));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('a fresh install has three destinations, and Files is not one', (
    WidgetTester tester,
  ) async {
    await pumpShell(tester);
    expect(tabLabel('Home'), findsOneWidget);
    expect(tabLabel('Devices'), findsOneWidget);
    expect(tabLabel('Settings'), findsOneWidget);
    expect(tabLabel('Files'), findsNothing);
    expect(shownPage(tester), 0);
  });

  testWidgets('turning Advanced on puts the Files tab in the bar', (
    WidgetTester tester,
  ) async {
    await pumpShell(tester);
    expect(tabLabel('Files'), findsNothing);

    await AdvancedMode.instance.setEnabled(true);
    await tester.pumpAndSettle();

    expect(tabLabel('Files'), findsOneWidget);
    // The switch adds a destination; it does not replace one.
    expect(tabLabel('Home'), findsOneWidget);
    expect(tabLabel('Devices'), findsOneWidget);
    expect(tabLabel('Settings'), findsOneWidget);
  });

  testWidgets('the Files tab opens the file manager when it is tapped', (
    WidgetTester tester,
  ) async {
    AdvancedMode.instance.resetForTest(enabled: true);
    await pumpShell(tester);

    await tapAndLand(tester, 'Files');

    // Page 1 is the file manager. Asking the stack rather than the widget tree
    // is the only honest question here: every page is built either way.
    expect(shownPage(tester), 1);
  });

  testWidgets(
    'turning Advanced off takes the tab away and leaves Settings in front of '
    'the user',
    (WidgetTester tester) async {
      AdvancedMode.instance.resetForTest(enabled: true);
      await pumpShell(tester);
      await tapAndLand(tester, 'Files');
      expect(shownPage(tester), 1);

      await AdvancedMode.instance.setEnabled(false);
      // Bounded pumps, not settle: the file manager was opened a moment ago and
      // keeps work in flight, so "nothing left to do" is not a state this test
      // can wait for.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(tabLabel('Files'), findsNothing);
      // Not a stack index that no longer exists: Settings is where the switch
      // lives, so that is the page the user lands back on.
      expect(shownPage(tester), 3);
      expect(tabLabel('Settings'), findsOneWidget);
    },
  );

  test('the choice is remembered across launches', () async {
    await AdvancedMode.instance.setEnabled(true);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(kAdvancedModeKey), isTrue);

    await AdvancedMode.instance.setEnabled(false);
    expect(prefs.getBool(kAdvancedModeKey), isFalse);
  });
}
