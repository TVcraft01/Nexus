// The Nexus particle field: how the Core looks, and when its clock runs.
//
// This file owns two things and nothing else:
//
//   1. Rendering. One `CustomPaint`, one painter, and dots drawn as batched
//      `drawPoints` calls bucketed by size and brightness — a phone is the
//      target, so the whole field is single-digit draw calls per frame.
//   2. The clock. The field ticks while Nexus is doing something and stops
//      dead when it is not: a still constellation costs nothing, and motion
//      in this app has to mean work.
//
// It does not decide the physics (that is [ParticleSimulation]) and it does
// not decide what Nexus is doing (that is the caller). It is handed a mood and
// two optional real signals — microphone loudness and whether speech is
// actually coming out — and it draws accordingly.
import 'dart:ui' show PointMode;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../tokens.dart';
import 'particle_simulation.dart';

/// The Core's material: a field of fine dots that answers to real state.
///
/// [energy] and [speaking] are [ValueListenable]s rather than values so a
/// voice that arrives twenty times a second repaints the dots without
/// rebuilding a single widget above them.
class ParticleField extends StatefulWidget {
  const ParticleField({
    super.key,
    required this.mood,
    this.energy,
    this.speaking,
    this.size = 44,
    this.semanticLabel,
  });

  /// What Nexus is honestly doing.
  final ParticleMood mood;

  /// Microphone loudness, 0 to 1, while listening. Null on a platform with no
  /// level signal — the field then breathes at its floor instead of faking a
  /// reaction to a voice it cannot hear.
  final ValueListenable<double>? energy;

  /// Whether sound is actually coming out of Nexus right now. Null (or false)
  /// means no speaking state is shown, which is the honest answer on a
  /// platform that cannot report it.
  final ValueListenable<bool>? speaking;

  /// Edge length of the square the field is painted into.
  final double size;

  /// What a screen reader announces, when the field is the whole message.
  final String? semanticLabel;

  @override
  State<ParticleField> createState() => _ParticleFieldState();
}

class _ParticleFieldState extends State<ParticleField>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final ParticleSimulation _sim =
      ParticleSimulation(count: NexusParticle.count);

  /// Repaints the painter without rebuilding anything. The widget tree above
  /// the field is untouched for the whole life of the animation.
  final _Repaint _repaint = _Repaint();

  late final Ticker _ticker = createTicker(_onTick);

  Duration _lastTick = Duration.zero;

  /// Wall-clock time of the last frame and of the last mood change. The grace
  /// window below is measured in real time, not simulated time: a phone that
  /// stalls must not be handed twenty more seconds of animation before the
  /// field is allowed to rest.
  Duration _now = Duration.zero;
  Duration _moodChangedAt = Duration.zero;

  /// When the current speech pulse started, on the simulation's clock — taken
  /// from the real utterance, so the rings are in time with the voice.
  double _speechStartedAt = -1;

  bool _appActive = true;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.energy?.addListener(_onSignal);
    widget.speaking?.addListener(_onSignal);
    _sync();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Respect the platform's "reduce motion": the field still shows the right
    // shape, it simply never moves on its own.
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduced != _reduceMotion) {
      _reduceMotion = reduced;
      _sync();
    }
  }

  @override
  void didUpdateWidget(covariant ParticleField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.energy != widget.energy) {
      oldWidget.energy?.removeListener(_onSignal);
      widget.energy?.addListener(_onSignal);
    }
    if (oldWidget.speaking != widget.speaking) {
      oldWidget.speaking?.removeListener(_onSignal);
      widget.speaking?.addListener(_onSignal);
    }
    if (oldWidget.mood != widget.mood) _moodChangedAt = _now;
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appActive = state == AppLifecycleState.resumed;
    _sync();
  }

  @override
  void dispose() {
    widget.energy?.removeListener(_onSignal);
    widget.speaking?.removeListener(_onSignal);
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _repaint.dispose();
    super.dispose();
  }

  bool get _speakingNow => widget.speaking?.value ?? false;

  /// Speaking is a real signal about right now, so it outranks a resting or
  /// offline report — but never outranks work that is actually in flight.
  ParticleMood get _mood {
    final base = widget.mood;
    if (!_speakingNow) return base;
    if (base == ParticleMood.rest || base == ParticleMood.offline) {
      return ParticleMood.speaking;
    }
    return base;
  }

  double get _pulse {
    if (!_speakingNow || _speechStartedAt < 0) return 0;
    return ((_sim.elapsed - _speechStartedAt) / 0.42) % 1.0;
  }

  ParticleFrame get _frame => ParticleFrame(
        mood: _mood,
        energy: (widget.energy?.value ?? 0).clamp(0.0, 1.0),
        pulse: _pulse,
      );

  /// The field keeps moving for a moment after a mood change, so the move into
  /// the new shape is a transition and not a jump — a failure has to be seen to
  /// destabilise, and a field going offline has to be seen to close in. Without
  /// this, a field that was perfectly still would stop its own clock on the
  /// first frame of the change, because nothing is moving yet.
  bool get _inGrace =>
      _now - _moodChangedAt < const Duration(milliseconds: 1400);

  bool get _needsClock =>
      _appActive &&
      !_reduceMotion &&
      (_mood.isMoving || _speakingNow || !_sim.isSettled || _inGrace);

  void _onSignal() {
    if (_speakingNow && _speechStartedAt < 0) _speechStartedAt = _sim.elapsed;
    if (!_speakingNow) _speechStartedAt = -1;
    _repaint.tick();
    _sync();
  }

  void _sync() {
    if (_reduceMotion) {
      // Nothing moves, but the field must still be the right shape.
      _sim.settle(_frame);
      _repaint.tick();
      if (_ticker.isActive) _ticker.stop();
      return;
    }
    if (_needsClock && !_ticker.isActive) {
      _lastTick = Duration.zero;
      _ticker.start();
    } else if (!_needsClock && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _onTick(Duration elapsed) {
    // The first frame of a run has no previous timestamp: assume 60 Hz.
    final dt = _lastTick == Duration.zero
        ? 1 / 60
        : (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    _now = elapsed;
    _sim.step(dt, _frame);
    _repaint.tick();
    // Stop the moment there is nothing left to show. A ticker that keeps
    // running on a still constellation is a battery bug that never looks like
    // one in a screenshot.
    if (!_needsClock && _ticker.isActive) _ticker.stop();
  }

  @override
  Widget build(BuildContext context) {
    final palette = NexusPalette.of(context);
    return Semantics(
      label: widget.semanticLabel,
      container: widget.semanticLabel != null,
      child: RepaintBoundary(
        child: SizedBox.square(
          dimension: widget.size,
          child: CustomPaint(
            painter: ParticlePainter(
              simulation: _sim,
              mood: _mood,
              palette: palette,
              repaint: _repaint,
            ),
            isComplex: true,
            willChange: true,
          ),
        ),
      ),
    );
  }
}

/// Repaint-only notifier: the painter listens to this, so a frame of the field
/// never rebuilds a widget.
class _Repaint extends ChangeNotifier {
  void tick() => notifyListeners();
}

/// Draws one frame of the field.
///
/// Depth is the whole point: each dot is projected with a perspective divide,
/// so the far side of the shell is smaller and dimmer than the near side and
/// the constellation reads as a sphere rather than a flat disc. Dots are
/// batched by size and brightness into a handful of `drawPoints` calls — one
/// call per bucket instead of one per particle.
class ParticlePainter extends CustomPainter {
  ParticlePainter({
    required this.simulation,
    required this.mood,
    required this.palette,
    required Listenable repaint,
  }) : super(repaint: repaint);

  /// Positions come from the simulation (already stepped this frame) and the
  /// mood from the widget: the painter draws, it does not read signals. The
  /// loudness and speech listenables are the state's business, so a change of
  /// signal cannot mean two different things in two files.
  final ParticleSimulation simulation;
  final ParticleMood mood;
  final NexusPalette palette;

  /// How lit the field is, per mood. Restrained on purpose: this sits in a
  /// header beside a title, and a Core that shouts drowns the screen.
  double get _litness => switch (mood) {
        ParticleMood.rest => 0.52,
        ParticleMood.offline => 0.30,
        ParticleMood.listening => 0.96,
        ParticleMood.thinking => 0.82,
        ParticleMood.working => 0.90,
        ParticleMood.speaking => 0.94,
        ParticleMood.error => 0.86,
      };

  Color get _tint => switch (mood) {
        ParticleMood.offline => palette.textSecondary,
        ParticleMood.error => palette.danger,
        ParticleMood.thinking => palette.accentStrong,
        _ => palette.accent,
      };

  @override
  void paint(Canvas canvas, Size size) {
    if (size.shortestSide <= 0) return;
    final center = size.center(Offset.zero);
    final reach = size.shortestSide * 0.46;
    final tint = _tint;
    final lit = _litness;

    _paintHalo(canvas, center, reach, tint, lit);
    _paintShell(canvas, center, reach, tint, lit);
    _paintParticles(canvas, center, reach, tint, lit);
    _paintCore(canvas, center, reach, tint, lit);
  }

  /// A single soft gradient behind the field — the only glow in the app, and
  /// it is a gradient rather than a blur filter because a blur per frame on a
  /// phone is exactly the kind of cost this component must never pay.
  void _paintHalo(
    Canvas canvas,
    Offset center,
    double reach,
    Color tint,
    double lit,
  ) {
    final alpha = (mood == ParticleMood.rest || mood == ParticleMood.offline)
        ? NexusParticle.restGlow * lit
        : NexusParticle.activeGlow * lit;
    if (alpha <= 0.01) return;
    final rect = Rect.fromCircle(center: center, radius: reach * 1.05);
    canvas.drawCircle(
      center,
      reach * 1.05,
      Paint()
        ..shader = RadialGradient(
          colors: [tint.withValues(alpha: alpha), tint.withValues(alpha: 0)],
          stops: const [0.25, 1],
        ).createShader(rect),
    );
  }

  /// The thin ring that keeps the field reading as one sphere — the Core's old
  /// identity, now the orbit the dots live on.
  void _paintShell(
    Canvas canvas,
    Offset center,
    double reach,
    Color tint,
    double lit,
  ) {
    canvas.drawCircle(
      center,
      reach * 0.86,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8
        ..color = tint.withValues(alpha: 0.10 * lit),
    );
  }

  void _paintParticles(
    Canvas canvas,
    Offset center,
    double reach,
    Color tint,
    double lit,
  ) {
    // Nine buckets at most: three sizes by three brightnesses. Each bucket is
    // one drawPoints call.
    final batches = <int, List<Offset>>{};
    for (final p in simulation.particles) {
      // Perspective divide. z runs to 1.45 at the clamp, so the near side of
      // the shell is roughly 2x the far side.
      final persp = 1.55 / (1.55 - p.z * 0.42);
      final near = ((p.z + 1.0) / 2).clamp(0.0, 1.0);
      final point = Offset(
        center.dx + p.x * reach * persp,
        center.dy + p.y * reach * persp,
      );
      final sizeBucket = (near * 2.999).floor();
      final alpha = (0.22 + 0.78 * near) * lit;
      final alphaBucket = (alpha * 2.999).floor().clamp(0, 2);
      (batches[sizeBucket * 3 + alphaBucket] ??= []).add(point);
    }
    batches.forEach((key, points) {
      final sizeBucket = key ~/ 3;
      final alphaBucket = key % 3;
      final width = NexusParticle.dot * (0.7 + 0.35 * sizeBucket);
      final alpha = lit * (0.22 + 0.38 * alphaBucket);
      canvas.drawPoints(
        PointMode.points,
        points,
        Paint()
          ..strokeWidth = width
          ..strokeCap = StrokeCap.round
          ..color = tint.withValues(alpha: alpha.clamp(0.0, 1.0)),
      );
    });
  }

  /// The one bright dot at the middle: what makes the field a Core and not a
  /// cloud. It answers the same way the old sphere did — brighter, and a touch
  /// bigger, when Nexus is doing something.
  void _paintCore(
    Canvas canvas,
    Offset center,
    double reach,
    Color tint,
    double lit,
  ) {
    final r = reach * (mood == ParticleMood.listening ? 0.10 : 0.075) * (0.8 + 0.4 * lit);
    canvas.drawCircle(center, r * 2.4, Paint()..color = tint.withValues(alpha: 0.12 * lit));
    canvas.drawCircle(center, r, Paint()..color = tint.withValues(alpha: (0.55 + 0.45 * lit).clamp(0.0, 1.0)));
  }

  @override
  bool shouldRepaint(covariant ParticlePainter oldDelegate) =>
      oldDelegate.mood != mood ||
      oldDelegate.palette != palette ||
      oldDelegate.simulation != simulation;
}
