// The pair screen's own behaviour, away from the e2e harness.
//
// Two regressions the e2e run caught are pinned here so the ordinary `flutter
// test` job (which does not build a desktop app) still sees them:
//
//  * the submit button was enabled from whatever the field held when the page
//    was built, so it stayed disabled while a person typed;
//  * the guest's screen replaced itself with the confirm card the moment it
//    answered, so its QR2 and six digits — the two things the host needs —
//    were never shown.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/identity_seed_store.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/mesh/mesh_service.dart';
import 'package:nexus/ui/offline_pair_page.dart';
import 'package:nexus/ui/theme.dart';
import 'package:qr_flutter/qr_flutter.dart';

class _MemorySeedStore implements IdentitySeedStore {
  final Map<String, Map<String, dynamic>> values = {};

  @override
  Future<Map<String, dynamic>?> read() async => values['seed'] == null
      ? null
      : Map<String, dynamic>.of(values['seed']!);

  @override
  Future<void> write(Map<String, dynamic> identity) async {
    values['seed'] = Map<String, dynamic>.of(identity);
  }

  @override
  Future<void> delete() async => values.remove('seed');
}

void main() {
  late Directory tmp;
  late MeshService mesh;

  MeshService device(String id, String name) {
    final store = NexusStore(explicitPath: '${tmp.path}/$id.json')..port = 0;
    return MeshService(
      identity: DeviceInfo(id: id, name: name, platform: 'linux'),
      store: store,
      heartbeatInterval: const Duration(seconds: 30),
    )..useIdentitySeedStoreForTest(_MemorySeedStore());
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('nexus_pair_page');
    mesh = device('page-device', 'This laptop');
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> open(WidgetTester tester) async {
    // A tall window: the confirm buttons sit below the QR at the default
    // 800x600, and a tap that misses is not what these tests are about.
    tester.view.physicalSize = const Size(1200, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildNexusTheme(brightness: Brightness.dark),
        home: OfflinePairPage(mesh: mesh),
      ),
    );
    await tester.pumpAndSettle();
  }

  FilledButton buttonWith(WidgetTester tester, String label) =>
      tester.widget<FilledButton>(
        find.ancestor(
          of: find.text(label),
          matching: find.byType(FilledButton),
        ),
      );

  testWidgets('the submit button turns on when a code is typed', (tester) async {
    await open(tester);

    expect(buttonWith(tester, 'Check answer').onPressed, isNull);

    await tester.enterText(
      find.widgetWithText(TextField, 'Their answer'),
      'NEXUS2.something',
    );
    await tester.pump();

    expect(
      buttonWith(tester, 'Check answer').onPressed,
      isNotNull,
      reason: 'typing a code must enable the button that uses it',
    );
  });

  testWidgets('the guest keeps its answer and six digits on screen', (
    tester,
  ) async {
    final host = device('page-host', 'Other device');
    final session = await host.beginOfflinePairing();

    await open(tester);
    await tester.tap(find.text('Enter their code'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'The code from the other device'),
      session.qr1,
    );
    await tester.pump();
    await tester.tap(find.text('Use this code'));
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.byType(QrImageView).evaluate().isNotEmpty) break;
    }
    await tester.pumpAndSettle();

    expect(
      find.byType(QrImageView),
      findsOneWidget,
      reason: 'the guest must still show its QR2 back to the host',
    );
    final codes = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .where((t) => RegExp(r'^\d{6}$').hasMatch(t))
        .toList();
    expect(codes, hasLength(1), reason: 'the six digits must be visible');
    expect(find.textContaining('They match'), findsOneWidget);

    // Confirming is deliberately not tapped here: it writes the pairing to
    // disk, and a widget test's fake clock never finishes real file I/O. The
    // integration test (`integration_test/offline_pair_ui_e2e_test.dart`) taps
    // it on the real engine and checks the stored record.
  });
}
