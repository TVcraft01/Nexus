import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../core/capability.dart';
import '../core/network_info.dart' show isTailscaleIp;
import '../mesh/discovery.dart';
import '../mesh/mesh_service.dart';
import '../mesh/serial_bridge.dart';
import 'components/nexus_ui.dart';
import 'pair_sheet.dart';
import 'theme.dart';

// The platform glyph and label live with the rest of the shared presentation
// layer; re-exported so this file's callers keep one import for both.
export 'components/nexus_ui.dart' show platformIcon, platformLabel;

/// "3m ago", "2h ago" — or "never" when there is no record of the device.
String _timeAgo(DateTime? t) {
  if (t == null) return 'never';
  final d = DateTime.now().difference(t);
  if (d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  return '${d.inDays}d ago';
}

/// What this device can actually run for you, named the way the capability
/// registry names it.
///
/// Derived, not written down here: the list is generated from the same
/// registry that decides what the device advertises to its peers, filtered to
/// the capabilities that have a device backend (the catalog answers every
/// device shares are not "this device can do" facts).
List<String> _runnableCapabilityLabels(String platform) => [
  for (final advertised in defaultCapabilitiesFor(platform))
    if (capabilityFor(advertised.id) case final capability?
        when capability.isDeviceExecutable)
      capability.label.toLowerCase(),
];

class DevicesView extends StatelessWidget {
  final MeshService mesh;

  const DevicesView({super.key, required this.mesh});

  @override
  Widget build(BuildContext context) {
    final paired = mesh.pairedDevices;
    final nearby = mesh.nearbyDevices
        .where((d) => !mesh.isPaired(d.id))
        .toList();
    final serial = mesh.serialDevices;
    final remoteSerial = mesh.remoteSerialDevices;

    return NexusPage(
      pinnedBottom: paired.isEmpty
          ? null
          // The one action that matters on this screen, in reach of a thumb.
          : SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => showPairSheet(context, mesh: mesh),
                icon: const Icon(Icons.add_rounded, size: 20),
                label: const Text('Add device'),
              ),
            ),
      children: [
        const NexusPageHeader(
          title: 'Devices',
          subtitle: 'Everything Nexus can work across.',
        ),
        _Reachability(note: mesh.lastNotice, mesh: mesh),
        if (paired.isEmpty)
          const SizedBox(height: NexusSpace.lg)
        else ...[
          const NexusSectionHeader('Your devices'),
          NexusGroup(
            children: [
              for (final d in paired) _PairedRow(mesh: mesh, device: d),
            ],
          ),
        ],
        if (paired.isEmpty)
          NexusEmptyState(
            icon: Icons.devices_rounded,
            title: 'No devices yet',
            message:
                'Connect your first device and Nexus can work across all of '
                'them — clipboard, files, messages and actions.',
            action: FilledButton.icon(
              onPressed: () => showPairSheet(context, mesh: mesh),
              icon: const Icon(Icons.add_rounded, size: 20),
              label: const Text('Add device'),
            ),
            secondaryAction: TextButton(
              onPressed: () => showPairSheet(context, mesh: mesh),
              child: const Text('Show my code on another device'),
            ),
          ),
        if (nearby.isNotEmpty) ...[
          NexusSectionHeader(
            'Nearby',
            detail: 'Pairing is the only step — after that everything is '
                'encrypted and direct.',
            trailing: Text(
              '${nearby.length}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          NexusGroup(
            children: [
              for (final d in nearby) _NearbyRow(mesh: mesh, device: d),
            ],
          ),
        ],
        if (serial.isNotEmpty || remoteSerial.isNotEmpty) ...[
          NexusSectionHeader(
            'Microcontrollers',
            detail: 'On a cable, or reachable through another device. They '
                'only do what they advertise.',
          ),
          NexusGroup(
            children: [
              for (final d in serial) _SerialRow(mesh: mesh, device: d),
              for (final d in remoteSerial)
                _SerialRow(
                  mesh: mesh,
                  device: d,
                  hostName: _hostNameFor(mesh, d),
                ),
            ],
          ),
        ],
      ],
    );
  }

  String? _hostNameFor(MeshService mesh, SerialDevice device) {
    final hostId = device.port.startsWith('remote:')
        ? device.port.substring(7)
        : null;
    if (hostId == null) return null;
    return mesh.pairedDevices
            .where((p) => p.id == hostId)
            .map((p) => p.name)
            .firstOrNull ??
        hostId;
  }
}

/// One honest line about whether Nexus can reach anything right now. Not a
/// card: it is a sentence, and it used to wear a rounded rectangle.
class _Reachability extends StatelessWidget {
  const _Reachability({required this.note, required this.mesh});

  final String? note;
  final MeshService mesh;

  @override
  Widget build(BuildContext context) {
    final palette = NexusPalette.of(context);
    final total = mesh.pairedDevices.length;
    final online = mesh.onlineCount;

    // With nothing paired the empty state below already says what to do, in
    // its own words — the phone showed both on one screen, saying the same
    // thing twice. Only a real operational notice is still worth a line here.
    if (total == 0 && note == null) return const SizedBox.shrink();

    final (NexusStatusLevel level, String text) = switch ((total, online)) {
      (0, _) => (
        NexusStatusLevel.offline,
        'No paired devices yet. Pair your first device to begin.',
      ),
      (final t, final o) when o == t => (
        NexusStatusLevel.online,
        'All $t devices reachable right now.',
      ),
      (final t, 0) => (
        NexusStatusLevel.offline,
        'None of your $t devices are reachable right now.',
      ),
      (final t, final o) => (
        NexusStatusLevel.nearby,
        '$o of $t devices reachable right now.',
      ),
    };

    return Row(
      children: [
        NexusStatusDot(level: level, size: 8),
        const SizedBox(width: NexusSpace.sm),
        Expanded(
          child: Text(
            note ?? text,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: palette.textSecondary),
          ),
        ),
      ],
    );
  }
}

/// A paired device, as a row.
///
/// The row says the four things a person needs — name, what it is, whether it
/// is here, and one useful fact — and nothing else. Addresses, ports and
/// protocol details live behind "Advanced" in the detail sheet.
class _PairedRow extends StatelessWidget {
  const _PairedRow({required this.mesh, required this.device});

  final MeshService mesh;
  final PairedDevice device;

  @override
  Widget build(BuildContext context) {
    final online = mesh.isOnline(device.id);
    final visible = mesh.isVisible(device.id);
    final lastSeen = mesh.lastSeenAt(device.id);

    final (NexusStatusLevel level, String status) = online
        ? (NexusStatusLevel.online, 'Online')
        : visible
            ? (NexusStatusLevel.nearby, 'Nearby')
            : (
                NexusStatusLevel.offline,
                'Offline · last seen ${_timeAgo(lastSeen)}',
              );

    return NexusRow(
      minHeight: NexusSize.row,
      onTap: () {
        HapticFeedback.selectionClick();
        _showDetail(context, mesh, device);
      },
      leading: _DeviceGlyph(
        platform: device.platform,
        level: level,
        online: online,
      ),
      title: device.name,
      subtitle: '${platformLabel(device.platform)} · $status',
      chevron: true,
      trailing: Semantics(
        label: status,
        child: Tooltip(
          message: status,
          child: NexusStatusDot(level: level, size: 10),
        ),
      ),
    );
  }
}

/// A device icon that also carries reachability, so the eye can scan status
/// down the column without reading every row.
class _DeviceGlyph extends StatelessWidget {
  const _DeviceGlyph({
    required this.platform,
    required this.level,
    required this.online,
  });

  final String platform;
  final NexusStatusLevel level;
  final bool online;

  @override
  Widget build(BuildContext context) {
    final palette = NexusPalette.of(context);
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: online
            ? palette.accentTint(0.10)
            : palette.surfaceSecondary,
        borderRadius: NexusRadius.row,
      ),
      child: Icon(
        platformIcon(platform),
        size: 20,
        color: online ? palette.accent : palette.textSecondary,
      ),
    );
  }
}

/// The device detail sheet: what it is, what it can do for you, and the
/// actions — with the technical facts behind one more tap.
void _showDetail(
  BuildContext context,
  MeshService mesh,
  PairedDevice device,
) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _DeviceDetailSheet(mesh: mesh, device: device),
  );
}

class _DeviceDetailSheet extends StatefulWidget {
  const _DeviceDetailSheet({required this.mesh, required this.device});

  final MeshService mesh;
  final PairedDevice device;

  @override
  State<_DeviceDetailSheet> createState() => _DeviceDetailSheetState();
}

class _DeviceDetailSheetState extends State<_DeviceDetailSheet> {
  bool _advanced = false;

  MeshService get mesh => widget.mesh;
  PairedDevice get device => widget.device;

  @override
  Widget build(BuildContext context) {
    final palette = NexusPalette.of(context);
    final online = mesh.isOnline(device.id);
    final visible = mesh.isVisible(device.id);
    final lastSeen = mesh.lastSeenAt(device.id);

    final (NexusStatusLevel level, String status) = online
        ? (NexusStatusLevel.online, 'Online · reachable now')
        : visible
            ? (NexusStatusLevel.nearby, 'Nearby but not reachable')
            : (
                NexusStatusLevel.offline,
                'Offline · last seen ${_timeAgo(lastSeen)}',
              );

    final capabilities = _runnableCapabilityLabels(device.platform);

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          NexusSpace.xl,
          0,
          NexusSpace.xl,
          NexusSpace.xl,
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                device.name,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: NexusSpace.sm),
              Row(
                children: [
                  NexusStatusDot(level: level, size: 9),
                  const SizedBox(width: NexusSpace.sm),
                  Expanded(
                    child: Text(
                      '${platformLabel(device.platform)} · $status',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
              if (capabilities.isNotEmpty) ...[
                const SizedBox(height: NexusSpace.xl),
                Text(
                  'Can do with this device'.toUpperCase(),
                  style: Theme.of(context).textTheme.labelSmall,
                ),
                const SizedBox(height: NexusSpace.sm),
                Wrap(
                  spacing: NexusSpace.sm,
                  runSpacing: NexusSpace.sm,
                  children: [
                    for (final c in capabilities)
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: palette.surfaceSecondary,
                          borderRadius: NexusRadius.pill,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: NexusSpace.md,
                            vertical: NexusSpace.xs + 2,
                          ),
                          child: Text(
                            c,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: palette.textSecondary),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: NexusSpace.xl),
              NexusGroup(
                children: [
                  NexusRow(
                    title: 'Rename',
                    minHeight: NexusSize.rowCompact,
                    leading: Icon(
                      Icons.edit_outlined,
                      size: 20,
                      color: palette.textSecondary,
                    ),
                    onTap: () async {
                      Navigator.pop(context);
                      await _renamePairedDevice(context, mesh, device);
                    },
                  ),
                  NexusRow(
                    title: 'Advanced',
                    subtitle: _advanced
                        ? 'Address, port and pairing details'
                        : 'Technical details',
                    minHeight: NexusSize.rowCompact,
                    leading: Icon(
                      Icons.tune_rounded,
                      size: 20,
                      color: palette.textSecondary,
                    ),
                    trailing: Icon(
                      _advanced
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 20,
                      color: palette.textTertiary,
                    ),
                    onTap: () => setState(() => _advanced = !_advanced),
                  ),
                ],
              ),
              // Progressive disclosure: the facts a normal person never needs
              // are here for the times someone does.
              AnimatedCrossFade(
                duration: NexusMotion.scaled(context, NexusMotion.base),
                crossFadeState: _advanced
                    ? CrossFadeState.showSecond
                    : CrossFadeState.showFirst,
                firstChild: const SizedBox(width: double.infinity),
                secondChild: Padding(
                  padding: const EdgeInsets.only(top: NexusSpace.md),
                  child: NexusGroup(
                    children: [
                      _DetailRow(
                        label: 'Address',
                        value: '${device.address}:${device.port}',
                      ),
                      _DetailRow(
                        label: 'Link',
                        value: 'Encrypted · direct',
                      ),
                      if (device.addresses.any(isTailscaleIp))
                        const _DetailRow(
                          label: 'Tailscale',
                          value: 'Reachable across networks',
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: NexusSpace.xl),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: palette.danger,
                    side: BorderSide(color: palette.danger.withValues(alpha: 0.5)),
                  ),
                  icon: const Icon(Icons.link_off_rounded, size: 18),
                  label: const Text('Forget device'),
                  onPressed: () async {
                    final confirmed = await _confirmForget(context, device);
                    if (confirmed != true || !context.mounted) return;
                    await mesh.forgetDevice(device.id);
                    if (context.mounted) Navigator.pop(context);
                  },
                ),
              ),
              const SizedBox(height: NexusSpace.sm),
              Text(
                'Forgetting removes the pairing. The device must be paired '
                'again from scratch to reconnect.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One technical fact. Label left, value right — the shape every phone's
/// "About" screen uses, because it reads at a glance.
class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: NexusSpace.lg,
        vertical: NexusSpace.md,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          const SizedBox(width: NexusSpace.md),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

/// A device Nexus can see but has not been paired with yet.
class _NearbyRow extends StatelessWidget {
  const _NearbyRow({required this.mesh, required this.device});

  final MeshService mesh;
  final DiscoveredDevice device;

  @override
  Widget build(BuildContext context) {
    final online = mesh.isOnline(device.id);
    return NexusRow(
      minHeight: NexusSize.row,
      leading: _DeviceGlyph(
        platform: device.platform,
        level: online ? NexusStatusLevel.online : NexusStatusLevel.offline,
        online: online,
      ),
      title: device.name,
      subtitle: online
          ? '${platformLabel(device.platform)} · reachable'
          : '${platformLabel(device.platform)} · seen ${_timeAgo(device.lastSeen)}',
      trailing: FilledButton.tonal(
        onPressed: () => showPairSheet(context, mesh: mesh, nearby: device),
        child: const Text('Pair'),
      ),
    );
  }
}

/// A microcontroller on the cable. Capability-aware: it advertises only
/// `ping`/`msg`, so the row offers exactly that and nothing more.
class _SerialRow extends StatelessWidget {
  const _SerialRow({required this.mesh, required this.device, this.hostName});

  final MeshService mesh;
  final SerialDevice device;

  /// Set for devices hosted by another paired device (multi-hop relay); the
  /// row then says "via [host]" instead of "over USB cable".
  final String? hostName;

  @override
  Widget build(BuildContext context) {
    final palette = NexusPalette.of(context);
    final online = device.online;
    final link = hostName != null ? 'via $hostName' : 'over USB cable';
    return NexusRow(
      minHeight: NexusSize.row,
      leading: Container(
        width: 40,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: online ? palette.accentTint(0.10) : palette.surfaceSecondary,
          borderRadius: NexusRadius.row,
        ),
        child: Icon(
          online ? Icons.memory_rounded : Icons.memory_outlined,
          size: 20,
          color: online ? palette.accent : palette.textSecondary,
        ),
      ),
      title: device.name,
      subtitle: online ? 'Online · $link' : 'Disconnected · $link',
      trailing: device.can('msg')
          ? NexusAsyncButton(
              label: 'Blink',
              icon: Icons.bolt_rounded,
              busyLabel: 'Sending…',
              successLabel: 'Sent',
              failureLabel: 'Unreachable',
              filled: false,
              onRun: () => mesh.sendSerialMessage(device.id, {'blink': true}),
            )
          : null,
    );
  }
}

Future<void> _renamePairedDevice(
  BuildContext context,
  MeshService mesh,
  PairedDevice device,
) async {
  final name = await showDialog<String>(
    context: context,
    builder: (_) => _RenameDeviceDialog(initialName: device.name),
  );
  if (name == null || name.isEmpty) return;
  await mesh.renamePairedDevice(device.id, name);
}

Future<bool?> _confirmForget(BuildContext context, PairedDevice device) {
  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Forget this device?'),
      content: Text(
        '${device.name} will be removed and must be paired again from '
        "scratch to reconnect. This can't be undone.",
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: NexusPalette.of(context).danger,
            foregroundColor: NexusPalette.of(context).onDanger,
          ),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Forget device'),
        ),
      ],
    ),
  );
}

class _RenameDeviceDialog extends StatefulWidget {
  final String initialName;

  const _RenameDeviceDialog({required this.initialName});

  @override
  State<_RenameDeviceDialog> createState() => _RenameDeviceDialogState();
}

class _RenameDeviceDialogState extends State<_RenameDeviceDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialName,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename device'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: 24,
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(labelText: 'Device name'),
        onSubmitted: (value) => Navigator.pop(context, value.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
