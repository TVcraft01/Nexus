import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/query_log.dart';
import '../../core/version.dart';
import '../../mesh/mesh_service.dart';
import 'design_system.dart';

class NexusV2DiagnosticsView extends StatefulWidget {
  final MeshService mesh;
  const NexusV2DiagnosticsView({super.key, required this.mesh});

  @override
  State<NexusV2DiagnosticsView> createState() => _NexusV2DiagnosticsViewState();
}

class _NexusV2DiagnosticsViewState extends State<NexusV2DiagnosticsView> {
  List<String> _lines = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final lines = await QueryLog.i.readAll();
    if (!mounted) return;
    setState(() {
      _lines = lines.reversed.take(250).toList();
      _loading = false;
    });
  }

  String _format(String line) {
    try {
      final json = jsonDecode(line);
      if (json is Map<String, dynamic>) {
        final time = json['ts']?.toString() ?? '';
        final kind = json['kind']?.toString() ?? 'event';
        final detail = switch (kind) {
          'ask' => '${json['input'] ?? ''} → ${json['status'] ?? ''} (${json['route'] ?? ''})',
          'call' => 'call ${json['contact'] ?? ''} → ${json['outcome'] ?? ''}',
          'remote' => 'remote ${json['action'] ?? ''} from ${json['from'] ?? ''} → ${json['approval'] ?? ''}',
          'learned' => 'learned “${json['phrase'] ?? ''}”',
          'sync' => 'synced “${json['phrase'] ?? ''}”',
          'fact' => '${json['op'] ?? 'fact'}: ${json['text'] ?? ''}',
          'fact-sync' => 'fact sync: ${json['text'] ?? ''}',
          _ => json.toString(),
        };
        return '$time  •  $kind\n$detail';
      }
    } catch (_) {}
    return line;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnostics'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading ? null : () => unawaited(_load()),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                children: [
                  NexusV2Group(
                    title: 'Environment',
                    children: [
                      NexusV2Row(
                        title: 'Nexus',
                        subtitle: appVersion,
                        leading: const Icon(Icons.apps_outlined),
                      ),
                      NexusV2Row(
                        title: 'This device',
                        subtitle: '${widget.mesh.identity.name} · ${widget.mesh.identity.platform}',
                        leading: const Icon(Icons.devices_other_outlined),
                      ),
                      NexusV2Row(
                        title: 'Paired devices',
                        subtitle: '${widget.mesh.pairedDevices.length}',
                        leading: const Icon(Icons.hub_outlined),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Text('Assistant activity', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  if (_lines.isEmpty)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text(
                          'No recorded activity yet.',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    )
                  else
                    Card(
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        children: [
                          for (var i = 0; i < _lines.length; i++)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: SelectableText(
                                  _format(_lines[i]),
                                  style: theme.textTheme.bodySmall,
                                ),
                              ),
                            ),
                          if (_lines.length >= 250)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
                              child: Text(
                                'Showing the latest 250 entries.',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}
