import 'package:flutter/material.dart';

import '../../mesh/discovery.dart';
import '../../mesh/mesh_service.dart';
import 'design_system.dart';
import 'pair_sheet.dart';

class NexusV2DevicesView extends StatelessWidget {
  final MeshService mesh;
  const NexusV2DevicesView({super.key, required this.mesh});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: mesh,
      builder: (context, _) {
        final paired = mesh.pairedDevices.toList()
          ..sort((a, b) => (mesh.isOnline(a.id) ? 0 : 1).compareTo(mesh.isOnline(b.id) ? 0 : 1));
        final nearby = mesh.nearbyDevices.where((d) => !mesh.isPaired(d.id)).toList();
        final online = paired.where((d) => mesh.isOnline(d.id)).length;

        return CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: NexusV2PageTitle(
                title: 'Devices',
                subtitle: paired.isEmpty
                    ? 'Connect the devices you use every day.'
                    : '$online of ${paired.length} connected',
                trailing: Semantics(
                  label: 'Add a device',
                  button: true,
                  child: IconButton.filled(
                    tooltip: 'Add device',
                    icon: const Icon(Icons.add_rounded),
                    onPressed: () => showNexusV2PairSheet(context, mesh: mesh),
                  ),
                ),
              ),
            ),
            if (paired.isEmpty)
              SliverToBoxAdapter(child: _EmptyDevices(mesh: mesh))
            else ...[
              const SliverToBoxAdapter(child: SizedBox(height: 4)),
              SliverList.builder(
                itemCount: paired.length,
                itemBuilder: (context, index) => Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: _DeviceRow(mesh: mesh, device: paired[index]),
                ),
              ),
            ],
            if (nearby.isNotEmpty) ...[
              const SliverToBoxAdapter(child: SizedBox(height: 20)),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text('Nearby', style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                ),
              ),
              SliverList.builder(
                itemCount: nearby.length,
                itemBuilder: (context, index) => Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: _NearbyRow(mesh: mesh, device: nearby[index]),
                ),
              ),
            ],
            if (mesh.serialDevices.isNotEmpty || mesh.remoteSerialDevices.isNotEmpty) ...[
              const SliverToBoxAdapter(child: SizedBox(height: 20)),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text('Connected accessories', style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                ),
              ),
              SliverList(
                delegate: SliverChildListDelegate([
                  for (final d in mesh.serialDevices) Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 8), child: _AccessoryRow(name: d.id, online: d.online)),
                  for (final d in mesh.remoteSerialDevices) Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 8), child: _AccessoryRow(name: d.id, online: d.online)),
                ]),
              ),
            ],
            const SliverPadding(padding: EdgeInsets.only(bottom: 28)),
          ],
        );
      },
    );
  }
}

class _EmptyDevices extends StatelessWidget {
  final MeshService mesh;
  const _EmptyDevices({required this.mesh});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
          child: Column(
            children: [
              Icon(Icons.devices_rounded, size: 42, color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(height: 14),
              Text('Bring your devices together', style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
              const SizedBox(height: 8),
              Text(
                'Pair a phone or computer once. Nexus keeps the connection ready so you can move files, share your clipboard and use devices together.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add a device'),
                onPressed: () => showNexusV2PairSheet(context, mesh: mesh),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  final MeshService mesh;
  final PairedDevice device;
  const _DeviceRow({required this.mesh, required this.device});

  @override
  Widget build(BuildContext context) {
    final online = mesh.isOnline(device.id);
    final visible = mesh.isVisible(device.id);
    final status = online ? 'Connected' : visible ? 'Nearby' : 'Offline';
    final icon = switch (device.platform) {
      'android' => Icons.phone_android_rounded,
      'windows' => Icons.desktop_windows_rounded,
      'linux' => Icons.computer_rounded,
      'macos' => Icons.laptop_mac_rounded,
      'ios' => Icons.phone_iphone_rounded,
      _ => Icons.devices_other_rounded,
    };
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _showMenu(context),
        child: NexusV2Row(
          leading: Icon(icon, color: online ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.onSurfaceVariant),
          title: device.name,
          subtitle: status,
          trailing: NexusV2Status(active: online, label: status),
        ),
      ),
    );
  }

  Future<void> _showMenu(BuildContext context) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (sheet) => SafeArea(
        child: NexusV2Group(
          title: device.name,
          children: [
            NexusV2Row(title: 'Device details', leading: const Icon(Icons.info_outline_rounded), onTap: () => Navigator.pop(sheet, 'details')),
            NexusV2Row(title: 'Rename', leading: const Icon(Icons.edit_outlined), onTap: () => Navigator.pop(sheet, 'rename')),
            NexusV2Row(title: 'Forget device', leading: const Icon(Icons.link_off_rounded), destructive: true, onTap: () => Navigator.pop(sheet, 'forget')),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    switch (action) {
      case 'details':
        await _details(context);
      case 'rename':
        await _rename(context);
      case 'forget':
        await _forget(context);
    }
  }

  Future<void> _details(BuildContext context) => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(device.name),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(mesh.isOnline(device.id) ? 'Connected' : 'Offline'),
              const SizedBox(height: 6),
              Text('Platform: ${device.platform}'),
              const SizedBox(height: 6),
              Text('Last verified: ${device.lastVerified ?? 'Never'}'),
            ],
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))],
        ),
      );

  Future<void> _rename(BuildContext context) async {
    final controller = TextEditingController(text: device.name);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename device'),
        content: TextField(controller: controller, autofocus: true, maxLength: 24, decoration: const InputDecoration(labelText: 'Name')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    controller.dispose();
    if (value != null && value.isNotEmpty && context.mounted) {
      await mesh.renamePairedDevice(device.id, value);
    }
  }

  Future<void> _forget(BuildContext context) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Forget ${device.name}?'),
        content: const Text('You can pair this device again later.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Forget')),
        ],
      ),
    );
    if (yes == true) await mesh.forgetDevice(device.id);
  }
}

class _NearbyRow extends StatelessWidget {
  final MeshService mesh;
  final DiscoveredDevice device;
  const _NearbyRow({required this.mesh, required this.device});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: NexusV2Row(
        leading: Icon(Icons.devices_other_rounded, color: Theme.of(context).colorScheme.onSurfaceVariant),
        title: device.name,
        subtitle: 'Found on your network',
        trailing: FilledButton.tonal(
          onPressed: () => showNexusV2PairSheet(context, mesh: mesh, nearby: device),
          child: const Text('Connect'),
        ),
      ),
    );
  }
}

class _AccessoryRow extends StatelessWidget {
  final String name;
  final bool online;
  const _AccessoryRow({required this.name, required this.online});

  @override
  Widget build(BuildContext context) => Card(
        child: NexusV2Row(
          leading: Icon(Icons.memory_rounded, color: Theme.of(context).colorScheme.onSurfaceVariant),
          title: name,
          subtitle: online ? 'Connected accessory' : 'Offline',
          trailing: NexusV2Status(active: online, label: online ? 'Connected' : 'Offline'),
        ),
      );
}
