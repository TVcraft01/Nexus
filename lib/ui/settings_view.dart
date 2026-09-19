import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';

import '../core/version.dart';
import '../mesh/mesh_service.dart';
import '../mesh/updater.dart';
import 'components/nexus_ui.dart';
import 'theme.dart';

/// Settings, in the order a person asks about them: who am I, what is
/// connected, what does it know about me, how does the assistant behave, how
/// does it look, how do I update it — and only then the technical parts.
///
/// Rows and groups, not one card per setting: a setting is a line in a list,
/// and a separate rounded box around every line is decoration that says
/// nothing.
class SettingsView extends StatefulWidget {
  final MeshService mesh;
  final Future<UpdateCheck> Function()? onCheckForUpdate;
  const SettingsView({super.key, required this.mesh, this.onCheckForUpdate});

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

  @override
  Widget build(BuildContext context) {
    final palette = NexusPalette.of(context);
    final isAndroid = defaultTargetPlatform == TargetPlatform.android;
    final icon = palette.textSecondary;

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
              leading: Icon(Icons.person_outline_rounded, size: 20, color: icon),
            ),
          ],
        ),

        const NexusSectionHeader('Devices'),
        NexusGroup(
          children: [
            NexusSwitchRow(
              title: 'Sync clipboard across devices',
              subtitle: 'What you copy goes to paired devices, and theirs '
                  'lands on your clipboard.',
              value: mesh.store.clipboardSync,
              onChanged: (v) => _setBool(() => mesh.store.clipboardSync = v),
            ),
            NexusSwitchRow(
              title: 'Always merge clipboard',
              subtitle: 'Push every copy immediately. Off uses smart mode: wait '
                  "3 s and only sync if you didn't paste it here.",
              value: mesh.store.alwaysMerge,
              onChanged: (v) => _setBool(() => mesh.store.alwaysMerge = v),
            ),
            NexusSwitchRow(
              title: 'Broadcast discovery',
              subtitle: 'Announce this device on the local network so others '
                  'can find it.',
              value: mesh.store.broadcastDiscovery,
              onChanged: (v) => _setBool(() => mesh.store.broadcastDiscovery = v),
            ),
          ],
        ),

        const NexusSectionHeader('Privacy'),
        NexusGroup(
          children: [
            NexusRow(
              title: 'Local-first, no account',
              subtitle: 'Pairing secrets and your data stay on your devices. '
                  'Nothing is sent anywhere.',
              leading: Icon(Icons.lock_outline_rounded, size: 20, color: icon),
            ),
            NexusRow(
              title: 'Reachability is honest',
              subtitle: 'A device reads online only when this device has '
                  'actually talked to it. If it shows "not reachable", it '
                  'really was not.',
              leading:
                  Icon(Icons.verified_user_outlined, size: 20, color: icon),
            ),
            if (isAndroid)
              NexusRow(
                title: 'Show all your files to paired devices',
                subtitle: _allFilesAccess == false
                    ? 'Off: devices only see files Nexus downloaded. Grant it '
                        'so your PC can browse your photos and music.'
                    : 'On: paired devices can browse this device and delete '
                        'files you allow.',
                leading: Icon(
                  _allFilesAccess == false
                      ? Icons.lock_outline_rounded
                      : Icons.folder_open_rounded,
                  size: 20,
                  color: icon,
                ),
                trailing: FilledButton.tonal(
                  onPressed: MeshService.openAllFilesAccessSettings,
                  child: Text(_allFilesAccess == false ? 'Grant' : 'Manage'),
                ),
                onTap: MeshService.openAllFilesAccessSettings,
              ),
          ],
        ),

        const NexusSectionHeader('Assistant'),
        NexusGroup(
          children: [
            NexusRow(
              title: 'Understands what you teach it',
              subtitle: 'Teach a phrase from any answer that missed, and it '
                  'works on every paired device.',
              leading: Icon(Icons.school_outlined, size: 20, color: icon),
            ),
            NexusRow(
              title: 'Actions need your approval',
              subtitle: 'Anything that changes another device waits for a yes '
                  'on that device.',
              leading: Icon(Icons.shield_outlined, size: 20, color: icon),
            ),
          ],
        ),

        const NexusSectionHeader('Appearance'),
        NexusGroup(
          children: [
            NexusRow(
              title: 'Dark',
              subtitle: 'Nexus is built as one calm dark surface. Light mode '
                  'is not available yet.',
              minHeight: NexusSize.rowCompact,
              leading: Icon(Icons.dark_mode_outlined, size: 20, color: icon),
              trailing: Text(
                'This device',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),

        const NexusSectionHeader('Updates'),
        NexusGroup(
          children: [
            NexusSwitchRow(
              title: 'Check for updates automatically',
              subtitle: 'On startup, look for a newer Nexus release on GitHub '
                  'and offer to install it.',
              value: mesh.store.autoUpdate,
              onChanged: (v) => _setBool(() => mesh.store.autoUpdate = v),
            ),
            NexusRow(
              title: 'Check for updates now',
              subtitle: _checking
                  ? 'Checking…'
                  : _checkResult ?? 'Manually look for a newer release.',
              minHeight: NexusSize.rowCompact,
              leading: Icon(
                Icons.system_update_alt_rounded,
                size: 20,
                color: icon,
              ),
              trailing: _checking
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : FilledButton.tonal(
                      onPressed: widget.onCheckForUpdate == null
                          ? null
                          : _checkForUpdate,
                      child: const Text('Check now'),
                    ),
              onTap:
                  widget.onCheckForUpdate == null ? null : _checkForUpdate,
            ),
          ],
        ),

        const NexusSectionHeader('About'),
        NexusGroup(
          children: [
            NexusRow(
              title: 'Nexus $appVersion',
              subtitle: 'Local-first mesh. Encrypted end to end (AES-GCM), '
                  'direct between devices.',
              minHeight: NexusSize.rowCompact,
              leading: Icon(Icons.info_outline_rounded, size: 20, color: icon),
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
