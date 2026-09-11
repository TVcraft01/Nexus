import 'package:flutter/material.dart';

import '../../core/version.dart';
import '../../mesh/mesh_service.dart';
import 'design_system.dart';
import 'diagnostics_view.dart';

class NexusV2AboutView extends StatefulWidget {
  final MeshService mesh;
  const NexusV2AboutView({super.key, required this.mesh});

  @override
  State<NexusV2AboutView> createState() => _NexusV2AboutViewState();
}

class _NexusV2AboutViewState extends State<NexusV2AboutView> {
  int _versionTaps = 0;
  DateTime? _lastTap;

  void _versionTapped() {
    final now = DateTime.now();
    if (_lastTap == null || now.difference(_lastTap!) > const Duration(seconds: 2)) {
      _versionTaps = 0;
    }
    _lastTap = now;
    _versionTaps++;
    if (_versionTaps >= 7) {
      _versionTaps = 0;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => NexusV2DiagnosticsView(mesh: widget.mesh),
        ),
      );
    } else {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('About Nexus')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          Center(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0, 24, 0, 16),
              child: Column(
                children: [
                  const NexusOrbProxy(size: 82),
                  const SizedBox(height: 14),
                  Text('Nexus', style: theme.textTheme.headlineMedium),
                  const SizedBox(height: 4),
                  Text(
                    'One assistant across your devices.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          GestureDetector(
            onTap: _versionTapped,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Version', style: theme.textTheme.labelLarge),
                    const SizedBox(height: 5),
                    Text(appVersion, style: theme.textTheme.titleLarge),
                    const SizedBox(height: 6),
                    Text(
                      _versionTaps == 0
                          ? 'Tap for details'
                          : '$_versionTaps / 7',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          NexusV2Group(
            title: 'Built for your devices',
            children: [
              NexusV2Row(
                leading: const Icon(Icons.devices_other_outlined),
                title: widget.mesh.identity.name,
                subtitle: widget.mesh.identity.platform,
              ),
              NexusV2Row(
                leading: const Icon(Icons.hub_outlined),
                title: '${widget.mesh.pairedDevices.length} paired devices',
                subtitle: 'Connections managed by Nexus',
              ),
            ],
          ),
          const SizedBox(height: 20),
          Center(
            child: Text(
              'Developer diagnostics unlock after seven taps on Version.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class NexusOrbProxy extends StatelessWidget {
  final double size;
  const NexusOrbProxy({super.key, required this.size});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _AboutOrbPainter(Theme.of(context).colorScheme.primary),
    );
  }
}

class _AboutOrbPainter extends CustomPainter {
  final Color color;
  const _AboutOrbPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide * .36;
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = color.withValues(alpha: .52);
    canvas.drawCircle(c, r, p);
    for (final factor in const [-.55, 0.0, .55]) {
      canvas.drawOval(
        Rect.fromCenter(
          center: c,
          width: r * 2 * (1 - factor.abs() * .45),
          height: r * .55,
        ),
        p,
      );
      canvas.drawOval(
        Rect.fromCenter(
          center: c,
          width: r * .55,
          height: r * 2 * (1 - factor.abs() * .45),
        ),
        p,
      );
    }
    final dot = Paint()..color = color.withValues(alpha: .82);
    canvas.drawCircle(c, 3, dot);
  }

  @override
  bool shouldRepaint(covariant _AboutOrbPainter oldDelegate) => oldDelegate.color != color;
}
