import 'dart:math' as math;

import 'package:flutter/material.dart';

/// What the globe is allowed to say about Nexus.
///
/// Every member has a real signal behind it in [orbStateFor]; none of them is
/// inferred from a timer or a mood. The vocabulary is deliberately short:
/// a state the app cannot evidence is not in the enum, because the globe
/// showing one would be decoration claiming to be information.
enum NexusOrbState {
  /// Nothing is happening. Nexus is here and ready.
  idle('Ready'),

  /// The microphone is open and Nexus is waiting for you to speak.
  listening('Listening'),

  /// A question is out with the brain and the answer has not come back.
  thinking('Thinking'),

  /// Nexus is actually speaking right now — the speech engine reports when an
  /// utterance starts and stops. A platform that cannot report it never
  /// reaches this state.
  speaking('Speaking'),

  /// An action is being carried out — here, or on a paired device.
  working('Working'),

  /// Paired devices exist but none of them can be reached right now.
  offline('Offline'),

  /// The last thing Nexus tried, it could not do.
  error('That did not work');

  const NexusOrbState(this.label);

  /// The words a screen reader announces, and what the tooltip says.
  final String label;

  /// Whether Nexus is *doing* something, as opposed to resting or reporting.
  /// Only these states move, because motion in the globe has to mean work.
  bool get isActive =>
      this == listening || this == thinking || this == working || this == speaking;
}

/// The one owner of what the globe shows.
///
/// Precedence is immediacy: what Nexus is doing this instant beats what it
/// could not do last, which beats where it stands. Speaking sits below the
/// states that describe work in flight, because a voice reading the previous
/// reply while a new ask is already thinking is still, above all, thinking.
NexusOrbState orbStateFor({
  required bool listening,
  required bool thinking,
  required bool speaking,
  required bool working,
  required bool failed,
  required bool offline,
}) {
  if (listening) return NexusOrbState.listening;
  if (thinking) return NexusOrbState.thinking;
  if (working) return NexusOrbState.working;
  if (speaking) return NexusOrbState.speaking;
  if (failed) return NexusOrbState.error;
  if (offline) return NexusOrbState.offline;
  return NexusOrbState.idle;
}

/// Everything about how the globe looks, in one place.
///
/// The appearance is a value, not a pile of literals inside the painter, so it
/// can be changed — or one day chosen by the person using Nexus — without
/// touching the drawing code. [NexusOrbStyle.of] is the default: Nexus' own
/// accent on the current theme, which is what every screen gets today.
class NexusOrbStyle {
  const NexusOrbStyle({
    required this.accent,
    required this.core,
    this.shellStroke = 1.35,
    this.gridStroke = 0.75,
    this.glowBlur = 18,
    this.gridRings = 1,
  });

  /// The sphere's shell, its latitude/longitude grid, and the source of its
  /// glow. States vary the alpha, never the hue, so colour always means
  /// "Nexus", not "some mood".
  final Color accent;

  /// The bright centre — the one point that reads as "awake".
  final Color core;

  final double shellStroke;
  final double gridStroke;
  final double glowBlur;

  /// Latitude rings drawn each way from the equator (1 draws three).
  final int gridRings;

  static NexusOrbStyle of(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return NexusOrbStyle(accent: scheme.primary, core: scheme.primary);
  }

  static NexusOrbStyle lerp(NexusOrbStyle a, NexusOrbStyle b, double t) =>
      NexusOrbStyle(
        accent: Color.lerp(a.accent, b.accent, t)!,
        core: Color.lerp(a.core, b.core, t)!,
        shellStroke: a.shellStroke + (b.shellStroke - a.shellStroke) * t,
        gridStroke: a.gridStroke + (b.gridStroke - a.gridStroke) * t,
        glowBlur: a.glowBlur + (b.glowBlur - a.glowBlur) * t,
        gridRings: t < 0.5 ? a.gridRings : b.gridRings,
      );
}

/// The Nexus globe: a thin, dimensional sphere whose motion means work.
///
/// It is deliberately not a neon "AI orb". At rest it is completely still —
/// a globe that shimmers while nothing is happening is decoration pretending
/// to be information, and it costs a phone battery to say nothing. While
/// Nexus listens, thinks, works or speaks, the sphere answers with one
/// restrained motion per state, and when the work ends it stops again.
///
/// The same widget is the presence marker on the assistant screen and in the
/// desktop rail's leading slot, so phone and desktop cannot drift apart.
class NexusOrb extends StatefulWidget {
  const NexusOrb({
    super.key,
    required this.state,
    this.size = 64,
    this.style,
    this.semanticLabel,
  });

  final NexusOrbState state;

  /// Edge length of the square the globe is painted into.
  final double size;

  /// Overrides the default appearance. Null means [NexusOrbStyle.of].
  final NexusOrbStyle? style;

  /// Overrides the announced text. The assistant passes null and the state's
  /// own label is announced, so the words and the drawing cannot disagree.
  final String? semanticLabel;

  @override
  State<NexusOrb> createState() => _NexusOrbState();
}

class _NexusOrbState extends State<NexusOrb> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _durationFor(widget.state),
  );

  /// One full cycle of the state's motion. Slower states read as thought,
  /// faster ones as work; none of them is fast enough to look like a toy.
  static Duration _durationFor(NexusOrbState state) => switch (state) {
        NexusOrbState.listening => const Duration(milliseconds: 2600),
        NexusOrbState.thinking => const Duration(milliseconds: 6000),
        NexusOrbState.working => const Duration(milliseconds: 1400),
        NexusOrbState.speaking => const Duration(milliseconds: 900),
        _ => const Duration(milliseconds: 900),
      };

  /// Whether the platform wants motion at all this frame. Read from the
  /// frame's own accessibility settings; nothing here guesses.
  bool _motionAllowed = true;
  bool _dependenciesReady = false;

  /// A failure's one-shot destabilisation has already played for the current
  /// error state — so returning to it from something else plays it again,
  /// while a rebuild of the same error does not.
  bool _errorPlayed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final allowed = !MediaQuery.disableAnimationsOf(context);
    // The first pass always applies motion (an initial state must still
    // start its control); later passes only when the setting really moved.
    if (_dependenciesReady && allowed == _motionAllowed) return;
    _dependenciesReady = true;
    _motionAllowed = allowed;
    _applyMotion();
  }

  @override
  void didUpdateWidget(NexusOrb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state == widget.state) return;
    if (widget.state != NexusOrbState.error) _errorPlayed = false;
    _applyMotion();
  }

  /// Runs (or stops) the control for the state the caller asked for. Called
  /// outside build, from the two places a state change can arrive.
  void _applyMotion() {
    final state = widget.state;
    if (!_motionAllowed) {
      if (_controller.isAnimating) _controller.stop();
      _controller.value = 0;
      return;
    }
    if (state == NexusOrbState.error) {
      // A failure destabilises once, then settles — the exception, not a
      // state to live in. Forward only: it must never loop.
      if (_errorPlayed) return;
      _errorPlayed = true;
      _controller.forward(from: 0);
      return;
    }
    if (!state.isActive) {
      if (_controller.isAnimating) _controller.stop();
      _controller.value = 0;
      return;
    }
    _controller.duration = _durationFor(state);
    if (!_controller.isAnimating) _controller.repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.style ?? NexusOrbStyle.of(context);
    final allowMotion = !MediaQuery.disableAnimationsOf(context);
    return Tooltip(
      // A caller that overrides the announced text is naming the globe rather
      // than reporting its state (the desktop rail's mark), and the tooltip
      // says the same thing the screen reader does.
      message: widget.semanticLabel ?? widget.state.label,
      excludeFromSemantics: true,
      child: Semantics(
        label: widget.semanticLabel ?? 'Nexus — ${widget.state.label}',
        // The globe is a status, not a control: it must never look tappable.
        readOnly: true,
        child: RepaintBoundary(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) => CustomPaint(
              size: Size.square(widget.size),
              painter: _NexusOrbPainter(
                phase: _controller.value,
                state: widget.state,
                style: style,
                still: !allowMotion,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One painted frame. Split from the widget so the same drawing code serves
/// every state and every surface that shows a globe.
class _NexusOrbPainter extends CustomPainter {
  const _NexusOrbPainter({
    required this.phase,
    required this.state,
    required this.style,
    required this.still,
  });

  final double phase;
  final NexusOrbState state;
  final NexusOrbStyle style;

  /// Reduced motion: the state's shape without its movement.
  final bool still;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final base = size.shortestSide * 0.37;
    // Reduced motion holds every state at one composed frame instead of the
    // frame the clock happens to be on; the state stays legible, the globe
    // simply does not move.
    final t = still ? math.pi * 0.25 : phase * math.pi * 2;
    final motion = still ? 0.0 : phase;

    // What each state does to the sphere, in one row each: breathing height,
    // shell brightness, grid brightness, core brightness and radius.
    final (
      double breathe,
      double shellAlpha,
      double gridAlpha,
      double coreAlpha,
      double coreRadius,
    ) = switch (state) {
      NexusOrbState.idle => (1.0, 0.38, 0.26, 0.30, 3.2),
      NexusOrbState.listening => (
          1 + math.sin(t * 2) * 0.035,
          0.92,
          0.55,
          0.92,
          4.4,
        ),
      NexusOrbState.thinking => (
          1 + math.sin(t) * 0.015,
          0.66,
          0.42,
          0.66,
          3.8,
        ),
      NexusOrbState.speaking => (
          1 + math.sin(t * 3) * 0.012,
          0.82,
          0.40,
          0.82,
          4.0,
        ),
      NexusOrbState.working => (
          1 + math.sin(t * 2) * 0.02,
          0.86,
          0.48,
          0.90,
          4.2,
        ),
      NexusOrbState.offline => (1.0, 0.22, 0.14, 0.18, 2.6),
      NexusOrbState.error => (
          1 - (1 - motion) * 0.02,
          0.70 - (1 - motion) * 0.2,
          0.34,
          0.60,
          3.4,
        ),
    };

    // A failure's one-shot destabilisation: a small positional wobble that
    // decays to nothing as the animation completes, so the globe visibly
    // takes the hit and then settles back into a still, calm sphere.
    final upset = state == NexusOrbState.error && !still
        ? (1 - phase) * base * 0.06
        : 0.0;
    final wobble = Offset(
      math.sin(t * 11) * upset,
      math.cos(t * 9) * upset * 0.6,
    );

    // Offline and error hold the constellation closer: the same globe, drawn
    // in — a state you can read from across the room without reading a word.
    final tighten = switch (state) {
      NexusOrbState.offline => 0.72,
      NexusOrbState.error => 0.92,
      _ => 1.0,
    };
    final r = base * breathe * tighten;
    final c = center + wobble;

    final glowAlpha = switch (state) {
      NexusOrbState.listening => 0.16,
      NexusOrbState.thinking || NexusOrbState.working || NexusOrbState.speaking => 0.12,
      NexusOrbState.error => 0.10 * (1 - motion) + 0.04,
      NexusOrbState.offline => 0.02,
      NexusOrbState.idle => 0.04,
    };
    canvas.drawCircle(
      c,
      r * 1.12,
      Paint()
        ..color = style.accent.withValues(alpha: glowAlpha)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, style.glowBlur),
    );

    final shell = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = style.shellStroke
      ..color = style.accent.withValues(alpha: shellAlpha);
    canvas.drawCircle(c, r, shell);

    final grid = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = style.gridStroke
      ..color = style.accent.withValues(alpha: gridAlpha);

    // Latitude rings. While listening they ride a wave: the ring nearest the
    // voice's centre of mass rises and falls, which is displacement rather
    // than an equaliser bar.
    for (var i = -style.gridRings; i <= style.gridRings; i++) {
      final wave = state == NexusOrbState.listening
          ? math.sin(t * 2 + i * 0.9) * r * 0.05
          : 0.0;
      final y = i * r * 0.32 + wave;
      if (y.abs() >= r) continue;
      final width = math.sqrt(math.max(0, r * r - y * y));
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(c.dx, c.dy + y),
          width: width * 2,
          height: math.max(8, r * 0.17),
        ),
        grid,
      );
    }

    // Longitude rings. Thinking rotates them slowly; idle holds them at a
    // fixed angle so a still globe looks composed rather than arbitrary.
    final rotation = switch (state) {
      NexusOrbState.thinking => math.cos(t) * r,
      NexusOrbState.working => math.cos(t * 2) * r,
      _ => r * 0.12,
    };
    for (var i = -style.gridRings; i <= style.gridRings; i++) {
      final x = (i * r * 0.33) + rotation * 0.18;
      if (x.abs() >= r) continue;
      final height = math.sqrt(math.max(0, r * r - x * x));
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(c.dx + x * 0.55, c.dy),
          width: math.max(10, r * 0.18),
          height: height * 2,
        ),
        grid,
      );
    }

    final corePaint = Paint()..color = style.core.withValues(alpha: coreAlpha);

    if (state == NexusOrbState.working && !still) {
      // Work is deliberate beats, not a shimmer: three points on the equator
      // brighten in sequence, one per pulse.
      for (var i = 0; i < 3; i++) {
        final beat = math.max(0.0, math.sin(t - i * 2.1));
        if (beat <= 0.02) continue;
        final angle = t * 0.6 + i * (math.pi * 2 / 3);
        canvas.drawCircle(
          Offset(c.dx + math.cos(angle) * r * 0.62, c.dy + math.sin(angle) * r * 0.26),
          coreRadius * 0.55 * beat,
          Paint()..color = style.core.withValues(alpha: 0.5 * beat * coreAlpha),
        );
      }
    }

    if (state == NexusOrbState.speaking && !still) {
      // Speech propagates outward: rings leave the globe and fade, one per
      // utterance beat. Only ever drawn while a voice is really playing.
      for (final offset in const [0.0, 0.5]) {
        final k = (phase + offset) % 1.0;
        canvas.drawCircle(
          c,
          r * (0.85 + k * 0.75),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = style.gridStroke
            ..color = style.accent.withValues(alpha: 0.22 * (1 - k)),
        );
      }
    }

    canvas.drawCircle(c, still ? coreRadius * 0.9 : coreRadius, corePaint);
  }

  @override
  bool shouldRepaint(covariant _NexusOrbPainter oldDelegate) =>
      oldDelegate.phase != phase ||
      oldDelegate.state != state ||
      oldDelegate.still != still ||
      oldDelegate.style.accent != style.accent ||
      oldDelegate.style.core != style.core ||
      oldDelegate.style.shellStroke != style.shellStroke ||
      oldDelegate.style.gridStroke != style.gridStroke ||
      oldDelegate.style.glowBlur != style.glowBlur ||
      oldDelegate.style.gridRings != style.gridRings;
}
