// The layout guarantee the shell owes at 200% text.
//
// textScaleFactor is the platform's setting, and the shell does not clamp it:
// WCAG 1.4.4 asks for text that reaches 200% without loss of content, and a
// clamp is a refusal, not a fix. What the shell does owe is a layout that
// survives the setting — no RenderFlex overflow, at 880 points (desktop) and
// at 360 (the narrowest window the rules promise), on every tab.
//
// This measured the opposite before: at 200% the sidebar pushed its own labels
// past the column, the tab bar clipped its captions, the chat header's chip
// shoved the row off the edge, and the Files heading could not fit its sort
// button. Each of those is a row that could not give way; the assertions are
// the same rows, at the sizes that broke them.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/main_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Every tab the shipped shell can show.
const List<String> _tabs = <String>['Files', 'Devices', 'Settings'];

void main() {
  setUp(
    () => SharedPreferences.setMockInitialValues(<String, Object>{
      'nexus.profile.onboarded': true,
      'flutter.has_onboarded': true,
    }),
  );

  for (final double scale in <double>[1.0, 1.5, 2.0]) {
    for (final double width in <double>[880, 360]) {
      testWidgets('every tab fits at ${scale}x text in a ${width}px window', (
        tester,
      ) async {
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(const NexusUiApp());
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));

        expect(
          tester.takeException(),
          isNull,
          reason: 'Home overflowed at ${scale}x in a ${width}px window',
        );

        for (final String tab in _tabs) {
          await tester.tap(find.text(tab).last);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 80));
          expect(
            tester.takeException(),
            isNull,
            reason: '$tab overflowed at ${scale}x in a ${width}px window',
          );
        }
      });
    }
  }

  testWidgets('a narrow desktop window uses the phone layout, not a sidebar '
      'crammed beside a ribbon', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const NexusUiApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    // The sidebar is 280 of the 360 points, which leaves the page 80 — a
    // column one character wide. Below the breakpoint the shell draws the tab
    // bar instead, whatever platform it is running on.
    expect(find.text('Settings'), findsWidgets);
    expect(
      tester.getRect(find.text('Settings').last).width,
      greaterThan(20),
      reason: 'the destination is readable, not a vertical ribbon',
    );
  });
}
