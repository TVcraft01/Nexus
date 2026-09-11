import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, debugPrint;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/brain.dart';
import '../core/distributed_brain.dart';
import '../core/tiny_brain.dart';
import '../core/version.dart';
import '../mesh/mesh_service.dart';
import '../mesh/updater.dart';
import 'nexus_ui.dart';
import 'theme.dart';

class HomeShell extends StatefulWidget {
  final MeshService mesh;
  const HomeShell({super.key, required this.mesh});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  late final LocalBrain? _brain;
  UpdateInfo? _update;
  bool _applying = false;
  String? _updateError;
  bool _checked = false;

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
    if (widget.mesh.store.autoUpdate) unawaited(_checkForUpdates());
  }

  Future<UpdateInfo?> _checkForUpdates({bool force = false}) async {
    if (_checked && !force) return null;
    _checked = true;
    try {
      final info = await Updater.checkForUpdate(currentVersion: appVersion);
      if (mounted && info != null) setState(() => _update = info);
      return info;
    } catch (e) {
      debugPrint('NEXUS updater: $e');
      return null;
    }
  }

  Future<void> _updateNow() async {
    final info = _update;
    if (info == null || _applying) return;
    if (defaultTargetPlatform == TargetPlatform.windows) {
      final url = info.releaseUrl;
      if (url == null || !await launchUrl(Uri.parse(url))) {
        if (mounted) setState(() => _updateError = 'Could not open the release page.');
      }
      return;
    }
    final url = info.downloadUrl;
    if (url == null) return;
    if (mounted) setState(() { _applying = true; _updateError = null; });
    try {
      final path = await Updater.download(url);
      if (path == null) {
        if (mounted) setState(() => _updateError = 'Could not download the update.');
      } else if (defaultTargetPlatform == TargetPlatform.android) {
        final ok = await Updater.applyUpdate(path);
        if (mounted && !ok) setState(() => _updateError = 'Could not open the installer.');
      } else if (defaultTargetPlatform == TargetPlatform.linux) {
        final ok = await Updater.applyUpdate(path, installDir: File(Platform.resolvedExecutable).parent.path);
        if (ok) exit(0);
        if (mounted) setState(() => _updateError = 'The update could not be applied.');
      }
    } catch (e) {
      debugPrint('NEXUS updater: $e');
      if (mounted) setState(() => _updateError = 'The update failed. Check your connection and try again.');
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        NexusExperience(
          mesh: widget.mesh,
          brain: _brain,
          onCheckForUpdate: () => _checkForUpdates(force: true),
        ),
        if (_update != null)
          Positioned(
            left: 16,
            right: 16,
            top: MediaQuery.paddingOf(context).top + 8,
            child: Material(
              color: NexusColors.surfaceElevated,
              elevation: 8,
              borderRadius: BorderRadius.circular(14),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
                child: Row(
                  children: [
                    Icon(
                      _updateError == null ? Icons.system_update_outlined : Icons.error_outline,
                      color: _updateError == null ? NexusColors.accent : NexusColors.danger,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _updateError ?? (_applying ? 'Updating to v${_update!.version}…' : 'Nexus v${_update!.version} is available'),
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                    TextButton(onPressed: _applying ? null : () => setState(() => _update = null), child: const Text('Later')),
                    FilledButton(onPressed: _applying ? null : _updateNow, child: const Text('Update')),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
