// 360 px wide with the text doubled is where a layout that "fits" stops
// fitting: the tab bar, the section labels and the device rows all compete for
// a quarter of the width. A tab bar that draws a word as a column of letters
// still screenshots fine, so these are checked by finder rather than by eye.
//
// The shell needs the same test seams the other shell tests install — a paired
// list of its own, and no font fetching — or it never gets past its first
// frame in a test environment.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:nexus/core/onboarding.dart';
import 'package:nexus/core/paired_devices.dart';
import 'package:nexus/main_ui.dart';

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  setUp(() {
    PairedDevices.override = () =>
        PairedDevices(seed: <PairedDevice>[]);
    // A fresh install opens on the welcome screen; this file is about the
    // shell behind it, so every test starts set up.
    Onboarding.debugOverride = true;
  });

  tearDown(() {
    PairedDevices.override = null;
    Onboarding.debugOverride = null;
  });

  Future<void> pumpNarrow(WidgetTester tester, Brightness brightness) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    tester.platformDispatcher.platformBrightnessTestValue = brightness;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.pumpWidget(const NexusUiApp());
    await tester.pumpAndSettle();
  }

  for (final Brightness brightness in Brightness.values) {
    testWidgets(
      '360 px at 200 % text keeps the destinations in a bottom bar '
      '(${brightness.name})',
      (WidgetTester tester) async {
        await pumpNarrow(tester, brightness);

        // The sidebar is the wide-window answer. At 360 it must give way: a
        // 260 px column beside a 360 px window leaves 100 px for the page,
        // which is where a word starts breaking one letter per line.
        expect(find.byType(NexusTabBar), findsOneWidget);
        expect(
          find.byKey(const ValueKey<String>('nexus-wide-sidebar')),
          findsNothing,
        );
        // A 200 % layout that overflows throws, and what a person sees is the
        // yellow-and-black bar.
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '360 px at 200 % text never wraps a tab label one letter per line '
      '(${brightness.name})',
      (WidgetTester tester) async {
        await pumpNarrow(tester, brightness);

        final List<Text> labels = tester
            .widgetList<Text>(
              find.descendant(
                of: find.byType(NexusTabBar),
                matching: find.byType(Text),
              ),
            )
            .toList();
        expect(labels.length, 4, reason: 'four destinations, no more');
        for (final Text label in labels) {
          expect(label.maxLines, 1, reason: '${label.data} must stay one line');
          expect(label.softWrap, isFalse, reason: '${label.data} must not wrap');
        }
        expect(find.text('Settings'), findsOneWidget);
      },
    );
  }
}
