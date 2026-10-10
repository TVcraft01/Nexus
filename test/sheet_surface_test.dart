// A sheet's controls, painted with no Material above them.
//
// Nexus wears Cupertino chrome: a sheet here is a `CupertinoSheetRoute`, and
// nothing Material is in scope inside it. Not every Material control survives
// that — `RawChip` asserts an ambient `Material` for its ink (`chip.dart`) —
// which is why a transparent `Material` used to sit under the content of every
// sheet in the app. The choices a sheet holds are Nexus's own pill now, so the
// wrapper is gone; this measures that the sheet really does work without it,
// rather than trusting that it does.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/ui/components/nexus_ui.dart';
import 'package:nexus/ui/theme.dart';

void main() {
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
