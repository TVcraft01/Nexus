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
  late final LocalBrain? _brain;

  UpdateInfo? _update;
  bool _applying = false;
  String? _updateError;
  String? _lastPeerUpdateVersion;
  bool _peerUpdateChecking = false;
  bool _updateChecked = false;

  static const _items = <_NavItem>[
    _NavItem(Icons.devices_rounded, 'Devices'),
    _NavItem(Icons.folder_rounded, 'Files'),
    _NavItem(Icons.chat_bubble_outline_rounded, 'Assistant'),
    _NavItem(Icons.settings_outlined, 'Settings'),
  ];

  @override
  void initState() {
    super.initState();
    _brain = switch (defaultTargetPlatform) {
      TargetPlatform.linux || TargetPlatform.windows || TargetPlatform.macOS =>
        LocalBrain(),
      TargetPlatform.android => DistributedBrain(
        mesh: widget.mesh,
        tiny: TinyBrain(),
      ),
      _ => null,
    };
    if (_brain case final LocalBrain strong when strong is! DistributedBrain) {
      widget.mesh.brain = strong;
    }
    if (widget.mesh.store.autoUpdate) {
      unawaited(_checkForUpdates());
    }
  }

  Future<UpdateInfo?> _checkForUpdates({bool force = false}) async {
    if (_updateChecked && !force) return null;
    _updateChecked = true;
    final info = await Updater.checkForUpdate(currentVersion: appVersion);
    if (!mounted) return info;
    if (info != null) setState(() => _update = info);
    return info;
  }

  void _checkPeerUpdate() {
    if (!widget.mesh.store.autoUpdate) return;
    final version = widget.mesh.latestPeerUpdateVersion;
    if (version == null ||
        Updater.compareVersions(version, appVersion) <= 0 ||
        version == _lastPeerUpdateVersion ||
        _peerUpdateChecking) {
      return;
    }
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

    if (defaultTargetPlatform == TargetPlatform.windows) {
      final url = info.releaseUrl;
      if (url == null || !await launchUrl(Uri.parse(url))) {
        if (mounted) {
          setState(() => _updateError = 'Could not open the release page.');
        }
      }
      return;
    }

    final url = info.downloadUrl;
    if (url == null) return;
    setState(() {
      _applying = true;
      _updateError = null;
    });
    try {
      final path = await Updater.download(url);
      if (path == null) {
        if (mounted) {
          setState(() {
            _applying = false;
            _updateError = 'Could not download the update.';
          });
        }
        return;
      }

      if (defaultTargetPlatform == TargetPlatform.android) {
        final applied = await Updater.applyUpdate(path);
        if (!mounted) return;
        setState(() {
          _applying = false;
          if (!applied) {
            _updateError = 'Could not open the installer. Try GitHub instead.';
          }
        });
        return;
      }

      if (defaultTargetPlatform == TargetPlatform.linux) {
        final dir = File(Platform.resolvedExecutable).parent.path;
        final applied = await Updater.applyUpdate(path, installDir: dir);
        if (applied) {
          exit(0);
        }
        if (mounted) {
          setState(() {
            _applying = false;
            _updateError = 'The update could not be applied.';
          });
        }
        return;
      }

      if (mounted) {
        setState(() {
          _applying = false;
          _updateError = 'Automatic updates are not available here yet.';
        });
      }
    } catch (e) {
      debugPrint('NEXUS updater: $e');
      if (mounted) {
        setState(() {
          _applying = false;
          _updateError = 'The update failed. Check your connection and try again.';
        });
      }
    }
  }

  bool get _desktop =>
      defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.macOS;

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

        final page = IndexedStack(
          index: _index,
          children: [
            DevicesView(mesh: widget.mesh),
            FilesView(mesh: widget.mesh),
            AssistantView(mesh: widget.mesh, brain: _brain),
            SettingsView(
              mesh: widget.mesh,
              onCheckForUpdate: () => _checkForUpdates(force: true),
            ),
          ],
        );

        return Scaffold(
          backgroundColor: NexusColors.bg,
          body: SafeArea(
            bottom: false,
            child: _desktop
                ? Row(
                    children: [
                      _DesktopSidebar(
                        index: _index,
                        items: _items,
                        onSelected: (value) => setState(() => _index = value),
                      ),
                      Expanded(
                        child: Column(
                          children: [
                            if (_update != null)
                              _UpdateBanner(
                                info: _update!,
                                applying: _applying,
                                error: _updateError,
                                onUpdate: _updateNow,
                                onDismiss: () => setState(() => _update = null),
                              ),
                            Expanded(child: page),
                          ],
                        ),
                      ),
                    ],
                  )
                : Column(
                    children: [
                      if (_update != null)
                        _UpdateBanner(
                          info: _update!,
                          applying: _applying,
                          error: _updateError,
                          onUpdate: _updateNow,
                          onDismiss: () => setState(() => _update = null),
                        ),
                      Expanded(child: page),
                    ],
                  ),
          ),
          bottomNavigationBar: _desktop
              ? null
              : _MobileNavigation(
                  index: _index,
                  items: _items,
                  onSelected: (value) => setState(() => _index = value),
                ),
        );
      },
    );
  }
}

class _NavItem {
  final IconData icon;
  final String label;
  const _NavItem(this.icon, this.label);
}

class _DesktopSidebar extends StatelessWidget {
  final int index;
  final List<_NavItem> items;
  final ValueChanged<int> onSelected;

  const _DesktopSidebar({
    required this.index,
    required this.items,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 216,
      decoration: const BoxDecoration(
        color: NexusColors.surface,
        border: Border(right: BorderSide(color: NexusColors.border)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 4, 8, 28),
              child: Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: NexusColors.accent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: const Icon(
                      Icons.hub_outlined,
                      color: NexusColors.accent,
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    'Nexus',
                    style: TextStyle(
                      color: NexusColors.text,
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.25,
                    ),
                  ),
                ],
              ),
            ),
            for (var i = 0; i < items.length; i++) ...[
              _SidebarItem(
                item: items[i],
                selected: i == index,
                onTap: () => onSelected(i),
              ),
              const SizedBox(height: 4),
            ],
            const Spacer(),
            Text(
              'Your devices, one system',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _SidebarItem extends StatelessWidget {
  final _NavItem item;
  final bool selected;
  final VoidCallback onTap;

  const _SidebarItem({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? NexusColors.accent.withValues(alpha: 0.11) : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          height: 44,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Icon(
                  item.icon,
                  size: 20,
                  color: selected ? NexusColors.accent : NexusColors.muted,
                ),
                const SizedBox(width: 12),
                Text(
                  item.label,
                  style: TextStyle(
                    color: selected ? NexusColors.text : NexusColors.muted,
                    fontSize: 14,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MobileNavigation extends StatelessWidget {
  final int index;
  final List<_NavItem> items;
  final ValueChanged<int> onSelected;

  const _MobileNavigation({
    required this.index,
    required this.items,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return NavigationBar(
      selectedIndex: index,
      onDestinationSelected: onSelected,
      destinations: [
        for (final item in items)
          NavigationDestination(icon: Icon(item.icon), label: item.label),
      ],
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
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(
        color: error == null
            ? NexusColors.surfaceHi
            : NexusColors.danger.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: NexusColors.border),
      ),
      child: Row(
        children: [
          Icon(
            error == null ? Icons.system_update_outlined : Icons.error_outline,
            size: 18,
            color: error == null ? NexusColors.accent : NexusColors.danger,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              error ?? (applying ? 'Updating to v${info.version}…' : 'Nexus v${info.version} is available'),
              style: const TextStyle(color: NexusColors.text, fontSize: 13),
            ),
          ),
          TextButton(onPressed: applying ? null : onDismiss, child: const Text('Later')),
          FilledButton(
            onPressed: applying ? null : onUpdate,
            child: Text(
              windows
                  ? 'View update'
                  : defaultTargetPlatform == TargetPlatform.android
                      ? 'Install'
                      : 'Update',
            ),
          ),
        ],
      ),
    );
  }
}
