import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'design_system.dart';

/// A restrained, system-like Nexus presence indicator.
///
/// This is intentionally not a neon "AI orb". It is a thin, dimensional
/// sphere that communicates state through motion and a small amount of light.
class NexusOrb extends StatefulWidget {
  final bool active;
  final bool listening;
  final double size;

  const NexusOrb({
    super.key,
    this.active = false,
    this.listening = false,
    this.size = 104,
  });

  @override
  State<NexusOrb> createState() => _NexusOrbState();
}

class _NexusOrbState extends State<NexusOrb>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 12),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final scale = widget.listening ? 1.08 : widget.active ? 1.03 : 1.0;
    return AnimatedScale(
      scale: scale,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return CustomPaint(
            size: Size.square(widget.size),
            painter: _NexusOrbPainter(
              phase: _controller.value * math.pi * 2,
              accent: accent,
              active: widget.active,
              listening: widget.listening,
            ),
          );
        },
      ),
    );
  }
}

class _NexusOrbPainter extends CustomPainter {
  final double phase;
  final Color accent;
  final bool active;
  final bool listening;

  const _NexusOrbPainter({
    required this.phase,
    required this.accent,
    required this.active,
    required this.listening,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide * 0.37;
    final breathe = 1 + math.sin(phase * 2) * (listening ? 0.035 : 0.012);
    final r = radius * breathe;

    final glow = Paint()
      ..color = accent.withValues(alpha: listening ? 0.16 : active ? 0.10 : 0.04)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18);
    canvas.drawCircle(center, r * 1.12, glow);

    final shell = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.35
      ..color = accent.withValues(alpha: listening ? 0.92 : active ? 0.62 : 0.38);
    canvas.drawCircle(center, r, shell);

    final grid = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.75
      ..color = accent.withValues(alpha: listening ? 0.62 : 0.28);

    for (var i = -1; i <= 1; i++) {
      final y = i * r * 0.32;
      final width = math.sqrt(math.max(0, r * r - y * y));
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(center.dx, center.dy + y),
          width: width * 2,
          height: math.max(8, r * 0.17),
        ),
        grid,
      );
    }

    final rotation = math.cos(phase) * r;
    for (var i = -1; i <= 1; i++) {
      final x = (i * r * 0.33) + rotation * 0.18;
      final width = math.sqrt(math.max(0, r * r - math.min(r * r, x * x)));
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(center.dx + x * 0.55, center.dy),
          width: math.max(10, r * 0.18),
          height: width * 2,
        ),
        grid,
      );
    }

    final core = Paint()
      ..color = accent.withValues(alpha: listening ? 0.92 : active ? 0.58 : 0.25);
    canvas.drawCircle(center, listening ? 4.4 : 3.2, core);
  }

  @override
  bool shouldRepaint(covariant _NexusOrbPainter oldDelegate) =>
      oldDelegate.phase != phase ||
      oldDelegate.active != active ||
      oldDelegate.listening != listening ||
      oldDelegate.accent != accent;
}
