import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, debugPrint;
import 'package:flutter/material.dart';

import '../core/version.dart';
import '../mesh/mesh_service.dart';
import '../mesh/updater.dart';
import 'assistant_view.dart';
import 'devices_view.dart';
import 'files_view.dart';
import 'pair_sheet.dart';
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
    // Check for updates on startup when auto-update is enabled and the
    // platform supports it (Linux + Android).
    if (widget.mesh.store.autoUpdate &&
        (defaultTargetPlatform == TargetPlatform.linux ||
            defaultTargetPlatform == TargetPlatform.android)) {
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

      if (defaultTargetPlatform == TargetPlatform.android) {
        // Hand the APK to the system installer; the user confirms there.
        final applied = await Updater.applyUpdate(path);
        setState(() {
          _applying = false;
          if (!applied) {
            _updateError = 'Could not open the installer. Try downloading from GitHub manually.';
          }
        });
      } else {
        // Linux: extract, swap, and relaunch.
        final installDir = File(Platform.resolvedExecutable).parent.path;
        final applied = await Updater.applyUpdate(path, installDir: installDir);
        if (applied) {
          exit(0);
        }
        setState(() {
          _applying = false;
          _updateError = 'The update could not be applied. Run update.sh to update manually.';
        });
      }
    } catch (e) {
      debugPrint('NEXUS updater: ${e.runtimeType}: $e');
      setState(() {
        _applying = false;
        _updateError =
            'The update failed. Check your connection and try again.';
      });
    }
  }

  /// Desktop screens are wide — a stretched bottom bar looks wrong there, so
  /// they get a left rail instead; phones keep the familiar bottom bar.
  bool get _isDesktop =>
      defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.macOS;

  static const _destinations = [
    NavigationRailDestination(
      icon: Icon(Icons.devices_rounded),
      selectedIcon: Icon(Icons.devices_rounded),
      label: Text('Devices'),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.folder_rounded),
      selectedIcon: Icon(Icons.folder_rounded),
      label: Text('Files'),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.mic_none_rounded),
      selectedIcon: Icon(Icons.mic_none_rounded),
      label: Text('Assistant'),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.tune_rounded),
      selectedIcon: Icon(Icons.tune_rounded),
      label: Text('Settings'),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.mesh,
      builder: (context, _) {
        // Show a friendly notification the moment a clip arrives from another
        // device — the text is already on the clipboard, this just says so.
        final incoming = widget.mesh.lastIncomingClip;
        if (incoming != null && incoming != _lastShown) {
          _lastShown = incoming;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Copied on ${incoming.fromName ?? 'another device'}: '
                  '"${incoming.text.length > 60 ? '${incoming.text.substring(0, 60)}…' : incoming.text}"',
                ),
              ),
            );
          });
        }

        final views = [
          DevicesView(mesh: widget.mesh),
          FilesView(mesh: widget.mesh),
          const AssistantView(),
          SettingsView(mesh: widget.mesh),
        ];

        final content = Column(
          children: [
            if (_update != null)
              _UpdateBanner(
                info: _update!,
                applying: _applying,
                error: _updateError,
                onUpdate: _updateNow,
                onDismiss: () => setState(() => _update = null),
              ),
            Expanded(
              child: IndexedStack(index: _index, children: views),
            ),
          ],
        );

        return Scaffold(
          body: _isDesktop
              ? Row(
                  children: [
                    NavigationRail(
                      selectedIndex: _index,
                      onDestinationSelected: (i) => setState(() => _index = i),
                      labelType: NavigationRailLabelType.all,
                      groupAlignment: -0.8,
                      backgroundColor: NexusColors.surface,
                      destinations: _destinations,
                    ),
                    const VerticalDivider(width: 1),
                    // Desktop windows can be very wide — cap the content
                    // column so cards and text don't stretch across the
                    // whole monitor.
                    Expanded(
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 980),
                          child: content,
                        ),
                      ),
                    ),
                  ],
                )
              : SafeArea(top: true, bottom: false, child: content),
          bottomNavigationBar: _isDesktop
              ? null
              : NavigationBar(
                  selectedIndex: _index,
                  onDestinationSelected: (i) => setState(() => _index = i),
                  destinations: const [
                    NavigationDestination(
                      icon: Icon(Icons.devices_rounded),
                      label: 'Devices',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.folder_rounded),
                      label: 'Files',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.mic_none_rounded),
                      label: 'Assistant',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.tune_rounded),
                      label: 'Settings',
                    ),
                  ],
                ),
          // A + button to pair a new device, on every platform.
          floatingActionButton: FloatingActionButton(
            onPressed: () => showPairSheet(context, mesh: widget.mesh),
            tooltip: 'Pair a new device',
            backgroundColor: NexusColors.accent,
            foregroundColor: const Color(0xFF06251F),
            child: const Icon(Icons.add_rounded),
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
          const Icon(
            Icons.system_update_alt_rounded,
            size: 20,
            color: NexusColors.accent,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  applying
                      ? 'Updating to v${info.version}…'
                      : 'Nexus v${info.version} is available',
                  style: const TextStyle(
                    color: NexusColors.text,
                    fontWeight: FontWeight.w600,
                    fontSize: 13.5,
                  ),
                ),
                if (error != null)
                  Text(
                    error!,
                    style: const TextStyle(
                      color: NexusColors.danger,
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
          ),
          if (!applying)
            TextButton(
              onPressed: onUpdate,
              child: Text(
                defaultTargetPlatform == TargetPlatform.android
                    ? 'Update & install'
                    : 'Update & restart',
              ),
            )
          else
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          IconButton(
            onPressed: applying ? null : onDismiss,
            icon: const Icon(
              Icons.close_rounded,
              size: 18,
              color: NexusColors.muted,
            ),
          ),
        ],
      ),
    );
  }
}
