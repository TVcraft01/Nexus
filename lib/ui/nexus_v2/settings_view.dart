import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';

import '../../core/version.dart';
import '../../mesh/mesh_service.dart';
import '../../mesh/updater.dart';
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

  @override
  Widget build(BuildContext context) {
    final store = widget.mesh.store;
    final profileName = store.profileUserName;
    final assistantName = store.profileAssistantName ?? 'Nexus';
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
      children: [
        const NexusV2PageTitle(title: 'Settings', subtitle: 'How Nexus behaves on this device.'),
        NexusV2Group(
          title: 'Your assistant',
          children: [
            NexusV2Row(
              leading: const Icon(Icons.person_outline_rounded),
              title: profileName == null || profileName.isEmpty ? 'Set up your profile' : profileName,
              subtitle: assistantName == 'Nexus' ? 'Assistant: Nexus' : 'Assistant: $assistantName',
              onTap: () => _showProfile(context),
            ),
            NexusV2Row(
              leading: const Icon(Icons.psychology_alt_outlined),
              title: 'Assistant behavior',
              subtitle: 'Voice, memory and how Nexus asks for approval',
              onTap: () => _showInfo(context, 'Assistant behavior', 'Nexus uses its available skills, memory and connected devices to complete requests. High-impact actions can require your approval.'),
            ),
          ],
        ),
        const SizedBox(height: 20),
        NexusV2Group(
          title: 'Devices & network',
          children: [
            NexusV2Row(
              leading: const Icon(Icons.content_paste_rounded),
              title: 'Clipboard sync',
              subtitle: 'Share copied text with paired devices',
              trailing: Switch(value: store.clipboardSync, onChanged: (value) { setState(() => store.clipboardSync = value); store.save(); }),
            ),
            NexusV2Row(
              leading: const Icon(Icons.sync_alt_rounded),
              title: 'Always sync copies',
              subtitle: 'Send clipboard changes immediately',
              trailing: Switch(value: store.alwaysMerge, onChanged: (value) { setState(() => store.alwaysMerge = value); store.save(); }),
            ),
            NexusV2Row(
              leading: const Icon(Icons.cell_tower_rounded),
              title: 'Device discovery',
              subtitle: 'Let nearby Nexus devices find this one',
              trailing: Switch(value: store.broadcastDiscovery, onChanged: (value) { setState(() => store.broadcastDiscovery = value); store.save(); }),
            ),
            NexusV2Row(
              leading: const Icon(Icons.wifi_tethering_rounded),
              title: 'Paired devices',
              subtitle: '${widget.mesh.pairedDevices.length} connected in your Nexus',
              onTap: () {},
            ),
          ],
        ),
        const SizedBox(height: 20),
        if (defaultTargetPlatform == TargetPlatform.android) ...[
          NexusV2Group(
            title: 'Files',
            children: [
              NexusV2Row(
                leading: Icon(_allFilesAccess == true ? Icons.folder_open_rounded : Icons.lock_outline_rounded),
                title: 'Full file access',
                subtitle: _allFilesAccess == true ? 'Paired devices can browse this device' : 'Grant access to let paired devices browse shared storage',
                trailing: FilledButton.tonal(
                  onPressed: MeshService.openAllFilesAccessSettings,
                  child: Text(_allFilesAccess == true ? 'Manage' : 'Grant'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
        ],
        NexusV2Group(
          title: 'Updates',
          children: [
            NexusV2Row(
              leading: const Icon(Icons.system_update_alt_rounded),
              title: 'Automatic updates',
              subtitle: 'Check for a newer Nexus release when the app starts',
              trailing: Switch(value: store.autoUpdate, onChanged: (value) { setState(() => store.autoUpdate = value); store.save(); }),
            ),
            NexusV2Row(
              leading: const Icon(Icons.refresh_rounded),
              title: 'Check for updates',
              subtitle: _checkResult ?? 'Current version: $appVersion',
              trailing: _checking
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : FilledButton.tonal(
                      onPressed: widget.onCheckForUpdate == null ? null : () async {
                        setState(() { _checking = true; _checkResult = null; });
                        try {
                          final info = await widget.onCheckForUpdate!();
                          if (!mounted) return;
                          setState(() { _checking = false; _checkResult = info == null ? 'You’re up to date' : 'Version ${info.version} is available'; });
                        } catch (_) {
                          if (!mounted) return;
                          setState(() { _checking = false; _checkResult = 'Could not check right now'; });
                        }
                      },
                      child: const Text('Check'),
                    ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        NexusV2Group(
          title: 'About',
          children: [
            NexusV2Row(
              leading: const Icon(Icons.info_outline_rounded),
              title: 'Nexus $appVersion',
              subtitle: 'One assistant across your connected devices',
              onTap: () => _showInfo(context, 'Nexus', 'Version $appVersion. Local-first by design.'),
            ),
            NexusV2Row(
              leading: const Icon(Icons.privacy_tip_outlined),
              title: 'Privacy',
              subtitle: 'See what stays on your devices and what can leave them',
              onTap: () => _showInfo(context, 'Privacy', 'Nexus is designed around local-first operation. Review individual permissions and connected services before enabling anything that needs external access.'),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _showProfile(BuildContext context) async {
    final name = TextEditingController(text: widget.mesh.store.profileUserName ?? '');
    final assistant = TextEditingController(text: widget.mesh.store.profileAssistantName ?? 'Nexus');
    final result = await showDialog<(String, String)?>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Your assistant'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, autofocus: true, decoration: const InputDecoration(labelText: 'Your name')),
          const SizedBox(height: 12),
          TextField(controller: assistant, decoration: const InputDecoration(labelText: 'Assistant name')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, (name.text.trim(), assistant.text.trim())), child: const Text('Save')),
        ],
      ),
    );
    name.dispose();
    assistant.dispose();
    if (result == null || !mounted) return;
    widget.mesh.store.profileUserName = result.$1.isEmpty ? null : result.$1;
    widget.mesh.store.profileAssistantName = result.$2.isEmpty ? 'Nexus' : result.$2;
    await widget.mesh.store.save();
    setState(() {});
  }

  void _showInfo(BuildContext context, String title, String body) {
    showDialog<void>(context: context, builder: (context) => AlertDialog(title: Text(title), content: Text(body), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))]));
  }
}
