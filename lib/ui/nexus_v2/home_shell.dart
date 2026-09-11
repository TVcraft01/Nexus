import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/version.dart';
import '../../mesh/mesh_service.dart';
import '../../mesh/updater.dart';
import 'assistant_view.dart';
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

  @override
  void initState() {
    super.initState();
    if (widget.mesh.store.autoUpdate) unawaited(_checkForUpdate());
  }

  Future<void> _checkForUpdate({bool force = false}) async {
    if (_checking && !force) return;
    setState(() => _checking = true);
    try {
      final info = await Updater.checkForUpdate(currentVersion: appVersion);
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
  }

  bool get _desktop => switch (defaultTargetPlatform) {
        TargetPlatform.linux || TargetPlatform.windows || TargetPlatform.macOS => true,
        _ => false,
      };

  @override
  Widget build(BuildContext context) {
    final views = [
      NexusV2DevicesView(mesh: widget.mesh),
      NexusV2FilesView(mesh: widget.mesh),
      NexusV2AssistantView(mesh: widget.mesh),
      NexusV2SettingsView(mesh: widget.mesh, onCheckForUpdate: () => _checkForUpdate(force: true)),
    ];

    return Scaffold(
      body: Column(
        children: [
          if (_update != null || _updateError != null)
            _UpdateNotice(
              update: _update,
              error: _updateError,
              checking: _checking,
              onUpdate: () => _applyUpdate(_update!),
              onDismiss: () => setState(() { _update = null; _updateError = null; }),
            ),
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
      bottomNavigationBar: _desktop
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
      drawer: _desktop
          ? NavigationDrawer(
              selectedIndex: _index,
              onDestinationSelected: (value) {
                Navigator.pop(context);
                setState(() => _index = value);
              },
              children: const [
                Padding(padding: EdgeInsets.fromLTRB(28, 28, 24, 18), child: Text('Nexus', style: TextStyle(fontSize: 25, fontWeight: FontWeight.w700))),
                NavigationDrawerDestination(icon: Icon(Icons.devices_outlined), selectedIcon: Icon(Icons.devices_rounded), label: Text('Devices')),
                NavigationDrawerDestination(icon: Icon(Icons.folder_outlined), selectedIcon: Icon(Icons.folder_rounded), label: Text('Files')),
                NavigationDrawerDestination(icon: Icon(Icons.auto_awesome_outlined), selectedIcon: Icon(Icons.auto_awesome_rounded), label: Text('Assistant')),
                NavigationDrawerDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings_rounded), label: Text('Settings')),
              ],
            )
          : null,
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
          child: Row(children: [
            Icon(error == null ? Icons.system_update_outlined : Icons.error_outline, size: 20),
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
