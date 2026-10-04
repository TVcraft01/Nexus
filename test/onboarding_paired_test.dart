// Regression guard for the bug the GUI walkthrough caught: a fresh profile
// that pairs a device *before* finishing first-run setup used to end up with
// the composer hidden (`_onboardingActive` gates it) while the setup view was
// never shown (it was gated on "no paired devices"). The assistant was then
// unusable — no setup to complete, no composer to type into.
//
// The exact walkthrough condition is reproduced here: a paired device is
// present while the profile is still not onboarded. Setup must show, be
// completable, and the composer must return and accept a file-fetch command.
// Lives in its own file because the profile store needs a SharedPreferences
// mock, which must not leak into the other view tests.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent_contract.dart';
import 'package:nexus/core/device_actions.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/query_log.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/mesh/mesh_service.dart';
import 'package:nexus/ui/assistant_view.dart';
import 'package:nexus/ui/device_executor.dart';
import 'package:nexus/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A mesh that reports one paired PC without opening any sockets — enough for
/// the assistant to resolve "my pc". Only the two members the device list is
/// built from are faked.
class _PairedPcMesh extends MeshService {
  _PairedPcMesh({required super.store})
    : super(
        identity: DeviceInfo(
          id: 'this-phone',
          name: 'Test Phone',
          platform: 'android',
        ),
      );

  static final _pc = PairedDevice(
    id: 'pc1',
    name: 'My PC',
    platform: 'linux',
    address: '127.0.0.1',
    port: 1,
    pairingSecret: 'test-secret',
  );

  @override
  List<PairedDevice> get pairedDevices => [_pc];

  @override
  bool isOnline(String id) => id == _pc.id;
}

/// An executor whose file fetch the test finishes by hand — so the in-flight
/// view can be asserted before the transfer lands.
class _GatedFileExecutor extends DeviceExecutor {
  final _outcome = Completer<ActionResult>();
  AgentRequest? lastRequest;

  @override
  Future<ActionResult> run(AgentRequest request) {
    lastRequest = request;
    return _outcome.future;
  }

  void finish(ActionResult result) => _outcome.complete(result);
}

void main() {
  testWidgets(
    'a device paired before setup: the setup view shows and, once done, the '
    'composer returns and runs a file fetch',
    (tester) async {
      // A brand-new profile that has already paired a PC but never finished
      // first-run setup — the state the walkthrough landed in.
      SharedPreferences.setMockInitialValues({});
      final store = NexusStore(
        explicitPath:
            '${Directory.systemTemp.createTempSync('onboard-paired').path}/s.json',
      )..clipboardSync = true;
      final mesh = _PairedPcMesh(store: store);
      final executor = _GatedFileExecutor();

      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildNexusTheme(),
            home: Scaffold(
              body: AssistantView(mesh: mesh, executor: executor),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(); // profile load settles

        // The paired device must not suppress the setup view. Before the fix
        // the empty thread branched straight to the empty chat here, leaving
        // no setup to finish and no composer to type into.
        expect(
          find.text('Set me up — 30 seconds.'),
          findsOneWidget,
          reason: 'setup must be reachable even with a paired device',
        );
        // And the composer is correctly still hidden while setup is open.
        expect(find.byTooltip('Send'), findsNothing);

        // Complete setup — the composer comes back.
        await tester.enterText(
          find.widgetWithText(TextField, 'What should I be called?'),
          'Atlas',
        );
        await tester.tap(find.text('Start'));
        await tester.pump();
        await tester.pump();
        await tester.pump(); // save + greeting settle
        expect(find.byTooltip('Send'), findsOneWidget);

        // The composer now accepts the walkthrough's own command and hands a
        // real file fetch to the executor.
        await tester.enterText(
          find.byType(TextField),
          'get report.pdf from my pc',
        );
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();

        expect(
          find.textContaining('Getting report.pdf from My PC'),
          findsOneWidget,
        );
        expect(find.text('Working'), findsOneWidget);
        expect(executor.lastRequest!.action, AgentActions.fileFetch);
        expect(executor.lastRequest!.arguments['peerId'], 'pc1');
        expect(executor.lastRequest!.arguments['filename'], 'report.pdf');

        executor.finish(
          const ActionResult(
            true,
            'Saved report.pdf from My PC to /tmp/report.pdf.',
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(find.text('Done'), findsOneWidget);
        expect(
          find.textContaining('Saved report.pdf from My PC to /tmp/report.pdf'),
          findsOneWidget,
        );
      } finally {
        QueryLog.i.resetForTest();
        await mesh.stop();
      }
    },
  );
}
