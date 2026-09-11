import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../mesh/mesh_service.dart';
import 'design_system.dart';

class NexusV2FilesView extends StatefulWidget {
  final MeshService mesh;
  const NexusV2FilesView({super.key, required this.mesh});

  @override
  State<NexusV2FilesView> createState() => _NexusV2FilesViewState();
}

class _NexusV2FilesViewState extends State<NexusV2FilesView> {
  PairedDevice? _device;
  String _path = '';
  List<FileEntry>? _entries;
  bool _loading = false;
  String? _error;
  final Set<String> _busy = {};
  final Map<String, double> _progress = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final devices = _devices;
      if (devices.isNotEmpty) _selectDevice(devices.first);
    });
  }

  List<PairedDevice> get _devices => widget.mesh.pairedDevices.toList()
    ..sort((a, b) => (widget.mesh.isOnline(a.id) ? 0 : 1).compareTo(widget.mesh.isOnline(b.id) ? 0 : 1));

  void _selectDevice(PairedDevice device) {
    setState(() {
      _device = device;
      _path = '';
      _entries = null;
      _error = null;
    });
    _load();
  }

  Future<void> _load() async {
    final device = _device;
    if (device == null || _loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final entries = await widget.mesh.listRemoteFiles(device, _path);
    if (!mounted || device.id != _device?.id) return;
    setState(() {
      _loading = false;
      if (entries != null) {
        entries.sort((a, b) {
          if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });
        _entries = entries;
      } else {
        _entries = null;
        _error = widget.mesh.lastFileError ?? 'Could not open this folder.';
      }
    });
  }

  void _open(FileEntry entry) {
    if (entry.isDir) {
      setState(() {
        _path = entry.path;
        _entries = null;
      });
      _load();
    } else {
      _download(entry);
    }
  }

  void _up() {
    if (_path.isEmpty) return;
    final separator = Platform.pathSeparator;
    final clean = _path.endsWith(separator) ? _path.substring(0, _path.length - 1) : _path;
    final index = clean.lastIndexOf(separator);
    setState(() {
      _path = index <= 0 ? '' : clean.substring(0, index);
      _entries = null;
    });
    _load();
  }

  Future<String> _downloadsDir() async {
    try {
      final dir = await getDownloadsDirectory();
      if (dir != null) return dir.path;
    } catch (_) {}
    final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home != null && home.isNotEmpty) return '$home${Platform.pathSeparator}Downloads';
    return (await getApplicationDocumentsDirectory()).path;
  }

  Future<void> _download(FileEntry entry) async {
    final device = _device;
    if (device == null || _busy.contains(entry.path)) return;
    setState(() {
      _busy.add(entry.path);
      _progress[entry.path] = 0;
    });
    var destination = '${await _downloadsDir()}${Platform.pathSeparator}${entry.name}';
    var n = 1;
    while (File(destination).existsSync()) {
      destination = '${await _downloadsDir()}${Platform.pathSeparator}${_withCounter(entry.name, n)}';
      n++;
    }
    final local = await widget.mesh.pullRemoteFile(
      device,
      entry.path,
      savePath: destination,
      onProgress: (done, total) {
        if (!mounted) return;
        setState(() => _progress[entry.path] = total > 0 ? done / total : 0);
      },
    );
    if (!mounted) return;
    setState(() {
      _busy.remove(entry.path);
      _progress.remove(entry.path);
    });
    _notice(local != null ? 'Saved ${entry.name} to Downloads' : 'Could not download ${entry.name}');
  }

  static String _withCounter(String name, int n) {
    final match = RegExp(r'^(.*?)(\.[^.]*)?$').firstMatch(name)!;
    return '${match.group(1)} ($n)${match.group(2) ?? ''}';
  }

  Future<void> _sendFile() async {
    final targets = _devices;
    if (targets.isEmpty) {
      _notice('Connect another device first.');
      return;
    }
    XFile? picked;
    try {
      picked = await openFile();
    } catch (_) {}
    if (picked == null || !mounted) return;
    final file = File(picked.path);
    if (!await file.exists()) {
      _notice('That file is no longer available.');
      return;
    }
    final target = await _chooseDevice(title: 'Send to…', devices: targets);
    if (target == null || !mounted) return;
    setState(() {
      _busy.add(picked!.path);
      _progress[picked.path] = 0;
    });
    final saved = await widget.mesh.pushLocalFile(
      target,
      picked.path,
      onProgress: (done, total) {
        if (!mounted) return;
        setState(() => _progress[picked!.path] = total > 0 ? done / total : 0);
      },
    );
    if (!mounted) return;
    setState(() {
      _busy.remove(picked!.path);
      _progress.remove(picked!.path);
    });
    _notice(saved != null ? 'Sent to ${target.name}' : 'Could not send the file');
  }

  Future<void> _delete(FileEntry entry) async {
    final device = _device;
    if (device == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${entry.name}?'),
        content: Text(entry.isDir ? 'Only an empty folder can be deleted.' : 'This removes the file from ${device.name}.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy.add(entry.path));
    final ok = await widget.mesh.deleteRemoteFile(device, entry.path);
    if (!mounted) return;
    setState(() => _busy.remove(entry.path));
    if (ok) {
      setState(() => _entries?.removeWhere((e) => e.path == entry.path));
    } else {
      _notice(widget.mesh.lastFileError ?? 'Could not delete ${entry.name}');
    }
  }

  Future<void> _rename(FileEntry entry) async {
    final device = _device;
    if (device == null) return;
    final controller = TextEditingController(text: entry.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename'),
        content: TextField(controller: controller, autofocus: true, decoration: const InputDecoration(labelText: 'Name')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty || name == entry.name || !mounted) return;
    final destination = _join(_path, name);
    setState(() => _busy.add(entry.path));
    final result = await widget.mesh.operateRemoteFile(device, operation: 'rename', source: entry.path, destination: destination);
    if (!mounted) return;
    setState(() => _busy.remove(entry.path));
    if (result == null) {
      _notice(widget.mesh.lastFileError ?? 'Could not rename ${entry.name}');
    } else {
      await _load();
    }
  }

  Future<void> _copyMove(FileEntry entry, {required bool move}) async {
    final source = _device;
    if (source == null) return;
    final targets = _devices;
    final target = await _chooseDevice(title: move ? 'Move to…' : 'Copy to…', devices: targets);
    if (target == null || !mounted) return;
    final destination = _join('', entry.name);
    setState(() => _busy.add(entry.path));
    final result = await widget.mesh.transferRemoteFile(source, entry.path, target, destination, move: move);
    if (!mounted) return;
    setState(() => _busy.remove(entry.path));
    if (result == null) {
      _notice(widget.mesh.lastFileError ?? 'Could not ${move ? 'move' : 'copy'} ${entry.name}');
    } else {
      await _load();
      _notice('${move ? 'Moved' : 'Copied'} ${entry.name} to ${target.name}');
    }
  }

  static String _join(String dir, String name) {
    if (dir.isEmpty) return name;
    final separator = Platform.pathSeparator;
    return '${dir.endsWith(separator) ? dir.substring(0, dir.length - 1) : dir}$separator$name';
  }

  Future<PairedDevice?> _chooseDevice({required String title, required List<PairedDevice> devices}) {
    return showModalBottomSheet<PairedDevice>(
      context: context,
      builder: (context) => SafeArea(
        child: NexusV2Group(
          title: title,
          children: [
            for (final d in devices)
              NexusV2Row(
                leading: Icon(Icons.devices_other_rounded, color: widget.mesh.isOnline(d.id) ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.onSurfaceVariant),
                title: d.name,
                subtitle: widget.mesh.isOnline(d.id) ? 'Connected' : 'Offline',
                onTap: () => Navigator.pop(context, d),
              ),
          ],
        ),
      ),
    );
  }

  void _notice(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final devices = _devices;
    final device = _device;
    final title = _path.isEmpty ? 'Files' : _basename(_path);
    return ListenableBuilder(
      listenable: widget.mesh,
      builder: (context, _) {
        return Column(
          children: [
            NexusV2PageTitle(
              title: title,
              subtitle: device == null ? 'Your connected files' : device.name,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Choose device',
                    icon: const Icon(Icons.devices_other_rounded),
                    onPressed: devices.isEmpty ? null : () async {
                      final chosen = await _chooseDevice(title: 'Browse on…', devices: devices);
                      if (chosen != null) _selectDevice(chosen);
                    },
                  ),
                  IconButton(tooltip: 'Send file', icon: const Icon(Icons.upload_file_rounded), onPressed: _sendFile),
                ],
              ),
            ),
            if (device != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                child: Row(
                  children: [
                    if (_path.isNotEmpty)
                      IconButton(tooltip: 'Back', onPressed: _up, icon: const Icon(Icons.chevron_left_rounded)),
                    Expanded(
                      child: Text(
                        _path.isEmpty ? 'Home' : _path,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    IconButton(tooltip: 'Refresh', onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh_rounded)),
                  ],
                ),
              ),
            Expanded(child: _body(context, devices, device)),
          ],
        );
      },
    );
  }

  Widget _body(BuildContext context, List<PairedDevice> devices, PairedDevice? device) {
    if (device == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.folder_copy_outlined, size: 44, color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(height: 14),
            Text('Choose a device', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text('Files are private to each paired device. Pick one to browse it.', textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 18),
            FilledButton.icon(onPressed: devices.isEmpty ? null : () async {
              final chosen = await _chooseDevice(title: 'Browse on…', devices: devices);
              if (chosen != null) _selectDevice(chosen);
            }, icon: const Icon(Icons.devices_other_rounded), label: const Text('Choose device')),
          ]),
        ),
      );
    }
    if (_loading && _entries == null) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(child: Padding(padding: const EdgeInsets.all(28), child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.cloud_off_rounded, size: 42),
        const SizedBox(height: 12),
        Text(_error!, textAlign: TextAlign.center),
        const SizedBox(height: 16),
        FilledButton(onPressed: _load, child: const Text('Try again')),
      ])));
    }
    final entries = _entries;
    if (entries == null || entries.isEmpty) {
      return Center(child: Text('Nothing here yet.', style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
        itemCount: entries.length,
        separatorBuilder: (_, __) => const SizedBox(height: 6),
        itemBuilder: (context, index) => _FileRow(
          entry: entries[index],
          busy: _busy.contains(entries[index].path),
          progress: _progress[entries[index].path],
          onTap: () => _open(entries[index]),
          onDelete: () => _delete(entries[index]),
          onRename: () => _rename(entries[index]),
          onCopy: () => _copyMove(entries[index], move: false),
          onMove: () => _copyMove(entries[index], move: true),
        ),
      ),
    );
  }

  static String _basename(String path) {
    final normalized = path.replaceAll('\\', '/');
    final parts = normalized.split('/').where((p) => p.isNotEmpty).toList();
    return parts.isEmpty ? 'Files' : parts.last;
  }
}

class _FileRow extends StatelessWidget {
  final FileEntry entry;
  final bool busy;
  final double? progress;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback onRename;
  final VoidCallback onCopy;
  final VoidCallback onMove;

  const _FileRow({required this.entry, required this.busy, required this.progress, required this.onTap, required this.onDelete, required this.onRename, required this.onCopy, required this.onMove});

  @override
  Widget build(BuildContext context) {
    final ext = entry.name.contains('.') ? entry.name.split('.').last.toLowerCase() : '';
    final icon = entry.isDir ? Icons.folder_rounded : switch (ext) {
      'png' || 'jpg' || 'jpeg' || 'gif' || 'webp' => Icons.image_rounded,
      'mp3' || 'wav' || 'ogg' || 'm4a' => Icons.music_note_rounded,
      'mp4' || 'mkv' || 'mov' || 'webm' => Icons.movie_rounded,
      'pdf' => Icons.picture_as_pdf_rounded,
      'zip' || '7z' || 'rar' => Icons.archive_rounded,
      _ => Icons.insert_drive_file_rounded,
    };
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: busy ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 9, 6, 9),
          child: Row(children: [
            Icon(icon, size: 24, color: entry.isDir ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(entry.isDir ? 'Folder' : _size(entry.size), style: Theme.of(context).textTheme.bodySmall),
              if (busy && progress != null) ...[
                const SizedBox(height: 6),
                LinearProgressIndicator(value: progress),
              ],
            ])),
            PopupMenuButton<String>(
              tooltip: 'More',
              onSelected: switch (_) {},
              itemBuilder: (_) => [
                if (!entry.isDir) const PopupMenuItem(value: 'open', child: Text('Open')),
                const PopupMenuItem(value: 'rename', child: Text('Rename')),
                const PopupMenuItem(value: 'copy', child: Text('Copy to…')),
                const PopupMenuItem(value: 'move', child: Text('Move to…')),
                const PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
              onCanceled: () {},
            ),
          ]),
        ),
      ),
    );
  }

  static String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
