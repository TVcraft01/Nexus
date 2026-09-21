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
import 'assistant_controller.dart';
import 'assistant_view.dart';
import 'desktop_panel.dart';
import 'devices_view.dart';
import 'files_view.dart';
import 'nexus_orb.dart';
import 'settings_view.dart';

/// One navigation entry, in one list.
///
/// The phone's bottom bar and the desktop rail are two layouts of the same
/// thing: same order, same names, same icons, same words for the user. Only
/// the layout differs — a phone is not a shrunken desktop, and the desktop is
/// not a stretched phone.
class NexusV2Destination {
  const NexusV2Destination({
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

const List<NexusV2Destination> kNexusV2Destinations = [
  NexusV2Destination(
    label: 'Devices',
    icon: Icons.devices_outlined,
    selectedIcon: Icons.devices_rounded,
  ),
  NexusV2Destination(
    label: 'Files',
    icon: Icons.folder_outlined,
    selectedIcon: Icons.folder_rounded,
  ),
  // The Assistant is the tab that *is* Nexus, so it gets a conversation glyph
  // rather than a filled sparkle: the sparkle claimed the row even when
  // another destination was selected, and this is the one part of the app you
  // talk to rather than operate.
  NexusV2Destination(
    label: 'Assistant',
    icon: Icons.chat_bubble_outline_rounded,
    selectedIcon: Icons.chat_bubble_rounded,
  ),
  NexusV2Destination(
    label: 'Settings',
    icon: Icons.settings_outlined,
    selectedIcon: Icons.settings_rounded,
  ),
];

/// Where a fresh start lands: the assistant, on both layouts.
///
/// A person opening Nexus is opening their assistant; the device list is
/// something they visit. Landing on Devices made the app read as a control
/// panel with an AI tab.
const int kNexusV2AssistantIndex = 2;

/// The width at which a window is a desktop: a rail replaces the bottom bar.
const double kNexusV2RailFrom = 720;

/// The width at which there is room for an extended rail *and* the assistant's
/// status panel together — 210 + 520 + 288 leaves room to spare, so the extra
/// surface never squeezes the conversation's readable band.
const double kNexusV2PanelFrom = 1080;

class NexusV2HomeShell extends StatefulWidget {
  final MeshService mesh;
  const NexusV2HomeShell({super.key, required this.mesh});

  @override
  State<NexusV2HomeShell> createState() => _NexusV2HomeShellState();
}

class _NexusV2HomeShellState extends State<NexusV2HomeShell> {
  int _index = kNexusV2AssistantIndex;
  UpdateInfo? _update;
  bool _checking = false;
  String? _updateError;
  late final LocalBrain? _brain;

  /// The assistant's state, owned here rather than by the assistant screen:
  /// the desktop layout reads the same instance for its status panel, so both
  /// widgets report one state rather than two copies of it.
  late final NexusAssistantController _assistant;

  @override
  void dispose() {
    _assistant.dispose();
    super.dispose();
  }

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
    _assistant = NexusAssistantController(mesh: widget.mesh, brain: _brain);
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

  @override
  Widget build(BuildContext context) {
    final views = [
      NexusV2DevicesView(mesh: widget.mesh),
      NexusV2FilesView(mesh: widget.mesh),
      NexusV2AssistantView(controller: _assistant),
      NexusV2SettingsView(
        mesh: widget.mesh,
        onCheckForUpdate: () => _checkForUpdate(force: true),
      ),
    ];

    // The keyboard owns the bottom edge while it is open: the navigation bar
    // steps aside so the composer sits directly above the keys, in the thumb
    // zone the user is already looking at.
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final rail = _desktop && constraints.maxWidth >= kNexusV2RailFrom;
        final wide = rail && constraints.maxWidth >= kNexusV2PanelFrom;
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
                        extended: wide,
                        minWidth: 72,
                        minExtendedWidth: 210,
                        leading: Padding(
                          padding: const EdgeInsets.fromLTRB(8, 14, 8, 18),
                          child: wide
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
                              // The rail's globe is the app's mark, not a status
                              // readout: it names Nexus rather than reporting
                              // what Nexus is doing, and the assistant screen
                              // is where the state lives.
                              : const NexusOrb(
                                  state: NexusOrbState.idle,
                                  size: 34,
                                  semanticLabel: 'Nexus',
                                ),
                        ),
                        destinations: [
                          for (final destination in kNexusV2Destinations)
                            NavigationRailDestination(
                              icon: Icon(destination.icon),
                              selectedIcon: Icon(destination.selectedIcon),
                              label: Text(destination.label),
                            ),
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
                    // A wide window gets a second surface instead of a wider
                    // one: the assistant's link state and last action, beside
                    // the conversation rather than on top of it.
                    if (wide) ...[
                      const VerticalDivider(width: 1),
                      SizedBox(
                        width: NexusV2DesktopPanel.width,
                        child: NexusV2DesktopPanel(
                          controller: _assistant,
                          mesh: widget.mesh,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          bottomNavigationBar: rail || keyboardOpen
              ? null
              : NavigationBar(
                  selectedIndex: _index,
                  onDestinationSelected: (value) => setState(() => _index = value),
                  destinations: [
                    for (final destination in kNexusV2Destinations)
                      NavigationDestination(
                        icon: Icon(destination.icon),
                        selectedIcon: Icon(destination.selectedIcon),
                        label: destination.label,
                        tooltip: destination.label,
                      ),
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
