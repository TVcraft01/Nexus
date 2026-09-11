import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';

import '../../core/version.dart';
import '../../mesh/mesh_service.dart';
import '../../mesh/updater.dart';
import 'about_view.dart';
import 'design_system.dart';

class NexusV2SettingsView extends StatefulWidget {
  final MeshService mesh;
  final Future<UpdateInfo?> Function()? onCheckForUpdate;
  const NexusV2SettingsView({super.key, required this.mesh, this.onCheckForUpdate});

  @override
  State<NexusV2SettingsView> createState() => _NexusV2SettingsViewState();
}

class _NexusV2SettingsViewState extends State<NexusV2SettingsView> {
  bool? _allFilesAccess;
  bool _checking = false;
  String? _checkResult;

  @override
  void initState() {
    super.initState();
    MeshService.hasAllFilesAccess().then((value) {
      if (mounted) setState(() => _allFilesAccess = value);
    });
  }

  Future<void> _checkUpdates() async {
    final callback = widget.onCheckForUpdate;
    if (callback == null || _checking) return;
    setState(() {
      _checking = true;
      _checkResult = null;
    });
    try {
      final info = await callback();
      if (!mounted) return;
      setState(() {
        _checking = false;
        _checkResult = info == null
            ? 'You’re up to date'
            : 'Version ${info.version} is available';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _checkResult = 'Could not check right now';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.mesh.store;
    final profileName = store.profileUserName;
    final assistantName = store.profileAssistantName ?? 'Nexus';
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
      children: [
        const NexusV2PageTitle(
          title: 'Settings',
          subtitle: 'Make Nexus work the way you want.',
        ),
        NexusV2Group(
          title: 'Personal',
          children: [
            NexusV2Row(
              leading: const Icon(Icons.person_outline_rounded),
              title: profileName?.isNotEmpty == true ? profileName! : 'Your profile',
              subtitle: assistantName == 'Nexus'
                  ? 'Set your name and how Nexus addresses you'
                  : 'Assistant: $assistantName',
              onTap: () => _showProfile(context),
            ),
            NexusV2Row(
              leading: const Icon(Icons.psychology_alt_outlined),
              title: 'Assistant',
              subtitle: 'Voice, memory and approval behavior',
              onTap: () => _showInfo(
                context,
                'Assistant',
                'Nexus uses the skills and devices that are available. Higher-impact actions can ask for your approval before they run.',
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        NexusV2Group(
          title: 'Devices & connectivity',
          children: [
            NexusV2Row(
              leading: const Icon(Icons.content_paste_outlined),
              title: 'Clipboard sync',
              subtitle: 'Share copied text with paired devices',
              trailing: Switch(
                value: store.clipboardSync,
                onChanged: (value) {
                  setState(() => store.clipboardSync = value);
                  store.save();
                },
              ),
            ),
            NexusV2Row(
              leading: const Icon(Icons.sync_alt_rounded),
              title: 'Sync immediately',
              subtitle: 'Send clipboard changes without the smart delay',
              trailing: Switch(
                value: store.alwaysMerge,
                onChanged: (value) {
                  setState(() => store.alwaysMerge = value);
                  store.save();
                },
              ),
            ),
            NexusV2Row(
              leading: const Icon(Icons.radar_outlined),
              title: 'Nearby discovery',
              subtitle: 'Let Nexus devices find this one on the local network',
              trailing: Switch(
                value: store.broadcastDiscovery,
                onChanged: (value) {
                  setState(() => store.broadcastDiscovery = value);
                  store.save();
                },
              ),
            ),
            NexusV2Row(
              leading: const Icon(Icons.hub_outlined),
              title: 'Paired devices',
              subtitle: '${widget.mesh.pairedDevices.length} device${widget.mesh.pairedDevices.length == 1 ? '' : 's'} in your Nexus',
              onTap: null,
            ),
          ],
        ),
        if (defaultTargetPlatform == TargetPlatform.android) ...[
          const SizedBox(height: 18),
          NexusV2Group(
            title: 'Files',
            children: [
              NexusV2Row(
                leading: Icon(
                  _allFilesAccess == true
                      ? Icons.folder_open_outlined
                      : Icons.lock_outline,
                ),
                title: 'Full file access',
                subtitle: _allFilesAccess == true
                    ? 'Paired devices can browse shared storage'
                    : 'Allow paired devices to browse shared storage',
                trailing: FilledButton.tonal(
                  onPressed: MeshService.openAllFilesAccessSettings,
                  child: Text(_allFilesAccess == true ? 'Manage' : 'Grant'),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 18),
        NexusV2Group(
          title: 'Updates',
          children: [
            NexusV2Row(
              leading: const Icon(Icons.system_update_outlined),
              title: 'Automatic updates',
              subtitle: 'Check for a newer version when Nexus starts',
              trailing: Switch(
                value: store.autoUpdate,
                onChanged: (value) {
                  setState(() => store.autoUpdate = value);
                  store.save();
                },
              ),
            ),
            NexusV2Row(
              leading: const Icon(Icons.refresh_outlined),
              title: 'Check for updates',
              subtitle: _checkResult ?? 'Current version: $appVersion',
              trailing: _checking
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : TextButton(
                      onPressed: widget.onCheckForUpdate == null ? null : _checkUpdates,
                      child: const Text('Check'),
                    ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        NexusV2Group(
          title: 'About',
          children: [
            NexusV2Row(
              leading: const Icon(Icons.info_outline_rounded),
              title: 'About Nexus',
              subtitle: 'Version, device information and developer diagnostics',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => NexusV2AboutView(mesh: widget.mesh),
                ),
              ),
            ),
            NexusV2Row(
              leading: const Icon(Icons.privacy_tip_outlined),
              title: 'Privacy',
              subtitle: 'Review how Nexus keeps your data on your devices',
              onTap: () => _showInfo(
                context,
                'Privacy',
                'Nexus is designed around local-first operation. Review individual permissions and connected services before enabling anything that needs external access.',
              ),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _showProfile(BuildContext context) async {
    final name = TextEditingController(text: widget.mesh.store.profileUserName ?? '');
    final assistant = TextEditingController(
      text: widget.mesh.store.profileAssistantName ?? 'Nexus',
    );
    final result = await showDialog<(String, String)?>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Your assistant'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Your name'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: assistant,
              decoration: const InputDecoration(labelText: 'Assistant name'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(
              context,
              (name.text.trim(), assistant.text.trim()),
            ),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    name.dispose();
    assistant.dispose();
    if (result == null || !mounted) return;
    widget.mesh.store.profileUserName = result.$1.isEmpty ? null : result.$1;
    widget.mesh.store.profileAssistantName =
        result.$2.isEmpty ? 'Nexus' : result.$2;
    await widget.mesh.store.save();
    setState(() {});
  }

  void _showInfo(BuildContext context, String title, String body) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }
}
