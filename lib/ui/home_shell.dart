import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, debugPrint;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/brain.dart';
import '../core/device_actions.dart' show gapAnswer;
import '../core/distributed_brain.dart';
import '../core/tiny_brain.dart';
import '../core/version.dart';
import '../mesh/mesh_service.dart';
import '../mesh/updater.dart';
import 'assistant_view.dart';
import 'devices_view.dart';
import 'files_view.dart';
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

  /// The conversational brain, one per platform: desktops run a strong
  /// local model (Ollama) and answer brain asks from paired phones; the
  /// phone runs a tiny on-device model for everyday questions and escalates
  /// the rest over the mesh to the PC — one assistant living everywhere,
  /// fully offline.
  late final LocalBrain? _brain;

  UpdateInfo? _update;
  bool _applying = false;
  String? _updateError;
  String? _lastPeerUpdateVersion;
  bool _peerUpdateChecking = false;
  bool _updateChecked = false;

  @override
  void initState() {
    super.initState();
    _brain = switch (defaultTargetPlatform) {
      TargetPlatform.linux ||
      TargetPlatform.windows ||
      TargetPlatform.macOS => LocalBrain(),
      TargetPlatform.android => DistributedBrain(
        mesh: widget.mesh,
        tiny: TinyBrain(),
      ),
      _ => null,
    };
    // Only a device with its own strong model answers delegated brain
    // questions — the phone's distributed brain ASKS, it never serves (a
    // served question must not escalate back, or the mesh would bounce it
    // forever).
    if (_brain case final LocalBrain strong when strong is! DistributedBrain) {
      widget.mesh.brain = strong;
    }
    // Check for updates on startup when auto-update is enabled. Updater decides
    // whether this platform has a safe, matching release asset.
    if (widget.mesh.store.autoUpdate) {
      unawaited(_checkForUpdates());
    }
  }

  Future<UpdateInfo?> _checkForUpdates({bool force = false}) async {
    if (_updateChecked && !force) return null;
    _updateChecked = true;
    final info = await Updater.checkForUpdate(currentVersion: appVersion);
    if (info != null && mounted) {
      setState(() => _update = info);
    }
    return info;
  }

  void _checkPeerUpdate() {
    if (!widget.mesh.store.autoUpdate) return;
    final version = widget.mesh.latestPeerUpdateVersion;
    if (version == null ||
        Updater.compareVersions(version, appVersion) <= 0 ||
        version == _lastPeerUpdateVersion) {
      return;
    }
    if (_peerUpdateChecking) return;
    _peerUpdateChecking = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        _peerUpdateChecking = false;
        return;
      }
      unawaited(
        _checkForUpdates(force: true)
            .then((info) {
              if (info != null) _lastPeerUpdateVersion = version;
            })
            .whenComplete(() => _peerUpdateChecking = false),
      );
    });
  }

  Future<void> _updateNow() async {
    final info = _update;
    if (info == null || _applying) return;

    // Windows currently uses the normal release package rather than trying to
    // replace a running executable in-place. Open the exact release page.
    if (defaultTargetPlatform == TargetPlatform.windows) {
      final url = info.releaseUrl;
      if (url == null || !await launchUrl(Uri.parse(url))) {
        setState(() => _updateError = 'Could not open the GitHub release page.');
      }
      return;
    }

    if (info.downloadUrl == null) return;
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
      } else if (defaultTargetPlatform == TargetPlatform.linux) {
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
      } else {
        // Windows and macOS have no in-app installer wired up. Name what the
        // user cannot do and where it does work, like every other gap answer.
        setState(() {
          _applying = false;
          _updateError = gapAnswer(
            'install updates from inside the app',
            'Linux and your phone',
          );
        });
      }
    } catch (e) {
      debugPrint('NEXUS updater: ${e.runtimeType}: $e');
      setState(() {
        _applying = false;
        _updateError = 'The update failed. Check your connection and try again.';
      });
    }
  }

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
      icon: Icon(Icons.forum_rounded),
      selectedIcon: Icon(Icons.forum_rounded),
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
        _checkPeerUpdate();
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
          AssistantView(mesh: widget.mesh, brain: _brain),
          SettingsView(
            mesh: widget.mesh,
            onCheckForUpdate: () => _checkForUpdates(force: true),
          ),
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
              : SafeArea(bottom: false, child: content),
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
                      icon: Icon(Icons.forum_rounded),
                      label: 'Assistant',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.tune_rounded),
                      label: 'Settings',
                    ),
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
    final windows = defaultTargetPlatform == TargetPlatform.windows;
    return MaterialBanner(
      leading: Icon(
        error == null ? Icons.system_update_rounded : Icons.error_outline_rounded,
      ),
      content: Text(
        error ??
            (applying
                ? 'Updating to v${info.version}…'
                : windows
                    ? 'Nexus v${info.version} is available'
                    : 'Nexus v${info.version} is available'),
      ),
      actions: [
        TextButton(
          onPressed: applying ? null : onDismiss,
          child: const Text('Later'),
        ),
        FilledButton(
          onPressed: applying ? null : onUpdate,
          child: Text(
            windows
                ? 'View update'
                : defaultTargetPlatform == TargetPlatform.android
                    ? 'Update & install'
                    : 'Update & restart',
          ),
        ),
      ],
    );
  }
}
