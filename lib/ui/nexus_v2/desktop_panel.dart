import 'package:flutter/material.dart';

import '../../core/agent_contract.dart';
import '../../core/conversation_engine.dart';
import '../../mesh/mesh_service.dart';
import 'assistant_controller.dart';
import 'design_system.dart';

/// What a wide window can show and a phone cannot: the state the assistant
/// controller already holds, in a column beside the conversation.
///
/// Only real state, and only what the conversation beside it does not say out
/// loud. The globe and its line stay in the conversation column — repeating
/// them an inch to the right would be noise, not information — so this panel
/// answers the two questions a wide window has room for and the thread does
/// not: which devices are linked right now, and what Nexus last did with the
/// last thing it was asked.
///
/// Nothing here is inferred: the device rows come from the mesh's own paired
/// list and its own online answer, and the outcome line comes from the real
/// result the controller is holding. With nothing to report, it says so.
class NexusV2DesktopPanel extends StatelessWidget {
  const NexusV2DesktopPanel({
    super.key,
    required this.controller,
    required this.mesh,
  });

  /// What the panel occupies on a wide window. The shell's threshold comes
  /// from this: a rail (210 at its widest), the conversation's readable band
  /// (520) and this (288) still leave room to spare at 1080.
  static const double width = 288;

  final NexusAssistantController controller;
  final MeshService mesh;

  /// How each link is described, in one place, in the same words the Devices
  /// screen uses — the mesh's own verified-online answer, never a guess about
  /// the transport behind it.
  static String deviceLine(String name, bool online) =>
      online ? '$name · Connected' : '$name · Offline';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Both halves can change while this is on screen — a peer is verified, an
    // ask comes back — so it listens to the same two things it reads.
    return ListenableBuilder(
      listenable: Listenable.merge([mesh, controller]),
      builder: (context, _) {
        final rows = [
          for (final device in mesh.pairedDevices)
            (name: device.name, online: mesh.isOnline(device.id)),
        ];
        return Material(
          color: theme.colorScheme.surface,
          child: SafeArea(
            left: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                NexusV2Space.lg,
                NexusV2Space.xl,
                NexusV2Space.lg,
                NexusV2Space.lg,
              ),
              child: ListView(
                children: [
                  _Devices(theme: theme, rows: rows),
                  const SizedBox(height: NexusV2Space.xl),
                  _Last(
                    theme: theme,
                    last: controller.conversation.lastResult,
                    ask: _newestAsk(controller.entries),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// The newest ask in the thread — the words the user really typed, never a
  /// re-description of them.
  static String? _newestAsk(List<ConversationEntry> entries) {
    for (final entry in entries.reversed) {
      if (entry.userText case final String user) return user;
    }
    return null;
  }
}

class _Devices extends StatelessWidget {
  const _Devices({required this.theme, required this.rows});

  final ThemeData theme;
  final List<({String name, bool online})> rows;

  @override
  Widget build(BuildContext context) {
    final reachable = rows.where((row) => row.online).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Devices', style: theme.textTheme.titleSmall),
        const SizedBox(height: NexusV2Space.xs),
        if (rows.isEmpty)
          _muted('No other devices are paired yet.')
        else ...[
          Text(
            '$reachable of ${rows.length} connected',
            style: _small,
          ),
          // The presence line's own sentence, verbatim: here it explains the
          // list instead of repeating the globe.
          if (reachable == 0) ...[
            const SizedBox(height: NexusV2Space.xs),
            _muted(NexusAssistantController.offlineLine),
          ],
          const SizedBox(height: NexusV2Space.sm),
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: NexusV2Space.sm),
              child: Row(
                children: [
                  Icon(
                    Icons.devices_outlined,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: NexusV2Space.sm),
                  Expanded(
                    child: Text(
                      NexusV2DesktopPanel.deviceLine(row.name, row.online),
                      style: theme.textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }

  TextStyle? get _small => theme.textTheme.bodySmall
      ?.copyWith(color: theme.colorScheme.onSurfaceVariant);

  Widget _muted(String text) => Text(text, style: _small);
}

/// What Nexus last did, from the result it is really holding: the outcome in
/// the same words the card uses, the ask that produced it, and the reason when
/// there is one.
class _Last extends StatelessWidget {
  const _Last({required this.theme, required this.last, required this.ask});

  final ThemeData theme;
  final AgentDispatchResult? last;
  final String? ask;

  @override
  Widget build(BuildContext context) {
    final result = last;
    final words = result == null
        ? null
        : NexusAssistantController.statusWords(result.status);
    final failed =
        result != null && NexusAssistantController.isFailure(result.status);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Last', style: theme.textTheme.titleSmall),
        const SizedBox(height: NexusV2Space.xs),
        if (result == null)
          Text(
            'Nothing yet — ask something.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          )
        else ...[
          Row(
            children: [
              Icon(
                failed ? Icons.error_outline : Icons.check_circle_outline,
                size: 16,
                color: failed
                    ? theme.colorScheme.error
                    : theme.colorScheme.primary,
              ),
              const SizedBox(width: NexusV2Space.sm),
              // Flexible, not fixed: the outcome is core's own words, and a
              // narrow panel or a large text scale must wrap them rather than
              // run off the edge.
              Expanded(
                child: Text(words!, style: theme.textTheme.bodyMedium),
              ),
            ],
          ),
          if (ask != null) ...[
            const SizedBox(height: NexusV2Space.xs),
            Text(
              ask!,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          // The card already shows a reason that repeats its own headline, so
          // this adds it only when it says something the outcome word does not.
          if (result.message.isNotEmpty && result.message != words) ...[
            const SizedBox(height: NexusV2Space.xs),
            Text(
              result.message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: failed
                    ? theme.colorScheme.error
                    : theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ],
    );
  }
}
