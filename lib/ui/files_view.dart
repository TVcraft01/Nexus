import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../mesh/mesh_service.dart';
import 'devices_view.dart' show platformIcon;
import 'theme.dart';

/// Browse files on any device in the mesh over the encrypted channel.
///
/// Each device serves its own home folder (see [MeshService.fileRoot]); this
/// view lets you pick any paired device, walk its folders, and download files
/// to this device's Downloads folder — or pick "This device", walk its own
/// folder, and send a file to a paired device (it lands in the peer's
/// "Nexus Incoming" folder). Works on LAN and — via a Tailscale address —
/// from anywhere.
class FilesView extends StatefulWidget {
  final MeshService mesh;
  const FilesView({super.key, required this.mesh});

  @override
  State<FilesView> createState() => _FilesViewState();
}

class _FilesViewState extends State<FilesView> {
  PairedDevice? _device;
  bool _local = false; // browsing this device's own served folder
  String _path = ''; // '' = the device's home
  List<FileEntry>? _entries;
  bool _loading = false;
  String? _error;
  final Map<String, double> _progress = {}; // entry path -> 0..1
  final Set<String> _downloading = {};
  final Set<String> _sending = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final devices = _selectableDevices();
      if (devices.isNotEmpty) _selectDevice(devices.first);
    });
  }

  /// Paired devices, online ones first (an offline device simply won't answer).
  List<PairedDevice> _selectableDevices() {
    final devices = widget.mesh.pairedDevices.toList()
      ..sort((a, b) {
        final ao = widget.mesh.isOnline(a.id) ? 0 : 1;
        final bo = widget.mesh.isOnline(b.id) ? 0 : 1;
        return ao.compareTo(bo);
      });
    return devices;
  }

  void _selectDevice(PairedDevice device) {
    setState(() {
      _local = false;
      _device = device;
      _path = '';
      _entries = null;
      _error = null;
      _progress.clear();
      _downloading.clear();
      _sending.clear();
    });
    _load();
  }

  void _selectLocal() {
    setState(() {
      _local = true;
      _device = null;
      _path = '';
      _entries = null;
      _error = null;
      _progress.clear();
      _downloading.clear();
      _sending.clear();
    });
    _load();
  }

  Future<void> _load() async {
    if (_loading) return;
    final local = _local;
    final device = _device;
    if (!local && device == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final entries = local
        ? await widget.mesh.listLocalFiles(_path)
        : await widget.mesh.listRemoteFiles(device!, _path);
    if (!mounted || _local != local) return;
    setState(() {
      _loading = false;
      if (entries != null) {
        _entries = entries;
      } else {
        _error = widget.mesh.lastFileError ?? 'Could not read that folder.';
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
    } else if (_local) {
      _send(entry);
    } else {
      _download(entry);
    }
  }

  void _goUp() {
    final sep = Platform.pathSeparator;
    final idx = _path.lastIndexOf(sep);
    if (idx <= 0) {
      setState(() {
        _path = '';
        _entries = null;
      });
    } else {
      setState(() {
        _path = _path.substring(0, idx);
        _entries = null;
      });
    }
    _load();
  }

  Future<String> _downloadsDir() async {
    try {
      final dir = await getDownloadsDirectory();
      if (dir != null) return dir.path;
    } catch (_) {}
    final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home != null && home.isNotEmpty) {
      return '$home${Platform.pathSeparator}Downloads';
    }
    final docs = await getApplicationDocumentsDirectory();
    return docs.path;
  }

  Future<void> _download(FileEntry entry) async {
    final device = _device;
    if (device == null || _downloading.contains(entry.path)) return;
    setState(() {
      _downloading.add(entry.path);
      _progress[entry.path] = 0;
    });

    var savePath = '${await _downloadsDir()}${Platform.pathSeparator}${entry.name}';
    var n = 1;
    while (File(savePath).existsSync()) {
      savePath = '${await _downloadsDir()}${Platform.pathSeparator}'
          '${entry.name.replaceFirst(RegExp(r'(\.[^.]*)?$'), ' ($n)\$1')}';
      n++;
    }

    final file = await widget.mesh.pullRemoteFile(
      device,
      entry.path,
      savePath: savePath,
      onProgress: (received, total) {
        if (!mounted) return;
        setState(() {
          _progress[entry.path] = total > 0 ? received / total : 0;
        });
      },
    );

    if (!mounted) return;
    setState(() {
      _downloading.remove(entry.path);
      _progress.remove(entry.path);
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(file != null
          ? 'Saved ${entry.name} to $savePath'
          : 'Could not download ${entry.name}: ${widget.mesh.lastFileError ?? 'unknown error'}'),
    ));
  }

  /// Opens the native file picker and sends the chosen file to a paired
  /// device — the way a phone can push a photo or download that lives
  /// outside the app's own folder. On Android the picker hands back a plain
  /// filesystem path (a cache copy when the source has no direct path), so
  /// the result feeds straight into the same send flow as a browsed file.
  Future<void> _pickAndSend() async {
    XFile? picked;
    try {
      picked = await openFile();
    } catch (_) {
      picked = null;
    }
    if (picked == null || !mounted) return;
    final file = File(picked.path);
    final exists = await file.exists();
    if (!mounted) return;
    if (!exists) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Could not open the chosen file.'),
      ));
      return;
    }
    await _send(FileEntry(
      name: picked.name.isNotEmpty ? picked.name : file.uri.pathSegments.last,
      path: picked.path,
      size: await file.length(),
      isDir: false,
      modified: await file.lastModified(),
    ));
  }

  /// Sends a local file to a paired device: pick the target, then stream it
  /// over the encrypted mesh into the peer's "Nexus Incoming" folder.
  Future<void> _send(FileEntry entry) async {
    if (_sending.contains(entry.path)) return;
    final peers = widget.mesh.pairedDevices;
    if (peers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Pair a device first — there is nowhere to send it.'),
      ));
      return;
    }
    final target = await showModalBottomSheet<PairedDevice>(
      context: context,
      backgroundColor: NexusColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Send ${entry.name} to…',
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
            ),
            for (final p in peers)
              ListTile(
                leading: Icon(platformIcon(p.platform)),
                title: Text(p.name),
                trailing: Icon(
                  Icons.send_rounded,
                  size: 18,
                  color: widget.mesh.isOnline(p.id) ? NexusColors.ok : NexusColors.muted,
                ),
                onTap: () => Navigator.pop(sheetContext, p),
              ),
          ],
        ),
      ),
    );
    if (target == null || !mounted) return;
    setState(() {
      _sending.add(entry.path);
      _progress[entry.path] = 0;
    });
    final saved = await widget.mesh.pushLocalFile(
      target,
      entry.path,
      onProgress: (sent, total) {
        if (!mounted) return;
        setState(() {
          _progress[entry.path] = total > 0 ? sent / total : 0;
        });
      },
    );
    if (!mounted) return;
    setState(() {
      _sending.remove(entry.path);
      _progress.remove(entry.path);
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(saved != null
          ? 'Sent ${entry.name} to ${target.name}'
          : 'Could not send ${entry.name}: ${widget.mesh.lastFileError ?? 'unknown error'}'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final devices = _selectableDevices();
    final device = _device;
    // The selected device was forgotten or vanished — fall back gracefully.
    if (device != null && !devices.any((d) => d.id == device.id)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (devices.isNotEmpty) {
          _selectDevice(devices.first);
        } else {
          setState(() {
            _device = null;
            _entries = null;
          });
        }
      });
    }

    if (devices.isEmpty) {
      return _EmptyFiles(mesh: widget.mesh);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
          child: Text('Files', style: Theme.of(context).textTheme.headlineMedium),
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            'Browse and pull files from your devices — over LAN at home, or from '
            'anywhere via a Tailscale address.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        const SizedBox(height: 14),
        // Device picker: one chip per paired device, online ones first.
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  selected: _local,
                  onSelected: (_) => _selectLocal(),
                  avatar: const Icon(Icons.devices_rounded, size: 16, color: NexusColors.accent),
                  label: const Text('This device', overflow: TextOverflow.ellipsis),
                  labelStyle: const TextStyle(fontSize: 13),
                  selectedColor: NexusColors.accent.withValues(alpha: 0.16),
                  backgroundColor: NexusColors.surface,
                  side: BorderSide(
                    color: _local ? NexusColors.accent : NexusColors.border,
                  ),
                ),
              ),
              for (final d in devices)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    selected: device?.id == d.id,
                    onSelected: (_) => _selectDevice(d),
                    avatar: Icon(
                      platformIcon(d.platform),
                      size: 16,
                      color: widget.mesh.isOnline(d.id) ? NexusColors.ok : NexusColors.muted,
                    ),
                    label: Text(d.name, overflow: TextOverflow.ellipsis),
                    labelStyle: const TextStyle(fontSize: 13),
                    selectedColor: NexusColors.accent.withValues(alpha: 0.16),
                    backgroundColor: NexusColors.surface,
                    side: BorderSide(
                      color: device?.id == d.id ? NexusColors.accent : NexusColors.border,
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        // Path bar with navigation controls.
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              IconButton(
                onPressed: _path.isEmpty || _loading ? null : _goUp,
                tooltip: 'Up',
                icon: const Icon(Icons.arrow_upward_rounded, size: 20),
              ),
              IconButton(
                onPressed: _path.isEmpty || _loading
                    ? null
                    : () {
                        setState(() {
                          _path = '';
                          _entries = null;
                        });
                        _load();
                      },
                tooltip: 'Home',
                icon: const Icon(Icons.home_rounded, size: 20),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _path.isEmpty
                      ? (_local ? 'This device · Home' : '${device?.name ?? ''} · Home')
                      : _path,
                  style: const TextStyle(fontSize: 13, color: NexusColors.muted),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (_local)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: FilledButton.tonalIcon(
                    onPressed: _sending.isNotEmpty ? null : _pickAndSend,
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                    icon: const Icon(Icons.upload_file_rounded, size: 18),
                    label: const Text('Send file…'),
                  ),
                ),
              IconButton(
                onPressed: _loading ? null : _load,
                tooltip: 'Refresh',
                icon: const Icon(Icons.refresh_rounded, size: 20),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(child: _buildBody(context)),
      ],
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading && _entries == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.folder_off_rounded, size: 40, color: NexusColors.muted),
              const SizedBox(height: 10),
              Text(_error!, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Try again'),
              ),
            ],
          ),
        ),
      );
    }
    final entries = _entries;
    if (entries == null || entries.isEmpty) {
      return Center(
        child: Text(
          'This folder is empty.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        itemCount: entries.length,
        itemBuilder: (context, i) => _EntryRow(
          entry: entries[i],
          local: _local,
          progress: _progress[entries[i].path],
          busy: _downloading.contains(entries[i].path) || _sending.contains(entries[i].path),
          onTap: () => _open(entries[i]),
        ),
      ),
    );
  }
}

class _EntryRow extends StatelessWidget {
  final FileEntry entry;
  final bool local; // this device's own folder → send, not download
  final double? progress;
  final bool busy;
  final VoidCallback onTap;

  const _EntryRow({
    required this.entry,
    required this.local,
    required this.progress,
    required this.busy,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: busy ? null : onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    entry.isDir ? Icons.folder_rounded : Icons.insert_drive_file_rounded,
                    size: 20,
                    color: entry.isDir ? NexusColors.accent : NexusColors.muted,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      entry.name,
                      style: Theme.of(context).textTheme.bodyMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (busy && progress != null)
                    SizedBox(
                      width: 26,
                      height: 26,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          CircularProgressIndicator(
                            strokeWidth: 2.5,
                            value: progress!,
                            color: NexusColors.accent,
                            backgroundColor: NexusColors.surfaceHi,
                          ),
                          Text(
                            '${(progress! * 100).round()}',
                            style: const TextStyle(fontSize: 8, color: NexusColors.muted),
                          ),
                        ],
                      ),
                    )
                  else if (!entry.isDir)
                    IconButton(
                      onPressed: onTap,
                      tooltip: local ? 'Send' : 'Download',
                      icon: Icon(
                        local ? Icons.send_rounded : Icons.download_rounded,
                        size: 20,
                        color: NexusColors.accent,
                      ),
                    ),
                ],
              ),
              if (entry.isDir)
                Padding(
                  padding: const EdgeInsets.only(left: 32),
                  child: Text(
                    'Folder',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.only(left: 32),
                  child: Text(
                    '${_size(entry.size)} · ${_when(entry.modified)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

String _size(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

String _when(DateTime t) {
  final now = DateTime.now();
  if (t.year == now.year && t.month == now.month && t.day == now.day) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return 'Today $h:$m';
  }
  return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
}

class _EmptyFiles extends StatelessWidget {
  final MeshService mesh;
  const _EmptyFiles({required this.mesh});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.folder_rounded, size: 44, color: NexusColors.muted),
            const SizedBox(height: 12),
            Text('No devices yet', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              'Pair a device and its home folder becomes browsable here — '
              'from LAN at home, or anywhere via Tailscale.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
