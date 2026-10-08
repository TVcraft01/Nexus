import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart' show CupertinoTabBar;
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, debugPrint;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'components/nexus_ui.dart' show NexusPressable;

import '../core/brain.dart';
import '../core/device_actions.dart' show gapAnswer;
import '../core/distributed_brain.dart';
import '../core/tiny_brain.dart';
import '../core/version.dart';
import '../mesh/mesh_service.dart';
import '../mesh/updater.dart';
import 'update_banner.dart';
import 'assistant_view.dart';
import 'devices_view.dart';
import 'files_view.dart';
import 'settings_view.dart';
import 'theme.dart';

/// One navigation entry, in one list.
///
/// The phone's bottom bar and the desktop rail are two layouts of the same
/// thing: same order, same names, same icons, same words for the user. Only
/// the layout differs — a phone is not a shrunken desktop, and the desktop is
/// not a stretched phone.
class NexusDestination {
  const NexusDestination({
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// Assistant first: it is the app's main screen, not a tab among peers.
const List<NexusDestination> kNexusDestinations = [
  NexusDestination(
    label: 'Assistant',
    icon: Icons.forum_outlined,
    selectedIcon: Icons.forum_rounded,
  ),
  NexusDestination(
    label: 'Devices',
    icon: Icons.devices_outlined,
    selectedIcon: Icons.devices_rounded,
  ),
  NexusDestination(
    label: 'Files',
    icon: Icons.folder_outlined,
    selectedIcon: Icons.folder_rounded,
  ),
  NexusDestination(
    label: 'Settings',
    icon: Icons.tune_outlined,
    selectedIcon: Icons.tune_rounded,
  ),
];

class HomeShell extends StatefulWidget {
  final MeshService mesh;
  const HomeShell({super.key, required this.mesh});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  /// Starts on the Assistant: the first thing a new user should see is what
  /// Nexus is and where to talk to it, not a device list they do not have yet.
  int _index = 0;

  /// A handle on the assistant's state, so Settings' "What I still
  /// misunderstand" row can open the review sheet the assistant owns — one
  /// owner of what this device learned, not two that could disagree.
  final _assistantKey = GlobalKey<AssistantViewState>();

  ClipEntry? _lastShown;

  /// The conversational brain, one per platform: desktops run a strong
  /// local model (Ollama) and answer brain asks from paired phones; the
  /// phone runs a tiny on-device model for everyday questions and escalates
  /// the rest over the mesh to the PC — one assistant living everywhere,
  /// fully offline.
  late final LocalBrain? _brain;

  UpdateInfo? _update;
  bool _applying = false;

  /// What the user still has to do to finish an update — a step, not a failure.
  String? _updateNote;

  String? _updateError;
  String? _lastPeerUpdateVersion;
  bool _peerUpdateChecking = false;

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

  Future<UpdateCheck> _checkForUpdates() async {
    final check = await Updater.checkForUpdate(currentVersion: appVersion);
    if (check.info != null && mounted) {
      setState(() => _update = check.info);
    }
    return check;
  }

  /// Settings → Assistant: the review is an assistant concern, so the row
  /// brings the assistant forward and then asks it to open the sheet.
  void _openDreamReview() {
    setState(() => _index = 0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _assistantKey.currentState?.openDreamReview();
    });
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
        _checkForUpdates()
            .then((check) {
              if (check.info != null) _lastPeerUpdateVersion = version;
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
      _updateNote = null;
    });
    try {
      final path = await Updater.download(info.downloadUrl!);
      if (path == null) {
        setState(() {
          _applying = false;
          _updateError =
              'Could not download the update. Check your connection and try again.';
        });
        return;
      }

      if (defaultTargetPlatform == TargetPlatform.android) {
        // Hand the APK to the system installer; the user confirms it there.
        // The three outcomes read very differently to the person holding the
        // phone: Android may first send them to the screen that lets Nexus
        // install apps, and the install resumes by itself when they return —
        // saying nothing there is what made the update look broken.
        final outcome = await Updater.applyUpdate(path);
        setState(() {
          _applying = false;
          _updateError = outcome == UpdateApply.failed
              ? 'Could not open the installer. Try downloading from GitHub manually.'
              : null;
          _updateNote = updateHandoffNote(outcome);
        });
      } else if (defaultTargetPlatform == TargetPlatform.linux) {
        // Linux: extract, swap, and relaunch.
        final installDir = File(Platform.resolvedExecutable).parent.path;
        final outcome = await Updater.applyUpdate(path, installDir: installDir);
        if (outcome == UpdateApply.applied) {
          exit(0);
        }
        setState(() {
          _applying = false;
          _updateError =
              'The update could not be applied. Run update.sh to update manually.';
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
          AssistantView(
            key: _assistantKey,
            mesh: widget.mesh,
            brain: _brain,
          ),
          DevicesView(mesh: widget.mesh),
          FilesView(mesh: widget.mesh),
          SettingsView(
            mesh: widget.mesh,
            onCheckForUpdate: _checkForUpdates,
            onOpenDreamReview: _openDreamReview,
          ),
        ];

        // The update banner sits at the head of the page it belongs to, not
        // floating over the content: it is about this app, and it disappears
        // once there is nothing to offer.
        final content = Column(
          children: [
            if (_update != null)
              UpdateBanner(
                info: _update!,
                applying: _applying,
                error: _updateError,
                note: _updateNote,
                onUpdate: _updateNow,
                onDismiss: () => setState(() => _update = null),
              ),
            Expanded(
              child: IndexedStack(index: _index, children: views),
            ),
          ],
        );

        // The keyboard owns the bottom edge while it is open: the navigation
        // bar steps aside so the composer sits directly above the keys, in the
        // thumb zone the user is already looking at.
        final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;

        return Scaffold(
          resizeToAvoidBottomInset: true,
          body: _isDesktop
              ? Row(
                  children: [
                    NexusSidebar(
                      index: _index,
                      onSelect: (i) => setState(() => _index = i),
                    ),
                    Expanded(
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                            maxWidth: NexusSize.desktop,
                          ),
                          child: content,
                        ),
                      ),
                    ),
                  ],
                )
              : SafeArea(bottom: false, child: content),
          bottomNavigationBar: _isDesktop || keyboardOpen
              ? null
              : NexusTabBar(
                  index: _index,
                  onSelect: (i) => setState(() => _index = i),
                ),
        );
      },
    );
  }
}

/// The phone's bottom bar: an iOS tab bar.
///
/// Four destinations at the bottom of the screen, a hairline on top and a
/// small label under each glyph. The background is deliberately translucent:
/// `CupertinoTabBar` turns a non-opaque background into a real backdrop blur
/// (`bottom_tab_bar.dart` — `ClipRect` + `BackdropFilter(sigma 10)`), so the
/// page keeps scrolling underneath the bar instead of stopping above an
/// opaque strip. That blur is the one thing Material's `NavigationBar`
/// cannot do, and it is what makes a bar read as chrome floating over the
/// content rather than a wall across it.
class NexusTabBar extends StatelessWidget {
  const NexusTabBar({super.key, required this.index, required this.onSelect});

  final int index;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final palette = NexusPalette.of(context);
    return CupertinoTabBar(
      currentIndex: index,
      onTap: onSelect,
      backgroundColor: palette.surface.withValues(alpha: 0.82),
      activeColor: palette.accent,
      inactiveColor: palette.textSecondary,
      iconSize: NexusSize.navIcon,
      border: Border(top: BorderSide(color: palette.separator, width: 0.5)),
      items: [
        for (final d in kNexusDestinations)
          BottomNavigationBarItem(
            icon: Icon(d.icon),
            activeIcon: Icon(d.selectedIcon),
            label: d.label,
          ),
      ],
    );
  }
}

/// The desktop's rail: a sidebar, not a tab bar.
///
/// iOS does not put a tab bar under a pointer: a wide window gets a sidebar,
/// where the same destinations are rows — glyph and name side by side, the
/// current one on a tinted row with the accent ink. It is the same list in a
/// layout the platform actually has, which is the point of having two.
class NexusSidebar extends StatelessWidget {
  const NexusSidebar({super.key, required this.index, required this.onSelect});

  final int index;
  final ValueChanged<int> onSelect;

  /// Wide enough for a label beside an icon, narrow enough to give the page
  /// back most of a half-screen window.
  static const double width = 184;

  @override
  Widget build(BuildContext context) {
    final palette = NexusPalette.of(context);
    return Container(
      width: width,
      decoration: BoxDecoration(
        // The sidebar is the heavier material, so it separates the region
        // instead of competing with the page.
        color: palette.surface,
        border: Border(right: BorderSide(color: palette.separator, width: 0.5)),
      ),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: NexusSpace.lg),
            for (var i = 0; i < kNexusDestinations.length; i++)
              _SidebarRow(
                destination: kNexusDestinations[i],
                selected: i == index,
                onTap: () => onSelect(i),
              ),
          ],
        ),
      ),
    );
  }
}

class _SidebarRow extends StatelessWidget {
  const _SidebarRow({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final NexusDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = NexusPalette.of(context);
    final ink = selected ? palette.accent : palette.textSecondary;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: NexusSpace.sm,
        vertical: NexusSpace.xxs,
      ),
      child: NexusPressable(
        onTap: onTap,
        tint: selected ? palette.accentTint(0.14) : null,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: selected ? palette.accentTint() : Colors.transparent,
            borderRadius: NexusRadius.row,
          ),
          child: SizedBox(
            height: NexusSize.minTouch,
            child: Row(
              children: [
                const SizedBox(width: NexusSpace.sm),
                Icon(
                  selected ? destination.selectedIcon : destination.icon,
                  size: NexusSize.navIcon,
                  color: ink,
                ),
                const SizedBox(width: NexusSpace.sm),
                Expanded(
                  child: Text(
                    destination.label,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: selected ? palette.accent : palette.textPrimary,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
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
