// The two surfaces a peer-initiated action touches: the card that asks the user
// on the Devices tab, and the pre-approval table in Settings.
//
// The card is drawn against a real [IncomingAgentAction], so the wording it
// chooses between is the wording the mesh's own answer produced — not a string
// a test made up.
import 'dart:io' show Directory;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent_contract.dart';
import 'package:nexus/core/identity.dart' show DeviceInfo;
import 'package:nexus/core/paired_devices.dart' as shell
    show PairedDevice, PairedDevices;
import 'package:nexus/core/store.dart';
import 'package:nexus/main_ui.dart'
    show
        DevicesTab,
        NexusTheme,
        SettingsTab,
        kNexusPeerRequestsRow,
        showPeerRequestPolicySheet;
import 'package:nexus/mesh/mesh_service.dart'
    show IncomingAgentAction, MeshService, PairedDevice;

/// A request as it arrives from a peer, with a reply callback that records
/// instead of sending: the card's job is the answer, not the wire.
IncomingAgentAction _incoming({
  required bool trusted,
  AgentPolicy policy = AgentPolicy.ask,
  String action = AgentActions.mediaPlay,
  void Function(AgentDispatchResult result)? onReply,
}) => IncomingAgentAction(
  (String requestId, AgentDispatchResult result) async {
    onReply?.call(result);
    return true;
  },
  from: 'phone-1',
  request: AgentRequest(
    requestId: 'card-1',
    target: 'car-1',
    action: action,
    arguments: const <String, dynamic>{'query': 'hotline bling'},
  ),
  trusted: trusted,
  policy: policy,
);

void main() {
  late Directory tmp;
  late MeshService mesh;
  late NexusStore store;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('nexus-peer-ui-');
    store = NexusStore(explicitPath: '${tmp.path}/store.json')
      ..pairingEnabled = true;
    await store.save();
    store.upsertPaired(
      PairedDevice(
        id: 'phone-1',
        name: 'Kit',
        platform: 'android',
        address: '127.0.0.1',
        port: 51820,
        pairingSecret: 'ABCD-2345',
      ).toJson(),
    );
    await store.save();
    mesh = MeshService(
      identity: DeviceInfo(id: 'car-1', name: 'My Car', platform: 'linux'),
      store: store,
    );
    // The shell's own row for the peer, which is where a name a person reads
    // comes from first: the card has to say the name this device knows the
    // requester by, not the mesh id it arrived under.
    shell.PairedDevices.override = () => shell.PairedDevices(
      seed: <shell.PairedDevice>[
        shell.PairedDevice(id: 'phone-1', name: 'Kit', publicKey: 'k1'),
      ],
    );
    addTearDown(() async {
      shell.PairedDevices.override = null;
      await mesh.stop();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
  });

  Future<void> pumpDevices(
    WidgetTester tester, {
    IncomingAgentAction? request,
    Future<void> Function(bool approve)? onAnswered,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: NexusTheme.light(),
        home: Scaffold(
          body: DevicesTab(
            mesh: mesh,
            peerRequest: request,
            onPeerRequestAnswered: onAnswered,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  group('the waiting request is on the screen, above the devices', () {
    testWidgets('nothing waiting means no card at all', (tester) async {
      await pumpDevices(tester);

      // The ordinary state. A card that appeared empty would be a permanent
      // question mark at the top of the device list.
      expect(find.byKey(const ValueKey<String>('peer-request-card')), findsNothing);
    });

    testWidgets('a verified request names the peer and what it wants', (
      tester,
    ) async {
      await pumpDevices(tester, request: _incoming(trusted: true));

      // The catalogue's word for `media.play`, not the protocol's id: the
      // person reading this is deciding whether to let a device play something.
      expect(find.text('Kit wants to: Music'), findsOneWidget);
      expect(find.text('From a paired, verified device.'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('peer-request-card')),
        findsOneWidget,
      );
    });

    testWidgets('an unverified request says so, in the same card', (
      tester,
    ) async {
      await pumpDevices(tester, request: _incoming(trusted: false));

      expect(
        find.text(
          'Could not be verified — approve this only if you asked for it.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('the two answers are the two taps, and they are reported', (
      tester,
    ) async {
      final List<bool> answers = <bool>[];
      await pumpDevices(
        tester,
        request: _incoming(trusted: true),
        onAnswered: (bool approve) async => answers.add(approve),
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('peer-request-approve')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey<String>('peer-request-deny')));
      await tester.pump();

      expect(answers, <bool>[true, false]);
    });

    testWidgets('a shell with no app above it cannot answer', (tester) async {
      // A widget test, or a shell built without services: the card shows what
      // is waiting and does not pretend it can answer.
      await pumpDevices(tester, request: _incoming(trusted: true));

      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey<String>('peer-request-approve')),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const ValueKey<String>('peer-request-deny')),
            )
            .onPressed,
        isNull,
      );
    });
  });

  group('the pre-approval table lives in Settings', () {
    testWidgets('the Settings row opens the sheet', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: NexusTheme.light(),
          home: Scaffold(
            body: SettingsTab(
              darkMode: false,
              onDarkModeChanged: (bool _) {},
              mesh: mesh,
            ),
          ),
        ),
      );
      await tester.pump();

      final Finder row = find.byKey(kNexusPeerRequestsRow);
      await tester.scrollUntilVisible(
        row,
        160,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(row);
      await tester.pumpAndSettle();

      expect(find.text('Peer requests'), findsWidgets);
      expect(find.text('Ask first'), findsWidgets);
    });

    testWidgets('every action starts on Ask first, and choosing persists', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: NexusTheme.light(),
          home: Builder(
            builder: (BuildContext context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showPeerRequestPolicySheet(
                    context,
                    mesh: mesh,
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

      // A fresh install has nothing pre-approved: the first row it can offer is
      // on the default, and the table itself is empty.
      expect(store.agentPolicyChoices, isEmpty);
      final Finder picker = find.byKey(
        const ValueKey<String>('peer-policy-menu-${AgentActions.mediaPlay}'),
      );
      // The sheet is a list of every action this platform can run, so the one
      // under test is found by scrolling to it rather than by hoping it is on
      // the first screenful.
      await tester.scrollUntilVisible(
        picker,
        120,
        scrollable: find.byType(Scrollable).last,
      );
      expect(picker, findsOneWidget);
      expect(
        tester
            .widget<Text>(
              find.byKey(
                const ValueKey<String>('peer-policy-value-${AgentActions.mediaPlay}'),
              ),
            )
            .data,
        'Ask first',
      );

      await tester.tap(picker);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Auto-approve').last);
      await tester.pumpAndSettle();

      // Written through the store the mesh reads, not into a local copy: the
      // decision at request time has to be the one the user made here.
      expect(store.agentPolicy(AgentActions.mediaPlay), AgentPolicy.auto);
      expect(
        tester
            .widget<Text>(
              find.byKey(
                const ValueKey<String>('peer-policy-value-${AgentActions.mediaPlay}'),
              ),
            )
            .data,
        'Auto-approve',
      );

      // The durable half -- the same choice read back from the file after a
      // restart -- is pinned in peer_actions_test.dart, where a store can be
      // reloaded outside this fake-async zone. What belongs here is that the
      // row writes through the table the mesh reads rather than to a copy of
      // its own, which is the assertion above.
    });

    testWidgets('the sheet explains what auto-approve actually does', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: NexusTheme.light(),
          home: Builder(
            builder: (BuildContext context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () =>
                      showPeerRequestPolicySheet(context, mesh: mesh),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // The promise is narrower than the words, so the sheet has to say so.
      expect(
        find.textContaining('only when the other device is paired'),
        findsOneWidget,
      );
    });
  });
}
