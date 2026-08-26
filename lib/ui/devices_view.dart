import 'package:flutter/material.dart';

import '../mesh/discovery.dart';
import '../mesh/mesh_service.dart';
import '../mesh/serial_bridge.dart';
import 'nexus_header.dart';
import 'pair_sheet.dart';
import 'theme.dart';

IconData platformIcon(String platform) {
  switch (platform) {
    case 'android':
      return Icons.phone_android;
    case 'linux':
      return Icons.desktop_windows_rounded; // closest neutral glyph set
    case 'windows':
      return Icons.desktop_windows;
    case 'macos':
      return Icons.laptop_mac;
    case 'ios':
      return Icons.phone_iphone;
    default:
      return Icons.devices_other;
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
  if (name == null || name.isEmpty || !context.mounted) return;
  await mesh.renamePairedDevice(device.id, name);
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
      backgroundColor: NexusColors.surface,
      title: const Text('Rename device'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: 24,
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

String platformLabel(String platform) {
  switch (platform) {
    case 'android':
      return 'Phone';
    case 'linux':
      return 'Linux';
    case 'windows':
      return 'Windows';
    case 'macos':
      return 'Mac';
    case 'ios':
      return 'iPhone';
    default:
      return 'Device';
  }
}

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
    final online = mesh.onlineCount;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
      children: [
        const NexusHeader(
          icon: Icons.blur_on_rounded,
          title: 'Nexus',
          subtitle: 'Your devices, one system',
        ),
        const SizedBox(height: 24),
        _StatusStrip(online: online, total: paired.length, mesh: mesh),
        const SizedBox(height: 24),
        Row(
          children: [
            Text('Your devices', style: Theme.of(context).textTheme.titleLarge),
            const Spacer(),
            if (paired.isNotEmpty)
              Text(
                '$online online',
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (paired.isEmpty)
          _EmptyState(mesh: mesh)
        else
          ...paired.map((d) => _DeviceCard(mesh: mesh, device: d)),
        if (serial.isNotEmpty || remoteSerial.isNotEmpty) ...[
          const SizedBox(height: 28),
          Row(
            children: [
              Text('Microcontrollers', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(width: 8),
              const Icon(Icons.usb_rounded, size: 16, color: NexusColors.muted),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'On a cable, or reachable through another device. They only do '
            'what they advertise — no clipboard or files.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          ...serial.map((d) => _SerialCard(mesh: mesh, device: d)),
          ...remoteSerial.map((d) {
            final hostId = d.port.startsWith('remote:')
                ? d.port.substring(7)
                : null;
            final hostName = hostId == null
                ? null
                : mesh.pairedDevices
                    .where((p) => p.id == hostId)
                    .map((p) => p.name)
                    .firstOrNull;
            return _SerialCard(
              mesh: mesh,
              device: d,
              hostName: hostName ?? hostId,
            );
          }),
        ],
        if (nearby.isNotEmpty) ...[
          const SizedBox(height: 28),
          Text('Nearby', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            'Devices on your network. Pairing is the only step — after that, '
            'everything is encrypted and direct.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          ...nearby.map((d) => _NearbyCard(mesh: mesh, device: d)),
        ],
      ],
    );
  }
}

class _StatusStrip extends StatelessWidget {
  final int online;
  final int total;
  final MeshService mesh;

  const _StatusStrip({
    required this.online,
    required this.total,
    required this.mesh,
  });

  @override
  Widget build(BuildContext context) {
    final note = mesh.lastNotice;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: NexusColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: NexusColors.border),
      ),
      child: Row(
        children: [
          _PulseDot(color: online > 0 ? NexusColors.ok : NexusColors.muted),
          const SizedBox(width: 10),
          Expanded(
            child: note != null
                ? Text(note, style: Theme.of(context).textTheme.bodySmall)
                : Text(
                    total == 0
                        ? 'No paired devices yet. Pair your first device to begin.'
                        : online == total
                        ? 'All $total devices reachable right now.'
                        : '$online of $total devices reachable right now.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
          ),
        ],
      ),
    );
  }
}

class _PulseDot extends StatefulWidget {
  final Color color;
  const _PulseDot({required this.color});

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 18,
      height: 18,
      child: Stack(
        alignment: Alignment.center,
        children: [
          FadeTransition(
            opacity: Tween(begin: 0.5, end: 0.0).animate(_controller),
            child: ScaleTransition(
              scale: Tween(begin: 0.7, end: 1.8).animate(
                CurvedAnimation(parent: _controller, curve: Curves.easeOut),
              ),
              child: Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  color: widget.color.withValues(alpha: 0.35),
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              color: widget.color,
              shape: BoxShape.circle,
            ),
          ),
        ],
      ),
    );
  }
}

class _DeviceCard extends StatelessWidget {
  final MeshService mesh;
  final PairedDevice device;

  const _DeviceCard({required this.mesh, required this.device});

  @override
  Widget build(BuildContext context) {
    final online = mesh.isOnline(device.id);
    final visible = mesh.isVisible(device.id);
    final lastSeen = mesh.lastSeenAt(device.id);

    final (Color dotColor, String statusText) = online
        ? (NexusColors.ok, 'Online')
        : visible
        ? (NexusColors.warn, 'Nearby · not reachable')
        : (NexusColors.muted, 'Offline · last seen ${_timeAgo(lastSeen)}');

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              _Avatar(name: device.name),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      device.name,
                      style: Theme.of(context).textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        _PulseDot(color: dotColor),
                        const SizedBox(width: 6),
                        Text(
                          '$statusText · ${platformLabel(device.platform)}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                color: NexusColors.surfaceHi,
                icon: const Icon(
                  Icons.more_vert,
                  color: NexusColors.muted,
                  size: 20,
                ),
                onSelected: (value) async {
                  switch (value) {
                    case 'details':
                      showDialog(
                        context: context,
                        builder: (context) => AlertDialog(
                          backgroundColor: NexusColors.surface,
                          title: Text(
                            device.name,
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          content: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _DetailRow(label: 'Status', value: statusText),
                              _DetailRow(
                                label: 'Platform',
                                value: platformLabel(device.platform),
                              ),
                              _DetailRow(
                                label: 'Address',
                                value: '${device.address}:${device.port}',
                              ),
                              _DetailRow(
                                label: 'Paired',
                                value: 'Encrypted · direct',
                              ),
                            ],
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('Close'),
                            ),
                          ],
                        ),
                      );
                    case 'edit_name':
                      await _renamePairedDevice(context, mesh, device);
                    case 'forget':
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          backgroundColor: NexusColors.surface,
                          title: const Text(
                            'Forget this device?',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          content: Text(
                            'Careful — ${device.name} will be removed and must be paired '
                            'again from scratch to reconnect. This can\'t be undone.',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text('Cancel'),
                            ),
                            FilledButton(
                              style: FilledButton.styleFrom(
                                backgroundColor: NexusColors.danger,
                                foregroundColor: Colors.white,
                              ),
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text('Forget device'),
                            ),
                          ],
                        ),
                      );
                      if (confirmed == true) {
                        await mesh.forgetDevice(device.id);
                      }
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'edit_name',
                    child: Text('Edit name'),
                  ),
                  const PopupMenuItem(
                    value: 'details',
                    child: Text('Details'),
                  ),
                  PopupMenuItem(
                    value: 'forget',
                    child: Text(
                      'Forget device',
                      style: TextStyle(color: NexusColors.danger),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  const _DetailRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          Text(value, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}

/// "3m ago", "2h ago" — or "never" when we have no record of the device.
String _timeAgo(DateTime? t) {
  if (t == null) return 'never';
  final d = DateTime.now().difference(t);
  if (d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  return '${d.inDays}d ago';
}

class _NearbyCard extends StatelessWidget {
  final MeshService mesh;
  final DiscoveredDevice device;

  const _NearbyCard({required this.mesh, required this.device});

  @override
  Widget build(BuildContext context) {
    final online = mesh.isOnline(device.id);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              _Avatar(name: device.name),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      device.name,
                      style: Theme.of(context).textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      online
                          ? 'Reachable · ${platformLabel(device.platform)}'
                          : 'Seen ${_timeAgo(device.lastSeen)} · ${platformLabel(device.platform)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              OutlinedButton(
                onPressed: () =>
                    showPairSheet(context, mesh: mesh, nearby: device),
                child: const Text('Pair'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final String name;
  const _Avatar({required this.name});

  @override
  Widget build(BuildContext context) {
    final letters = name.trim().isEmpty
        ? '?'
        : name.trim().substring(0, 1).toUpperCase();
    return Container(
      width: 42,
      height: 42,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: NexusColors.surfaceHi,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        letters,
        style: const TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w700,
          color: NexusColors.accent,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final MeshService mesh;
  const _EmptyState({required this.mesh});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const Icon(
              Icons.devices_rounded,
              size: 40,
              color: NexusColors.muted,
            ),
            const SizedBox(height: 12),
            Text(
              'Nothing paired yet',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              'On the other device, tap “Show my code”, then pair with it here — '
              'or show your own code on this device and enter it there.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => showPairSheet(context, mesh: mesh),
              icon: const Icon(Icons.qr_code_2_rounded, size: 18),
              label: const Text('Pair a device'),
            ),
          ],
        ),
      ),
    );
  }
}

/// A microcontroller on the cable. Capability-aware: it advertises only
/// `ping`/`msg`, so the card offers exactly those actions and nothing more.
class _SerialCard extends StatelessWidget {
  final MeshService mesh;
  final SerialDevice device;

  /// Set for devices hosted by another paired device (multi-hop relay); the
  /// card then shows "via [host]" instead of "over USB cable".
  final String? hostName;
  const _SerialCard({required this.mesh, required this.device, this.hostName});

  @override
  Widget build(BuildContext context) {
    final online = device.online;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: (online ? NexusColors.accent : NexusColors.muted)
                      .withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  online ? Icons.memory_rounded : Icons.memory_outlined,
                  color: online ? NexusColors.accent : NexusColors.muted,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      device.name,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${device.id} · ${hostName != null ? "via $hostName" : "over USB cable"}',
                      style: const TextStyle(
                        fontSize: 11,
                        color: NexusColors.muted,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      online ? 'Online · small messages only' : 'Disconnected',
                      style: TextStyle(
                        fontSize: 11,
                        color: online ? NexusColors.ok : NexusColors.warn,
                      ),
                    ),
                  ],
                ),
              ),
              if (device.can('msg'))
                IconButton(
                  tooltip: 'Send a test blink',
                  icon: const Icon(Icons.bolt_rounded, size: 18),
                  color: NexusColors.accent,
                  onPressed: () async {
                    final ok = await mesh.sendSerialMessage(
                      device.id,
                      {'blink': true},
                    );
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            ok
                                ? 'Sent to ${device.name}.'
                                : 'Could not reach ${device.name}.',
                          ),
                        ),
                      );
                    }
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}
