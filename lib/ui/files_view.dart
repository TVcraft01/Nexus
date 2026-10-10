import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart'
    show
        CupertinoActionSheetAction,
        CupertinoActivityIndicator,
        CupertinoAlertDialog,
        CupertinoDialogAction,
        CupertinoSliverRefreshControl,
        CupertinoTextField;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;

import '../mesh/mesh_service.dart';
import 'components/nexus_ui.dart'
    show
        NexusEmptyState,
        NexusPageHeader,
        NexusRow,
        fileTypeIcon,
        platformIcon,
        showNexusActions,
        showNexusSheet;
import 'downloads_dir.dart';
import 'theme.dart';

/// Browse files on any device in the mesh over the encrypted channel.
///
/// Each device serves its own files (see [MeshService.fileRoot]); this view
/// lets you pick any paired device, walk its folders, download or delete
/// files on it — or send a file to a device via the native picker (it lands
/// in the peer's "Nexus Incoming" folder). Works on LAN and — via a
/// Tailscale address — from anywhere.
class FilesView extends StatefulWidget {
  final MeshService mesh;
  const FilesView({super.key, required this.mesh});

  @override
  State<FilesView> createState() => _FilesViewState();
}

class _FilesViewState extends State<FilesView> {
  PairedDevice? _device;
  String _path = ''; // '' = the device's home
  List<FileEntry>? _entries;
  bool _loading = false;
  String? _error;
  final Map<String, double> _progress = {}; // entry path -> 0..1
  final Set<String> _downloading = {};
  final Set<String> _sending = {};
  final Set<String> _deleting = {};
  final Set<String> _operating = {};

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
      _device = device;
      _path = '';
      _entries = null;
      _error = null;
      _progress.clear();
      _downloading.clear();
      _sending.clear();
      _deleting.clear();
      _operating.clear();
    });
    _load();
  }

  Future<void> _load() async {
    if (_loading) return;
    final device = _device;
    if (device == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final entries = await widget.mesh.listRemoteFiles(device, _path);
    if (!mounted || device.id != _device?.id) return;
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

  Future<void> _download(FileEntry entry) async {
    final device = _device;
    if (device == null || _downloading.contains(entry.path)) return;
    setState(() {
      _downloading.add(entry.path);
      _progress[entry.path] = 0;
    });

    final savePath = await downloadsFilePath(entry.name);

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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          file != null
              ? 'Saved ${entry.name} to $savePath'
              : 'Could not download ${entry.name}: ${widget.mesh.lastFileError ?? 'unknown error'}',
        ),
      ),
    );
  }

  /// Deletes [entry] on the remote device after a confirmation — the same
  /// primitive the file-manager mount uses, so folders must be empty.
  Future<void> _delete(FileEntry entry) async {
    final device = _device;
    if (device == null || _deleting.contains(entry.path)) return;
    final confirmed = await showDialog<bool>(
      context: context,
      // iOS anatomy: one sentence, then Cancel and the destructive action in
      // the platform's red ink.
      builder: (context) => CupertinoAlertDialog(
        title: Text('Delete ${entry.name}?'),
        content: Text(
          entry.isDir
              ? 'It will be removed from ${device.name} — only if empty.'
              : 'It will be removed from ${device.name}.',
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _deleting.add(entry.path));
    final ok = await widget.mesh.deleteRemoteFile(device, entry.path);
    if (!mounted) return;
    setState(() => _deleting.remove(entry.path));
    if (ok) {
      setState(() => _entries?.removeWhere((e) => e.path == entry.path));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Could not delete ${entry.name}: '
            '${widget.mesh.lastFileError ?? 'unknown error'}',
          ),
        ),
      );
    }
  }

  Future<void> _rename(FileEntry entry) async {
    final device = _device;
    if (device == null || _operating.contains(entry.path)) return;
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _RenameFileDialog(initialName: entry.name),
    );
    if (name == null || name.isEmpty || name == entry.name || !mounted) return;
    final destination = _joinPath(_path, name);
    setState(() => _operating.add(entry.path));
    final result = await widget.mesh.operateRemoteFile(
      device,
      operation: 'rename',
      source: entry.path,
      destination: destination,
    );
    if (!mounted) return;
    setState(() => _operating.remove(entry.path));
    if (result == null) {
      _showFileError('Could not rename ${entry.name}');
    } else {
      _entries?.removeWhere((e) => e.path == entry.path);
      await _load();
    }
  }

  Future<void> _copyOrMove(FileEntry entry, {required bool move}) async {
    final source = _device;
    if (source == null || _operating.contains(entry.path)) return;
    final target = await _pickDestination();
    if (target == null || !mounted) return;
    final destination = _joinPath(target.path, entry.name);
    setState(() => _operating.add(entry.path));
    final result = await widget.mesh.transferRemoteFile(
      source,
      entry.path,
      target.device,
      destination,
      move: move,
    );
    if (!mounted) return;
    setState(() => _operating.remove(entry.path));
    if (result == null) {
      _showFileError('Could not ${move ? 'move' : 'copy'} ${entry.name}');
    } else {
      if (move && target.device.id == source.id) {
        _entries?.removeWhere((e) => e.path == entry.path);
      }
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${move ? 'Moved' : 'Copied'} ${entry.name} to ${target.device.name}',
          ),
        ),
      );
    }
  }

  Future<_FileDestination?> _pickDestination() async {
    // Online peers first, exactly like the device chips above: the picker used
    // to take the raw pairing order, so it could open on a device that cannot
    // answer and sit on a spinner while the device the user was browsing sat
    // second in the same list.
    final devices = _selectableDevices();
    if (devices.isEmpty) return null;
    return showNexusSheet<_FileDestination>(
      context: context,
      builder: (context, controller) => _DestinationPicker(
        mesh: widget.mesh,
        devices: devices,
        // Open where the user already is, not on whatever is first.
        initial: _device,
        scroll: controller,
      ),
    );
  }

  void _showFileError(String prefix) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '$prefix: ${widget.mesh.lastFileError ?? 'unknown error'}',
        ),
      ),
    );
  }

  static String _joinPath(String directory, String name) {
    if (directory.isEmpty) return name;
    final separator = Platform.pathSeparator;
    return '${directory.endsWith(separator) ? directory.substring(0, directory.length - 1) : directory}$separator$name';
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the chosen file.')),
      );
      return;
    }
    await _send(
      FileEntry(
        name: picked.name.isNotEmpty ? picked.name : file.uri.pathSegments.last,
        path: picked.path,
        size: await file.length(),
        isDir: false,
        modified: await file.lastModified(),
      ),
    );
  }

  /// Sends a local file to a paired device: pick the target, then stream it
  /// over the encrypted mesh into the peer's "Nexus Incoming" folder.
  Future<void> _send(FileEntry entry) async {
    if (_sending.contains(entry.path)) return;
    final peers = widget.mesh.pairedDevices;
    if (peers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Pair a device first — there is nowhere to send it.'),
        ),
      );
      return;
    }
    final palette = NexusPalette.of(context);
    // "Which of these devices?" is the share sheet's question, and an action
    // sheet is its iOS answer: a page-sized sheet holding a title and two
    // rows is mostly empty space. Reachability stays in the glyph, the way a
    // device reads everywhere else — lit when the peer is up.
    final target = await showNexusActions<PairedDevice>(
      context: context,
      title: Text('Send ${entry.name} to…'),
      actions: (popup) => [
        for (final p in peers)
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(popup, p),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  platformIcon(p.platform),
                  size: 20,
                  color: widget.mesh.isOnline(p.id)
                      ? palette.success
                      : palette.textSecondary,
                ),
                const SizedBox(width: NexusSpace.sm),
                Text(p.name),
              ],
            ),
          ),
      ],
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          saved != null
              ? 'Sent ${entry.name} to ${target.name}'
              : 'Could not send ${entry.name}: ${widget.mesh.lastFileError ?? 'unknown error'}',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = NexusPalette.of(context);
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

    // The header belongs to the tab, not to the file listing — show it even
    // when there is nothing paired yet (the empty state below it). No icon
    // tile: it carried no state, and a tile beside a title is decoration.
    const header = Padding(
      padding: EdgeInsets.fromLTRB(
        NexusSpace.page,
        NexusSpace.xxl,
        NexusSpace.page,
        0,
      ),
      child: NexusPageHeader(
        title: 'Files',
        subtitle:
            'Browse, download and send files on your devices — over LAN at '
            'home, or from anywhere via a Tailscale address.',
      ),
    );

    if (devices.isEmpty) {
      return const Column(
        children: [
          header,
          Expanded(
            child: Center(
              child: Padding(
                padding: EdgeInsets.all(NexusSpace.page),
                child: NexusEmptyState(
                  icon: Icons.folder_rounded,
                  title: 'No devices yet',
                  message:
                      'Pair a device and its home folder becomes browsable '
                      'here — from LAN at home, or anywhere via Tailscale.',
                ),
              ),
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        header,
        const SizedBox(height: NexusSpace.lg),
        // Device picker: one chip per paired device, online ones first.
        SizedBox(
          height: NexusSize.minTouch,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: NexusSpace.page),
            children: [
              for (final d in devices)
                Padding(
                  padding: const EdgeInsets.only(right: NexusSpace.sm),
                  child: ChoiceChip(
                    selected: device?.id == d.id,
                    onSelected: (_) => _selectDevice(d),
                    avatar: Icon(
                      platformIcon(d.platform),
                      size: 16,
                      color: widget.mesh.isOnline(d.id)
                          ? palette.success
                          : palette.textSecondary,
                    ),
                    label: Text(d.name, overflow: TextOverflow.ellipsis),
                    labelStyle: NexusType.caption,
                    selectedColor: palette.accentTint(0.16),
                    backgroundColor: palette.surface,
                    side: BorderSide(
                      color: device?.id == d.id
                          ? palette.accent
                          : palette.separator,
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: NexusSpace.sm),
        // One action, one menu. "Send file…" is the only control on this screen
        // that creates something: it opens the picker and pushes a file to a
        // paired device, and nothing else does that. Up, Home and Refresh are
        // navigation and recovery, so they sit behind the menu rather than
        // competing with it for the same row.
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: NexusSpace.page),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _path.isEmpty ? '${device?.name ?? ''} · Home' : _path,
                  style: Theme.of(context).textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: NexusSpace.sm),
              FilledButton.icon(
                onPressed: _sending.isNotEmpty ? null : _pickAndSend,
                icon: const Icon(Icons.upload_file_rounded, size: 18),
                label: const Text('Send file…'),
              ),
              PopupMenuButton<String>(
                tooltip: 'More',
                onSelected: (action) {
                  switch (action) {
                    case 'up':
                      _goUp();
                    case 'home':
                      setState(() {
                        _path = '';
                        _entries = null;
                      });
                      _load();
                    case 'refresh':
                      _load();
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'up',
                    enabled: _path.isNotEmpty && !_loading,
                    child: const Text('Up one level'),
                  ),
                  PopupMenuItem(
                    value: 'home',
                    enabled: _path.isNotEmpty && !_loading,
                    child: const Text('Home'),
                  ),
                  PopupMenuItem(
                    value: 'refresh',
                    enabled: !_loading,
                    child: const Text('Refresh'),
                  ),
                ],
                // An explicit token, not the framework default: a
                // PopupMenuButton icon does not inherit iconButtonTheme, and
                // an unset colour renders plain white — louder than any other
                // icon in the app.
                icon: Icon(
                  Icons.more_vert_rounded,
                  color: palette.textSecondary,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: NexusSpace.sm),
        Divider(height: 1, color: palette.separator),
        Expanded(child: _buildBody(context)),
      ],
    );
  }

  Widget _buildBody(BuildContext context) {
    final palette = NexusPalette.of(context);
    if (_loading && _entries == null) {
      // The iOS spinner. There is nothing to measure here — the mesh knows
      // how many bytes a download has moved, not how many folders are left —
      // so the indeterminate spinner is the honest one.
      return const Center(child: CupertinoActivityIndicator(radius: 12));
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(NexusSpace.page),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.folder_off_rounded,
                size: 40,
                color: palette.textSecondary,
              ),
              const SizedBox(height: NexusSpace.sm),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: NexusSpace.lg),
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
    // Rows on the page, separated by hairlines — not a rounded card each.
    //
    // A sliver list rather than a ListView, because the refresh control is a
    // sliver: Cupertino's pull-to-refresh is part of the scroll itself — it
    // moves with the finger and springs back on release — where the Material
    // indicator is an overlay on a fixed 150/200 ms curve that cannot be
    // grabbed once the pull has started.
    return CustomScrollView(
      // A flick throws the list (momentum projection) and the next flick
      // carries the speed the last one left, which is what makes a fast
      // scroll feel thrown rather than driven. At an edge the list resists
      // progressively instead of stopping dead. Android's default physics
      // does neither: by the framework's own documentation it "doesn't carry
      // momentum", and its clamping boundary is a hard stop with a glow.
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      slivers: [
        CupertinoSliverRefreshControl(onRefresh: _load),
        SliverList.separated(
          itemCount: entries.length,
          separatorBuilder: (context, _) => Divider(
            height: 1,
            indent: NexusSpace.lg,
            color: palette.separator,
          ),
          itemBuilder: (context, i) => _EntryRow(
            entry: entries[i],
            progress: _progress[entries[i].path],
            busy:
                _downloading.contains(entries[i].path) ||
                _sending.contains(entries[i].path) ||
                _operating.contains(entries[i].path),
            deleting: _deleting.contains(entries[i].path),
            operating: _operating.contains(entries[i].path),
            onTap: () => _open(entries[i]),
            onDelete: () => _delete(entries[i]),
            onRename: () => _rename(entries[i]),
            onCopy: () => _copyOrMove(entries[i], move: false),
            onMove: () => _copyOrMove(entries[i], move: true),
          ),
        ),
        const SliverPadding(padding: EdgeInsets.only(bottom: NexusSpace.xxl)),
      ],
    );
  }
}

/// Renames a file.
///
/// The dialog owns its own field controller. Handing one in from the caller
/// and disposing it as soon as the route pops is not safe: the field is still
/// mounted while the route animates out, and reads a controller that is
/// already gone — the framework says so, in as many words, the moment the
/// dialog is driven for real.
class _RenameFileDialog extends StatefulWidget {
  const _RenameFileDialog({required this.initialName});

  final String initialName;

  @override
  State<_RenameFileDialog> createState() => _RenameFileDialogState();
}

class _RenameFileDialogState extends State<_RenameFileDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialName,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _controller.text.trim());

  @override
  Widget build(BuildContext context) {
    return CupertinoAlertDialog(
      title: const Text('Rename'),
      content: Padding(
        padding: const EdgeInsets.only(top: NexusSpace.md),
        child: CupertinoTextField(
          controller: _controller,
          autofocus: true,
          placeholder: 'New name',
          onSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        CupertinoDialogAction(
          isDefaultAction: true,
          onPressed: _submit,
          child: const Text('Rename'),
        ),
      ],
    );
  }
}

class _FileDestination {
  final PairedDevice device;
  final String path;
  const _FileDestination(this.device, this.path);
}

class _DestinationPicker extends StatefulWidget {
  final MeshService mesh;
  final List<PairedDevice> devices;

  /// The device being browsed, so the sheet opens where the user already is.
  final PairedDevice? initial;

  /// The sheet's scroll controller. The framework reads it to know when the
  /// folder list is at its top, which is when a downward drag should dismiss
  /// the sheet rather than scroll the folders.
  final ScrollController scroll;

  const _DestinationPicker({
    required this.mesh,
    required this.devices,
    required this.scroll,
    this.initial,
  });

  @override
  State<_DestinationPicker> createState() => _DestinationPickerState();
}

class _DestinationPickerState extends State<_DestinationPicker> {
  late PairedDevice _device = widget.initial ?? widget.devices.first;
  String _path = '';
  List<FileEntry>? _entries;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final entries = await widget.mesh.listRemoteFiles(_device, _path);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _entries = entries?.where((entry) => entry.isDir).toList();
      _error = entries == null ? widget.mesh.lastFileError : null;
    });
  }

  void _selectDevice(PairedDevice device) {
    setState(() {
      _device = device;
      _path = '';
      _entries = null;
    });
    _load();
  }

  void _open(FileEntry entry) {
    setState(() {
      _path = entry.path;
      _entries = null;
    });
    _load();
  }

  void _up() {
    if (_path.isEmpty) return;
    final separator = Platform.pathSeparator;
    final index = _path.lastIndexOf(separator);
    setState(() {
      _path = index <= 0 ? '' : _path.substring(0, index);
      _entries = null;
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final palette = NexusPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NexusSpace.lg,
        NexusSpace.md,
        NexusSpace.lg,
        NexusSpace.lg,
      ),
      // The sheet is as tall as the screen allows, so the folder list takes
      // what is left after the header instead of a fixed 72% of the display.
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                onPressed: _path.isEmpty ? null : _up,
                tooltip: 'Up',
                icon: const Icon(Icons.arrow_upward_rounded),
              ),
              Expanded(
                child: Text(
                  'Choose destination',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              FilledButton.icon(
                onPressed: () =>
                    Navigator.pop(context, _FileDestination(_device, _path)),
                icon: const Icon(Icons.check_rounded, size: 18),
                label: const Text('Choose here'),
              ),
            ],
          ),
          const SizedBox(height: NexusSpace.xs),
          SizedBox(
                height: NexusSize.minTouch,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final device in widget.devices)
                      Padding(
                        padding: const EdgeInsets.only(right: NexusSpace.sm),
                        child: ChoiceChip(
                          selected: device.id == _device.id,
                          label: Text(device.name),
                          avatar: Icon(platformIcon(device.platform), size: 16),
                          onSelected: (_) => _selectDevice(device),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: NexusSpace.sm),
              Text(
                _path.isEmpty ? '${_device.name} · Home' : _path,
                style: Theme.of(context).textTheme.bodySmall,
                overflow: TextOverflow.ellipsis,
              ),
              Divider(height: NexusSpace.xl, color: palette.separator),
              if (_loading)
                const Expanded(
                  child: Center(child: CupertinoActivityIndicator(radius: 12)),
                )
              else if (_error != null)
                Expanded(
                  child: Center(
                    child: Text(_error!, textAlign: TextAlign.center),
                  ),
                )
              else if (_entries == null || _entries!.isEmpty)
                const Expanded(
                  child: Center(child: Text('No subfolders here.')),
                )
              else
                Expanded(
                  child: ListView.builder(
                    controller: widget.scroll,
                    itemCount: _entries!.length,
                    itemBuilder: (context, index) {
                      final entry = _entries![index];
                      return NexusRow(
                        title: entry.name,
                        minHeight: NexusSize.rowCompact,
                        leading: Icon(
                          Icons.folder_rounded,
                          size: 22,
                          color: palette.accent,
                        ),
                        chevron: true,
                        onTap: () => _open(entry),
                      );
                    },
                  ),
                ),
        ],
      ),
    );
  }
}

/// One file in the listing: what it is, what it is called, how big and how
/// old — and nothing else.
///
/// This is the drive-app shape: the icon names the type, the name is the row,
/// and the size and date sit under it in the quiet voice. There is no button
/// per row — a list with a download button and a menu on every line is a
/// toolbar wearing a list's clothes, and the row itself is the target. The
/// actions are one long press away, and they are also published as the row's
/// own accessibility actions, because a screen reader cannot press and hold.
class _EntryRow extends StatelessWidget {
  final FileEntry entry;
  final double? progress;
  final bool busy;
  final bool deleting;
  final bool operating;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback onRename;
  final VoidCallback onCopy;
  final VoidCallback onMove;

  const _EntryRow({
    required this.entry,
    required this.progress,
    required this.busy,
    required this.deleting,
    required this.operating,
    required this.onTap,
    required this.onDelete,
    required this.onRename,
    required this.onCopy,
    required this.onMove,
  });

  /// The four things you can do to a file, in the order both the menu and the
  /// accessibility actions show them.
  List<({String label, IconData icon, VoidCallback run})> get _actions => [
    (label: 'Rename', icon: Icons.edit_outlined, run: onRename),
    (label: 'Copy to…', icon: Icons.copy_rounded, run: onCopy),
    (label: 'Move to…', icon: Icons.drive_file_move_outlined, run: onMove),
    (label: 'Delete', icon: Icons.delete_outline_rounded, run: onDelete),
  ];

  @override
  Widget build(BuildContext context) {
    final palette = NexusPalette.of(context);
    return NexusRow(
      title: entry.name,
      // A folder's second line is what it is; a file's is how big and how old.
      subtitle: entry.isDir
          ? 'Folder'
          : '${_size(entry.size)} · ${_when(entry.modified)}',
      leading: Icon(
        fileTypeIcon(name: entry.name, isDir: entry.isDir),
        size: 24,
        color: palette.textSecondary,
      ),
      // A folder goes somewhere, so it gets the one trailing chevron a row is
      // allowed. A file is the thing itself: tapping it fetches it, and the
      // chevron would promise another screen that does not exist.
      chevron: entry.isDir,
      trailing: _progressIndicator(palette),
      // A row at work keeps its shape and loses only its response: the file
      // being downloaded is still the row the finger landed on.
      enabled: !busy,
      onTap: onTap,
      onLongPress: () => _showActions(context),
      customActions: {
        for (final action in _actions)
          CustomSemanticsAction(label: action.label): action.run,
      },
    );
  }

  /// The row's own work, if it has any: a bare ring while the file is being
  /// moved or renamed, and a filled ring with the percentage while bytes are
  /// actually moving.
  Widget? _progressIndicator(NexusPalette palette) {
    if (deleting || operating) {
      return const SizedBox(
        width: 22,
        height: 22,
        child: CupertinoActivityIndicator(radius: 9),
      );
    }
    if (!busy || progress == null) return null;
    return SizedBox(
      width: 26,
      height: 26,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CircularProgressIndicator(
            strokeWidth: 2.5,
            value: progress,
            color: palette.accent,
            backgroundColor: palette.surfaceSecondary,
          ),
          Text(
            '${(progress! * 100).round()}',
            style: NexusType.micro.copyWith(color: palette.textSecondary),
          ),
        ],
      ),
    );
  }

  /// The long-press menu. It hands back a label instead of running the handler
  /// itself so the sheet is closed before the work starts — a rename dialog
  /// opening on top of a sheet that is still on screen is two modals deep.
  Future<void> _showActions(BuildContext context) async {
    final chosen = await showNexusActions<String>(
      context: context,
      title: Text(
        entry.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      actions: (popup) {
        final palette = NexusPalette.of(popup);
        return [
          for (final action in _actions)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(popup, action.label),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    action.icon,
                    size: 20,
                    // Delete is the one verb that cannot be undone, so it is
                    // the one that is not the ordinary ink.
                    color: action.label == 'Delete'
                        ? palette.danger
                        : palette.textSecondary,
                  ),
                  const SizedBox(width: NexusSpace.sm),
                  Text(
                    action.label,
                    style: action.label == 'Delete'
                        ? TextStyle(color: palette.danger)
                        : null,
                  ),
                ],
              ),
            ),
        ];
      },
    );
    if (chosen == null) return;
    for (final action in _actions) {
      if (action.label == chosen) action.run();
    }
  }
}

String _size(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
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

