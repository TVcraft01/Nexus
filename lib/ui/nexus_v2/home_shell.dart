import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/brain.dart';
import '../../core/distributed_brain.dart';
import '../../core/tiny_brain.dart';
import '../../core/version.dart';
import '../../mesh/mesh_service.dart';
import '../../mesh/updater.dart';
import 'assistant_view.dart';
import 'devices_view.dart';
import 'files_view.dart';
import 'nexus_orb.dart';
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

  /// Checks for an update and hands the result back so callers (Settings'
  /// own "Check" button) can report it themselves; the banner state is set
  /// here as well, so both entry points share one code path.
  Future<UpdateInfo?> _checkForUpdate({bool force = false}) async {
    if (_checking && !force) return _update;
    setState(() => _checking = true);
    UpdateInfo? info;
    try {
      info = await Updater.checkForUpdate(currentVersion: appVersion);
      if (mounted) {
        setState(() {
          _update = info;
          _updateError = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _updateError = 'Could not check for updates.');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
    return info;
  }

  bool get _desktop => switch (defaultTargetPlatform) {
        TargetPlatform.linux || TargetPlatform.windows || TargetPlatform.macOS => true,
        _ => false,
      };

  Widget _assistant() => NexusAssistantPresence(
        brain: _brain,
        child: NexusV2AssistantView(mesh: widget.mesh, brain: _brain),
      );

  @override
  Widget build(BuildContext context) {
    final views = [
      NexusV2DevicesView(mesh: widget.mesh),
      NexusV2FilesView(mesh: widget.mesh),
      _assistant(),
      NexusV2SettingsView(
        mesh: widget.mesh,
        onCheckForUpdate: () => _checkForUpdate(force: true),
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final rail = _desktop && constraints.maxWidth >= 720;
        final extended = rail && constraints.maxWidth >= 1080;
        return Scaffold(
          body: Column(
            children: [
              if (_update != null || _updateError != null)
                _UpdateNotice(
                  update: _update,
                  error: _updateError,
                  checking: _checking,
                  onUpdate: () => _applyUpdate(_update!),
                  onDismiss: () => setState(() {
                    _update = null;
                    _updateError = null;
                  }),
                ),
              Expanded(
                child: Row(
                  children: [
                    if (rail)
                      NavigationRail(
                        selectedIndex: _index,
                        onDestinationSelected: (value) => setState(() => _index = value),
                        extended: extended,
                        minWidth: 72,
                        minExtendedWidth: 210,
                        leading: Padding(
                          padding: const EdgeInsets.fromLTRB(8, 14, 8, 18),
                          child: extended
                              ? const Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    'Nexus',
                                    style: TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: -0.5,
                                    ),
                                  ),
                                )
                              : const NexusOrb(size: 34),
                        ),
                        destinations: const [
                          NavigationRailDestination(icon: Icon(Icons.devices_outlined), selectedIcon: Icon(Icons.devices_rounded), label: Text('Devices')),
                          NavigationRailDestination(icon: Icon(Icons.folder_outlined), selectedIcon: Icon(Icons.folder_rounded), label: Text('Files')),
                          NavigationRailDestination(icon: Icon(Icons.auto_awesome_outlined), selectedIcon: Icon(Icons.auto_awesome_rounded), label: Text('Assistant')),
                          NavigationRailDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings_rounded), label: Text('Settings')),
                        ],
                      ),
                    if (rail) const VerticalDivider(width: 1),
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 180),
                        switchInCurve: Curves.easeOut,
                        switchOutCurve: Curves.easeIn,
                        child: KeyedSubtree(key: ValueKey(_index), child: views[_index]),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          bottomNavigationBar: rail
              ? null
              : NavigationBar(
                  selectedIndex: _index,
                  onDestinationSelected: (value) => setState(() => _index = value),
                  destinations: const [
                    NavigationDestination(icon: Icon(Icons.devices_outlined), selectedIcon: Icon(Icons.devices_rounded), label: 'Devices'),
                    NavigationDestination(icon: Icon(Icons.folder_outlined), selectedIcon: Icon(Icons.folder_rounded), label: 'Files'),
                    NavigationDestination(icon: Icon(Icons.auto_awesome_outlined), selectedIcon: Icon(Icons.auto_awesome_rounded), label: 'Assistant'),
                    NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings_rounded), label: 'Settings'),
                  ],
                ),
        );
      },
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
        return;
      }
      if (defaultTargetPlatform == TargetPlatform.linux) {
        final dir = File(Platform.resolvedExecutable).parent.path;
        if (await Updater.applyUpdate(path, installDir: dir)) exit(0);
      }
    } catch (_) {
      if (mounted) setState(() => _updateError = 'The update could not be applied.');
    }
  }
}

class NexusAssistantPresence extends StatelessWidget {
  final LocalBrain? brain;
  final Widget child;

  const NexusAssistantPresence({super.key, required this.brain, required this.child});

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 560;
    final available = brain != null;
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.only(top: compact ? 2 : 6),
          child: Column(
            children: [
              NexusOrb(size: compact ? 64 : 78),
              const SizedBox(height: 4),
              Text(
                available ? 'Ready' : 'Assistant',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
        ),
        Expanded(child: child),
      ],
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
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(
            children: [
              Icon(error == null ? Icons.system_update_outlined : Icons.error_outline, size: 20),
              const SizedBox(width: 10),
              Expanded(child: Text(error ?? (checking ? 'Checking for updates…' : 'Nexus v${update!.version} is ready.'))),
              if (!checking && hasUpdate) TextButton(onPressed: onUpdate, child: const Text('Update')),
              TextButton(onPressed: onDismiss, child: const Text('Later')),
            ],
          ),
        ),
      ),
    );
  }
}
