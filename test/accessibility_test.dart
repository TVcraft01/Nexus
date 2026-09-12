// Accessibility invariants, measured on the real widgets.
//
// Two things every interactive control owes the user:
//
//  1. A name. An icon-only button with no tooltip reaches a screen reader as
//     "button" and nothing else, so the primary action in the app (send) was
//     announced as an anonymous control.
//  2. A target big enough to hit. 44dp is the floor both Apple and Material
//     name for a finger; `VisualDensity.compact` is the usual way this code
//     quietly falls under it.
//
// Both are asserted against the real trees at real phone geometry, so a new
// button or a new density setting has to satisfy them rather than discover
// them later on a user's phone.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/query_log.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/mesh/mesh_service.dart';
import 'package:nexus/ui/assistant_view.dart';
import 'package:nexus/ui/pair_sheet.dart';
import 'package:nexus/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The floor a finger target may not go under.
const _minTarget = 44.0;

/// Every interactive control in the current tree, as (what it is, its label,
/// its rendered size).
List<({String control, String? label, Size size})> _controls(
  WidgetTester tester,
) {
  final out = <({String control, String? label, Size size})>[];
  for (final element in find
      .byWidgetPredicate((w) => w is IconButton || w is ButtonStyleButton)
      .evaluate()) {
    final widget = element.widget;
    out.add((
      control: widget.runtimeType.toString(),
      label: widget is IconButton ? widget.tooltip : null,
      size: tester.getSize(find.byWidget(widget)),
    ));
  }
  return out;
}

/// Asserts both invariants across whatever is on screen.
void expectControlsAreUsable(WidgetTester tester, {required String where}) {
  final controls = _controls(tester);
  expect(controls, isNotEmpty, reason: '$where exposes no controls at all');

  for (final c in controls) {
    expect(
      c.size.width,
      greaterThanOrEqualTo(_minTarget),
      reason: '${c.control} "${c.label ?? ''}" is ${c.size.width}dp wide in '
          '$where — under the $_minTarget dp touch minimum',
    );
    expect(
      c.size.height,
      greaterThanOrEqualTo(_minTarget),
      reason: '${c.control} "${c.label ?? ''}" is ${c.size.height}dp tall in '
          '$where — under the $_minTarget dp touch minimum',
    );
  }

  // Only an icon-only control can be unlabelled: a text button carries its
  // own words, an IconButton carries none, so it needs a tooltip.
  final unnamed = [
    for (final c in controls)
      if (c.control == 'IconButton' && (c.label == null || c.label!.isEmpty))
        c.control,
  ];
  expect(
    unnamed,
    isEmpty,
    reason: '$where has ${unnamed.length} icon-only control(s) with no '
        'accessible name',
  );
}

Future<MeshService> _mesh(String tag, int port) async {
  final store = NexusStore(
    explicitPath: '${Directory.systemTemp.createTempSync(tag).path}/s.json',
  );
  store.autoUpdate = false;
  store.port = port;
  await store.save();
  return MeshService(
    identity: DeviceInfo(id: tag, name: 'A11y PC', platform: 'linux'),
    store: store,
    heartbeatInterval: const Duration(seconds: 30),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({
    'nexus.profile.onboarded': true,
  }));

  testWidgets('the assistant keeps every control labelled and hittable', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    // The dream nudge is where the smallest controls live, so the walk has to
    // reach it: a log with a re-asked phrase that matches something taught.
    final store = NexusStore(
      explicitPath: '${Directory.systemTemp.createTempSync('a11y1').path}/s.json',
    )..agentLearned = {'text mom': 'call tvcraft01'};
    final mesh = MeshService(
      identity: DeviceInfo(id: 'a11y1', name: 'A11y PC', platform: 'linux'),
      store: store,
    );
    QueryLog.readAllOverride = () async => [
      '{"ts":"t","kind":"ask","input":"tex mom","status":"needsInfo","route":"teach:tex mom","detail":""}',
      '{"ts":"t","kind":"ask","input":"tex mom","status":"needsInfo","route":"teach:tex mom","detail":""}',
    ];

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildNexusTheme(),
          home: Scaffold(body: AssistantView(mesh: mesh)),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        find.byKey(const ValueKey('dream-learn-card')),
        findsOneWidget,
        reason: 'the nudge has to be open for this to cover its controls',
      );
      expectControlsAreUsable(tester, where: 'the assistant');
    } finally {
      QueryLog.readAllOverride = null;
      QueryLog.i.resetForTest();
      debugDefaultTargetPlatformOverride = null;
      tester.view.reset();
      await mesh.stop();
    }
  });

  testWidgets('the send button is named', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    // Built inside runAsync: it writes a real store file, and real I/O never
    // completes under the fake clock a widget test runs in.
    final mesh = (await tester.runAsync(() => _mesh('a11y2', 53992)))!;

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildNexusTheme(),
          home: Scaffold(body: AssistantView(mesh: mesh)),
        ),
      );
      await tester.pump();

      // The specific defect: an icon with no text and no tooltip, so a screen
      // reader announced the send button as nothing.
      final send = tester
          .widgetList<IconButton>(find.byType(IconButton))
          .where((b) => b.icon is Icon)
          .where((b) => (b.icon as Icon).icon == Icons.send_rounded)
          .toList();
      expect(send, hasLength(1), reason: 'the composer has one send button');
      expect(send.single.tooltip, isNotNull);
      expect(send.single.tooltip, isNotEmpty);

      expectControlsAreUsable(tester, where: 'the assistant composer');
    } finally {
      debugDefaultTargetPlatformOverride = null;
      tester.view.reset();
      await mesh.stop();
    }
  });

  testWidgets('the pair sheet can be read and closed by name', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    final mesh = (await tester.runAsync(() => _mesh('a11y3', 53993)))!;

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildNexusTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: OutlinedButton(
                  onPressed: () => showPairSheet(context, mesh: mesh),
                  child: const Text('Pair a device'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Pair a device'));
      // Bounded pumps, not pumpAndSettle: the sheet animates on a loop (the
      // pairing code refreshes), so "settled" never arrives.
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }

      // The sheet is open — its own close control must carry a name, and the
      // button that opened it is a text button, so this also covers the
      // toolbar-sized controls the sheet uses.
      expect(find.byType(OutlinedButton), findsWidgets);
      expectControlsAreUsable(tester, where: 'the pair sheet');
    } finally {
      debugDefaultTargetPlatformOverride = null;
      tester.view.reset();
      await mesh.stop();
    }
  });
}
