import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../mesh/discovery.dart';
import '../mesh/mesh_service.dart';
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
    final nearby = mesh.nearbyDevices.where((d) => !mesh.isPaired(d.id)).toList();
    final online = mesh.onlineCount;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
      children: [
        Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: NexusColors.accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.blur_on_rounded, color: NexusColors.accent, size: 24),
            ),
            const SizedBox(width: 14),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Nexus', style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 2),
                Text('Your devices, one system', style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ],
        ),
        const SizedBox(height: 24),
        _StatusStrip(online: online, total: paired.length, mesh: mesh),
        const SizedBox(height: 24),
        Row(
          children: [
            Text('Your devices', style: Theme.of(context).textTheme.titleLarge),
            const Spacer(),
            if (paired.isNotEmpty)
              Text('$online online', style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        const SizedBox(height: 12),
        // Always available — pairing a new device must be possible even when
        // devices already exist (found this missing during real testing).
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: () => showPairSheet(context, mesh: mesh),
            icon: const Icon(Icons.qr_code_2_rounded, size: 18),
            label: const Text('Pair a new device'),
          ),
        ),
        const SizedBox(height: 12),
        if (paired.isEmpty)
          _EmptyState(mesh: mesh)
        else
          ...paired.map((d) => _DeviceCard(mesh: mesh, device: d)),
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
        const SizedBox(height: 28),
        Text('Clipboard tray', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          mesh.store.clipboardSync
              ? 'Copy on any device and it lands on the others — and in your '
                  'clipboard, ready to paste anywhere.'
              : 'Clipboard sync is off — turn it on in Settings.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        if (mesh.clipTray.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text('Nothing copied yet.', style: Theme.of(context).textTheme.bodySmall),
          )
        else
          ...mesh.clipTray.take(10).map((e) => _ClipCard(entry: e)),
      ],
    );
  }
}

class _StatusStrip extends StatelessWidget {
  final int online;
  final int total;
  final MeshService mesh;

  const _StatusStrip({required this.online, required this.total, required this.mesh});

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

class _PulseDotState extends State<_PulseDot> with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat();

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
              scale: Tween(begin: 0.7, end: 1.8).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut)),
              child: Container(width: 18, height: 18, decoration: BoxDecoration(color: widget.color.withValues(alpha: 0.35), shape: BoxShape.circle)),
            ),
          ),
          Container(width: 9, height: 9, decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle)),
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
                    Text(device.name, style: Theme.of(context).textTheme.titleMedium, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        _PulseDot(color: dotColor),
                        const SizedBox(width: 6),
                        Text('$statusText · ${platformLabel(device.platform)}', style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                color: NexusColors.surfaceHi,
                icon: const Icon(Icons.more_vert, color: NexusColors.muted, size: 20),
                onSelected: (value) async {
                  switch (value) {
                    case 'send':
                      final controller = TextEditingController();
                      final text = await showDialog<String>(
                        context: context,
                        builder: (context) => AlertDialog(
                          backgroundColor: NexusColors.surface,
                          title: Text('Send to ${device.name}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                          content: TextField(
                            controller: controller,
                            autofocus: true,
                            maxLines: 4,
                            minLines: 2,
                            decoration: const InputDecoration(hintText: 'Text to send…'),
                          ),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                            FilledButton(
                              onPressed: () => Navigator.pop(context, controller.text),
                              child: const Text('Send'),
                            ),
                          ],
                        ),
                      );
                      if (text != null && text.trim().isNotEmpty) {
                        final sent = await mesh.broadcastClipboard(text.trim());
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                            content: Text(sent > 0 ? 'Sent to $sent device${sent == 1 ? '' : 's'}.' : 'Could not reach ${device.name} right now.'),
                          ));
                        }
                      }
                    case 'details':
                      showDialog(
                        context: context,
                        builder: (context) => AlertDialog(
                          backgroundColor: NexusColors.surface,
                          title: Text(device.name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                          content: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _DetailRow(label: 'Status', value: statusText),
                              _DetailRow(label: 'Platform', value: platformLabel(device.platform)),
                              _DetailRow(label: 'Address', value: '${device.address}:${device.port}'),
                              _DetailRow(label: 'Paired', value: 'Encrypted · direct'),
                            ],
                          ),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
                          ],
                        ),
                      );
                    case 'forget':
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          backgroundColor: NexusColors.surface,
                          title: const Text('Forget device?', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                          content: Text('${device.name} will need to be paired again to connect.', style: Theme.of(context).textTheme.bodyMedium),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                            FilledButton(
                              style: FilledButton.styleFrom(backgroundColor: NexusColors.danger, foregroundColor: Colors.white),
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text('Forget'),
                            ),
                          ],
                        ),
                      );
                      if (confirmed == true) {
                        await mesh.forgetDevice(device.id);
                      }
                  }
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'send', child: Text('Send text')),
                  PopupMenuItem(value: 'details', child: Text('Details')),
                  PopupMenuItem(value: 'forget', child: Text('Forget device')),
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
                    Text(device.name, style: Theme.of(context).textTheme.titleMedium, overflow: TextOverflow.ellipsis),
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
                onPressed: () => showPairSheet(context, mesh: mesh, nearby: device),
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
    final letters = name.trim().isEmpty ? '?' : name.trim().substring(0, 1).toUpperCase();
    return Container(
      width: 42,
      height: 42,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: NexusColors.surfaceHi,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(letters, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: NexusColors.accent)),
    );
  }
}

class _ClipCard extends StatelessWidget {
  final ClipEntry entry;
  const _ClipCard({required this.entry});

  @override
  Widget build(BuildContext context) {
    final from = entry.fromName ?? 'This device';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: NexusColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: NexusColors.border),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(entry.text, maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodyMedium),
                  const SizedBox(height: 4),
                  Text('From $from', style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Copy here',
              icon: const Icon(Icons.copy_rounded, size: 18, color: NexusColors.muted),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: entry.text));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied on this device.')));
                }
              },
            ),
          ],
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
            const Icon(Icons.devices_rounded, size: 40, color: NexusColors.muted),
            const SizedBox(height: 12),
            Text('Nothing paired yet', style: Theme.of(context).textTheme.titleMedium),
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
