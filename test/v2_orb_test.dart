// The Nexus globe: which state it may show, and when it is allowed to move.
//
// Motion in the globe has to mean work, so these tests pin both halves of
// that: an idle globe is completely still (no ticker at all), and each state
// that does move actually runs one — then stops again when the work ends.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/ui/nexus_v2/design_system.dart';
import 'package:nexus/ui/nexus_v2/nexus_orb.dart';

// Built once: handing MaterialApp a new ThemeData every pump would make
// AnimatedTheme animate a theme change, and that ticker would be measured
// instead of the globe's.
final _theme = buildNexusV2Theme();

Widget _host(Widget orb, {bool disableAnimations = false}) => MaterialApp(
      theme: _theme,
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(disableAnimations: disableAnimations),
          child: Scaffold(body: Center(child: orb)),
        ),
      ),
    );

void main() {
  group('the state vocabulary', () {
    test('immediacy wins: what Nexus is doing beats what it could not do', () {
      // Everything on at once is the pathological case; the order must still
      // be the one the doctrine describes.
      expect(
        orbStateFor(
          listening: true,
          thinking: true,
          speaking: true,
          working: true,
          failed: true,
          offline: true,
        ),
        NexusOrbState.listening,
      );
      expect(
        orbStateFor(
          listening: false,
          thinking: true,
          speaking: true,
          working: true,
          failed: true,
          offline: true,
        ),
        NexusOrbState.thinking,
      );
      expect(
        orbStateFor(
          listening: false,
          thinking: false,
          speaking: true,
          working: true,
          failed: true,
          offline: true,
        ),
        NexusOrbState.working,
      );
      expect(
        orbStateFor(
          listening: false,
          thinking: false,
          speaking: true,
          working: false,
          failed: true,
          offline: true,
        ),
        NexusOrbState.speaking,
      );
      expect(
        orbStateFor(
          listening: false,
          thinking: false,
          speaking: false,
          working: false,
          failed: true,
          offline: true,
        ),
        NexusOrbState.error,
      );
      expect(
        orbStateFor(
          listening: false,
          thinking: false,
          speaking: false,
          working: false,
          failed: false,
          offline: true,
        ),
        NexusOrbState.offline,
      );
    });

    test('a device with no signals at all is simply ready', () {
      expect(
        orbStateFor(
          listening: false,
          thinking: false,
          speaking: false,
          working: false,
          failed: false,
          offline: false,
        ),
        NexusOrbState.idle,
      );
    });

    test('only the working states are active', () {
      expect(NexusOrbState.idle.isActive, isFalse);
      expect(NexusOrbState.offline.isActive, isFalse);
      expect(NexusOrbState.error.isActive, isFalse);
      expect(NexusOrbState.listening.isActive, isTrue);
      expect(NexusOrbState.thinking.isActive, isTrue);
      expect(NexusOrbState.working.isActive, isTrue);
      expect(NexusOrbState.speaking.isActive, isTrue);
    });
  });

  group('motion means work', () {
    testWidgets('an idle globe costs nothing', (tester) async {
      await tester.pumpWidget(_host(const NexusOrb(state: NexusOrbState.idle)));
      await tester.pump(const Duration(milliseconds: 100));

      expect(tester.binding.transientCallbackCount, 0);
      expect(find.byType(CustomPaint), findsWidgets);
    });

    testWidgets('offline rests too — being out of reach is not work',
        (tester) async {
      await tester.pumpWidget(
        _host(const NexusOrb(state: NexusOrbState.offline)),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(tester.binding.transientCallbackCount, 0);
    });

    testWidgets('listening, thinking and working each animate', (tester) async {
      for (final state in const [
        NexusOrbState.listening,
        NexusOrbState.thinking,
        NexusOrbState.working,
        NexusOrbState.speaking,
      ]) {
        await tester.pumpWidget(_host(NexusOrb(state: state)));
        await tester.pump(const Duration(milliseconds: 50));

        expect(
          tester.binding.transientCallbackCount,
          greaterThan(0),
          reason: '$state should be moving while it is true',
        );
      }
    });

    testWidgets('leaving a working state stops the clock again', (tester) async {
      await tester.pumpWidget(
        _host(const NexusOrb(state: NexusOrbState.thinking)),
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.binding.transientCallbackCount, greaterThan(0));

      await tester.pumpWidget(_host(const NexusOrb(state: NexusOrbState.idle)));
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.binding.transientCallbackCount, 0);
    });

    testWidgets('a failure destabilises once, then settles by itself',
        (tester) async {
      await tester.pumpWidget(_host(const NexusOrb(state: NexusOrbState.error)));
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.binding.transientCallbackCount, greaterThan(0));

      // One-shot: past its own duration it must not still be running — an
      // error is an event, not a state to live in.
      await tester.pump(const Duration(milliseconds: 1200));
      expect(tester.binding.transientCallbackCount, 0);
      // And the globe is still there: settling is not disappearing.
      expect(find.byType(NexusOrb), findsOneWidget);
    });

    testWidgets('reduced motion keeps the state and drops the movement',
        (tester) async {
      await tester.pumpWidget(
        _host(const NexusOrb(state: NexusOrbState.listening),
            disableAnimations: true),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(tester.binding.transientCallbackCount, 0);
      expect(find.byType(NexusOrb), findsOneWidget);
    });
  });

  group('what it says and how it looks', () {
    testWidgets('the globe announces its state, unless the caller names it',
        (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(const NexusOrb(state: NexusOrbState.listening)),
      );
      expect(find.bySemanticsLabel('Nexus — Listening'), findsOneWidget);

      // The desktop rail's mark names the app, not a state it cannot know.
      await tester.pumpWidget(
        _host(
          const NexusOrb(
            state: NexusOrbState.idle,
            semanticLabel: 'Nexus',
          ),
        ),
      );
      expect(find.bySemanticsLabel('Nexus'), findsOneWidget);
      expect(find.bySemanticsLabel('Nexus — Ready'), findsNothing);
      handle.dispose();
    });

    testWidgets('the default style is the theme accent, and can be replaced',
        (tester) async {
      late NexusOrbStyle defaultStyle;
      late NexusOrbStyle customStyle;
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) {
              defaultStyle = NexusOrbStyle.of(context);
              customStyle = const NexusOrbStyle(
                accent: Color(0xFF112233),
                core: Color(0xFF445566),
              );
              return NexusOrb(
                state: NexusOrbState.idle,
                style: customStyle,
              );
            },
          ),
        ),
      );

      final expectedAccent = _theme.colorScheme.primary;
      expect(defaultStyle.accent, expectedAccent);
      expect(customStyle.accent, const Color(0xFF112233));
      expect(customStyle.gridRings, 1);
      // The painter's own contract: two different styles are different frames.
      expect(
        NexusOrbStyle.lerp(defaultStyle, customStyle, 1).accent,
        customStyle.accent,
      );
    });
  });
}
