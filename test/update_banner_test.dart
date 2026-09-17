// The banner a phone reads when it is trying to update itself.
//
// A phone could not update from inside the app: Android sent the user to the
// screen that grants "install unknown apps", the app said nothing at all, and
// the install it was holding never started unless the user guessed. The banner
// is where that step has to be named — and a step is not an error, so it must
// not wear the error icon.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/mesh/updater.dart';
import 'package:nexus/ui/update_banner.dart';

void main() {
  const info = UpdateInfo(version: '0.1.53');

  Future<void> pump(
    WidgetTester tester, {
    String? error,
    String? note,
    bool applying = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UpdateBanner(
            info: info,
            applying: applying,
            error: error,
            note: note,
            onUpdate: () {},
            onDismiss: () {},
          ),
        ),
      ),
    );
  }

  /// Runs a body as the phone. The override is cleared inside the body: the
  /// test framework checks the debug variables are unset before tearDowns run.
  Future<void> asAndroid(Future<void> Function() body) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  testWidgets('an available update names the version', (tester) async {
    await pump(tester);
    expect(find.text('Nexus v0.1.53 is available'), findsOneWidget);
    expect(find.byIcon(Icons.system_update_rounded), findsOneWidget);
  });

  testWidgets('the Android permission step is shown as the next step', (
    tester,
  ) async {
    await asAndroid(() async {
      await pump(tester, note: updateHandoffNote(UpdateApply.needsPermission));

      expect(
        find.textContaining('Allow Nexus to install this update'),
        findsOneWidget,
      );
      // A step the user must take is not a failure: no error icon, and the
      // update is still offered as available.
      expect(find.byIcon(Icons.info_outline_rounded), findsOneWidget);
      expect(find.byIcon(Icons.error_outline_rounded), findsNothing);
      expect(find.text('Update & install'), findsOneWidget);
    });
  });

  testWidgets('a failure replaces the step it was retrying', (tester) async {
    await asAndroid(() async {
      await pump(
        tester,
        error: 'Could not open the installer.',
        note: updateHandoffNote(UpdateApply.needsPermission),
      );

      expect(find.text('Could not open the installer.'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
      expect(
        find.textContaining('Allow Nexus to install this update'),
        findsNothing,
      );
    });
  });

  testWidgets('while the update runs the actions are disabled', (tester) async {
    await pump(tester, applying: true);
    expect(find.text('Updating to v0.1.53…'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(
      tester.widget<TextButton>(find.byType(TextButton)).onPressed,
      isNull,
    );
  });
}
