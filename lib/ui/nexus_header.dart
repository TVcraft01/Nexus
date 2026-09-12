import 'package:flutter/material.dart';

import 'theme.dart';

/// One header for every tab: an icon tile, a title, and a one-line subtitle.
/// Before this, each view rolled its own header — Devices had a hero, Settings
/// a bare label, Assistant none at all. Same shape everywhere now, so the app
/// reads as one product.
class NexusHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  /// Replaces the icon tile outright. The Assistant passes the live Nexus
  /// core here, so the one tab that *is* Nexus shows what Nexus is doing
  /// while the rest keep the flat tile — same header everywhere, one shared
  /// identity, without forcing every screen into the same contents.
  final Widget? leading;

  const NexusHeader({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.leading,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        leading ??
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: NexusColors.accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: NexusColors.accent, size: 24),
            ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 2),
              Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ],
    );
  }
}
