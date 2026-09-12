// The Nexus core: one small sphere that says what Nexus is actually doing.
//
// It keeps the visual identity of the redesign's orb — a thin, dimensional
// sphere (outer glow, shell ring, latitude and longitude ovals, one bright
// core) rather than a neon "AI orb" — but rebuilt on this branch's theme
// tokens and, more importantly, rebuilt so that every state it can show is
// backed by a signal the app already has.
//
// That last part is the whole point. A core that shimmers while nothing is
// happening is decoration pretending to be information, and a core that says
// "thinking" when nothing is thinking is a lie in the corner of the screen.
// So: motion means work, colour means state, and a state with no honest
// signal is simply absent.
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// What the core is allowed to say about itself.
///
/// Deliberately short. The eight-state vocabulary the product brief names
/// includes two members this build does not show, because nothing in the app
/// can evidence them:
///
///  * **speaking** — the platform speech call resolves when the utterance is
///    *queued*, not when it finishes (see `MainActivity`'s speech_out
///    channel: "the MethodChannel result resolves at queue time"), so the app
///    can know it handed text to the engine but never that sound is coming
///    out. It becomes a real state the day the channel reports utterance
///    start and stop.
///  * **connecting** — the mesh reports reachability after the fact
///    (`isOnline` answers about now), never a connection in progress. There
///    is no signal that means "trying right now", so there is nothing
///    truthful to show.
///
/// Adding either without its signal would be the exact fake state this core
/// exists to avoid.
enum NexusCoreState {
  /// Nothing is happening. Nexus is here and ready.
  idle('Idle'),

  /// The microphone is on and Nexus is waiting for you to speak.
  listening('Listening'),

  /// A question is out with the brain and the answer has not come back.
  thinking('Thinking'),

  /// An action is being carried out — here, or on a paired device.
  working('Working'),

  /// Paired devices exist but none of them can be reached right now.
  offline('Offline'),

  /// The last thing Nexus tried, it could not do on this device.
  error("Couldn't do that");

  const NexusCoreState(this.label);

  /// The words a screen reader announces, and what a tooltip would say.
  final String label;

  /// Whether Nexus is *doing* something, as opposed to resting or reporting.
  /// Only these states animate, because motion in the core has to mean work.
  bool get isActive =>
      this == listening || this == thinking || this == working;
}

/// The one owner of what the core shows.
///
/// Precedence is immediacy: what Nexus is doing this instant beats what it
/// could not do last, which beats where it stands.
///
/// Every argument is a signal the app already has — the microphone, the brain
/// exchange, an action in flight, the last result, the mesh — and nothing here
/// invents one. A caller with no signal for an argument passes `false` and the
/// core says nothing about it.
NexusCoreState coreStateFor({
  required bool listening,
  required bool thinking,
  required bool working,
  required bool failed,
  required bool offline,
}) {
  if (listening) return NexusCoreState.listening;
  if (thinking) return NexusCoreState.thinking;
  if (working) return NexusCoreState.working;
  if (failed) return NexusCoreState.error;
  if (offline) return NexusCoreState.offline;
  return NexusCoreState.idle;
}

/// The Nexus presence indicator. Compact by default: it is a status, not a
/// hero, and it has to sit in a header beside a title without crowding it.
class NexusCore extends StatefulWidget {
  const NexusCore({super.key, required this.state, this.size = 40});

  final NexusCoreState state;

  /// Edge length of the square the sphere is painted into. Small on purpose.
  final double size;

  @override
  State<NexusCore> createState() => _NexusCoreState();
}

class _NexusCoreState extends State<NexusCore>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 12),
  );

  @override
  void initState() {
    super.initState();
    _syncMotion();
  }

  @override
  void didUpdateWidget(covariant NexusCore oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state.isActive != widget.state.isActive) _syncMotion();
  }

  /// Motion means work. A core with nothing happening is a still sphere: it
  /// neither spins for decoration nor keeps a ticker running on a resting tab.
  void _syncMotion() {
    if (widget.state.isActive) {
      _spin.repeat();
    } else {
      _spin.stop();
      _spin.value = 0;
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Colour from the shared theme, so phone and desktop read as one Nexus:
    // the accent for everything Nexus is doing, the error red for a failure,
    // and the muted ink while it has nothing to say.
    final tint = switch (widget.state) {
      NexusCoreState.offline => scheme.onSurfaceVariant,
      NexusCoreState.error => scheme.error,
      _ => scheme.primary,
    };
    return Semantics(
      label: 'Nexus — ${widget.state.label}',
      container: true,
      child: ExcludeSemantics(
        child: AnimatedBuilder(
          animation: _spin,
          builder: (context, _) => CustomPaint(
            size: Size.square(widget.size),
            painter: _NexusCorePainter(
              phase: _spin.value * math.pi * 2,
              state: widget.state,
              tint: tint,
            ),
          ),
        ),
      ),
    );
  }
}

class _NexusCorePainter extends CustomPainter {
  const _NexusCorePainter({
    required this.phase,
    required this.state,
    required this.tint,
  });

  final double phase;
  final NexusCoreState state;
  final Color tint;

  /// How much of each layer a state lights up. One table instead of colour
  /// decisions scattered through the paint code, so a new state is one row.
  ({double glow, double shell, double grid, double core}) get _weight =>
      switch (state) {
        NexusCoreState.idle => (glow: 0.05, shell: 0.32, grid: 0.16, core: 0.28),
        NexusCoreState.listening => (
          glow: 0.18,
          shell: 0.95,
          grid: 0.55,
          core: 0.95,
        ),
        NexusCoreState.thinking => (
          glow: 0.12,
          shell: 0.75,
          grid: 0.50,
          core: 0.60,
        ),
        NexusCoreState.working => (
          glow: 0.16,
          shell: 0.85,
          grid: 0.45,
          core: 0.85,
        ),
        NexusCoreState.offline => (
          glow: 0.04,
          shell: 0.28,
          grid: 0.14,
          core: 0.30,
        ),
        NexusCoreState.error => (
          glow: 0.14,
          shell: 0.70,
          grid: 0.35,
          core: 0.70,
        ),
      };

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide * 0.36;
    final w = _weight;
    // Only listening breathes: someone is talking to it, and the sphere moves
    // the way a person leans in. Every other state holds its size.
    final breathe = state == NexusCoreState.listening
        ? 1 + math.sin(phase * 3) * 0.045
        : 1.0;
    final r = radius * breathe;

    canvas.drawCircle(
      center,
      r * 1.1,
      Paint()
        ..color = tint.withValues(alpha: w.glow)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
    );

    canvas.drawCircle(
      center,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = tint.withValues(alpha: w.shell),
    );

    final grid = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.7
      ..color = tint.withValues(alpha: w.grid);

    // Latitude lines are still; a sphere at rest has no reason to turn.
    for (var i = -1; i <= 1; i++) {
      final y = i * r * 0.32;
      final halfWidth = math.sqrt(math.max(0, r * r - y * y));
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(center.dx, center.dy + y),
          width: halfWidth * 2,
          height: math.max(6, r * 0.17),
        ),
        grid,
      );
    }

    // Longitude lines swing only when Nexus is working — faster while it is
    // thinking, which is the one difference between those two states.
    final swing = state.isActive ? math.cos(phase) * r * 0.18 : 0.0;
    final fast = state == NexusCoreState.thinking ? 1.7 : 1.0;
    for (var i = -1; i <= 1; i++) {
      final x = (i * r * 0.33) + swing * fast;
      final halfHeight =
          math.sqrt(math.max(0, r * r - math.min(r * r, x * x)));
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(center.dx + x * 0.55, center.dy),
          width: math.max(8, r * 0.18),
          height: halfHeight * 2,
        ),
        grid,
      );
    }

    canvas.drawCircle(
      center,
      state == NexusCoreState.listening ? r * 0.16 : r * 0.12,
      Paint()..color = tint.withValues(alpha: w.core),
    );
  }

  @override
  bool shouldRepaint(covariant _NexusCorePainter oldDelegate) =>
      oldDelegate.phase != phase ||
      oldDelegate.state != state ||
      oldDelegate.tint != tint;
}
