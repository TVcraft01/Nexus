import 'package:flutter/cupertino.dart'
    show CupertinoActivityIndicator, CupertinoPageRoute;
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';

import '../core/version.dart';
import '../mesh/mesh_service.dart';
import '../mesh/updater.dart';
import 'about_view.dart';
import 'components/nexus_ui.dart';
import 'theme.dart';

/// Settings, in the order a person asks about them: who am I, what is
/// connected, what does it know about me, how does the assistant behave, how
/// does it look, how do I update it — and only then the technical parts.
///
/// One row per setting, iOS anatomy: a label on the left, its value or control
/// on the right, and a description only where the label cannot carry the
/// answer — never more than one line. The sentences that used to explain Nexus
/// in the middle of the list live on [AboutView], one tap away, instead of
/// standing between the user and their settings.
class SettingsView extends StatefulWidget {
  final MeshService mesh;
  final Future<UpdateCheck> Function()? onCheckForUpdate;

  /// Opens the assistant's "what I still misunderstand" review. Supplied by
  /// the shell, which holds the one assistant whose service owns what this
  /// device learned; null in a test that builds this view on its own.
  final VoidCallback? onOpenDreamReview;

  const SettingsView({
    super.key,
    required this.mesh,
    this.onCheckForUpdate,
    this.onOpenDreamReview,
  });

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  bool? _allFilesAccess; // Android: can this device read its whole storage?
  String? _checkResult;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    MeshService.hasAllFilesAccess().then((v) {
      if (mounted) setState(() => _allFilesAccess = v);
    });
  }

  MeshService get mesh => widget.mesh;

  void _setBool(void Function() change) {
    setState(change);
    mesh.store.save();
  }

  Future<void> _checkForUpdate() async {
    final check = widget.onCheckForUpdate;
    if (check == null || _checking) return;
    setState(() {
      _checking = true;
      _checkResult = null;
    });
    try {
      final result = await check();
      if (!mounted) return;
      setState(() {
        _checking = false;
        // Three different answers, never conflated: a check that could not be
        // made must not read as "up to date".
        _checkResult = switch (result) {
          UpdateCheck(:final info?) => 'Update to v${info.version} available',
          UpdateCheck(:final failure?) => 'Could not check — $failure',
          _ => 'Up to date — v$appVersion',
        };
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _checkResult = 'Could not check — try again';
      });
    }
  }

  /// The facts this list used to explain in place, on their own screen.
  void _openAbout() {
    // The iOS push: horizontal, with the edge-swipe back the platform has.
    Navigator.of(context).push<void>(
      CupertinoPageRoute(builder: (_) => const AboutView()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = NexusPalette.of(context);
    final isAndroid = defaultTargetPlatform == TargetPlatform.android;
    final icon = palette.textSecondary;
    final filesOff = _allFilesAccess == false;

    return NexusPage(
      children: [
        const NexusPageHeader(
          title: 'Settings',
          subtitle: 'This device and how Nexus behaves.',
        ),

        const NexusSectionHeader('You'),
        NexusGroup(
          children: [
            NexusRow(
              title: mesh.identity.name,
              subtitle: 'This device · ${_platformName()}',
              leading: Icon(
                Icons.person_outline_rounded,
                size: 20,
                color: icon,
              ),
            ),
          ],
        ),

        const NexusSectionHeader('Devices'),
        NexusGroup(
          children: [
            NexusSwitchRow(
              title: 'Sync clipboard across devices',
              value: mesh.store.clipboardSync,
              onChanged: (v) => _setBool(() => mesh.store.clipboardSync = v),
            ),
            NexusSwitchRow(
              title: 'Always merge clipboard',
              subtitle: 'Off waits 3 s in case you paste it here.',
              value: mesh.store.alwaysMerge,
              onChanged: (v) => _setBool(() => mesh.store.alwaysMerge = v),
            ),
            NexusSwitchRow(
              title: 'Broadcast discovery',
              subtitle: 'Lets nearby devices find this one.',
              value: mesh.store.broadcastDiscovery,
              onChanged: (v) => _setBool(() => mesh.store.broadcastDiscovery = v),
            ),
          ],
        ),

        // The one privacy control this device has: what other devices may see.
        // The promises themselves are on About, not between the settings.
        if (isAndroid) ...[
          const NexusSectionHeader('Privacy'),
          NexusGroup(
            children: [
              NexusRow(
                title: 'Show your files to paired devices',
                subtitle: filesOff
                    ? 'Off — they see only what Nexus downloaded.'
                    : 'On — they can browse and delete files you allow.',
                leading: Icon(
                  filesOff ? Icons.lock_outline_rounded : Icons.folder_open_rounded,
                  size: 20,
                  color: icon,
                ),
                trailing: NexusRowValue(filesOff ? 'Off' : 'On'),
                chevron: true,
                onTap: MeshService.openAllFilesAccessSettings,
              ),
            ],
          ),
        ],

        const NexusSectionHeader('Assistant'),
        NexusGroup(
          children: [
            NexusRow(
              title: 'What I still misunderstand',
              subtitle: 'Review and teach the phrases I missed.',
              leading: Icon(
                Icons.psychology_alt_outlined,
                size: 20,
                color: icon,
              ),
              chevron: true,
              onTap: widget.onOpenDreamReview,
            ),
          ],
        ),

        const NexusSectionHeader('Appearance'),
        NexusGroup(
          children: [
            NexusRow(
              title: 'Theme',
              minHeight: NexusSize.rowCompact,
              leading: Icon(Icons.dark_mode_outlined, size: 20, color: icon),
              trailing: const NexusRowValue('Dark'),
            ),
          ],
        ),

        const NexusSectionHeader('Updates'),
        NexusGroup(
          children: [
            NexusSwitchRow(
              title: 'Check for updates automatically',
              value: mesh.store.autoUpdate,
              onChanged: (v) => _setBool(() => mesh.store.autoUpdate = v),
            ),
            // The state is the only thing this row has to say beyond its
            // label, so it is the only thing it shows: nothing when idle.
            NexusRow(
              title: 'Check for updates now',
              subtitle: _checking ? 'Checking…' : _checkResult,
              leading: Icon(
                Icons.system_update_alt_rounded,
                size: 20,
                color: icon,
              ),
              trailing: _checking
                  ? CupertinoActivityIndicator(radius: 8, color: palette.accent)
                  : null,
              onTap: widget.onCheckForUpdate == null ? null : _checkForUpdate,
            ),
          ],
        ),

        const NexusSectionHeader('About'),
        NexusGroup(
          children: [
            NexusRow(
              title: 'About Nexus',
              leading: Icon(Icons.info_outline_rounded, size: 20, color: icon),
              trailing: NexusRowValue('v$appVersion'),
              chevron: true,
              onTap: _openAbout,
            ),
          ],
        ),
      ],
    );
  }

  String _platformName() {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'Phone';
      case TargetPlatform.iOS:
        return 'iPhone';
      case TargetPlatform.macOS:
        return 'Mac';
      case TargetPlatform.windows:
        return 'Windows';
      case TargetPlatform.linux:
        return 'Linux';
      default:
        return 'Device';
    }
  }
}
