import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';

import '../core/version.dart';
import '../mesh/mesh_service.dart';
import 'theme.dart';

class SettingsView extends StatefulWidget {
  final MeshService mesh;
  const SettingsView({super.key, required this.mesh});

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  bool? _allFilesAccess; // Android: can this device read its whole storage?

  @override
  void initState() {
    super.initState();
    MeshService.hasAllFilesAccess().then((v) {
      if (mounted) setState(() => _allFilesAccess = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final mesh = widget.mesh;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
      children: [
        Text('Settings', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 4),
        Text(
          'This device and how it behaves.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 20),

        _SectionCard(
          children: [
            _SectionTitle('Clipboard sync'),
            _ToggleRow(
              title: 'Sync clipboard across devices',
              detail:
                  'One switch for everything: what I copy is shared with paired '
                  'devices, and what they copy lands directly on my clipboard.',
              value: mesh.store.clipboardSync,
              onChanged: (v) {
                setState(() => mesh.store.clipboardSync = v);
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
              detail:
                  'A device is marked online only when this device has actually '
                  'talked to it. If it shows “not reachable”, it really wasn’t.',
              icon: Icons.verified_user_outlined,
            ),
          ],
        ),
        const SizedBox(height: 14),

        if (defaultTargetPlatform == TargetPlatform.android) ...[
          _SectionCard(
            children: [
              _SectionTitle('Files on this device'),
              _InfoRow(
                title: 'Show all your files to paired devices',
                detail: _allFilesAccess == false
                    ? 'Without it, devices only see files Nexus downloaded. Grant '
                          'it so your PC’s file manager can browse your photos, '
                          'downloads and music.'
                    : 'Paired devices can browse everything on this device — '
                          'photos, downloads, music — and delete files you allow.',
                icon: _allFilesAccess == false
                    ? Icons.lock_outline_rounded
                    : Icons.folder_open_rounded,
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonalIcon(
                  onPressed: MeshService.openAllFilesAccessSettings,
                  icon: Icon(
                    _allFilesAccess == false
                        ? Icons.lock_open_rounded
                        : Icons.settings_rounded,
                    size: 18,
                  ),
                  label: Text(
                    _allFilesAccess == false ? 'Grant access' : 'Open settings',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
        ],

        _SectionCard(
          children: [
            _SectionTitle('Updates'),
            _ToggleRow(
              title: 'Check for updates automatically',
              detail:
                  'On startup, look for a newer Nexus release on GitHub and offer '
                  'to install it.',
              value: mesh.store.autoUpdate,
              onChanged: (v) {
                setState(() => mesh.store.autoUpdate = v);
                mesh.store.save();
              },
            ),
          ],
        ),
        const SizedBox(height: 14),

        _SectionCard(
          children: [
            _SectionTitle('About'),
            _InfoRow(
              title: 'Nexus $appVersion — the mesh',
              detail:
                  'Local-first. No cloud, no account. Everything between paired '
                  'devices is encrypted (AES-GCM) and travels direct.',
              icon: Icons.info_outline_rounded,
            ),
            const Divider(height: 20),
            const _InfoRow(
              title: 'Privacy',
              detail:
                  'Pairing secrets and your data stay on your devices. Nothing is '
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
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: children),
      ),
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
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleMedium
            ?.copyWith(color: NexusColors.accent),
      ),
    );
  }
}

class _ToggleRow extends StatelessWidget {
  final String title;
  final String detail;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _ToggleRow({
    required this.title,
    required this.detail,
    required this.value,
    required this.onChanged,
  });

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
  const _InfoRow({
    required this.title,
    required this.detail,
    required this.icon,
  });

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
