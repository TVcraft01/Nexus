import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:nexus/main_ui.dart';

/// The UI shell is standalone, so it is tested standalone: pump [NexusUiApp],
/// drive it like a thumb would, and check what is actually on screen.
void main() {
  setUpAll(() {
    // The shell asks google_fonts for Inter; in a test there is no network, so
    // tell the package not to try and let text fall back to the test font.
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  /// A phone-shaped surface — the layout the shell is designed against.
  Future<void> pumpShell(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const NexusUiApp());
    await tester.pumpAndSettle();
  }

  Finder tab(String label) => find.descendant(
    of: find.byType(NexusTabBar),
    matching: find.text(label),
  );

  Future<void> openTab(WidgetTester tester, String label, int index) async {
    await tester.tap(tab(label));
    await tester.pumpAndSettle();
    expect(tester.widget<IndexedStack>(find.byType(IndexedStack)).index, index);
  }

  /// The tab bar's icon colour — scoped, because the same glyphs show up in
  /// the file and device lists too.
  Color tabIconColor(WidgetTester tester, IconData icon) => tester
      .widget<Icon>(
        find.descendant(
          of: find.byType(NexusTabBar),
          matching: find.byIcon(icon),
        ),
      )
      .color!;

  testWidgets('opens on Home with the greeting and a bubble per side', (
    tester,
  ) async {
    await pumpShell(tester);

    expect(find.text('Hey, what do you need?'), findsOneWidget);
    expect(find.textContaining('Everything stays on your devices'), findsWidgets);
    expect(find.text('What’s in my Downloads?'), findsOneWidget);
    expect(find.text('Message Nexus'), findsOneWidget);

    final home = tester.widget<IndexedStack>(find.byType(IndexedStack));
    expect(home.index, 0);

    // The composer starts as a mic, because there is nothing to send.
    expect(find.byTooltip('Voice input'), findsOneWidget);
    expect(find.byTooltip('Send'), findsNothing);
  });

  testWidgets('the composer turns the mic into send, and posts the message', (
    tester,
  ) async {
    await pumpShell(tester);

    await tester.enterText(find.byType(TextField), 'summarise my notes');
    await tester.pumpAndSettle();
    expect(find.byTooltip('Send'), findsOneWidget);
    expect(find.byTooltip('Voice input'), findsNothing);

    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();

    expect(find.text('summarise my notes'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '');
    expect(find.byTooltip('Voice input'), findsOneWidget);
  });

  testWidgets('only the active tab is purple; the rest are grey', (
    tester,
  ) async {
    await pumpShell(tester);

    expect(tabIconColor(tester, Icons.home_rounded), kNexusAccent);
    expect(tabIconColor(tester, Icons.folder_outlined), isNot(kNexusAccent));

    await openTab(tester, 'Files', 1);
    expect(tabIconColor(tester, Icons.folder_rounded), kNexusAccent);
    expect(tabIconColor(tester, Icons.home_outlined), isNot(kNexusAccent));
  });

  testWidgets('Files lists files for the chosen device', (tester) async {
    await pumpShell(tester);
    await openTab(tester, 'Files', 1);

    expect(find.text('This Phone'), findsWidgets);
    expect(find.text('report.pdf'), findsOneWidget);
    expect(find.text('3.4 MB · Oct 9'), findsOneWidget);

    // Switch device through the dropdown.
    await tester.tap(find.text('This Phone').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('My PC').last);
    await tester.pumpAndSettle();
    expect(find.text('On My PC'), findsOneWidget);
  });

  testWidgets('long-pressing a file opens its action sheet', (tester) async {
    await pumpShell(tester);
    await openTab(tester, 'Files', 1);

    await tester.longPress(find.text('report.pdf'));
    await tester.pumpAndSettle();

    final sheet = find.byType(BottomSheet);
    expect(sheet, findsOneWidget);
    expect(
      find.descendant(of: sheet, matching: find.text('4.0 KB · Oct 11')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: sheet, matching: find.text('Send to a device')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: sheet, matching: find.text('Rename')),
      findsOneWidget,
    );
  });

  testWidgets('the composer clears the tab bar and the bubbles take sides', (
    tester,
  ) async {
    await pumpShell(tester);

    // The pill must never sit under the navigation bar.
    final field = tester.getRect(find.byType(TextField));
    final bar = tester.getRect(find.byType(NexusTabBar));
    expect(field.bottom, lessThan(bar.top));

    // Measure the text, not the bubble: each bubble is an Align, so the
    // bubble's own rect is the full column and says nothing about its side.
    final mine = tester.getRect(find.text('What’s in my Downloads?'));
    final theirs = tester.getRect(
      find.textContaining('Everything stays on your devices'),
    );
    expect(theirs.left, lessThan(60));
    expect(mine.left, greaterThan(theirs.left));
    expect(mine.right, greaterThan(theirs.right));
  });

  testWidgets('Devices shows a dot and a word per peer', (tester) async {
    await pumpShell(tester);
    await openTab(tester, 'Devices', 2);

    expect(find.text('PAIRED'), findsOneWidget);
    expect(find.text('Online'), findsNWidgets(2));
    expect(find.text('Offline'), findsOneWidget);
    expect(find.byType(NexusStatusDot), findsNWidgets(3));
    expect(find.text('Pair a device'), findsOneWidget);

    final dots = tester.widgetList<NexusStatusDot>(
      find.byType(NexusStatusDot),
    );
    expect(dots.where((dot) => dot.online).length, 2);
  });

  testWidgets('the dark-mode switch darkens the frame', (tester) async {
    await pumpShell(tester);
    await openTab(tester, 'Settings', 3);

    expect(find.text('Dark mode'), findsOneWidget);
    expect(find.text('Voice & speech'), findsOneWidget);
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold).first).backgroundColor,
      NexusUiColors.light.background,
    );

    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();

    expect(
      tester.widget<Scaffold>(find.byType(Scaffold).first).backgroundColor,
      NexusUiColors.dark.background,
    );
  });

  testWidgets('voice settings is a real page you can open and leave', (
    tester,
  ) async {
    await pumpShell(tester);
    await openTab(tester, 'Settings', 3);

    await tester.tap(find.text('Voice & speech'));
    await tester.pumpAndSettle();

    expect(find.text('Wake word'), findsOneWidget);
    expect(find.text('Speak replies'), findsOneWidget);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Wake word'), findsNothing);
    expect(tester.widget<IndexedStack>(find.byType(IndexedStack)).index, 3);
  });
}
