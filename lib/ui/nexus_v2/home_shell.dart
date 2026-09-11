import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/brain.dart';
import '../../core/distributed_brain.dart';
import '../../core/tiny_brain.dart';
import '../../core/version.dart';
import '../../mesh/mesh_service.dart';
import '../../mesh/updater.dart';
import 'assistant_screen.dart';
import 'cable_pair_page.dart';
import 'design_system.dart';
import 'devices_view.dart';
import 'files_view.dart';
import 'settings_view.dart';

class NexusV2HomeShell extends StatefulWidget {
  final MeshService mesh;
  const NexusV2HomeShell({super.key, required this.mesh});

  @override
  State<NexusV2HomeShell> createState() => _NexusV2HomeShellState();
}

class _NexusV2HomeShellState extends State<NexusV2HomeShell> {
  int _index = 0;
  UpdateInfo? _update;
  bool _checking = false;
  String? _updateError;
  late final LocalBrain? _brain;

  @override
  void initState() {
    super.initState();
    _brain = switch (defaultTargetPlatform) {
      TargetPlatform.linux || TargetPlatform.windows || TargetPlatform.macOS => LocalBrain(),
      TargetPlatform.android => DistributedBrain(mesh: widget.mesh, tiny: TinyBrain()),
      _ => null,
    };
    if (_brain case final LocalBrain strong when strong is! DistributedBrain) {
      widget.mesh.brain = strong;
    }
    if (widget.mesh.store.autoUpdate) unawaited(_checkForUpdate());
  }

  Future<void> _checkForUpdate({bool force = false}) async {
    if (_checking && !force) return;
    setState(() => _checking = true);
    try {
      final info = await Updater.checkForUpdate(currentVersion: appVersion);
      if (mounted) setState(() { _update = info; _updateError = null; });
    } catch (_) {
      if (mounted) setState(() => _updateError = 'Could not check for updates.');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  bool get _desktop => switch (defaultTargetPlatform) {
        TargetPlatform.linux || TargetPlatform.windows || TargetPlatform.macOS => true,
        _ => false,
      };

  @override
  Widget build(BuildContext context) {
    final destinations = const [
      NavigationDestination(icon: Icon(Icons.devices_outlined), selectedIcon: Icon(Icons.devices_rounded), label: 'Devices'),
      NavigationDestination(icon: Icon(Icons.folder_outlined), selectedIcon: Icon(Icons.folder_rounded), label: 'Files'),
      NavigationDestination(icon: Icon(Icons.auto_awesome_outlined), selectedIcon: Icon(Icons.auto_awesome_rounded), label: 'Assistant'),
      NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings_rounded), label: 'Settings'),
    ];
    final views = [
      NexusV2DevicesView(mesh: widget.mesh),
      NexusV2FilesView(mesh: widget.mesh),
      NexusV2AssistantScreen(mesh: widget.mesh, brain: _brain),
      NexusV2SettingsView(mesh: widget.mesh, onCheckForUpdate: () => _checkForUpdate(force: true)),
    ];

    final content = Column(
      children: [
        if (_update != null || _updateError != null)
          _UpdateNotice(
            update: _update,
            error: _updateError,
            checking: _checking,
            onUpdate: () => _applyUpdate(_update!),
            onDismiss: () => setState(() { _update = null; _updateError = null; }),
          ),
        Expanded(child: views[_index]),
      ],
    );

    return Scaffold(
      body: _desktop
          ? Row(
              children: [
                Container(
                  width: 208,
                  color: Theme.of(context).scaffoldBackgroundColor,
                  padding: const EdgeInsets.fromLTRB(12, 24, 12, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Padding(
                        padding: EdgeInsets.fromLTRB(14, 0, 14, 28),
                        child: Text('Nexus', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700)),
                      ),
                      _SideNavItem(icon: Icons.devices_outlined, label: 'Devices', selected: _index == 0, onTap: () => setState(() => _index = 0)),
                      _SideNavItem(icon: Icons.folder_outlined, label: 'Files', selected: _index == 1, onTap: () => setState(() => _index = 1)),
                      _SideNavItem(icon: Icons.auto_awesome_outlined, label: 'Assistant', selected: _index == 2, onTap: () => setState(() => _index = 2)),
                      _SideNavItem(icon: Icons.settings_outlined, label: 'Settings', selected: _index == 3, onTap: () => setState(() => _index = 3)),
                      const Spacer(),
                      if (Theme.of(context).brightness == Brightness.dark)
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 14),
                          child: Text('Nexus', style: TextStyle(fontSize: 12, color: NexusV2Colors.tertiaryText)),
                        ),
                    ],
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1120),
                      child: content,
                    ),
                  ),
                ),
              ],
            )
          : SafeArea(bottom: false, child: content),
      bottomNavigationBar: _desktop
          ? null
          : NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: (value) => setState(() => _index = value),
              destinations: destinations,
            ),
    );
  }

  Future<void> _applyUpdate(UpdateInfo info) async {
    if (info.downloadUrl == null) return;
    if (defaultTargetPlatform == TargetPlatform.windows) {
      final url = info.releaseUrl;
      if (url != null) await launchUrl(Uri.parse(url));
      return;
    }
    try {
      final path = await Updater.download(info.downloadUrl!);
      if (path == null || !mounted) return;
      if (defaultTargetPlatform == TargetPlatform.android) {
        await Updater.applyUpdate(path);
      } else if (defaultTargetPlatform == TargetPlatform.linux) {
        final dir = File(Platform.resolvedExecutable).parent.path;
        if (await Updater.applyUpdate(path, installDir: dir)) exit(0);
      }
    } catch (_) {
      if (mounted) setState(() => _updateError = 'The update could not be applied.');
    }
  }
}

class _SideNavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _SideNavItem({required this.icon, required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = selected ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: selected ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.12) : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: SizedBox(
            height: 44,
            child: Row(children: [
              const SizedBox(width: 14),
              Icon(icon, size: 21, color: color),
              const SizedBox(width: 12),
              Text(label, style: TextStyle(color: selected ? Theme.of(context).colorScheme.onSurface : color, fontWeight: selected ? FontWeight.w600 : FontWeight.w500)),
            ]),
          ),
        ),
      ),
    );
  }
}

class _UpdateNotice extends StatelessWidget {
  final UpdateInfo? update;
  final String? error;
  final bool checking;
  final VoidCallback onUpdate;
  final VoidCallback onDismiss;
  const _UpdateNotice({required this.update, required this.error, required this.checking, required this.onUpdate, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final hasUpdate = update != null;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 7, 7, 7),
          child: Row(children: [
            Icon(error == null ? Icons.system_update_outlined : Icons.error_outline, size: 19),
            const SizedBox(width: 10),
            Expanded(child: Text(error ?? (checking ? 'Checking for updates…' : 'Nexus v${update!.version} is ready.'))),
            if (!checking && hasUpdate) TextButton(onPressed: onUpdate, child: const Text('Update')),
            TextButton(onPressed: onDismiss, child: const Text('Later')),
          ]),
        ),
      ),
    );
  }
}
