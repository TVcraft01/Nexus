// A sheet's controls, painted with no Material above them.
//
// Nexus wears Cupertino chrome: a sheet here is a `CupertinoSheetRoute`, and
// nothing Material is in scope inside it. Not every Material control survives
// that — `RawChip` asserts an ambient `Material` for its ink (`chip.dart`) —
// which is why a transparent `Material` used to sit under the content of every
// sheet in the app. The choices a sheet holds are Nexus's own pill now, so the
// wrapper is gone; this measures that the sheet really does work without it,
// rather than trusting that it does.
import 'dart:io';

import 'package:flutter/cupertino.dart' show CupertinoTextField;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/mesh/mesh_service.dart';
import 'package:nexus/ui/components/nexus_ui.dart';
import 'package:nexus/ui/pair_sheet.dart';
import 'package:nexus/ui/theme.dart';

/// A mesh that never opens a socket: the sheet only needs something to pair
/// with, not something to talk to.
Future<MeshService> _mesh() async {
  final store = NexusStore(
    explicitPath:
        '${Directory.systemTemp.createTempSync('sheet-surface').path}/s.json',
  );
  store.autoUpdate = false;
  store.port = 54123;
  await store.save();
  return MeshService(
    identity: DeviceInfo(
      id: 'sheet-device',
      name: 'Sheet PC',
      platform: 'linux',
    ),
    store: store,
    heartbeatInterval: const Duration(seconds: 30),
  );
}

void main() {
  testWidgets('the pair sheet\'s own fields are Cupertino, not Material', (
    tester,
  ) async {
    // Built through runAsync and stopped in the finally: a live MeshService
    // holds timers and sockets outside the fake clock, and a test that leaves
    // them running never finishes.
    final mesh = (await tester.runAsync(_mesh))!;

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildNexusTheme(),
          home: Builder(
            builder: (ctx) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showPairSheet(ctx, mesh: mesh),
                  child: const Text('open pairing'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open pairing'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('More ways to connect'));
      await tester.pump();
      await tester.tap(find.text('Enter a code from the other device'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // Building the tab is most of the assertion: a Material field here
      // throws "No Material widget found" as it builds, because the sheet
      // route has no Material above it. The rest pins the shape the fields
      // have now — captions over the fields, not floating labels.
      expect(tester.takeException(), isNull, reason: 'the tab must build');
      expect(
        find.byType(CupertinoTextField),
        findsNWidgets(3),
        reason: 'code, address and port are the app\'s own fields',
      );
      expect(find.text('Code'), findsOneWidget);
      expect(find.text('Address'), findsOneWidget);
      expect(find.text('Port'), findsOneWidget);
    } finally {
      await mesh.stop();
    }
  });

  testWidgets('a sheet holds a pill and a button with no Material over them', (
    tester,
  ) async {
    var picks = 0;
    var confirms = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: buildNexusTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () => showNexusSheet<void>(
                  context: context,
                  builder: (context, scroll) => ListView(
                    controller: scroll,
                    children: [
                      NexusChoicePill(
                        label: 'TVcraft01',
                        selected: true,
                        onTap: () => picks++,
                      ),
                      FilledButton(
                        onPressed: () => confirms++,
                        child: const Text('Choose here'),
                      ),
                    ],
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // The sheet is a route of its own: the page that opened it is a sibling,
    // not an ancestor, so anything Material above the content would be one the
    // sheet itself added.
    expect(
      find.ancestor(
        of: find.byType(NexusChoicePill),
        matching: find.byType(Material),
      ),
      findsNothing,
      reason: 'a sheet has no Material of its own, and must not need one',
    );

    await tester.tap(find.text('TVcraft01'));
    await tester.pumpAndSettle();
    expect(picks, 1, reason: 'the pill presses without an ambient Material');

    await tester.tap(find.text('Choose here'));
    await tester.pumpAndSettle();
    expect(confirms, 1, reason: 'a button in a sheet paints itself');
  });
}
