import 'package:flutter/material.dart';

import '../mesh/mesh_service.dart';
import 'devices_view.dart';
import 'theme.dart';

class SettingsView extends StatefulWidget {
  final MeshService mesh;
  const SettingsView({super.key, required this.mesh});

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  late final TextEditingController _nameController =
      TextEditingController(text: widget.mesh.identity.name);

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _rename() async {
    widget.mesh.renameDevice(_nameController.text);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Device name updated.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final mesh = widget.mesh;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
      children: [
        Text('Settings', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 4),
        Text('This device and how it behaves.', style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 20),

        _SectionCard(
          children: [
            _SectionTitle('This device'),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'Device name'),
              onSubmitted: (_) => _rename(),
            ),
            const SizedBox(height: 8),
            Text(
              'How other devices see this one. ${platformLabel(mesh.identity.platform)} · '
              'listening on port ${mesh.port}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        const SizedBox(height: 14),

        _SectionCard(
          children: [
            _SectionTitle('Clipboard everywhere'),
            _ToggleRow(
              title: 'Watch my clipboard',
              detail: 'When I copy something, share it with paired devices.',
              value: mesh.store.clipboardSync,
              onChanged: (v) {
                setState(() => mesh.store.clipboardSync = v);
                mesh.store.save();
              },
            ),
            const Divider(height: 20),
            _ToggleRow(
              title: 'Apply incoming clips automatically',
              detail: 'Copy on one device, paste anywhere on the other — text lands '
                  'directly on my clipboard. Turn off to never overwrite it.',
              value: mesh.store.autoApplyClipboard,
              onChanged: (v) {
                setState(() => mesh.store.autoApplyClipboard = v);
                mesh.store.save();
              },
            ),
          ],
        ),
        const SizedBox(height: 14),

        _SectionCard(
          children: [
            _SectionTitle('Network'),
            _ToggleRow(
              title: 'Broadcast discovery',
              detail: 'Announce this device on the local network so others can find it.',
              value: mesh.store.broadcastDiscovery,
              onChanged: (v) {
                setState(() => mesh.store.broadcastDiscovery = v);
                mesh.store.save();
              },
            ),
            const Divider(height: 20),
            _InfoRow(
              title: 'Reachability is honest',
              detail: 'A device is marked online only when this device has actually '
                  'talked to it. If it shows “not reachable”, it really wasn’t.',
              icon: Icons.verified_user_outlined,
            ),
          ],
        ),
        const SizedBox(height: 14),

        _SectionCard(
          children: [
            _SectionTitle('Paired devices'),
            if (mesh.pairedDevices.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text('None yet. Pair a device from the Devices tab.',
                    style: Theme.of(context).textTheme.bodySmall),
              )
            else
              ...mesh.pairedDevices.map((d) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(platformIcon(d.platform), color: NexusColors.accent),
                    title: Text(d.name, style: Theme.of(context).textTheme.titleMedium),
                    subtitle: Text(
                      mesh.isOnline(d.id) ? 'Online · ${d.address}:${d.port}' : 'Offline',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    trailing: IconButton(
                      tooltip: 'Forget',
                      icon: const Icon(Icons.delete_outline_rounded, size: 20, color: NexusColors.danger),
                      onPressed: () async {
                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            backgroundColor: NexusColors.surface,
                            title: const Text('Forget device?', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                            content: Text('${d.name} will need to be paired again.', style: Theme.of(context).textTheme.bodyMedium),
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
                        if (confirmed == true) await mesh.forgetDevice(d.id);
                      },
                    ),
                  )),
          ],
        ),
        const SizedBox(height: 14),

        _SectionCard(
          children: [
            _SectionTitle('About'),
            const _InfoRow(
              title: 'Nexus 0.1 — the mesh',
              detail: 'Local-first. No cloud, no account. Everything between paired '
                  'devices is encrypted (AES-GCM) and travels direct.',
              icon: Icons.info_outline_rounded,
            ),
            const Divider(height: 20),
            const _InfoRow(
              title: 'Privacy',
              detail: 'Pairing secrets and your data stay on your devices. Nothing is '
                  'sent anywhere, ever.',
              icon: Icons.lock_outline_rounded,
            ),
          ],
        ),
      ],
    );
  }
}

class _SectionCard extends StatelessWidget {
  final List<Widget> children;
  const _SectionCard({required this.children});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(padding: const EdgeInsets.all(16), child: Column(children: children)),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(text, style: Theme.of(context).textTheme.titleMedium?.copyWith(color: NexusColors.accent)),
    );
  }
}

class _ToggleRow extends StatelessWidget {
  final String title;
  final String detail;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _ToggleRow({required this.title, required this.detail, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 2),
              Text(detail, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        Switch(value: value, onChanged: onChanged),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String title;
  final String detail;
  final IconData icon;
  const _InfoRow({required this.title, required this.detail, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: NexusColors.muted),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 2),
              Text(detail, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ],
    );
  }
}
