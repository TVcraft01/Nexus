import 'package:flutter/material.dart';

import 'theme.dart';

/// The voice-first assistant is the heart of Nexus — but it is *next*, and
/// this screen says so honestly instead of pretending.
class AssistantView extends StatelessWidget {
  const AssistantView({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: NexusColors.accent.withValues(alpha: 0.1),
                  border: Border.all(color: NexusColors.accent.withValues(alpha: 0.35)),
                ),
                child: const Icon(Icons.mic_none_rounded, size: 38, color: NexusColors.accent),
              ),
              const SizedBox(height: 24),
              Text('The assistant comes next', style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 12),
              Text(
                'The plan: your PC runs the brain — a local AI that never needs '
                'the cloud — and your phone is its voice and face. You’ll talk to '
                'it, and it will answer out loud and act on your devices.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 28),
              _RoadmapTile(
                icon: Icons.link_rounded,
                title: 'The mesh',
                detail: 'Devices find, pair, and talk to each other.',
                done: true,
              ),
              _RoadmapTile(
                icon: Icons.content_paste_go_rounded,
                title: 'Clipboard everywhere',
                detail: 'Copy on one device, paste on another.',
                done: true,
              ),
              _RoadmapTile(
                icon: Icons.psychology_rounded,
                title: 'The brain on your PC',
                detail: 'A local AI, downloaded once, running entirely on your machine.',
                done: false,
              ),
              _RoadmapTile(
                icon: Icons.record_voice_over_rounded,
                title: 'Voice in, voice out',
                detail: 'Talk to it; it answers aloud — fully offline.',
                done: false,
              ),
              _RoadmapTile(
                icon: Icons.alarm_rounded,
                title: 'Memory, reminders, notes',
                detail: 'It knows you and acts: “remind me to call Sam at 7”',
                done: false,
              ),
              _RoadmapTile(
                icon: Icons.travel_explore_rounded,
                title: 'Files & control',
                detail: 'Find files, open apps, run your coding agent from your phone.',
                done: false,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoadmapTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String detail;
  final bool done;

  const _RoadmapTile({required this.icon, required this.title, required this.detail, required this.done});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: NexusColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: done ? NexusColors.accent.withValues(alpha: 0.35) : NexusColors.border),
      ),
      child: Row(
        children: [
          Icon(icon, size: 22, color: done ? NexusColors.accent : NexusColors.muted),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: done ? NexusColors.text : NexusColors.muted,
                      ),
                ),
                const SizedBox(height: 2),
                Text(detail, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          if (done)
            const Icon(Icons.check_circle_rounded, size: 18, color: NexusColors.ok)
          else
            Text('Next', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: NexusColors.accent)),
        ],
      ),
    );
  }
}
