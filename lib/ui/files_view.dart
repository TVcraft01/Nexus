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
        fileSizeLabel,
        fileTypeIcon,
        platformIcon,
        showNexusActions,
        showNexusSheet;
import 'downloads_dir.dart';
import 'local_files.dart';
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

  /// Opens a local file with the platform's default viewer — what a Recent
  /// row's tap does. Injectable so a widget test can watch a tap without
  /// launching anything; null uses the real one (ACTION_VIEW / xdg-open).
  final Future<bool> Function(String path)? openFile;

  /// The peer to open on, when the caller already knows which one the user
  /// meant. The shell's windowed copy does: it is opened from one device's row
  /// on the Files tab, and landing on a different peer would make that row a
  /// lie. Null opens on the first device in the list, which is what this view
  /// wants when it is the whole screen — its first chip is the answer.
  final String? initialDeviceId;

  /// Whether the page draws its own "Files" header. False for the shell's
  /// windowed copy, which sits under a page bar that already names it; two
  /// titles over one listing is one too many.
  final bool showHeader;

  /// Where a download lands, by file name. Null uses this device's Downloads
  /// folder (see [downloadsFilePath]); injectable so a widget test can tap a
  /// row without writing into the machine running the suite.
  final Future<String> Function(String name)? downloadPath;

  const FilesView({
    super.key,
    required this.mesh,
    this.openFile,
    this.initialDeviceId,
    this.showHeader = true,
    this.downloadPath,
  });

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

  /// Local copies of the images in this listing, by remote path — the
  /// thumbnails. Only a fetch that landed is here, so a path that is missing
  /// is one still in flight or one that failed: either way the tile keeps its
  /// type icon.
  final Map<String, String> _thumbs = {};
  final Set<String> _thumbPending = {};

  /// The entries the user has picked. Non-empty means the screen is in
  /// selection mode: a tap toggles a row instead of opening it, and the bar at
  /// the foot of the page carries the verbs.
  final Set<String> _picked = {};

  bool get _selecting => _picked.isNotEmpty;

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
      final wanted = widget.initialDeviceId;
      if (wanted != null) {
        for (final PairedDevice device in devices) {
          if (device.id != wanted) continue;
          _selectDevice(device);
          return;
        }
      }
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
      // A new listing is a new set of names. A picked path that is no longer
      // here is a selection the user cannot see, and a thumbnail from another
      // folder (or another device) is not this folder's picture.
      _picked.clear();
      _thumbs.clear();
      _thumbPending.clear();
    });
    if (entries != null) unawaited(_ensureThumbs(entries));
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
        : entries.where((e) => e.name.toLowerCase().contains(query)).toList();
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

    final savePath = await (widget.downloadPath ?? downloadsFilePath)(
      entry.name,
    );

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
    if (await _deleteNow(entry)) return;
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Could not delete ${entry.name}: '
          '${widget.mesh.lastFileError ?? 'unknown error'}',
        ),
      ),
    );
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

  /// The Files tab's own Recent: the last files this device fetched, newest
  /// first — straight from the local store, with no peer asked. A fetched
  /// file used to exist only inside the assistant's card as a path string;
  /// this is where the user finds it again, at the top of the root view.
  Widget _recentSection(BuildContext context, NexusPalette palette) {
    final recent = widget.mesh.store.recentFetched;
    if (recent.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NexusSpace.page,
        NexusSpace.lg,
        NexusSpace.page,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Recent',
            style: NexusType.caption1.copyWith(
              color: palette.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: NexusSpace.xs),
          ConstrainedBox(
            // Ten rows would push the listing they sit above off the screen.
            constraints: const BoxConstraints(maxHeight: 300),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final file in recent) _recentRow(context, palette, file),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// One recent fetch, in the same shape as a listing row: the type glyph,
  /// the name, and the size with where it came from.
  Widget _recentRow(
    BuildContext context,
    NexusPalette palette,
    Map<String, dynamic> file,
  ) {
    final path = file['path']?.toString() ?? '';
    final name = file['name']?.toString() ?? path;
    final peer = file['peer']?.toString() ?? '';
    final subtitle = [
      fileSizeLabel((file['size'] as num?)?.toInt() ?? 0),
      if (peer.isNotEmpty) 'from $peer',
    ].join(' · ');
    return Semantics(
      container: true,
      button: true,
      label: 'Recent file $name, $subtitle. Tap to open it.',
      child: NexusPressable(
        onTap: () => _openRecent(name, path),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Icon(
                fileTypeIcon(name: name, isDir: false),
                size: 22,
                color: palette.textSecondary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: palette.textTertiary),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: palette.textTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Tap a recent row: the local file opens the same way the assistant's
  /// card opens it. A row whose file is gone from disk (deleted outside the
  /// app) is forgotten rather than left as a trap.
  Future<void> _openRecent(String name, String path) async {
    final open = widget.openFile ?? openLocalFile;
    final ok = await open(path);
    if (!mounted || ok) return;
    widget.mesh.store.removeFetchedFile(path);
    unawaited(widget.mesh.store.save());
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$name is no longer on this device.')),
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

    // What this folder holds, in the one currency the mesh actually reports:
    // the listing itself — every entry's size, summed for the files. There is
    // no capacity to show: the peer sends names and sizes, never bytes free,
    // and dart:io has no filesystem-capacity API, so a "used of total" line
    // would be a number this app made up.
    final listing = _visible;
    final totalBytes = listing.fold<int>(
      0,
      (sum, e) => sum + (e.isDir ? 0 : e.size),
    );
    final summary = _entries == null || _error != null || listing.isEmpty
        ? null
        : '${listing.length} ${listing.length == 1 ? 'item' : 'items'} · '
              '${fileSizeLabel(totalBytes)}';

    // The header belongs to the tab, not to the file listing — show it even
    // when there is nothing paired yet (the empty state below it). No icon
    // tile: it carried no state, and a tile beside a title is decoration.
    final Widget header = widget.showHeader
        ? const Padding(
            padding: EdgeInsets.fromLTRB(
              NexusSpace.page,
              NexusSpace.xxl,
              NexusSpace.page,
              0,
            ),
            child: NexusPageHeader(
              title: 'Files',
              subtitle:
                  'Browse, download and send files on your devices — over LAN '
                  'at home, or from anywhere via a Tailscale address.',
            ),
          )
        // The caller owns the title (the shell's page bar), so the listing
        // still starts below it by the same gap the header would have left.
        : const SizedBox(height: NexusSpace.xxl);

    if (devices.isEmpty) {
      return Column(
        children: [
          header,
          // Recent stands even alone: a file fetched by asking is exactly
          // what a user comes back here to find.
          _recentSection(context, palette),
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
        // Recent sits at the top of the root view, above the peer list. Once
        // a folder is open, the listing the user asked for owns the screen.
        if (_trail.isEmpty) _recentSection(context, palette),
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
              // Measured 0 px on the phone: two 48dp targets sharing an
              // edge read as one blob to a thumb.
              const SizedBox(width: NexusSpace.sm),
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
        if (summary != null) ...[
          const SizedBox(height: NexusSpace.sm),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: NexusSpace.page),
            child: Text(
              summary,
              style: NexusType.caption1.copyWith(color: palette.textTertiary),
            ),
          ),
        ],
        const SizedBox(height: NexusSpace.sm),
        Divider(height: 1, color: palette.separator),
        Expanded(child: _buildBody(context)),
        // The batch bar sits at the foot of the page, above the app's tab bar:
        // where the hand already is when a list is being worked through.
        if (_selecting) _selectionBar(palette),
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
        (
          label: folder.name,
          open: i == _trail.length - 1 ? null : () => _goTo(i),
        ),
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
                // line it replaced started. A one-letter folder still gets
                // the full minimum width: a target is a target.
                NexusPressable(
                  borderRadius: BorderRadius.circular(NexusRadius.xs),
                  onTap: crumb.open,
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minWidth: 44),
                      child: Padding(
                        padding: const EdgeInsets.only(right: NexusSpace.md),
                        child: Text(crumb.label, style: style),
                      ),
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
                thumbPath: _thumbs[entries[i].path],
                picking: _selecting,
                picked: _picked.contains(entries[i].path),
                onPick: () => _togglePick(entries[i]),
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
              thumbPath: _thumbs[entries[i].path],
              picking: _selecting,
              picked: _picked.contains(entries[i].path),
              onPick: () => _togglePick(entries[i]),
              deleting: _deleting.contains(entries[i].path),
              operating: _operating.contains(entries[i].path),
              // One row's actions at a time, decided here rather than inside
              // each row: two rows cannot both be half-open by accident.
              revealed: _revealed == entries[i].path,
              onReveal: (open) =>
                  setState(() => _revealed = open ? entries[i].path : null),
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

  /// Fetches a preview for every small image in [entries], one at a time.
  ///
  /// The mesh has no preview endpoint: a thumbnail *is* the file, so this asks
  /// only for pictures small enough that the fetch costs less than opening the
  /// tile would, and it does them in listing order rather than all at once — a
  /// folder of two hundred photos should not open two hundred connections to
  /// draw a list somebody is scrolling through. A fetch that fails leaves the
  /// tile with its type icon, which is what it showed before thumbnails
  /// existed at all.
  Future<void> _ensureThumbs(List<FileEntry> entries) async {
    final device = _device;
    if (device == null || !widget.mesh.isOnline(device.id)) return;
    for (final entry in entries) {
      if (!mounted || device.id != _device?.id) return;
      if (entry.isDir || !_thumbWanted(entry)) continue;
      if (_thumbs.containsKey(entry.path) ||
          _thumbPending.contains(entry.path)) {
        continue;
      }
      setState(() => _thumbPending.add(entry.path));
      final file = await widget.mesh.pullRemoteFile(
        device,
        entry.path,
        savePath: _thumbSavePath(device, entry),
      );
      if (!mounted) return;
      setState(() {
        _thumbPending.remove(entry.path);
        if (file != null) _thumbs[entry.path] = file.path;
      });
    }
  }

  /// Whether a fetch for this entry is worth a connection: a picture, of a
  /// size the listing actually reported, under the cap.
  bool _thumbWanted(FileEntry entry) =>
      _isImageName(entry.name) &&
      entry.size > 0 &&
      entry.size <= _maxThumbBytes;

  /// Where a thumbnail is cached. `Directory.systemTemp` is the app's cache
  /// directory on Android — the right home for a copy that may be evicted at
  /// any time — and the name is keyed by device and path, so walking back into
  /// the same folder reuses the file instead of fetching it again.
  String _thumbSavePath(PairedDevice device, FileEntry entry) {
    final dir = Directory('${Directory.systemTemp.path}/nexus-thumbs');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final key = '${device.id}|${entry.path}'.hashCode.toRadixString(16);
    return '${dir.path}/$key-${entry.name}';
  }

  /// Picking: a long press selects, a tap toggles while anything is picked,
  /// and an empty selection is the ordinary listing again. Selection mode does
  /// not open files — the rule iOS Files follows, and the reason the bar has a
  /// way out rather than being a trap.
  void _togglePick(FileEntry entry) {
    HapticFeedback.selectionClick();
    setState(() {
      if (!_picked.add(entry.path)) _picked.remove(entry.path);
      if (_picked.isEmpty) _revealed = null;
    });
  }

  void _clearPicks() {
    if (_picked.isEmpty) return;
    setState(() {
      _picked.clear();
      _revealed = null;
    });
  }

  /// The picked entries, in listing order rather than in the order they were
  /// tapped: every batch verb then acts the way the list reads.
  List<FileEntry> get _pickedEntries => [
    for (final entry in _entries ?? const <FileEntry>[])
      if (_picked.contains(entry.path)) entry,
  ];

  /// Deletes [entry] on the peer, without asking. The confirmation belongs to
  /// whoever is doing the asking: one dialog for one file, one for a batch.
  Future<bool> _deleteNow(FileEntry entry) async {
    final device = _device;
    if (device == null || _deleting.contains(entry.path)) return false;
    setState(() => _deleting.add(entry.path));
    final ok = await widget.mesh.deleteRemoteFile(device, entry.path);
    if (!mounted) return ok;
    setState(() {
      _deleting.remove(entry.path);
      if (ok) _entries?.removeWhere((e) => e.path == entry.path);
    });
    return ok;
  }

  /// The batch verbs. Each is the single-file verb run over the picks, with
  /// the confirmation — or the destination — asked for once instead of once
  /// per file.
  Future<void> _deletePicked() async {
    final device = _device;
    final picked = _pickedEntries;
    if (device == null || picked.isEmpty) return;
    final folders = picked.where((e) => e.isDir).length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(
          picked.length == 1
              ? 'Delete ${picked.single.name}?'
              : 'Delete ${picked.length} items?',
        ),
        content: Text(
          folders > 0
              ? 'They will be removed from ${device.name}. Folders go only if '
                    'empty.'
              : 'They will be removed from ${device.name}.',
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
    var failed = 0;
    for (final entry in picked) {
      if (!mounted) return;
      if (!await _deleteNow(entry)) failed++;
    }
    if (!mounted) return;
    _clearPicks();
    if (failed > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            failed == picked.length
                ? 'Could not delete anything: '
                      '${widget.mesh.lastFileError ?? 'unknown error'}'
                : 'Deleted ${picked.length - failed} of ${picked.length}; '
                      '${widget.mesh.lastFileError ?? 'the rest failed'}',
          ),
        ),
      );
    }
  }

  /// Downloads every pick into the phone's Downloads folder, in order. The
  /// per-file progress ring is the same one a single download shows, so a
  /// batch reads as several downloads rather than as a batch.
  Future<void> _downloadPicked() async {
    final picked = _pickedEntries;
    if (picked.isEmpty) return;
    _clearPicks();
    for (final entry in picked) {
      if (!mounted) return;
      if (entry.isDir) continue;
      await _download(entry);
    }
  }

  /// Sends every pick to one destination, asked for once: a destination per
  /// file is a form, and the reason the single-file verb is a sheet is that
  /// there is one file to place. Copy and move are the same errand with one
  /// flag between them, so they share this.
  Future<void> _sendPicked({required bool move}) async {
    final source = _device;
    final picked = _pickedEntries;
    if (source == null || picked.isEmpty) return;
    final target = await _pickDestination();
    if (target == null || !mounted) return;
    var done = 0;
    for (final entry in picked) {
      if (!mounted) return;
      final destination = _joinPath(target.path, entry.name);
      final result = await widget.mesh.transferRemoteFile(
        source,
        entry.path,
        target.device,
        destination,
        move: move,
      );
      if (result != null) done++;
    }
    if (!mounted) return;
    _clearPicks();
    await _load();
    if (!mounted) return;
    final verb = move ? 'Moved' : 'Copied';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          done == picked.length
              ? '$verb $done to ${target.device.name}'
              : '$verb $done of ${picked.length} to ${target.device.name}',
        ),
      ),
    );
  }

  /// The rest of the verbs for the picks — the ones that do not fit in a bar,
  /// or that need exactly one item to make sense. Rename is offered only when
  /// one thing is picked: a list is not a form, and "rename these three" has
  /// no one answer.
  Future<void> _showPickedActions() async {
    final picked = _pickedEntries;
    if (picked.isEmpty) return;
    final chosen = await showNexusActions<String>(
      context: context,
      title: Text(
        _picked.length == 1 ? picked.single.name : '${_picked.length} items',
      ),
      actions: (popup) => [
        if (picked.length == 1)
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
      ],
    );
    if (chosen == null || !mounted) return;
    switch (chosen) {
      case 'rename':
        _clearPicks();
        await _rename(picked.single);
      case 'copy':
        await _sendPicked(move: false);
      case 'move':
        await _sendPicked(move: true);
    }
  }

  /// The bar the picks are acted on from. iOS shape: it arrives at the foot of
  /// the page, where the thumb already is, and carries the count, the verbs
  /// and the way out.
  Widget _selectionBar(NexusPalette palette) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        NexusSpace.page,
        NexusSpace.xs,
        NexusSpace.xs,
        NexusSpace.xs,
      ),
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border(top: BorderSide(color: palette.separator)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _picked.length == 1 ? '1 selected' : '${_picked.length} selected',
              overflow: TextOverflow.ellipsis,
              style: NexusType.callout.copyWith(
                color: palette.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Download',
            onPressed: _downloadPicked,
            icon: Icon(Icons.download_rounded, color: palette.textSecondary),
          ),
          // Edge-to-edge 48dp targets read as one blob to a thumb: the full
          // minimum gap between each, so Download, Delete and More land
          // separately even at speed.
          const SizedBox(width: NexusSpace.sm),
          IconButton(
            tooltip: 'Delete',
            onPressed: _deletePicked,
            icon: Icon(Icons.delete_rounded, color: palette.danger),
          ),
          // The verbs that do not fit a bar, one tap away in the same Cupertino
          // sheet the single-file verbs use: Rename (one pick), Copy to… and
          // Move to….
          // Not "More": the toolbar already has one of those, and two controls
          // with one name is one name a screen reader cannot tell apart.
          const SizedBox(width: NexusSpace.sm),
          IconButton(
            tooltip: 'More actions',
            onPressed: _showPickedActions,
            icon: Icon(Icons.more_horiz_rounded, color: palette.textSecondary),
          ),
          const SizedBox(width: NexusSpace.sm),
          TextButton(onPressed: _clearPicks, child: const Text('Cancel')),
        ],
      ),
    );
  }

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
              child: Center(child: Text(_error!, textAlign: TextAlign.center)),
            )
          else if (_entries == null || _entries!.isEmpty)
            const Expanded(child: Center(child: Text('No subfolders here.')))
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

  /// A local copy of this file when it is a small picture — the thumbnail.
  /// Null for everything else, and for an image whose fetch has not landed.
  final String? thumbPath;

  /// Whether the screen is in selection mode, and whether this row is one of
  /// the picks. A picking screen does not open files: a tap toggles.
  final bool picking;
  final bool picked;
  final VoidCallback onPick;

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
    required this.thumbPath,
    required this.picking,
    required this.picked,
    required this.onPick,
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
      SpringSimulation(NexusSpring.of(), _slide.value, target, _slide.velocity),
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
  List<({String label, IconData icon, Color color, VoidCallback run})>
  get _verbs => [
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
          : '${fileSizeLabel(entry.size)} · ${_when(entry.modified)}',
      leading: _leading(palette),
      // A folder goes somewhere, so it gets the one trailing chevron a row is
      // allowed. A file is the thing itself: tapping it fetches it, and the
      // chevron would promise another screen that does not exist.
      chevron: entry.isDir,
      trailing: widget.picking
          ? Icon(
              widget.picked
                  ? Icons.check_circle_rounded
                  : Icons.circle_outlined,
              size: 24,
              color: widget.picked ? palette.accent : palette.textTertiary,
            )
          : _progressIndicator(palette),
      // A row at work keeps its shape and loses only its response: the file
      // being downloaded is still the row the finger landed on.
      enabled: !widget.busy,
      onTap: () {
        // Picking first: while anything is picked, a tap answers the selection
        // rather than the file.
        if (widget.picking) {
          widget.onPick();
          return;
        }
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
      // Long press picks, which is how a file list gains a second thing to do
      // with a finger. The verbs it used to open are all still here: two on
      // the swipe, and all four as custom actions for a screen reader.
      onLongPress: widget.onPick,
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

  /// What sits before the name: the picture itself when there is a thumbnail,
  /// and the file's type glyph otherwise. A thumbnail that fails to decode
  /// falls back to the glyph rather than to a broken box — the file is still
  /// the file, and the row must not look damaged because a preview is.
  Widget _leading(NexusPalette palette) {
    final icon = Icon(
      fileTypeIcon(name: widget.entry.name, isDir: widget.entry.isDir),
      size: 24,
      color: palette.textSecondary,
    );
    final thumbPath = widget.thumbPath;
    if (thumbPath == null) return icon;
    return ClipRRect(
      borderRadius: NexusRadius.row,
      child: Image.file(
        File(thumbPath),
        width: 34,
        height: 34,
        fit: BoxFit.cover,
        // Decoded at the size it is drawn at, not at the camera's: a 12 MP
        // photo is 48 MB of pixels the row will never show.
        cacheWidth: 102,
        errorBuilder: (_, _, _) => icon,
      ),
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
      child: NexusPressable(
        // A pressable, not a bare detector: the swipe that revealed the verb
        // was the answer to the swipe, but the tap on the verb is its own
        // gesture and gets its own touch-down answer. The tint is faint on
        // purpose — the verb stays a flat wash of colour, not a button.
        borderRadius: BorderRadius.zero,
        tint: color.withValues(alpha: 0.22),
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
    required this.thumbPath,
    required this.picking,
    required this.picked,
    required this.onPick,
    required this.onTap,
    required this.onDelete,
    required this.onRename,
    required this.onActions,
  });

  final FileEntry entry;
  final double? progress;
  final bool busy;

  /// A local copy of this file when it is a small picture — the thumbnail.
  final String? thumbPath;

  /// Whether the screen is in selection mode, and whether this tile is one of
  /// the picks.
  final bool picking;
  final bool picked;
  final VoidCallback onPick;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback onRename;
  final VoidCallback onActions;

  @override
  Widget build(BuildContext context) {
    final palette = NexusPalette.of(context);
    final transferring = progress;
    return Semantics(
      container: true,
      button: true,
      label: entry.isDir
          ? '${entry.name}, folder'
          : '${entry.name}, ${fileSizeLabel(entry.size)}',
      customSemanticsActions: {
        CustomSemanticsAction(label: 'Rename'): onRename,
        CustomSemanticsAction(label: 'Copy to…'): onActions,
        CustomSemanticsAction(label: 'Move to…'): onActions,
        CustomSemanticsAction(label: 'Delete'): onDelete,
      },
      child: NexusPressable(
        enabled: !busy,
        borderRadius: NexusRadius.card,
        onTap: picking ? onPick : onTap,
        onLongPress: onPick,
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
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // Bytes moving outrank both: a tile being transferred
                      // says how far it has got, whatever it is a picture of.
                      if (busy && transferring != null)
                        Center(
                          child: SizedBox(
                            width: 26,
                            height: 26,
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                  value: transferring,
                                  color: palette.accent,
                                  backgroundColor: palette.surfaceSecondary,
                                ),
                                Text(
                                  '${(transferring * 100).round()}',
                                  style: NexusType.micro.copyWith(
                                    color: palette.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                      else if (thumbPath != null && !picking)
                        // The picture is the tile. Clipped to the tile's own
                        // corner rather than the sheet's, so a grid of photos
                        // reads as a grid of photos.
                        ClipRRect(
                          borderRadius: NexusRadius.card,
                          child: Image.file(
                            File(thumbPath!),
                            fit: BoxFit.cover,
                            // Drawn at tile width; decoding the full file to
                            // show it 100dp wide is the whole cost of a grid
                            // with no thumbnails in it.
                            cacheWidth: 260,
                            errorBuilder: (_, _, _) => Icon(
                              fileTypeIcon(
                                name: entry.name,
                                isDir: entry.isDir,
                              ),
                              size: 30,
                              color: palette.textSecondary,
                            ),
                          ),
                        )
                      else
                        Center(
                          child: Icon(
                            fileTypeIcon(name: entry.name, isDir: entry.isDir),
                            size: 30,
                            color: palette.textSecondary,
                          ),
                        ),
                      if (picking)
                        Positioned(
                          top: NexusSpace.xs,
                          right: NexusSpace.xs,
                          child: Icon(
                            picked
                                ? Icons.check_circle_rounded
                                : Icons.circle_outlined,
                            size: 22,
                            color: picked
                                ? palette.accent
                                : palette.textTertiary,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: NexusSpace.sm),
              Text(
                entry.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: NexusType.caption1.copyWith(color: palette.textPrimary),
              ),
              if (!entry.isDir)
                Text(
                  fileSizeLabel(entry.size),
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

/// The biggest file worth fetching to draw a tile: a thumbnail that costs
/// more than the picture itself is not a thumbnail.
const int _maxThumbBytes = 3 << 20; // 3 MB

/// Extensions whose bytes Flutter can decode from memory without a plugin
/// (PNG, JPEG, GIF, WebP and BMP all have codecs in the engine). Deliberately
/// short: a name this misses shows its type icon, which is what every tile
/// showed before thumbnails existed.
bool _isImageName(String name) {
  final lower = name.toLowerCase();
  return const [
    '.png',
    '.jpg',
    '.jpeg',
    '.gif',
    '.webp',
    '.bmp',
  ].any(lower.endsWith);
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
