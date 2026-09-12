// The Nexus core: what it is allowed to show, and what it must never show.
//
// Two claims are pinned here, and both are about honesty rather than looks.
//
//  1. Every state the core can display is a pure function of signals the app
//     already has, so "the core says Nexus is thinking" is provable without a
//     phone, a brain or a network.
//  2. The states this build cannot evidence stay absent. The vocabulary test
//     is the guard: adding a state means adding a signal, and a future
//     decorative state has to argue with a failing test rather than slip in.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/ui/nexus_core.dart';
import 'package:nexus/ui/theme.dart';

/// Every signal false: nothing is happening anywhere.
NexusCoreState _state({
  bool listening = false,
  bool thinking = false,
  bool working = false,
  bool failed = false,
  bool offline = false,
}) => coreStateFor(
  listening: listening,
  thinking: thinking,
  working: working,
  failed: failed,
  offline: offline,
);

Future<void> _pump(WidgetTester tester, NexusCoreState state) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildNexusTheme(),
      home: Scaffold(body: Center(child: NexusCore(state: state))),
    ),
  );
  await tester.pump();
}

/// Pumps long frames until the framework's own entrance animations are done.
///
/// Necessary before counting tickers: a freshly built MaterialApp and Scaffold
/// schedule a couple of their own, and they settle within a few seconds. What
/// is left after settling is the core's own motion, which is the thing under
/// test — measured rather than assumed.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(seconds: 1));
  }
}

void main() {
  group('core state mapping', () {
    test('with nothing happening, the core rests', () {
      expect(_state(), NexusCoreState.idle);
    });

    test('each signal alone says its own thing', () {
      expect(_state(listening: true), NexusCoreState.listening);
      expect(_state(thinking: true), NexusCoreState.thinking);
      expect(_state(working: true), NexusCoreState.working);
      expect(_state(failed: true), NexusCoreState.error);
      expect(_state(offline: true), NexusCoreState.offline);
    });

    test('what Nexus is doing now beats what it could not do, which beats '
        'where it stands', () {
      // Listening is the most immediate thing there is: the user is talking.
      expect(
        _state(
          listening: true,
          thinking: true,
          working: true,
          failed: true,
          offline: true,
        ),
        NexusCoreState.listening,
      );
      // An exchange in flight outranks an action in flight — the action is
      // reported by its own card the moment it lands.
      expect(
        _state(thinking: true, working: true, failed: true, offline: true),
        NexusCoreState.thinking,
      );
      expect(
        _state(working: true, failed: true, offline: true),
        NexusCoreState.working,
      );
      // A failure Nexus just had is more useful than a standing condition.
      expect(
        _state(failed: true, offline: true),
        NexusCoreState.error,
      );
      // And offline still outranks resting.
      expect(_state(offline: true), NexusCoreState.offline);
    });

    test('the vocabulary is only the states a real signal can produce', () {
      // The product brief names eight states. Two of them are deliberately
      // absent here, because nothing in the app can evidence them:
      //
      //  * speaking  — the platform speech call resolves at *queue* time, so
      //                the app never learns that sound is coming out.
      //  * connecting — the mesh reports reachability after the fact, never
      //                a connection in progress.
      //
      // Showing either today would be the fake state this core exists to
      // avoid. When a signal exists, this list grows and this test is where
      // the decision gets recorded.
      expect(
        NexusCoreState.values.map((s) => s.name).toList(),
        ['idle', 'listening', 'thinking', 'working', 'offline', 'error'],
      );
    });

    test('every state can name itself for a screen reader', () {
      for (final state in NexusCoreState.values) {
        expect(state.label, isNotEmpty, reason: state.name);
      }
    });

    test('motion is reserved for states where Nexus is working', () {
      // Motion means work: an idle or reporting core holds still.
      expect(NexusCoreState.idle.isActive, isFalse);
      expect(NexusCoreState.offline.isActive, isFalse);
      expect(NexusCoreState.error.isActive, isFalse);
      expect(NexusCoreState.listening.isActive, isTrue);
      expect(NexusCoreState.thinking.isActive, isTrue);
      expect(NexusCoreState.working.isActive, isTrue);
    });
  });

  group('the core widget', () {
    testWidgets('announces its state, so the core is not just a colour', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, NexusCoreState.thinking);
      expect(find.bySemanticsLabel('Nexus — Thinking'), findsOneWidget);
      await _pump(tester, NexusCoreState.error);
      expect(find.bySemanticsLabel("Nexus — Couldn't do that"), findsOneWidget);
      handle.dispose();
    });

    testWidgets('an idle core does not spin for decoration', (tester) async {
      await _pump(tester, NexusCoreState.idle);
      await _settle(tester);
      expect(
        tester.binding.transientCallbackCount,
        0,
        reason: 'a resting core must not keep a ticker running',
      );
    });

    testWidgets('a working core moves, and stops when it is done', (
      tester,
    ) async {
      await _pump(tester, NexusCoreState.listening);
      await _settle(tester);
      expect(
        tester.binding.transientCallbackCount,
        1,
        reason: 'listening is motion, and nothing else in the tree is moving',
      );

      // The same widget, now resting: the animation has to stop with it.
      await _pump(tester, NexusCoreState.idle);
      await _settle(tester);
      expect(tester.binding.transientCallbackCount, 0);

      // And a state that only reports holds still too.
      await _pump(tester, NexusCoreState.error);
      await _settle(tester);
      expect(tester.binding.transientCallbackCount, 0);
    });

    testWidgets('it stays a status, not a hero', (tester) async {
      await _pump(tester, NexusCoreState.idle);
      final size = tester.getSize(find.byType(NexusCore));
      expect(size.width, lessThanOrEqualTo(40));
      expect(size.height, size.width, reason: 'the core is square');
    });
  });
}
