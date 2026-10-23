// The Connections screen's two promises, checked where they are enforced rather
// than where they are drawn: a revoked connector refuses the action at the
// executor's door, and the audit records what really ran.
//
// The catalog is walked against the real vocabularies — [kSystemActionNames]
// and [kFastPathActionNames] — so a permission that covers an action nothing
// can produce, or an action no connector owns, fails here instead of on a
// screen that lists a grant nobody can use.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:nexus/core/action_audit.dart';
import 'package:nexus/core/agent_contract.dart' show AgentActions;
import 'package:nexus/core/connections.dart';
import 'package:nexus/core/device_actions.dart';
import 'package:nexus/core/fast_path.dart' show fastPathAction;
import 'package:nexus/core/system_actions.dart';
import 'package:nexus/main_ui.dart';

/// The phone, as these tests see it: what was asked of it, and what it answers.
class _Recorder extends DeviceActionBackend {
  final List<(String, Map<String, dynamic>)> calls =
      <(String, Map<String, dynamic>)>[];

  ActionResult reply = const ActionResult(true, 'Done.');

  @override
  Future<ActionResult> run(String action, Map<String, dynamic> args) async {
    calls.add((action, args));
    return reply;
  }
}

void main() {
  setUpAll(() {
    // The shell's type is Inter, and a test must not fetch it from the network.
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  setUp(() {
    Connections.debugReset();
    ActionAudit.debugReset();
  });

  tearDown(() {
    Connections.override = null;
    Connections.debugReset();
    ActionAudit.debugReset();
  });

  group('the catalog', () {
    test('names every connector once, with a stable id', () {
      final List<String> ids = kConnectors.map((c) => c.id).toList();
      expect(ids.toSet(), hasLength(ids.length), reason: 'ids are unique');
      for (final Connector connector in kConnectors) {
        expect(connector.name.trim(), isNotEmpty);
        expect(connector.summary.trim(), isNotEmpty);
        expect(connector.permissions, isNotEmpty);
        for (final ConnectorPermission permission in connector.permissions) {
          expect(permission.label.trim(), isNotEmpty);
        }
      }
      expect(
        kConnectors.where((c) => c.id == 'music_player'),
        hasLength(1),
      );
      expect(kConnectors.where((c) => c.id == 'phone_system'), hasLength(1));
      expect(kConnectors.where((c) => c.id == 'ai_model'), hasLength(1));
    });

    test('only covers actions the app can actually run', () {
      final Set<String> known = <String>{
        ...kSystemActionNames,
        ...kFastPathActionNames,
      };
      for (final Connector connector in kConnectors) {
        for (final String action in connector.actions) {
          expect(
            known,
            contains(action),
            reason: '${connector.name} grants "$action", which no speaker has',
          );
        }
      }
    });

    test('gives each action exactly one owner', () {
      final Map<String, String> owner = <String, String>{};
      for (final Connector connector in kConnectors) {
        for (final String action in connector.actions) {
          expect(
            owner.containsKey(action),
            isFalse,
            reason:
                '"$action" is granted by ${owner[action]} and ${connector.name}',
          );
          owner[action] = connector.name;
        }
      }
      // The three transports this feature added or that already existed are
      // owned by the player, not by the phone: revoking "Music Player" has to
      // stop the fast path's "skip this song" without stopping the torch.
      for (final String action in <String>[
        'play_music',
        'pause_music',
        'next_song',
        'previous_song',
        'restart_song',
      ]) {
        expect(owner[action], 'Music Player', reason: action);
      }
    });
  });

  group('revoking', () {
    test('is remembered, and answered with the way back', () async {
      final store = MemoryConnectionsStore();
      final connections = Connections(store: store);

      expect(connections.blockedReason('next_song'), isNull);

      await connections.revoke('music_player');
      expect(connections.isRevoked('music_player'), isTrue);
      expect(connections.isEnabled('music_player'), isFalse);
      expect(store.revoked, <String>['music_player']);
      final String? blocked = connections.blockedReason('restart_song');
      expect(blocked, isNotNull);
      expect(blocked, contains('Music Player'));
      expect(blocked, contains('Settings'));
      // One connector, not all of them: the phone's own actions still run.
      expect(connections.blockedReason('set_flashlight'), isNull);

      await connections.restore('music_player');
      expect(connections.blockedReason('restart_song'), isNull);
      expect(store.revoked, isEmpty);
    });

    test('reads a stored revocation once', () async {
      final connections = Connections(
        store: MemoryConnectionsStore(<String>['phone_system']),
      );
      await connections.attach();
      expect(connections.isRevoked('phone_system'), isTrue);
      expect(connections.blockedReason('set_alarm'), contains('Phone System'));
      expect(connections.blockedReason('next_song'), isNull);
    });

    test('leaves an action no connector owns alone', () async {
      final connections = Connections(
        store: MemoryConnectionsStore(<String>['music_player', 'phone_system']),
      );
      await connections.attach();
      expect(connections.blockedReason('get_time'), isNull);
      expect(connections.blockedReason('tell_joke'), isNull);
    });
  });

  group('the executor', () {
    test('refuses a revoked connector before the phone is asked', () async {
      Connections.override =
          () => Connections(revoked: <String>['music_player']);
      final _Recorder phone = _Recorder();
      final actions = DeviceSystemActions(backend: phone);

      final SystemActionOutcome outcome = await actions.execute(
        const SystemActionCall('next_song'),
      );

      expect(outcome.ok, isFalse);
      expect(phone.calls, isEmpty, reason: 'nothing reached the phone');
      expect(outcome.message, contains('Music Player'));
      expect(outcome.message, contains('Settings → Connections'));
    });

    test('runs a granted connector, and restart is a transport mode', () async {
      final _Recorder phone = _Recorder();
      final actions = DeviceSystemActions(backend: phone);

      final SystemActionOutcome outcome = await actions.execute(
        const SystemActionCall('restart_song'),
      );

      expect(outcome.ok, isTrue);
      // The backend takes *agent actions*, not native method names: the phone
      // is asked for `mediaControl` only after this name is translated into it.
      // Sending 'mediaControl' here reached the channel as `unknown` — a green
      // test over a sentence the phone answered "Not available".
      expect(phone.calls.single.$1, AgentActions.mediaNext);
      expect(phone.calls.single.$2, <String, dynamic>{'mode': 'restart'});
    });

    test('records a success, and never a refusal', () async {
      final _Recorder phone = _Recorder();
      final actions = DeviceSystemActions(backend: phone);

      await actions.execute(
        const SystemActionCall('set_flashlight', <String, Object?>{
          'state': 'on',
        }),
      );
      final AuditEntry entry = ActionAudit.instance.recent().single;
      expect(entry.action, 'set_flashlight');
      expect(entry.label, 'Flashlight on');

      Connections.override =
          () => Connections(revoked: <String>['music_player']);
      await DeviceSystemActions(
        backend: phone,
      ).execute(const SystemActionCall('pause_music'));
      expect(
        ActionAudit.instance.recent(),
        hasLength(1),
        reason: 'a refusal did not happen to the phone',
      );
    });
  });

  group('the restart phrases', () {
    test('reach the fast path as one action', () {
      for (final String phrase in <String>[
        'restart this song',
        'restart the song',
        'replay this track',
        'start the song over',
        'start this song again',
        'play this song from the start',
      ]) {
        expect(
          fastPathAction(phrase)?.action,
          'restart_song',
          reason: phrase,
        );
      }
    });

    test('do not turn a sentence about starting into a media key', () {
      for (final String phrase in <String>[
        'start over',
        'start the engine',
        'start a podcast',
      ]) {
        expect(fastPathAction(phrase)?.action, isNot('restart_song'),
            reason: phrase);
      }
      // A model that asks for it by name is still understood.
      expect(
        SystemActionCall.tryParse('{"action":"restart_song"}')?.action,
        'restart_song',
      );
    });
  });

  group('the audit', () {
    test('keeps the newest first, stamped in twelve-hour time', () {
      final audit = ActionAudit();
      audit.record(
        action: 'set_flashlight',
        label: 'Flashlight on.',
        at: DateTime(2026, 10, 22, 10, 42),
      );
      audit.record(
        action: 'set_timer',
        label: 'Timer set for 5 minutes',
        at: DateTime(2026, 10, 22, 0, 5),
      );

      expect(audit.recent().first.label, 'Timer set for 5 minutes');
      expect(audit.recent().first.clock, '12:05 AM');
      expect(audit.recent().last.clock, '10:42 AM');
      // The list item drops the bubble's full stop; the sentence keeps it.
      expect(audit.recent().last.label, 'Flashlight on');
    });

    test('lists ten of fifty, and forgets on clear', () {
      final audit = ActionAudit();
      for (int i = 0; i < 55; i++) {
        audit.record(action: 'set_volume', label: 'Volume $i');
      }
      expect(audit.length, kAuditLimit);
      expect(audit.recent(), hasLength(kAuditRecent));
      expect(audit.recent().first.label, 'Volume 54');
      audit.clear();
      expect(audit.recent(), isEmpty);
    });
  });

  group('the screen', () {
    testWidgets('lists every connector and revokes one', (tester) async {
      // A tall viewport so the whole page is built: a ListView does not build
      // what is below the fold, and a page whose third card is never laid out
      // is not the page a phone shows.
      tester.view.physicalSize = const Size(800, 1500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final connections = Connections(store: MemoryConnectionsStore());
      Connections.override = () => connections;

      await tester.pumpWidget(
        const MaterialApp(home: ConnectionsPage()),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(kNexusConnectionsPage), findsOneWidget);
      expect(find.text('Music Player'), findsOneWidget);
      expect(find.text('Phone System'), findsOneWidget);
      expect(find.text('AI Model'), findsOneWidget);
      expect(find.text('Play and pause media'), findsOneWidget);
      expect(find.text('Set alarms and timers'), findsOneWidget);
      expect(find.text('Read the screen'), findsOneWidget);
      expect(find.text('No actions yet'), findsOneWidget);

      await tester.tap(find.byKey(nexusConnectorToggle('music_player')));
      await tester.pumpAndSettle();

      expect(connections.isRevoked('music_player'), isTrue);
      expect(find.text('Revoked'), findsOneWidget);
      expect(find.text('Restore'), findsOneWidget);
    });

    testWidgets('shows what ran, newest first', (tester) async {
      tester.view.physicalSize = const Size(800, 1500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      Connections.override = () => Connections(store: MemoryConnectionsStore());
      ActionAudit.instance.record(
        action: 'set_flashlight',
        label: 'Flashlight on.',
        at: DateTime(2026, 10, 22, 10, 42),
      );
      ActionAudit.instance.record(
        action: 'next_song',
        label: 'Next track.',
        at: DateTime(2026, 10, 22, 10, 43),
      );

      await tester.pumpWidget(
        const MaterialApp(home: ConnectionsPage()),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(nexusAuditLine(0)), findsOneWidget);
      expect(find.text('10:43 AM'), findsOneWidget);
      expect(find.text('Next track'), findsOneWidget);
      expect(find.text('10:42 AM'), findsOneWidget);
      expect(find.text('Flashlight on'), findsOneWidget);
    });
  });
}
