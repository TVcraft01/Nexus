import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart'
    show
        CupertinoActionSheetAction,
        CupertinoActivityIndicator,
        CupertinoAlertDialog,
        CupertinoDialogAction,
        CupertinoSearchTextField,
        CupertinoSliverRefreshControl,
        CupertinoTextField;
import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart' show SpringSimulation;
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter/semantics.dart' show CustomSemanticsAction;

import '../mesh/mesh_service.dart';
import 'components/nexus_ui.dart'
    show
        NexusChoicePill,
        NexusEmptyState,
        NexusPageHeader,
        NexusPressable,
        NexusRow,
        fileTypeIcon,
        platformIcon,
        showNexusActions,
        showNexusSheet;
import 'downloads_dir.dart';
import 'theme.dart';

/// How the listing is ordered. Folders always lead whatever this says: the
/// drive apps this screen is built after never sort a folder down among the
/// files, and neither does this one.
enum _FileSort {
  name('Name'),
  date('Date'),
  size('Size');

  const _FileSort(this.label);

  final String label;
}

/// How the listing is drawn: rows, or a grid of tiles.
enum _FileLayout { list, grid }

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

  /// The folders walked into, oldest first — the breadcrumb, and the only
  /// record of where the user actually came from. The device's home is not on
  /// it: that is the crumb before the first entry.
  ///
  /// The entries themselves rather than a split of [_path] on the separator,
  /// because [_path] is an absolute path on *another* machine: its parents are
  /// directories this app has no listing for, and going up from
  /// `/home/neo/Docs` is not `/home/neo`.
  final List<FileEntry> _trail = [];

  /// What the search field holds. Filters this listing by name — the mesh has
  /// no remote search, so nothing is asked of the peer.
  final TextEditingController _search = TextEditingController();
  String _query = '';

  /// The breadcrumb's own scroll, moved to its end whenever the path changes:
  /// a crumb row is read from the deep end, and a jump into a nested folder
  /// must not leave the fold the user just entered off screen.
  final ScrollController _trailScroll = ScrollController();

  _FileSort _sort = _FileSort.name;
  _FileLayout _layout = _FileLayout.list;

  /// The row whose actions are showing, by path. One at a time: a second swipe
  /// closes the first, which is the one thing a list of revealed rows does not
  /// do by itself.
  String? _revealed;

  @override
  void initState() {
    super.initState();
    // Read before the first frame, so the listing never draws in one shape and
    // then jumps to the other.
    _sort = _FileSort.values.firstWhere(
      (s) => s.name == widget.mesh.store.fileSort,
      orElse: () => _FileSort.name,
    );
    _layout = widget.mesh.store.fileLayout == 'grid'
        ? _FileLayout.grid
        : _FileLayout.list;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final devices = _selectableDevices();
      if (devices.isNotEmpty) _selectDevice(devices.first);
    });
  }

  @override
  void dispose() {
    _search.dispose();
    _trailScroll.dispose();
    super.dispose();
  }

  /// Puts the breadcrumb's deep end in view once the new path has been laid
  /// out. After the frame, because the extent of a row that has not been
  /// measured yet is zero.
  void _crumbsToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_trailScroll.hasClients) return;
      final end = _trailScroll.position.maxScrollExtent;
      if (_trailScroll.offset != end) _trailScroll.jumpTo(end);
    });
  }

  /// Remembers one view preference and gets out of the way: a preference that
  /// fails to persist must never stop the listing changing now.
  void _persist(void Function() write) {
    write();
    unawaited(widget.mesh.store.save());
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
      _trail.clear();
      _revealed = null;
      _query = '';
    });
    _search.clear();
    _crumbsToEnd();
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
    if (!entry.isDir) {
      _download(entry);
      return;
    }
    setState(() {
      _trail.add(entry);
      _path = entry.path;
      _entries = null;
      _revealed = null;
      // A search is a search of where you are: carrying it into the folder you
      // just opened would show an empty listing for a folder that is not.
      _query = '';
    });
    _search.clear();
    _crumbsToEnd();
    _load();
  }

  /// Back to the device's home — the crumb before the first entry.
  void _goHome() {
    if (_trail.isEmpty) return;
    setState(() {
      _trail.clear();
      _path = '';
      _entries = null;
      _revealed = null;
      _query = '';
    });
    _search.clear();
    _crumbsToEnd();
    _load();
  }

  /// Back to the folder at [index] in the trail, dropping everything walked
  /// through after it: the trail is where the user has been, and jumping back
  /// means those folders are no longer part of the walk.
  ///
  /// This is the move the Up and Home it replaced could not make — sideways to
  /// a folder the user actually came from, in one tap.
  void _goTo(int index) {
    if (index < 0 || index >= _trail.length) return;
    setState(() {
      _path = _trail[index].path;
      _trail.removeRange(index + 1, _trail.length);
      _entries = null;
      _revealed = null;
      _query = '';
    });
    _search.clear();
    _crumbsToEnd();
    _load();
  }

  /// What the listing shows right now: the folder's entries, filtered by the
  /// search field and put in the chosen order.
  List<FileEntry> get _visible {
    final entries = _entries ?? const <FileEntry>[];
    final query = _query.trim().toLowerCase();
    final matched = query.isEmpty
        ? entries.toList()
        : entries
              .where((e) => e.name.toLowerCase().contains(query))
              .toList();
    int order(FileEntry a, FileEntry b) => switch (_sort) {
      _FileSort.name => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      // Newest first: "by date" in a file browser means the thing you just
      // wrote, not the oldest thing on the disk.
      _FileSort.date => b.modified.compareTo(a.modified),
      _FileSort.size => b.size.compareTo(a.size),
    };
    matched.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      final byChosen = order(a, b);
      // A stable tie-break, so two files of the same size do not swap places
      // every time the listing is re-read.
      return byChosen != 0 ? byChosen : a.name.compareTo(b.name);
    });
    return matched;
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
                  child: NexusChoicePill(
                    selected: device?.id == d.id,
                    onTap: () => _selectDevice(d),
                    icon: platformIcon(d.platform),
                    iconColor: widget.mesh.isOnline(d.id)
                        ? palette.success
                        : palette.textSecondary,
                    label: d.name,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: NexusSpace.sm),
        // The path is a breadcrumb now. "Send file…" is still the only control
        // here that creates anything; everything else the screen can do —
        // order the listing, change its shape, ask the peer again — is behind
        // the overflow. Up and Home are gone: they could only ever move one
        // step, and a crumb goes to any folder the user has actually been in.
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: NexusSpace.page),
          child: Row(
            children: [
              Expanded(child: _breadcrumb(context, palette)),
              const SizedBox(width: NexusSpace.sm),
              FilledButton.icon(
                onPressed: _sending.isNotEmpty ? null : _pickAndSend,
                icon: const Icon(Icons.upload_file_rounded, size: 18),
                label: const Text('Send file…'),
              ),
              IconButton(
                tooltip: 'More',
                onPressed: _loading ? null : _showOverflow,
                icon: Icon(
                  Icons.more_vert_rounded,
                  color: palette.textSecondary,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: NexusSpace.sm),
        // iOS Files' own search field, filtering the listing already on
        // screen: the mesh serves listings, not queries, so nothing here is
        // asked of the peer.
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: NexusSpace.page),
          child: CupertinoSearchTextField(
            controller: _search,
            placeholder: 'Search this folder',
            onChanged: (value) => setState(() => _query = value),
          ),
        ),
        const SizedBox(height: NexusSpace.sm),
        Divider(height: 1, color: palette.separator),
        Expanded(child: _buildBody(context)),
      ],
    );
  }


  /// The path as crumbs: the device's home, then one crumb per folder the user
  /// opened. The last one is where they already are and is not a control;
  /// every other one goes back to it.
  ///
  /// The home crumb reads exactly as the old path line did, so the top of a
  /// listing still starts with the same words. What changed is the way back:
  /// the path itself is the control now, instead of a menu item that could
  /// only ever step up once.
  Widget _breadcrumb(BuildContext context, NexusPalette palette) {
    final crumbs = <({String label, VoidCallback? open})>[
      (
        label: '${_device?.name ?? ''} · Home',
        open: _trail.isEmpty ? null : _goHome,
      ),
      for (final (i, folder) in _trail.indexed)
        (label: folder.name, open: i == _trail.length - 1 ? null : () => _goTo(i)),
    ];
    final style = Theme.of(context).textTheme.bodySmall;
    return SizedBox(
      height: NexusSize.minTouch,
      // Read from its end: a path too long for the row keeps the folder the
      // listing belongs to on screen and lets the top of the tree run off the
      // leading edge, which is the half a user already knows. A path that fits
      // starts at the page margin, where the path line it replaced started.
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        controller: _trailScroll,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (i, crumb) in crumbs.indexed) ...[
              if (i > 0)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: NexusSpace.xs,
                    ),
                    child: Text(
                      '\u203a',
                      style: style?.copyWith(color: palette.textTertiary),
                    ),
                  ),
                ),
              if (crumb.open == null)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.only(right: NexusSpace.md),
                    child: Text(
                      crumb.label,
                      style: style?.copyWith(
                        color: palette.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                )
              else
                // The crumb keeps its text's width and the row's full height,
                // so the first one starts on the page margin — where the path
                // line it replaced started.
                NexusPressable(
                  borderRadius: BorderRadius.circular(NexusRadius.xs),
                  onTap: crumb.open,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.only(right: NexusSpace.md),
                      child: Text(crumb.label, style: style),
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  /// Everything the toolbar can do besides send a file, as an action sheet —
  /// the shape iOS gives a short list of verbs. This was a Material
  /// `PopupMenuButton`: a Material menu inside Cupertino chrome, in an app that
  /// had converted every other menu it owns.
  Future<void> _showOverflow() async {
    HapticFeedback.selectionClick();
    final chosen = await showNexusActions<String>(
      context: context,
      actions: (popup) => [
        CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(popup, 'sort'),
          child: const Text('Sort'),
        ),
        CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(popup, 'layout'),
          child: Text(_layout == _FileLayout.list ? 'Grid view' : 'List view'),
        ),
        CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(popup, 'refresh'),
          child: const Text('Refresh'),
        ),
      ],
    );
    if (chosen == null || !mounted) return;
    switch (chosen) {
      case 'sort':
        // After this sheet has closed: two sheets stacked is a stack the user
        // has to unwind twice.
        await _showSortSheet();
      case 'layout':
        final next = _layout == _FileLayout.list
            ? _FileLayout.grid
            : _FileLayout.list;
        setState(() {
          _layout = next;
          _revealed = null;
        });
        _persist(() => widget.mesh.store.fileLayout = next.name);
      case 'refresh':
        _load();
    }
  }

  /// Order the listing by. Three choices are read faster than they are aimed
  /// at, and the one in force is marked.
  Future<void> _showSortSheet() async {
    final chosen = await showNexusActions<_FileSort>(
      context: context,
      title: const Text('Sort by'),
      actions: (popup) => [
        for (final sort in _FileSort.values)
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(popup, sort),
            child: Text(sort == _sort ? '${sort.label}  \u2713' : sort.label),
          ),
      ],
    );
    if (chosen == null || !mounted || chosen == _sort) return;
    setState(() => _sort = chosen);
    _persist(() => widget.mesh.store.fileSort = chosen.name);
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
    final entries = _visible;
    if (entries.isEmpty) {
      // Two different nothings. Saying "this folder is empty" to a search is a
      // lie the user cannot see through — the folder may be full.
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(NexusSpace.page),
          child: Text(
            _query.trim().isEmpty
                ? 'This folder is empty.'
                : 'Nothing here matches \u201c${_query.trim()}\u201d.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      );
    }
    // A sliver list rather than a ListView, because the refresh control is a
    // sliver: Cupertino's pull-to-refresh is part of the scroll itself — it
    // moves with the finger and springs back on release — where the Material
    // indicator is an overlay on a fixed 150/200 ms curve that cannot be
    // grabbed once the pull has started.
    return CustomScrollView(
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      slivers: [
        CupertinoSliverRefreshControl(onRefresh: _load),
        if (_layout == _FileLayout.grid)
          SliverPadding(
            padding: const EdgeInsets.all(NexusSpace.page),
            sliver: SliverGrid.builder(
              itemCount: entries.length,
              // Three columns on a phone, more as the window grows, and never a
              // tile so wide that its glyph floats in the middle of it.
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 124,
                mainAxisSpacing: NexusSpace.md,
                crossAxisSpacing: NexusSpace.md,
                childAspectRatio: 0.82,
              ),
              itemBuilder: (context, i) => _EntryTile(
                entry: entries[i],
                progress: _progress[entries[i].path],
                busy: _busy(entries[i]),
                onTap: () => _open(entries[i]),
                onDelete: () => _delete(entries[i]),
                onRename: () => _rename(entries[i]),
                onActions: () => _showRowActions(entries[i], all: true),
              ),
            ),
          )
        else
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
              busy: _busy(entries[i]),
              deleting: _deleting.contains(entries[i].path),
              operating: _operating.contains(entries[i].path),
              // One row's actions at a time, decided here rather than inside
              // each row: two rows cannot both be half-open by accident.
              revealed: _revealed == entries[i].path,
              onReveal: (open) => setState(
                () => _revealed = open ? entries[i].path : null,
              ),
              onTap: () => _open(entries[i]),
              onDelete: () => _delete(entries[i]),
              onRename: () => _rename(entries[i]),
              onActions: () => _showRowActions(entries[i]),
            ),
          ),
        const SliverPadding(padding: EdgeInsets.only(bottom: NexusSpace.xxl)),
      ],
    );
  }

  /// Whether this entry is mid-flight: bytes moving, or a folder operation on
  /// it. One definition, because the list and the grid must agree about it.
  bool _busy(FileEntry entry) =>
      _downloading.contains(entry.path) ||
      _sending.contains(entry.path) ||
      _operating.contains(entry.path);

  /// The verbs that do not fit on a swipe, in an action sheet. Rename and
  /// Delete are the two the swipe reveals, so they are not repeated here; a
  /// screen reader still gets all four on the row itself, because it cannot
  /// swipe one open.
  Future<void> _showRowActions(FileEntry entry, {bool all = false}) async {
    final palette = NexusPalette.of(context);
    final chosen = await showNexusActions<String>(
      context: context,
      title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      actions: (popup) => [
        // In a grid there is no swipe to reveal anything, so the sheet carries
        // the whole set rather than leaving Rename and Delete unreachable.
        if (all)
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(popup, 'rename'),
            child: const Text('Rename'),
          ),
        CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(popup, 'copy'),
          child: const Text('Copy to…'),
        ),
        CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(popup, 'move'),
          child: const Text('Move to…'),
        ),
        if (all)
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(popup, 'delete'),
            child: Text('Delete', style: TextStyle(color: palette.danger)),
          ),
      ],
    );
    if (chosen == null || !mounted) return;
    switch (chosen) {
      case 'rename':
        await _rename(entry);
      case 'copy':
        await _copyOrMove(entry, move: false);
      case 'move':
        await _copyOrMove(entry, move: true);
      case 'delete':
        await _delete(entry);
    }
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
                        child: NexusChoicePill(
                          selected: device.id == _device.id,
                          label: device.name,
                          icon: platformIcon(device.platform),
                          onTap: () => _selectDevice(device),
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
/// toolbar wearing a list's clothes, and the row itself is the target.
///
/// A swipe to the left reveals the two verbs a person reaches for most, the
/// way iOS Files does it; the other two are one long press away. All four are
/// published as the row's own accessibility actions, because a screen reader
/// can neither press and hold nor swipe a row open.
class _EntryRow extends StatefulWidget {
  final FileEntry entry;
  final double? progress;
  final bool busy;
  final bool deleting;
  final bool operating;

  /// Whether this row's verbs are showing. Owned by the page, so two rows
  /// cannot both be open.
  final bool revealed;
  final ValueChanged<bool> onReveal;

  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback onRename;

  /// The rest of the verbs, as a sheet: Copy to… and Move to….
  final VoidCallback onActions;

  const _EntryRow({
    required this.entry,
    required this.progress,
    required this.busy,
    required this.deleting,
    required this.operating,
    required this.revealed,
    required this.onReveal,
    required this.onTap,
    required this.onDelete,
    required this.onRename,
    required this.onActions,
  });

  @override
  State<_EntryRow> createState() => _EntryRowState();
}

class _EntryRowState extends State<_EntryRow>
    with SingleTickerProviderStateMixin {
  /// How far the row has slid, 0 → [_verbsWidth]. Unbounded, so a spring can
  /// be handed it and a drag can re-target it mid-flight.
  late final AnimationController _slide = AnimationController.unbounded(
    vsync: this,
  );

  /// Wide enough for two labelled verbs at a thumb's width.
  static const double _verbsWidth = 168;

  /// Below this the row counts as shut. A spring approaches its target rather
  /// than reaching it, so "is it at zero" is never the right question.
  static const double _shut = 1;

  bool get _open => _slide.value > _shut;

  @override
  void didUpdateWidget(covariant _EntryRow old) {
    super.didUpdateWidget(old);
    // The page owns which row is open. When it says this one is not, the row
    // goes back on its own spring rather than being teleported shut.
    if (!widget.revealed && _open) _settle(0);
  }

  @override
  void dispose() {
    _slide.dispose();
    super.dispose();
  }

  void _settle(double target) {
    if (MediaQuery.maybeDisableAnimationsOf(context) == true) {
      _slide.value = target;
      return;
    }
    _slide.animateWith(
      SpringSimulation(
        NexusSpring.of(),
        _slide.value,
        target,
        _slide.velocity,
      ),
    );
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (widget.busy) return;
    // Leftward drag opens: the verbs live at the trailing edge, under the row.
    final next = (_slide.value - details.delta.dx).clamp(0.0, _verbsWidth);
    if (next == _slide.value) return;
    _slide.value = next;
    widget.onReveal(next > _verbsWidth / 2);
  }

  void _onDragEnd(DragEndDetails details) {
    if (widget.busy) return;
    final opening = _slide.value > _verbsWidth / 2;
    _settle(opening ? _verbsWidth : 0);
    widget.onReveal(opening);
  }

  /// The verbs the swipe carries, in the order they appear.
  List<({String label, IconData icon, Color color, VoidCallback run})> get _verbs => [
    (
      label: 'Rename',
      icon: Icons.edit_outlined,
      color: NexusPalette.of(context).accent,
      run: widget.onRename,
    ),
    (
      label: 'Delete',
      icon: Icons.delete_outline_rounded,
      color: NexusPalette.of(context).danger,
      run: widget.onDelete,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final palette = NexusPalette.of(context);
    return GestureDetector(
      onHorizontalDragUpdate: _onDragUpdate,
      onHorizontalDragEnd: _onDragEnd,
      // The row follows the finger from where it landed, not from where the
      // recogniser decided the drag had started. The default throws away the
      // movement that crossed the touch slop, so the row would lag the finger
      // by it on every swipe.
      dragStartBehavior: DragStartBehavior.down,
      child: Stack(
        children: [
          AnimatedBuilder(
            animation: _slide,
            builder: (context, _) => Positioned.fill(
              child: Align(
                alignment: Alignment.centerRight,
                child: SizedBox(
                  width: _verbsWidth,
                  child: !_open
                      // Not built at all while the row is shut: a verb that is
                      // in the tree but not on screen is something a screen
                      // reader still reads and a test still finds.
                      ? const SizedBox.shrink()
                      : Row(
                          children: [
                            for (final verb in _verbs)
                              Expanded(
                                child: _SwipeVerb(
                                  label: verb.label,
                                  icon: verb.icon,
                                  color: verb.color,
                                  onPressed: verb.run,
                                ),
                              ),
                          ],
                        ),
                ),
              ),
            ),
          ),
          AnimatedBuilder(
            animation: _slide,
            builder: (context, child) => Transform.translate(
              offset: Offset(-_slide.value, 0),
              child: child,
            ),
            // Opaque on the page's own colour, because the verbs are under it:
            // a row that let them show through would read as a busy row rather
            // than one with something behind it.
            child: ColoredBox(color: palette.bg, child: _row(context, palette)),
          ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, NexusPalette palette) {
    final entry = widget.entry;
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
      enabled: !widget.busy,
      onTap: () {
        // A row with its verbs showing answers a tap by putting them away: the
        // tap is not for the file while the row is open, which is the rule iOS
        // Files follows too.
        if (_open) {
          _settle(0);
          widget.onReveal(false);
          return;
        }
        widget.onTap();
      },
      onLongPress: widget.onActions,
      // All four, in the order the sheet and the swipe show them — including
      // the two the swipe carries, which a screen reader cannot reach.
      customActions: {
        CustomSemanticsAction(label: 'Rename'): widget.onRename,
        CustomSemanticsAction(label: 'Copy to…'): widget.onActions,
        CustomSemanticsAction(label: 'Move to…'): widget.onActions,
        CustomSemanticsAction(label: 'Delete'): widget.onDelete,
      },
    );
  }

  /// The row's own work, if it has any: a bare ring while the file is being
  /// moved or renamed, and a filled ring with the percentage while bytes are
  /// actually moving.
  Widget? _progressIndicator(NexusPalette palette) {
    if (widget.deleting || widget.operating) {
      return const SizedBox(
        width: 22,
        height: 22,
        child: CupertinoActivityIndicator(radius: 9),
      );
    }
    final progress = widget.progress;
    if (!widget.busy || progress == null) return null;
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
            '${(progress * 100).round()}',
            style: NexusType.micro.copyWith(color: palette.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// One revealed verb. A filled surface rather than a pressable outline: it is
/// only on screen while the finger is already moving, and the swipe that put it
/// there is the response — a second press highlight would be a second answer to
/// one gesture.
class _SwipeVerb extends StatelessWidget {
  const _SwipeVerb({
    required this.label,
    required this.icon,
    required this.color,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      button: true,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: ColoredBox(
          color: color.withValues(alpha: 0.14),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 20, color: color),
                const SizedBox(height: NexusSpace.xxs),
                ExcludeSemantics(
                  child: Text(
                    label,
                    style: NexusType.caption1.copyWith(color: color),
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

/// One file as a tile, for the grid.
///
/// The tile's "thumbnail" is the type glyph on a surface square. Deliberately
/// not a preview: a real one would mean pulling the file to look at it, and a
/// placeholder that looked like a picture would be a claim about what is on
/// screen that nothing here has checked.
class _EntryTile extends StatelessWidget {
  const _EntryTile({
    required this.entry,
    required this.progress,
    required this.busy,
    required this.onTap,
    required this.onDelete,
    required this.onRename,
    required this.onActions,
  });

  final FileEntry entry;
  final double? progress;
  final bool busy;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback onRename;
  final VoidCallback onActions;

  @override
  Widget build(BuildContext context) {
    final palette = NexusPalette.of(context);
    return Semantics(
      container: true,
      button: true,
      label: entry.isDir
          ? '${entry.name}, folder'
          : '${entry.name}, ${_size(entry.size)}',
      customSemanticsActions: {
        CustomSemanticsAction(label: 'Rename'): onRename,
        CustomSemanticsAction(label: 'Copy to…'): onActions,
        CustomSemanticsAction(label: 'Move to…'): onActions,
        CustomSemanticsAction(label: 'Delete'): onDelete,
      },
      child: NexusPressable(
        enabled: !busy,
        borderRadius: NexusRadius.card,
        onTap: onTap,
        onLongPress: onActions,
        child: ExcludeSemantics(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: palette.surface,
                    borderRadius: NexusRadius.card,
                    border: Border.all(color: palette.separator),
                  ),
                  child: Center(
                    child: busy && progress != null
                        ? SizedBox(
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
                                  style: NexusType.micro.copyWith(
                                    color: palette.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          )
                        : Icon(
                            fileTypeIcon(
                              name: entry.name,
                              isDir: entry.isDir,
                            ),
                            size: 30,
                            color: palette.textSecondary,
                          ),
                  ),
                ),
              ),
              const SizedBox(height: NexusSpace.sm),
              Text(
                entry.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: NexusType.caption1.copyWith(
                  color: palette.textPrimary,
                ),
              ),
              if (!entry.isDir)
                Text(
                  _size(entry.size),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: NexusType.caption2.copyWith(
                    color: palette.textTertiary,
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

