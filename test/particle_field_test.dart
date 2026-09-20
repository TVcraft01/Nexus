// The Nexus particle field, pinned the same way the Core is: by behaviour, not
// by look.
//
// Four claims, all of them the kind that quietly rot if nobody checks:
//
//  1. The simulation is deterministic and stays in its box. A field that
//     depends on the frame rate, drifts off screen, or grows without bound is
//     a bug that only shows up on someone else's phone.
//  2. Each mood does what it says. Louder voice, greater displacement; thinking
//     collapses; a failure separates and then settles. These are product
//     promises, so they are asserted against the maths.
//  3. Motion costs nothing when there is nothing to show. An idle field, a
//     hidden tab and a reduced-motion device must all stop the clock — the
//     difference between a nice animation and a battery complaint.
//  4. The two real signals drive it: microphone loudness and speech start/stop.
//     No signal, no reaction — and never a fake one.
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/audio_level.dart';
import 'package:nexus/core/speech.dart';
import 'package:nexus/ui/design/particles/particle_field.dart';
import 'package:nexus/ui/design/particles/particle_simulation.dart';
import 'package:nexus/ui/nexus_core.dart';
import 'package:nexus/ui/theme.dart';

const _frame = Duration(milliseconds: 16);

/// Runs the simulation for [seconds] at 60 Hz and returns it.
ParticleSimulation _run(
  ParticleFrame frame, {
  double seconds = 1,
  ParticleSimulation? into,
  double frameSeconds = 1 / 60,
}) {
  final sim = into ?? ParticleSimulation(count: 140);
  final steps = (seconds / frameSeconds).round();
  for (var i = 0; i < steps; i++) {
    sim.step(frameSeconds, frame);
  }
  return sim;
}

Future<void> _pumpField(
  WidgetTester tester, {
  required ParticleMood mood,
  ValueListenable<double>? energy,
  ValueListenable<bool>? speaking,
  bool tickerMode = true,
  bool disableAnimations = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildNexusTheme(),
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: disableAnimations),
        child: TickerMode(
          enabled: tickerMode,
          child: Scaffold(
            body: Center(
              child: ParticleField(
                mood: mood,
                energy: energy,
                speaking: speaking,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// Pumps at 60 Hz until nothing is animating, or [maxSeconds] have passed.
Future<void> _untilStill(WidgetTester tester, {int maxSeconds = 12}) async {
  for (
    var i = 0;
    i < maxSeconds * 60 && tester.binding.transientCallbackCount > 0;
    i++
  ) {
    await tester.pump(_frame);
  }
}

void main() {
  group('the simulation', () {
    test('is deterministic: the same seed paints the same constellation', () {
      final a = ParticleSimulation(count: 90);
      final b = ParticleSimulation(count: 90);
      for (var i = 0; i < a.count; i++) {
        expect(a.particles[i].x, b.particles[i].x);
        expect(a.particles[i].y, b.particles[i].y);
        expect(a.particles[i].z, b.particles[i].z);
        expect(a.particles[i].r0, b.particles[i].r0);
      }
    });

    test('arrives formed and still: a resting field is not an entrance', () {
      final sim = ParticleSimulation(count: 140);
      expect(sim.isSettled, isTrue);
      expect(sim.meanRadius, greaterThan(0.5));
    });

    test('never leaves its box, in any mood, over a long run', () {
      for (final mood in ParticleMood.values) {
        final sim = _run(
          ParticleFrame(mood: mood, energy: 1, pulse: 0.5),
          seconds: 20,
        );
        for (final p in sim.particles) {
          expect(
            p.radius,
            lessThanOrEqualTo(1.45),
            reason: '${mood.name}: a particle escaped the drawn field',
          );
          expect(p.radius, greaterThanOrEqualTo(0.09), reason: mood.name);
          expect(p.x.isFinite && p.y.isFinite && p.z.isFinite, isTrue);
        }
      }
    });

    test('the shape does not depend on the frame rate', () {
      // Same mood, same elapsed time, different frame sizes: a phone at 30 fps
      // and one at 120 fps have to show the same Nexus.
      final slow = _run(
        const ParticleFrame(mood: ParticleMood.listening, energy: 0.6),
        seconds: 2,
        frameSeconds: 1 / 30,
      );
      final fast = _run(
        const ParticleFrame(mood: ParticleMood.listening, energy: 0.6),
        seconds: 2,
        frameSeconds: 1 / 120,
      );
      expect(
        (slow.meanRadius - fast.meanRadius).abs(),
        lessThan(0.02),
        reason: 'frame rate must not change the field',
      );
    });

    test('louder voice, greater displacement — and silence still breathes', () {
      double radiusAt(double energy) => _run(
        ParticleFrame(mood: ParticleMood.listening, energy: energy),
        seconds: 1.5,
      ).meanRadius;

      final quiet = radiusAt(0);
      final normal = radiusAt(0.4);
      final loud = radiusAt(1);
      expect(
        quiet,
        greaterThan(0.55),
        reason: 'an open microphone is itself the signal: the field breathes',
      );
      expect(normal, greaterThan(quiet), reason: 'a normal voice moves it');
      expect(loud, greaterThan(normal), reason: 'louder still moves it more');
      // ...and the displacement is proportional enough to read as a level.
      expect(loud - normal, greaterThan(0.05));
    });

    test('thinking collapses the field and holds an ordered orbit', () {
      final rest = ParticleSimulation(count: 140).meanRadius;
      final thinking = _run(
        const ParticleFrame(mood: ParticleMood.thinking),
        seconds: 1.5,
      );
      expect(thinking.meanRadius, lessThan(rest * 0.85));

      // Ordered, not frozen: every particle keeps moving...
      final before = thinking.particles.map((p) => (p.x, p.y, p.z)).toList();
      _run(
        const ParticleFrame(mood: ParticleMood.thinking),
        seconds: 0.2,
        into: thinking,
      );
      var moved = 0;
      for (var i = 0; i < before.length; i++) {
        final (x, y, z) = before[i];
        final p = thinking.particles[i];
        if ((p.x - x).abs() + (p.y - y).abs() + (p.z - z).abs() > 0.01) {
          moved++;
        }
      }
      expect(moved, greaterThan(thinking.count ~/ 2));
    });

    test('working pulses instead of drifting', () {
      final sim = ParticleSimulation(count: 140);
      final samples = <double>[];
      for (var i = 0; i < 240; i++) {
        sim.step(
          1 / 60,
          const ParticleFrame(mood: ParticleMood.working),
        );
        samples.add(sim.meanRadius);
      }
      final mean = samples.reduce((a, b) => a + b) / samples.length;
      var swing = 0.0;
      for (final sample in samples) {
        swing = math.max(swing, (sample - mean).abs());
      }
      expect(
        swing,
        greaterThan(0.03),
        reason: 'a beat has to be visible, not a shimmer',
      );
    });

    test('speaking sends a ring outward, timed from the utterance', () {
      double radiusAt(double pulse) => _run(
        ParticleFrame(mood: ParticleMood.speaking, pulse: pulse),
        seconds: 0.6,
      ).meanRadius;

      expect(radiusAt(0.5), greaterThan(radiusAt(0) + 0.03));
      // And the ring travels: at the same instant, outer particles lead.
      final sim = _run(
        const ParticleFrame(mood: ParticleMood.speaking, pulse: 0.5),
        seconds: 0.6,
      );
      double shellMean({required bool inner}) {
        final group = sim.particles.where((p) => p.inner == inner).toList();
        return group.map((p) => p.radius).reduce((a, b) => a + b) / group.length;
      }

      expect(shellMean(inner: false), greaterThan(shellMean(inner: true)));
    });

    test('offline holds the same shape, closer in', () {
      final rest = ParticleSimulation(count: 140);
      final offline = _run(
        const ParticleFrame(mood: ParticleMood.offline),
        seconds: 2,
      );
      expect(offline.meanRadius, lessThan(rest.meanRadius));
      expect(offline.meanRadius, greaterThan(0.4), reason: 'still a Nexus');
    });

    test('a failure separates, then settles back on its own', () {
      final sim = ParticleSimulation(count: 140);
      final rest = sim.meanRadius;
      var peak = 0.0;
      for (var i = 0; i < 180; i++) {
        sim.step(1 / 60, const ParticleFrame(mood: ParticleMood.error));
        peak = math.max(peak, sim.meanRadius);
      }
      expect(peak, greaterThan(rest * 1.15), reason: 'it must destabilise');
      expect(
        (sim.meanRadius - rest).abs(),
        lessThan(0.02),
        reason: 'and it must come back to the same constellation',
      );
      expect(sim.isSettled, isTrue, reason: 'a failure is a moment');
    });
  });

  group('mood mapping', () {
    test('every state the core can show has a mood, and it is the right one', () {
      expect(particleMoodFor(NexusCoreState.idle), ParticleMood.rest);
      expect(particleMoodFor(NexusCoreState.listening), ParticleMood.listening);
      expect(particleMoodFor(NexusCoreState.thinking), ParticleMood.thinking);
      expect(particleMoodFor(NexusCoreState.working), ParticleMood.working);
      expect(particleMoodFor(NexusCoreState.offline), ParticleMood.offline);
      expect(particleMoodFor(NexusCoreState.error), ParticleMood.error);
      // Exhaustive by construction: the switch in particleMoodFor has no
      // default, so a new state cannot be added without a mood.
      expect(
        NexusCoreState.values.map(particleMoodFor).toSet().length,
        NexusCoreState.values.length,
        reason: 'two states must not share one mood',
      );
    });

    test('only the states where Nexus works are allowed to keep moving', () {
      expect(ParticleMood.rest.isMoving, isFalse);
      expect(ParticleMood.offline.isMoving, isFalse);
      expect(ParticleMood.error.isMoving, isFalse,
          reason: 'a failure is a moment, not a loop');
      expect(ParticleMood.listening.isMoving, isTrue);
      expect(ParticleMood.thinking.isMoving, isTrue);
      expect(ParticleMood.working.isMoving, isTrue);
      expect(ParticleMood.speaking.isMoving, isTrue);
    });
  });

  group('the field\'s clock', () {
    testWidgets('a hidden tab costs nothing', (tester) async {
      await _pumpField(
        tester,
        mood: ParticleMood.listening,
        tickerMode: false,
      );
      await _untilStill(tester);
      expect(
        tester.binding.transientCallbackCount,
        0,
        reason: 'an off-screen field must not animate',
      );
    });

    testWidgets('"reduce motion" still shows the shape, just never moving', (
      tester,
    ) async {
      await _pumpField(
        tester,
        mood: ParticleMood.listening,
        disableAnimations: true,
      );
      await _untilStill(tester);
      expect(tester.binding.transientCallbackCount, 0);
      expect(find.byType(ParticleField), findsOneWidget);
    });

    testWidgets('a level with no listening behind it is not a signal', (
      tester,
    ) async {
      // The microphone reports loudness whenever it is running, but the field
      // only answers a voice while Nexus is genuinely listening. Waking a
      // resting Core because a stray reading arrived would be reacting to a
      // number instead of to the state it is supposed to describe.
      final energy = ValueNotifier<double>(0);
      addTearDown(energy.dispose);
      await _pumpField(tester, mood: ParticleMood.rest, energy: energy);
      await _untilStill(tester);
      expect(tester.binding.transientCallbackCount, 0);

      energy.value = 0.9;
      await tester.pump(_frame);
      await tester.pump(_frame);
      expect(
        tester.binding.transientCallbackCount,
        0,
        reason: 'a resting field must not twitch at a microphone level',
      );
    });
  });

  group('the real signals', () {
    testWidgets('speech start and stop drive the field, and stopping ends it', (
      tester,
    ) async {
      final speaking = ValueNotifier<bool>(false);
      addTearDown(speaking.dispose);
      await _pumpField(
        tester,
        mood: ParticleMood.rest,
        speaking: speaking,
      );
      await _untilStill(tester);
      expect(tester.binding.transientCallbackCount, 0,
          reason: 'silence is not a speaking state');

      // The engine says audio is coming out: the field must answer.
      speaking.value = true;
      await tester.pump(_frame);
      expect(tester.binding.transientCallbackCount, greaterThan(0));

      // ...and when the utterance is over, it must stop by itself.
      speaking.value = false;
      await _untilStill(tester);
      expect(tester.binding.transientCallbackCount, 0);
    });

    testWidgets('work in flight outranks speech: one field, one truth', (
      tester,
    ) async {
      // While an ask is out with the brain, that is what the Core shows — the
      // field cannot say "speaking" and "thinking" at once without lying about
      // one of them.
      final speaking = ValueNotifier<bool>(true);
      addTearDown(speaking.dispose);
      await _pumpField(
        tester,
        mood: ParticleMood.thinking,
        speaking: speaking,
      );
      await tester.pump(_frame);
      final painter = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byType(ParticleField),
          matching: find.byType(CustomPaint),
        ),
      );
      expect(
        (painter.painter! as ParticlePainter).mood,
        ParticleMood.thinking,
      );
    });

    test('a quiet room reads as quiet, and loud speech as loud', () {
      expect(MicLevel.normalizeLevel(-40), 0);
      expect(MicLevel.normalizeLevel(-2), 0);
      expect(MicLevel.normalizeLevel(100), 1);
      // Monotonic across the range the platform actually reports.
      var previous = -1.0;
      for (var db = -2.0; db <= 12.0; db += 1) {
        final level = MicLevel.normalizeLevel(db);
        expect(level, greaterThanOrEqualTo(previous));
        expect(level, inInclusiveRange(0, 1));
        previous = level;
      }
      // Normal speech has to move the field: a wave that only answers
      // shouting is a wave that looks broken.
      expect(MicLevel.normalizeLevel(2), greaterThan(0.2));
      expect(MicLevel.normalizeLevel(10), greaterThan(0.8));
    });

    test('a widget-test host is not a phone, so no channels are opened', () {
      // Flutter's own default in tests is TargetPlatform.android — and a Linux
      // test host is not an Android device. Believing the framework would make
      // the seams subscribe to platform channels that have no implementation,
      // which surfaces as a services error that fails whichever test happens
      // to be running (this exact failure came out of CI). `Platform.isAndroid`
      // is the part that tells the truth, so both seams must consult it.
      expect(defaultTargetPlatform, TargetPlatform.android);
      expect(Platform.isAndroid, isFalse, reason: 'a host is not a phone');
      expect(SpeechPlayback.current.available, isFalse,
          reason: 'no TTS channel on a host, so nothing may subscribe');
      expect(MicLevel.current.available, isFalse,
          reason: 'no recogniser on a host');
    });

    test('without a level signal, the field is told nothing', () {
      // Desktops have no recogniser, so there is no stream to invent values
      // from: the field keeps its floor and never fakes a reaction.
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        expect(MicLevel.current.available, isFalse);
        expect(MicLevel.current.levels, emitsDone);
        expect(SpeechPlayback.current.available, isFalse);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('a fake mic feeds the field like the real one', (tester) async {
      // The seam the widget tests use: a level source that reports a voice.
      final level = ValueNotifier<double>(0);
      addTearDown(level.dispose);
      MicLevel.override = () => _FakeMic(level.value);
      addTearDown(() => MicLevel.override = null);

      final mic = MicLevel.current;
      expect(mic.available, isTrue);
      expect(await mic.levels.first, level.value);

      await _pumpField(tester, mood: ParticleMood.listening, energy: level);
      await tester.pump(_frame);
      level.value = 0.8;
      await tester.pump(_frame);
      expect(tester.binding.transientCallbackCount, greaterThan(0));
    });
  });
}

/// A microphone that has already heard exactly one thing.
class _FakeMic extends MicLevel {
  _FakeMic(this.level);

  final double level;

  @override
  bool get available => true;

  @override
  Stream<double> get levels => Stream<double>.value(level);
}
