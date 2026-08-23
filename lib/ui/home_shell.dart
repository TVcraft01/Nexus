import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, debugPrint;
import 'package:flutter/material.dart';

import '../core/version.dart';
import '../mesh/mesh_service.dart';
import '../mesh/updater.dart';
import 'assistant_view.dart';
import 'devices_view.dart';
import 'settings_view.dart';
import 'theme.dart';

class HomeShell extends StatefulWidget {
  final MeshService mesh;
  const HomeShell({super.key, required this.mesh});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;
  ClipEntry? _lastShown;

  UpdateInfo? _update;
  bool _applying = false;
  String? _updateError;
  bool _updateChecked = false;

  @override
  void initState() {
    super.initState();
    // Auto-update currently works on Linux desktop; other platforms check
    // later (Android updates via APK).
    if (defaultTargetPlatform == TargetPlatform.linux) {
      unawaited(_checkForUpdates());
    }
  }

  Future<void> _checkForUpdates() async {
    if (_updateChecked) return;
    _updateChecked = true;
    final info = await Updater.checkForUpdate(currentVersion: appVersion);
    if (info != null && mounted) {
      setState(() => _update = info);
    }
  }

  Future<void> _updateNow() async {
    final info = _update;
    if (info == null || info.downloadUrl == null || _applying) return;
    setState(() {
      _applying = true;
      _updateError = null;
    });
    try {
      final path = await Updater.download(info.downloadUrl!);
      if (path == null) {
        setState(() {
          _applying = false;
          _updateError = 'Could not download the update. Check your connection and try again.';
        });
        return;
      }
      final installDir = File(Platform.resolvedExecutable).parent.path;
      final applied = await Updater.applyUpdate(path, installDir);
      if (applied) {
        // The new version relaunches itself; exit this one.
        exit(0);
      }
      setState(() {
        _applying = false;
        _updateError = 'The update could not be applied. Run update.sh to update manually.';
      });
    } catch (e) {
      debugPrint('NEXUS updater: ${e.runtimeType}: $e');
      setState(() {
        _applying = false;
        _updateError = 'The update failed. Run update.sh to update manually.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.mesh,
      builder: (context, _) {
        // Show a friendly banner the moment a clip arrives from another device.
        final incoming = widget.mesh.lastIncomingClip;
        if (incoming != null && incoming != _lastShown) {
          _lastShown = incoming;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('Copied on ${incoming.fromName ?? 'another device'}: '
                  '“${incoming.text.length > 60 ? '${incoming.text.substring(0, 60)}…' : incoming.text}”'),
              action: SnackBarAction(
                label: 'Paste here',
                textColor: Theme.of(context).colorScheme.primary,
                onPressed: () => widget.mesh.clipboard.writeText(incoming.text),
              ),
            ));
          });
        }

        final views = [
          DevicesView(mesh: widget.mesh),
          const AssistantView(),
          SettingsView(mesh: widget.mesh),
        ];

        return Scaffold(
          body: Column(
            children: [
              if (_update != null)
                _UpdateBanner(
                  info: _update!,
                  applying: _applying,
                  error: _updateError,
                  onUpdate: _updateNow,
                  onDismiss: () => setState(() => _update = null),
                ),
              Expanded(child: IndexedStack(index: _index, children: views)),
            ],
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: (i) => setState(() => _index = i),
            destinations: const [
              NavigationDestination(icon: Icon(Icons.devices_rounded), label: 'Devices'),
              NavigationDestination(icon: Icon(Icons.mic_none_rounded), label: 'Assistant'),
              NavigationDestination(icon: Icon(Icons.tune_rounded), label: 'Settings'),
            ],
          ),
        );
      },
    );
  }
}

class _UpdateBanner extends StatelessWidget {
  final UpdateInfo info;
  final bool applying;
  final String? error;
  final VoidCallback onUpdate;
  final VoidCallback onDismiss;

  const _UpdateBanner({
    required this.info,
    required this.applying,
    required this.error,
    required this.onUpdate,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      decoration: BoxDecoration(
        color: NexusColors.accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: NexusColors.accent.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          const Icon(Icons.system_update_alt_rounded, size: 20, color: NexusColors.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  applying
                      ? 'Updating to v${info.version}…'
                      : 'Nexus v${info.version} is available',
                  style: const TextStyle(color: NexusColors.text, fontWeight: FontWeight.w600, fontSize: 13.5),
                ),
                if (error != null)
                  Text(error!, style: const TextStyle(color: NexusColors.danger, fontSize: 12)),
              ],
            ),
          ),
          if (!applying)
            TextButton(onPressed: onUpdate, child: const Text('Update & restart'))
          else
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          IconButton(
            onPressed: applying ? null : onDismiss,
            icon: const Icon(Icons.close_rounded, size: 18, color: NexusColors.muted),
          ),
        ],
      ),
    );
  }
}
