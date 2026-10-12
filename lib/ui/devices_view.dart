import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart'
    show
        CupertinoActionSheetAction,
        CupertinoAlertDialog,
        CupertinoDialogAction,
        CupertinoTextField;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart' show SpringSimulation;
import 'package:flutter/services.dart' show HapticFeedback;

import '../core/capability.dart';
import '../core/network_info.dart' show isTailscaleIp;
import '../mesh/connection_supervisor.dart';
import '../mesh/discovery.dart';
import '../mesh/mesh_service.dart';
import '../mesh/serial_bridge.dart';
import 'components/nexus_ui.dart';
import 'pair_sheet.dart';
import 'theme.dart';

// The platform glyph and label live with the rest of the shared presentation
// layer; re-exported so this file's callers keep one import for both.
export 'components/nexus_ui.dart' show platformIcon, platformLabel;

/// The connection supervisor's live verdict that this paired link is down and
/// being retried *right now*, or null when it has nothing to say: the
/// supervisor is not running, or this peer was never watched. Null means the
/// mesh's own windows decide, exactly as they did before this state existed.
///
/// Deliberately narrower than "not up": a link that is down with no attempt
/// recorded is not being reconnected, so it is not called reconnecting.
PeerLink? _retryingLink(MeshService mesh, String id) {
  final link = mesh.supervisor?.links.where((l) => l.id == id).firstOrNull;
  return link != null && !link.up && link.attempts > 0 ? link : null;
}

/// "Reconnecting…", with the wait the supervisor is on when it knows one — the
/// countdown is the retry curve, so it grows as the backoff doubles instead of
/// repeating a promising number.
String _reconnectingLabel(PeerLink link) {
  final next = link.nextAttemptAt;
  if (next == null) return 'Reconnecting…';
  final seconds = next.difference(DateTime.now()).inSeconds;
  return seconds >= 1
      ? 'Reconnecting · next try in ${seconds}s'
      : 'Reconnecting…';
}

/// "3m ago", "2h ago" — or "never" when there is no record of the device.
String _timeAgo(DateTime? t) {
  if (t == null) return 'never';
  final d = DateTime.now().difference(t);
  if (d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  return '${d.inDays}d ago';
}

/// The most devices the graph draws before it hands over to the list.
///
/// The graph draws two rings — three peers around the middle, nine around
/// those — and pans and zooms, so a mesh of a dozen devices is still a picture
/// rather than a pile. Past this the rings stop being readable at any zoom and
/// the list below, which now carries the state itself (see [_PairedRow]), is
/// the honest rendering. It is a limit on what this picture can carry, not on
/// pairing.
const int _maxGraphDevices = 12;

/// What a link between two devices looks like, from the supervisor's own
/// snapshot.
///
/// Three states, each of them something the supervisor or the mesh actually
/// reports, and no fourth: deliberately narrower than "not online", because a
/// device that is down with no retry recorded is not being reconnected, and
/// calling it "reconnecting" would be a claim nothing measured.
enum _LinkState {
  online,
  reconnecting,
  offline;

  /// How live the line is, 0..1. The painter reads this one number, so the
  /// line's colour, its weight and its dash pattern all move together when the
  /// state does — a link that drops fades out rather than being cut.
  double get liveness => switch (this) {
    _LinkState.online => 1,
    _LinkState.reconnecting => 0.5,
    _LinkState.offline => 0,
  };

  String get label => switch (this) {
    _LinkState.online => 'Online',
    _LinkState.reconnecting => 'Reconnecting',
    _LinkState.offline => 'Offline',
  };
}

/// The graph's and the row's shared verdict on one paired device.
({_LinkState state, PeerLink? retry}) _linkFor(MeshService mesh, String id) {
  final retry = _retryingLink(mesh, id);
  if (retry != null) return (state: _LinkState.reconnecting, retry: retry);
  return (
    state: mesh.isOnline(id) ? _LinkState.online : _LinkState.offline,
    retry: null,
  );
}

/// What this device can actually run for you, named the way the capability
/// registry names it.
///
/// Derived, not written down here: the list is generated from the same
/// registry that decides what the device advertises to its peers, filtered to
/// the capabilities that have a device backend (the catalog answers every
/// device shares are not "this device can do" facts).
List<String> _runnableCapabilityLabels(String platform) => [
  for (final advertised in defaultCapabilitiesFor(platform))
    if (capabilityFor(advertised.id) case final capability?
        when capability.isDeviceExecutable)
      capability.label.toLowerCase(),
];

class DevicesView extends StatelessWidget {
  final MeshService mesh;

  const DevicesView({super.key, required this.mesh});

  @override
  Widget build(BuildContext context) {
    final paired = mesh.pairedDevices;
    final nearby = mesh.nearbyDevices
        .where((d) => !mesh.isPaired(d.id))
        .toList();
    final serial = mesh.serialDevices;
    final remoteSerial = mesh.remoteSerialDevices;

    return NexusPage(
      pinnedBottom: paired.isEmpty
          ? null
          // The one action that matters on this screen, in reach of a thumb.
          : SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => showPairSheet(context, mesh: mesh),
                icon: const Icon(Icons.add_rounded, size: 20),
                label: const Text('Add device'),
              ),
            ),
      children: [
        const NexusPageHeader(
          title: 'Devices',
          subtitle: 'Everything Nexus can work across.',
        ),
        // The picture comes first: this device in the middle and one line per
        // link, with the link's own state written under the device it belongs
        // to. That is the one place the state of a graphed link is read — the
        // rows below are the device index (name and what the device is), and
        // they take the state back only when there is no picture to draw it
        // in.
        if (paired.isNotEmpty && paired.length <= _maxGraphDevices) ...[
          const NexusSectionHeader(
            'The mesh',
            detail:
                'This device in the middle. Solid is online, dashed is being '
                'reconnected, dotted is down.',
          ),
          _TopologyGraph(mesh: mesh),
        ],
        _Reachability(note: mesh.lastNotice, mesh: mesh),
        if (paired.isEmpty)
          const SizedBox(height: NexusSpace.lg)
        else ...[
          const NexusSectionHeader('Your devices'),
          NexusGroup(
            children: [
              for (final d in paired)
                _PairedRow(
                  mesh: mesh,
                  device: d,
                  // The state is drawn on the graph node when there is a graph; the
                  // row says what the device *is*. With no picture (too many devices,
                  // or none paired) the words come back here, because they are the
                  // only place left that can carry them.
                  stateInGraph:
                      paired.isNotEmpty && paired.length <= _maxGraphDevices,
                ),
            ],
          ),
        ],
        // Phone-only mode: zero peers paired. No empty graph, no counts —
        // one node (this phone, centered) and one primary button. The app
        // is complete on a single phone; pairing is an invitation, not a
        // missing step. One or more peers restores the mesh picture below.
        if (paired.isEmpty)
          _PhoneOnlyDevice(mesh: mesh),
        if (nearby.isNotEmpty) ...[
          NexusSectionHeader(
            'Nearby',
            detail:
                'Pairing is the only step — after that everything is '
                'encrypted and direct.',
            trailing: Text(
              '${nearby.length}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          NexusGroup(
            children: [
              for (final d in nearby) _NearbyRow(mesh: mesh, device: d),
            ],
          ),
        ],
        if (serial.isNotEmpty || remoteSerial.isNotEmpty) ...[
          NexusSectionHeader(
            'Microcontrollers',
            detail:
                'On a cable, or reachable through another device. They '
                'only do what they advertise.',
          ),
          NexusGroup(
            children: [
              for (final d in serial) _SerialRow(mesh: mesh, device: d),
              for (final d in remoteSerial)
                _SerialRow(
                  mesh: mesh,
                  device: d,
                  hostName: _hostNameFor(mesh, d),
                ),
            ],
          ),
        ],
      ],
    );
  }

  String? _hostNameFor(MeshService mesh, SerialDevice device) {
    final hostId = device.port.startsWith('remote:')
        ? device.port.substring(7)
        : null;
    if (hostId == null) return null;
    return mesh.pairedDevices
            .where((p) => p.id == hostId)
            .map((p) => p.name)
            .firstOrNull ??
        hostId;
  }
}

/// Phone-only mode: zero peers paired. A single node — this phone,
/// centered — with one primary button below it. No empty graph, no counts.
class _PhoneOnlyDevice extends StatelessWidget {
  const _PhoneOnlyDevice({required this.mesh});

  final MeshService mesh;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: NexusSpace.xxl),
        Center(
          child: _TopologyNode(
            platform: mesh.identity.platform,
            name: 'This phone',
            state: _LinkState.online,
            detail: platformLabel(mesh.identity.platform),
            isSelf: true,
          ),
        ),
        const SizedBox(height: NexusSpace.xl),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: () => showPairSheet(context, mesh: mesh),
            icon: const Icon(Icons.add_rounded, size: 20),
            label: const Text('Pair another device'),
          ),
        ),
      ],
    );
  }
}

/// One honest line about whether Nexus can reach anything right now. Not a
/// card: it is a sentence, and it used to wear a rounded rectangle.
class _Reachability extends StatelessWidget {
  const _Reachability({required this.note, required this.mesh});

  final String? note;
  final MeshService mesh;

  @override
  Widget build(BuildContext context) {
    final palette = NexusPalette.of(context);
    final total = mesh.pairedDevices.length;
    // A peer the supervisor is retrying is not "reachable right now", even
    // while the mesh's own 25 s window still counts it — otherwise the strip
    // and the row beneath it would contradict each other on the same screen.
    final online = mesh.pairedDevices
        .where((d) => mesh.isOnline(d.id) && _retryingLink(mesh, d.id) == null)
        .length;

    // With nothing paired the empty state below already says what to do, in
    // its own words — the phone showed both on one screen, saying the same
    // thing twice. Only a real operational notice is still worth a line here.
    if (total == 0 && note == null) return const SizedBox.shrink();

    // One device is the common case, and the phone read "None of your 1
    // devices are reachable right now." back to its owner — a count that
    // only makes sense once there is more than one thing to count.
    final (NexusStatusLevel level, String text) = switch ((total, online)) {
      (0, _) => (
        NexusStatusLevel.offline,
        'No paired devices yet. Pair your first device to begin.',
      ),
      (1, 1) => (
        NexusStatusLevel.online,
        'Your device is reachable right now.',
      ),
      (final t, final o) when o == t => (
        NexusStatusLevel.online,
        'All $t devices reachable right now.',
      ),
      (1, 0) => (
        NexusStatusLevel.offline,
        "Your device isn't reachable right now.",
      ),
      (final t, 0) => (
        NexusStatusLevel.offline,
        'None of your $t devices are reachable right now.',
      ),
      (final t, final o) => (
        NexusStatusLevel.nearby,
        '$o of $t devices reachable right now.',
      ),
    };

    return Row(
      children: [
        NexusStatusDot(level: level, size: 8),
        const SizedBox(width: NexusSpace.sm),
        Expanded(
          child: Text(
            note ?? text,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: palette.textSecondary),
          ),
        ),
      ],
    );
  }
}

/// A paired device, as a row.
///
/// The row says what the device *is* — name, platform, and the way into its
/// details — and nothing else, because the state of a paired link is drawn on
/// the graph above it. Before this, the same link was described twice on one
/// screen: once by the node and the line the painter draws for it, and again
/// in this row's subtitle and its status dot. Two readings of one fact invite
/// the two to disagree, and the row is the one nobody needs twice — it is a
/// list of devices, and the picture is the state.
///
/// [stateInGraph] is false when no graph is drawn (more devices than the
/// picture can carry, or a mesh with nothing paired): the words come back to
/// the row, which is then the only place carrying them.
class _PairedRow extends StatelessWidget {
  const _PairedRow({
    required this.mesh,
    required this.device,
    this.stateInGraph = false,
  });

  final MeshService mesh;
  final PairedDevice device;
  final bool stateInGraph;

  @override
  Widget build(BuildContext context) {
    final online = mesh.isOnline(device.id);
    final visible = mesh.isVisible(device.id);
    final lastSeen = mesh.lastSeenAt(device.id);
    final retry = _retryingLink(mesh, device.id);

    // The supervisor's retry is the most current thing known about this link,
    // so it outranks the mesh's own 25 s window: showing it at once is the
    // whole reason the supervisor exists.
    final (NexusStatusLevel level, String status) = retry != null
        ? (NexusStatusLevel.working, _reconnectingLabel(retry))
        : online
        ? (NexusStatusLevel.online, 'Online')
        : visible
        ? (NexusStatusLevel.nearby, 'Nearby')
        : (
            NexusStatusLevel.offline,
            'Offline · last seen ${_timeAgo(lastSeen)}',
          );

    return NexusRow(
      minHeight: NexusSize.row,
      onTap: () {
        HapticFeedback.selectionClick();
        _showDetail(context, mesh, device);
      },
      leading: _DeviceGlyph(
        platform: device.platform,
        level: level,
        online: online,
      ),
      title: device.name,
      subtitle: stateInGraph
          ? platformLabel(device.platform)
          : '${platformLabel(device.platform)} · $status',
      chevron: true,
      // Only when this row is the state's only home. The dot reinforces the
      // words; it does not get to repeat them — the rule the phone taught this
      // screen, and now the reason there is no dot while the graph is up.
      trailing: stateInGraph
          ? null
          : ExcludeSemantics(
              child: Tooltip(
                message: status,
                child: NexusStatusDot(level: level, size: 10),
              ),
            ),
    );
  }
}

/// A device icon that also carries reachability, so the eye can scan status
/// down the column without reading every row.
class _DeviceGlyph extends StatelessWidget {
  const _DeviceGlyph({
    required this.platform,
    required this.level,
    required this.online,
  });

  final String platform;
  final NexusStatusLevel level;
  final bool online;

  @override
  Widget build(BuildContext context) {
    final palette = NexusPalette.of(context);
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: online ? palette.accentTint(0.10) : palette.surfaceSecondary,
        borderRadius: NexusRadius.row,
      ),
      child: Icon(
        platformIcon(platform),
        size: 20,
        color: online ? palette.accent : palette.textSecondary,
      ),
    );
  }
}

/// The device detail sheet: what it is, what it can do for you, and the
/// actions — with the technical facts behind one more tap.
void _showDetail(BuildContext context, MeshService mesh, PairedDevice device) {
  // The detail is a page of its own — what the device is, what it can do, and
  // the actions — so it opens as an iOS sheet: the page behind pushes back,
  // the grabber is the framework's, and a downward drag dismisses it.
  showNexusSheet<void>(
    context: context,
    builder: (context, controller) =>
        _DeviceDetailSheet(mesh: mesh, device: device, scroll: controller),
  );
}

class _DeviceDetailSheet extends StatefulWidget {
  const _DeviceDetailSheet({
    required this.mesh,
    required this.device,
    required this.scroll,
  });

  final MeshService mesh;
  final PairedDevice device;

  /// The sheet's scroll controller: the framework reads it to know when the
  /// page is scrolled to the top, which is when a downward drag should stop
  /// scrolling and start dismissing.
  final ScrollController scroll;

  @override
  State<_DeviceDetailSheet> createState() => _DeviceDetailSheetState();
}

class _DeviceDetailSheetState extends State<_DeviceDetailSheet> {
  bool _advanced = false;

  MeshService get mesh => widget.mesh;
  PairedDevice get device => widget.device;

  @override
  Widget build(BuildContext context) {
    final palette = NexusPalette.of(context);
    final online = mesh.isOnline(device.id);
    final visible = mesh.isVisible(device.id);
    final lastSeen = mesh.lastSeenAt(device.id);
    final retry = _retryingLink(mesh, device.id);

    // Same three states as the row it was opened from, so the sheet never
    // contradicts the row that led here.
    final (NexusStatusLevel level, String status) = retry != null
        ? (NexusStatusLevel.working, _reconnectingLabel(retry))
        : online
        ? (NexusStatusLevel.online, 'Online · reachable now')
        : visible
        ? (NexusStatusLevel.nearby, 'Nearby but not reachable')
        : (
            NexusStatusLevel.offline,
            'Offline · last seen ${_timeAgo(lastSeen)}',
          );

    final capabilities = _runnableCapabilityLabels(device.platform);

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          NexusSpace.xl,
          0,
          NexusSpace.xl,
          NexusSpace.xl,
        ),
        child: SingleChildScrollView(
          controller: widget.scroll,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(device.name, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: NexusSpace.sm),
              Row(
                children: [
                  NexusStatusDot(level: level, size: 9),
                  const SizedBox(width: NexusSpace.sm),
                  Expanded(
                    child: Text(
                      '${platformLabel(device.platform)} · $status',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
              if (capabilities.isNotEmpty) ...[
                const SizedBox(height: NexusSpace.xl),
                Text(
                  'Can do with this device'.toUpperCase(),
                  style: Theme.of(context).textTheme.labelSmall,
                ),
                const SizedBox(height: NexusSpace.sm),
                Wrap(
                  spacing: NexusSpace.sm,
                  runSpacing: NexusSpace.sm,
                  children: [
                    for (final c in capabilities)
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: palette.surfaceSecondary,
                          borderRadius: NexusRadius.pill,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: NexusSpace.md,
                            vertical: NexusSpace.xs + 2,
                          ),
                          child: Text(
                            c,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: palette.textSecondary),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: NexusSpace.xl),
              NexusGroup(
                children: [
                  NexusRow(
                    title: 'Rename',
                    minHeight: NexusSize.rowCompact,
                    leading: Icon(
                      Icons.edit_outlined,
                      size: 20,
                      color: palette.textSecondary,
                    ),
                    onTap: () async {
                      Navigator.pop(context);
                      await _renamePairedDevice(context, mesh, device);
                    },
                  ),
                  NexusRow(
                    title: 'Advanced',
                    subtitle: _advanced
                        ? 'Address, port and pairing details'
                        : 'Technical details',
                    minHeight: NexusSize.rowCompact,
                    leading: Icon(
                      Icons.tune_rounded,
                      size: 20,
                      color: palette.textSecondary,
                    ),
                    trailing: Icon(
                      _advanced
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 20,
                      color: palette.textTertiary,
                    ),
                    onTap: () => setState(() => _advanced = !_advanced),
                  ),
                ],
              ),
              // Progressive disclosure: the facts a normal person never needs
              // are here for the times someone does.
              AnimatedCrossFade(
                duration: NexusMotion.scaled(context, NexusMotion.base),
                crossFadeState: _advanced
                    ? CrossFadeState.showSecond
                    : CrossFadeState.showFirst,
                firstChild: const SizedBox(width: double.infinity),
                secondChild: Padding(
                  padding: const EdgeInsets.only(top: NexusSpace.md),
                  child: NexusGroup(
                    children: [
                      _DetailRow(
                        label: 'Address',
                        value: '${device.address}:${device.port}',
                      ),
                      _DetailRow(label: 'Link', value: 'Encrypted · direct'),
                      if (device.addresses.any(isTailscaleIp))
                        const _DetailRow(
                          label: 'Tailscale',
                          value: 'Reachable across networks',
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: NexusSpace.xl),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: palette.danger,
                    side: BorderSide(
                      color: palette.danger.withValues(alpha: 0.5),
                    ),
                  ),
                  icon: const Icon(Icons.link_off_rounded, size: 18),
                  label: const Text('Forget device'),
                  onPressed: () async {
                    final confirmed = await _confirmForget(context, device);
                    if (confirmed != true || !context.mounted) return;
                    await mesh.forgetDevice(device.id);
                    if (context.mounted) Navigator.pop(context);
                  },
                ),
              ),
              const SizedBox(height: NexusSpace.sm),
              Text(
                'Forgetting removes the pairing. The device must be paired '
                'again from scratch to reconnect.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// The node boxes are fixed sizes rather than content-sized, because the graph
// places them by hand: a box whose width depended on its label would move the
// line's endpoint every time a device was renamed. The room reserved under a
// disc for that label does follow the user's text size (see [_TopologyGraph]),
// but the width does not — a device with a long name ellipsises here, and the
// list below is where the whole name lives.
const double _peerDisc = 56;
const double _selfDisc = 76;
const double _peerNodeWidth = 92;
const double _selfNodeWidth = 124;

/// The gap a line keeps from the disc it starts or ends at, so a link reads as
/// joining two devices rather than passing under them.
const double _lineInset = 6;

/// The mesh as a picture: this device in the middle, every paired device on a
/// ring around it, one line per link.
///
/// The line is the link, so it carries the link's state and nothing else.
/// There is no signal-strength bar and no glow, because the app measures how
/// long a peer has been silent and whether a retry is in flight — and says
/// exactly that. Anything richer on this screen would be invented.
class _TopologyGraph extends StatefulWidget {
  const _TopologyGraph({required this.mesh});

  final MeshService mesh;

  @override
  State<_TopologyGraph> createState() => _TopologyGraphState();
}

class _TopologyGraphState extends State<_TopologyGraph>
    with TickerProviderStateMixin {
  /// The entrance. A spring, not a duration: it can be re-targeted mid-flight,
  /// which is what stops a graph arriving while the mesh is still changing its
  /// mind from restarting.
  late final AnimationController _enter = AnimationController.unbounded(
    vsync: this,
  )..animateWith(SpringSimulation(NexusSpring.of(), 0, 1, 0));

  /// The travelling dashes on a live retry. Started only while something is
  /// genuinely being retried, so a resting graph has no motion in it at all.
  late final AnimationController _dash = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  /// One spring per link, re-targeted in place from wherever it currently is
  /// (and at whatever speed), so a link that changes state mid-flight
  /// continues its motion instead of restarting it.
  final Map<String, AnimationController> _live = {};
  final Map<String, double> _want = {};

  bool _reduced = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduced == _reduced) return;
    _reduced = reduced;
    if (reduced) {
      _enter.value = 1;
      _dash.stop();
      _dash.value = 0;
    } else {
      _enter.animateWith(
        SpringSimulation(NexusSpring.of(), _enter.value, 1, _enter.velocity),
      );
    }
  }

  @override
  void dispose() {
    _enter.dispose();
    _dash.dispose();
    for (final controller in _live.values) {
      controller.dispose();
    }
    super.dispose();
  }

  /// The line's liveness, springing towards [target] from wherever it is now.
  /// Re-targeted only when the target itself changes, so a spring already on
  /// its way is never restarted every frame.
  AnimationController _livenessFor(String id, double target) {
    final controller = _live[id] ??= AnimationController.unbounded(
      vsync: this,
      value: target,
    );
    if (_want[id] == target) return controller;
    _want[id] = target;
    if (_reduced) {
      controller.value = target;
    } else {
      controller.animateWith(
        SpringSimulation(
          NexusSpring.of(),
          controller.value,
          target,
          controller.velocity,
        ),
      );
    }
    return controller;
  }

  /// How far a node has arrived: the centre first, then the ring a beat behind
  /// it, so the picture assembles clockwise instead of blinking in whole.
  double _arrival(int index) {
    if (_reduced) return 1;
    final delay = index < 0 ? 0.0 : math.min(0.06 * (index + 1), 0.36);
    return ((_enter.value - delay) / (1 - delay)).clamp(0.0, 1.0);
  }

  /// Far enough out that no two node boxes touch, and no further than the page
  /// has room for. Two facts set the floor — the centre node is the biggest box
  /// on the graph, and neighbours on the ring must not collide — and the width
  /// sets the ceiling, because on a phone width is what runs out first.
  double _radiusFor(int peers, double width) {
    const beside = _selfNodeWidth / 2 + _peerNodeWidth / 2 + NexusSpace.md;
    final chord = peers < 2
        ? 0.0
        : _peerNodeWidth / 2 / math.sin(math.pi / peers) + NexusSpace.sm;
    final allowed = (width - _peerNodeWidth) / 2;
    return math.min(
      math.max(beside, chord),
      math.max(allowed, _peerNodeWidth / 2 + NexusSpace.sm),
    );
  }

  /// Where each peer sits on its ring. One device goes to the right and two go
  /// left and right — a link reads best as a line across the screen — and from
  /// three on they are spread evenly from the top, clockwise.
  List<double> _ringAngles(int peers) {
    if (peers == 1) return const [0];
    if (peers == 2) return const [0, math.pi];
    return [
      for (var i = 0; i < peers; i++) -math.pi / 2 + 2 * math.pi * i / peers,
    ];
  }

  /// Peers the inner ring holds before a second ring opens.
  ///
  /// Three keeps the arrangements a small mesh reads best as (one device to
  /// the right, two left and right, three spread from the top). A fourth device
  /// crowds the labels of the first three — measured on the phone, a fourth
  /// node at that radius' angle sits on top of its neighbour — so it goes on a
  /// ring of its own, staggered by half a step so no outer node hides behind an
  /// inner one.
  static const _innerRing = 3;

  /// Which ring each peer sits on, and where on it.
  ///
  /// Not a force simulation: the mesh has no forces in it, and a picture that
  /// rearranges itself while the user is looking at it is harder to read than a
  /// fixed one. Position is a function of the device's index, so a device keeps
  /// its place as long as the list of devices does.
  List<({int ring, double angle})> _placement(int peers) {
    final inner = math.min(peers, _innerRing);
    final outer = peers - inner;
    final rings = <({int ring, double angle})>[
      for (final angle in _ringAngles(inner)) (ring: 0, angle: angle),
    ];
    if (outer <= 0) return rings;
    final step = 2 * math.pi / outer;
    rings.addAll([
      for (final angle in _ringAngles(outer))
        if (outer == 1 || outer == 2)
          // One or two on the outer ring sit opposite each other, offset from
          // the inner ring's own two so they are not a straight line.
          (ring: 1, angle: angle + math.pi / 2)
        else
          (ring: 1, angle: angle + step / 2),
    ]);
    return rings;
  }

  Future<void> _showNodeActions(PairedDevice device) async {
    HapticFeedback.selectionClick();
    final chosen = await showNexusActions<String>(
      context: context,
      title: Text(device.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      actions: (popup) => [
        CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(popup, 'details'),
          child: const Text('Show details'),
        ),
        CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(popup, 'unpair'),
          child: const Text('Unpair'),
        ),
      ],
    );
    if (chosen == null || !mounted) return;
    switch (chosen) {
      case 'details':
        _showDetail(context, widget.mesh, device);
      case 'unpair':
        // The same confirmation the detail sheet uses, because forgetting is
        // the same act wherever it is reached from.
        final confirmed = await _confirmForget(context, device);
        if (confirmed == true) await widget.mesh.forgetDevice(device.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = NexusPalette.of(context);
    final mesh = widget.mesh;
    final peers = mesh.pairedDevices;
    final self = mesh.identity;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;

        // The room reserved under a disc for its label follows the user's text
        // size; the disc itself and the box's width do not, because the graph
        // is a picture of the mesh, not a place to read a long name.
        final peerBox = Size(
          _peerNodeWidth,
          _peerDisc + NexusType.scaled(context, 46),
        );
        final selfBox = Size(
          _selfNodeWidth,
          _selfDisc + NexusType.scaled(context, 54),
        );

        // Two rings, one radius each. The inner one is the radius a ring of
        // three needs (clamped to the page, which is what keeps a small mesh
        // fitting without any panning); the outer one clears a whole node box
        // radially, so the labels of the two rings never overlap.
        final placement = _placement(peers.length);
        final innerRadius = _radiusFor(
          math.min(peers.length, _innerRing),
          width,
        );
        final outerRadius = innerRadius + peerBox.height + NexusSpace.md;
        final byRing = [innerRadius, outerRadius];

        final centres = [
          for (final spot in placement)
            Offset(
              math.cos(spot.angle) * byRing[spot.ring],
              math.sin(spot.angle) * byRing[spot.ring],
            ),
        ];

        // The picture's own bounds, so one device is a short graph and six is a
        // tall one rather than the same fixed rectangle with a mostly empty
        // middle — and so nothing is ever positioned outside the box it is
        // clipped to.
        var bounds = Rect.fromCenter(
          center: Offset.zero,
          width: selfBox.width,
          height: selfBox.height,
        );
        for (final centre in centres) {
          bounds = bounds.expandToInclude(
            Rect.fromCenter(
              center: centre,
              width: peerBox.width,
              height: peerBox.height,
            ),
          );
        }
        // Two rings are wider than a phone page, so the picture is drawn on a
        // canvas at least as large as the content and panned rather than
        // squeezed: the artist's answer (a smaller radius) would be a pile of
        // overlapping labels, and the user can move a canvas.
        final canvasWidth = math
            .max(width, bounds.width + NexusSpace.xxl)
            .toDouble();
        final canvasHeight = math
            .max(bounds.height + NexusSpace.md, 200.0)
            .toDouble();
        final shift = Offset(
          (canvasWidth - bounds.width) / 2 - bounds.left,
          (canvasHeight - bounds.height) / 2 - bounds.top,
        );

        final links = <({_LinkState state, PeerLink? retry, Offset at})>[];
        final live = <AnimationController>[_enter, _dash];
        var retrying = false;
        for (final (i, device) in peers.indexed) {
          final link = _linkFor(mesh, device.id);
          if (link.retry != null) retrying = true;
          live.add(_livenessFor(device.id, link.state.liveness));
          links.add((
            state: link.state,
            retry: link.retry,
            at: shift + centres[i],
          ));
        }

        // The dash phase travels only while a link is actually being retried —
        // and it is parked at zero otherwise, so a graph that is not
        // reconnecting is completely still.
        if (retrying && !_reduced) {
          if (!_dash.isAnimating) _dash.repeat();
        } else if (_dash.value != 0) {
          _dash.stop();
          _dash.value = 0;
        }

        return SizedBox(
          height: canvasHeight,
          child: InteractiveViewer(
            // The canvas is its own size, never the viewport's: with two rings
            // it is wider than the page, and panning is how the rest of it is
            // reached. Pinching zooms the same picture — nothing above it in
            // the page moves, so a zoomed graph is a magnifier, not a layout
            // change.
            constrained: false,
            minScale: 0.6,
            // maxScale is left at the control's own 2.5, and clipBehavior at
            // its own Clip.hardEdge: the graph must not paint over the page
            // around it when it is zoomed in.
            boundaryMargin: const EdgeInsets.all(NexusSpace.xxxl),
            child: AnimatedBuilder(
              animation: Listenable.merge(live),
              builder: (context, _) => SizedBox(
                width: canvasWidth,
                height: canvasHeight,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _TopologyPainter(
                          selfAt: shift,
                          selfRadius: _selfDisc / 2,
                          peerRadius: _peerDisc / 2,
                          links: [
                            for (final (i, link) in links.indexed)
                              (
                                at: link.at,
                                liveness: _live[peers[i].id]!.value,
                              ),
                          ],
                          accent: palette.accent,
                          quiet: palette.textTertiary,
                          // 12px of travel over the cycle: enough that a dashed
                          // link is visibly being worked on, slow enough that it
                          // never reads as a progress bar.
                          dashPhase: _dash.value * 12,
                        ),
                        size: Size(canvasWidth, canvasHeight),
                      ),
                    ),
                    _positioned(
                      centre: shift,
                      width: selfBox.width,
                      disc: _selfDisc,
                      arrival: _arrival(-1),
                      child: _TopologyNode(
                        platform: self.platform,
                        name: self.name,
                        state: _LinkState.online,
                        detail: platformLabel(self.platform),
                        isSelf: true,
                      ),
                    ),

                    for (final (i, device) in peers.indexed)
                      _positioned(
                        centre: shift + centres[i],
                        width: peerBox.width,
                        disc: _peerDisc,
                        arrival: _arrival(i),
                        child: _TopologyNode(
                          platform: device.platform,
                          name: device.name,
                          state: links[i].state,
                          // The state in words, under the device it belongs to.
                          // This is the one place a graphed link's state is read:
                          // the row below is the device index, and it carries the
                          // words only when there is no picture to draw them in
                          // (see [_PairedRow.stateInGraph]). A retry shows the
                          // wait it is actually on, so the countdown grows with
                          // the backoff instead of repeating a stale number, and a
                          // node that is being worked on says so.
                          detail: links[i].retry != null
                              ? _reconnectingLabel(links[i].retry!)
                              : links[i].state.label,
                          isSelf: false,
                          onTap: () {
                            HapticFeedback.selectionClick();
                            _showDetail(context, mesh, device);
                          },
                          onLongPress: () =>
                              unawaited(_showNodeActions(device)),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// One node, placed by its disc's centre and scaled in as it arrives.
  Widget _positioned({
    required Offset centre,
    required double width,
    required double disc,
    required double arrival,
    required Widget child,
  }) {
    return Positioned(
      left: centre.dx - width / 2,
      top: centre.dy - disc / 2,
      width: width,
      child: Opacity(
        opacity: arrival,
        // The spring's own value drives the scale: a node grows into place
        // rather than sliding into it, because there is nowhere on this screen
        // it would be sliding from.
        child: Transform.scale(scale: 0.8 + 0.2 * arrival, child: child),
      ),
    );
  }
}

/// One device on the graph: its platform glyph in a disc, its name and its link
/// state under it.
///
/// The whole node is the pressable surface, not just the disc, so a thumb
/// aiming at a glyph does not have to land on it exactly.
class _TopologyNode extends StatelessWidget {
  const _TopologyNode({
    required this.platform,
    required this.name,
    required this.state,
    required this.detail,
    required this.isSelf,
    this.onTap,
    this.onLongPress,
  });

  final String platform;
  final String name;
  final _LinkState state;
  final String detail;

  /// The device the graph is drawn from: bigger, ringed in the accent, and not
  /// something you can pair with or forget.
  final bool isSelf;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final palette = NexusPalette.of(context);
    final disc = isSelf ? _selfDisc : _peerDisc;
    final live = state == _LinkState.online;
    return Semantics(
      container: true,
      button: onTap != null,
      // The node's own label carries the state a screen reader cannot get from
      // a dashed line; the words inside are excluded so the node is not read as
      // three unrelated fragments.
      label: isSelf ? '$name, this device' : '$name, ${state.label}',
      child: NexusPressable(
        borderRadius: NexusRadius.pill,
        onTap: onTap,
        onLongPress: onLongPress,
        child: ExcludeSemantics(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: disc,
                height: disc,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: live
                      ? palette.accentTint(isSelf ? 0.14 : 0.12)
                      : palette.surfaceSecondary,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isSelf
                        ? palette.accent
                        : live
                        ? palette.accent.withValues(alpha: 0.5)
                        : palette.separator,
                    width: isSelf ? 2 : 1,
                  ),
                ),
                child: Icon(
                  platformIcon(platform),
                  size: isSelf ? 32 : 24,
                  color: live ? palette.accent : palette.textSecondary,
                ),
              ),
              const SizedBox(height: NexusSpace.xs),
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: (isSelf ? NexusType.rowTitle : NexusType.caption)
                    .copyWith(
                      color: palette.textPrimary,
                      fontWeight: isSelf ? FontWeight.w600 : FontWeight.w500,
                    ),
              ),
              Text(
                detail,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: NexusType.caption1.copyWith(color: palette.textTertiary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Draws the links. One line per paired device, from the centre disc to that
/// device's disc, carrying nothing but the link's own state.
class _TopologyPainter extends CustomPainter {
  _TopologyPainter({
    required this.selfAt,
    required this.selfRadius,
    required this.peerRadius,
    required this.links,
    required this.accent,
    required this.quiet,
    required this.dashPhase,
  });

  final Offset selfAt;
  final double selfRadius;
  final double peerRadius;
  final List<({Offset at, double liveness})> links;
  final Color accent;
  final Color quiet;
  final double dashPhase;

  @override
  void paint(Canvas canvas, Size size) {
    for (final link in links) {
      final direction = link.at - selfAt;
      final distance = direction.distance;
      if (distance <= 0) continue;
      final unit = direction / distance;
      final start = selfAt + unit * (selfRadius + _lineInset);
      final end = link.at - unit * (peerRadius + _lineInset);
      if ((end - start).distance <= 0) continue;

      final v = link.liveness.clamp(0.0, 1.0);
      // One number drives all three: colour towards the accent, weight up, and
      // the dash closing up. A link that comes back therefore brightens and
      // thickens into a solid line rather than switching to one.
      final colour = Color.lerp(quiet, accent, v)!;
      final alpha = 0.18 + 0.4 * v;
      final weight = 1 + 1.2 * v;

      // The solid line and the dashes cross-fade over the last quarter of the
      // way to online, so the change of pattern is a fade and never a cut.
      final solid = ((v - 0.75) / 0.25).clamp(0.0, 1.0);
      if (solid > 0) {
        canvas.drawLine(
          start,
          end,
          Paint()
            ..color = colour.withValues(alpha: alpha * solid)
            ..strokeWidth = weight
            ..strokeCap = StrokeCap.round,
        );
      }
      if (solid < 1) {
        canvas.drawPath(
          _dashedLine(
            start,
            end,
            // A down link is a sparse dotted trace: the pairing is
            // remembered, the link itself is not there. A live retry is a
            // clear dash that travels.
            on: 1.5 + 3.5 * v,
            gap: 10 - 3.5 * v,
            phase: dashPhase * v,
          ),
          Paint()
            ..color = colour.withValues(alpha: alpha * (1 - solid))
            ..strokeWidth = weight
            ..strokeCap = StrokeCap.round,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_TopologyPainter old) => true;
}

/// [a]→[b] as a dashed path, starting [phase] pixels into the pattern so the
/// dashes travel along the line instead of blinking where they are.
Path _dashedLine(
  Offset a,
  Offset b, {
  required double on,
  required double gap,
  required double phase,
}) {
  final path = Path();
  final total = (b - a).distance;
  final step = on + gap;
  if (total <= 0 || step <= 0 || on <= 0) return path;
  final unit = (b - a) / total;
  var at = -(phase % step);
  while (at < total) {
    final from = math.max(at, 0.0);
    final to = math.min(at + on, total);
    if (to > from) {
      path.moveTo(a.dx + unit.dx * from, a.dy + unit.dy * from);
      path.lineTo(a.dx + unit.dx * to, a.dy + unit.dy * to);
    }
    at += step;
  }
  return path;
}

/// One technical fact. Label left, value right — the shape every phone's
/// "About" screen uses, because it reads at a glance.
class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: NexusSpace.lg,
        vertical: NexusSpace.md,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          const SizedBox(width: NexusSpace.md),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

/// A device Nexus can see but has not been paired with yet.
class _NearbyRow extends StatelessWidget {
  const _NearbyRow({required this.mesh, required this.device});

  final MeshService mesh;
  final DiscoveredDevice device;

  @override
  Widget build(BuildContext context) {
    final online = mesh.isOnline(device.id);
    return NexusRow(
      minHeight: NexusSize.row,
      leading: _DeviceGlyph(
        platform: device.platform,
        level: online ? NexusStatusLevel.online : NexusStatusLevel.offline,
        online: online,
      ),
      title: device.name,
      subtitle: online
          ? '${platformLabel(device.platform)} · reachable'
          : '${platformLabel(device.platform)} · seen ${_timeAgo(device.lastSeen)}',
      trailing: FilledButton.tonal(
        onPressed: () => showPairSheet(context, mesh: mesh, nearby: device),
        child: const Text('Pair'),
      ),
    );
  }
}

/// A microcontroller on the cable. Capability-aware: it advertises only
/// `ping`/`msg`, so the row offers exactly that and nothing more.
class _SerialRow extends StatelessWidget {
  const _SerialRow({required this.mesh, required this.device, this.hostName});

  final MeshService mesh;
  final SerialDevice device;

  /// Set for devices hosted by another paired device (multi-hop relay); the
  /// row then says "via [host]" instead of "over USB cable".
  final String? hostName;

  @override
  Widget build(BuildContext context) {
    final palette = NexusPalette.of(context);
    final online = device.online;
    final link = hostName != null ? 'via $hostName' : 'over USB cable';
    return NexusRow(
      minHeight: NexusSize.row,
      leading: Container(
        width: 40,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: online ? palette.accentTint(0.10) : palette.surfaceSecondary,
          borderRadius: NexusRadius.row,
        ),
        child: Icon(
          online ? Icons.memory_rounded : Icons.memory_outlined,
          size: 20,
          color: online ? palette.accent : palette.textSecondary,
        ),
      ),
      title: device.name,
      subtitle: online ? 'Online · $link' : 'Disconnected · $link',
      trailing: device.can('msg')
          ? NexusAsyncButton(
              label: 'Blink',
              icon: Icons.bolt_rounded,
              busyLabel: 'Sending…',
              successLabel: 'Sent',
              failureLabel: 'Unreachable',
              filled: false,
              onRun: () => mesh.sendSerialMessage(device.id, {'blink': true}),
            )
          : null,
    );
  }
}

Future<void> _renamePairedDevice(
  BuildContext context,
  MeshService mesh,
  PairedDevice device,
) async {
  final name = await showDialog<String>(
    context: context,
    builder: (_) => _RenameDeviceDialog(initialName: device.name),
  );
  if (name == null || name.isEmpty) return;
  await mesh.renamePairedDevice(device.id, name);
}

Future<bool?> _confirmForget(BuildContext context, PairedDevice device) {
  return showDialog<bool>(
    context: context, // An iOS alert: the destructive action is red ink on the right, not a
    // filled red button — the platform's own way of saying "this one hurts".
    builder: (context) => CupertinoAlertDialog(
      title: const Text('Forget this device?'),
      content: Text(
        '${device.name} will be removed and must be paired again from '
        "scratch to reconnect. This can't be undone.",
      ),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        CupertinoDialogAction(
          isDestructiveAction: true,
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Forget device'),
        ),
      ],
    ),
  );
}

class _RenameDeviceDialog extends StatefulWidget {
  final String initialName;

  const _RenameDeviceDialog({required this.initialName});

  @override
  State<_RenameDeviceDialog> createState() => _RenameDeviceDialogState();
}

class _RenameDeviceDialogState extends State<_RenameDeviceDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialName,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoAlertDialog(
      title: const Text('Rename device'),
      content: Padding(
        padding: const EdgeInsets.only(top: NexusSpace.md),
        child: CupertinoTextField(
          controller: _controller,
          autofocus: true,
          maxLength: 24,
          textInputAction: TextInputAction.done,
          placeholder: 'Device name',
          onSubmitted: (value) => Navigator.pop(context, value.trim()),
        ),
      ),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        CupertinoDialogAction(
          isDefaultAction: true,
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
