import 'package:flutter/material.dart';

/// Shared section heading for Nexus. The heading establishes hierarchy; the
/// content below carries the visual weight.
class NexusHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const NexusHeader({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.displaySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        const SizedBox(width: 16),
        Semantics(
          excludeSemantics: true,
          child: Icon(icon, color: colors.onSurfaceVariant, size: 22),
        ),
      ],
    );
  }
}
