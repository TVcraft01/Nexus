// The phone as a mouse for a paired desktop.
//
// The pad is deliberately a surface, not a control panel: one large dark plane,
// one finger, and the two gestures a trackpad has — drag to move, tap to click.
// The right and middle buttons of a desktop mouse are not here yet; inventing
// a button that the receiving side cannot honour would be worse than leaving it
// out.
//
// Movement is coalesced on a 33 ms tick. A finger emits far more updates than a
// network should see, and sending every one would turn a smooth drag into a
// queue; what crosses the wire is the distance travelled since the last frame,
// which is exactly what a relative pointer needs.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../core/paired_devices.dart' show PairedDevice;
import '../mesh/file_transfer_service.dart' show FileTransferService;
import '../l10n/copy.dart';

/// The seam a widget test uses to see what the pad would send. Production
/// leaves it null and the real service sends the request.
typedef TrackpadSender = Future<bool> Function(int dx, int dy, bool click);

class TrackpadPage extends StatefulWidget {
  const TrackpadPage({super.key, required this.device, this.send});

  /// The desktop this pad drives.
  final PairedDevice device;

  /// Null uses [FileTransferService.sendMouse] against [device].
  final TrackpadSender? send;

  @override
  State<TrackpadPage> createState() => _TrackpadPageState();
}

class _TrackpadPageState extends State<TrackpadPage> {
  static const Color _ground = Color(0xFF07080A);
  static const Color _pad = Color(0xFF101216);
  static const Color _padBorder = Color(0xFF252A33);
  static const Color _ink = Color(0xFFF4F6FA);
  static const Color _inkMuted = Color(0xFF7D8798);
  static const Color _online = Color(0xFF34D399);
  static const Color _offline = Color(0xFFF87171);

  /// Where the finger has travelled since the last tick.
  double _dx = 0;
  double _dy = 0;

  /// Where the finger first landed. The pan gesture only starts after the
  /// touch slop, so its first update does not contain the movement that crossed
  /// that slop; measuring from down to start keeps a small drag from vanishing.
  Offset? _lastPointer;
  bool _click = false;
  bool _inFlight = false;
  bool _touching = false;
  bool _unreachable = false;

  late final Timer _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(
      const Duration(milliseconds: 33),
      (_) => unawaited(_flush()),
    );
  }

  @override
  void dispose() {
    _ticker.cancel();
    super.dispose();
  }

  Future<void> _flush() async {
    if (_inFlight) return;
    final int dx = _dx.round();
    final int dy = _dy.round();
    final bool click = _click;
    if (!click && dx == 0 && dy == 0) return;
    // A movement smaller than a pixel is kept until it becomes one, so a slow
    // finger is not rounded away to nothing.
    if (dx != 0) _dx -= dx;
    if (dy != 0) _dy -= dy;
    _click = false;
    _inFlight = true;
    final bool ok =
        await (widget.send?.call(dx, dy, click) ??
            FileTransferService.instance.sendMouse(
              widget.device,
              dx: dx.toDouble(),
              dy: dy.toDouble(),
              click: click,
            ));
    _inFlight = false;
    if (!mounted) return;
    if (ok && _unreachable) {
      setState(() => _unreachable = false);
    } else if (!ok && !_unreachable) {
      setState(() => _unreachable = true);
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              "Can't reach ${widget.device.name}. Check it is on this network.",
            ),
            duration: const Duration(seconds: 3),
          ),
        );
    }
  }

  void _tap() {
    unawaited(HapticFeedback.lightImpact());
    _click = true;
    unawaited(_flush());
  }

  @override
  Widget build(BuildContext context) {
    final String status = _unreachable
        ? "Can't reach ${widget.device.name}"
        : 'Sending to ${widget.device.name}';
    return Scaffold(
      backgroundColor: _ground,
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 20, 12),
              child: Row(
                children: <Widget>[
                  IconButton(
                    tooltip: context.l10n.back,
                    onPressed: () => Navigator.maybePop(context),
                    icon: const Icon(
                      Icons.arrow_back_rounded,
                      color: _ink,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          'Remote',
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(
                                color: _ink,
                                fontWeight: FontWeight.w600,
                                letterSpacing: -0.3,
                              ),
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: <Widget>[
                            Container(
                              width: 7,
                              height: 7,
                              decoration: BoxDecoration(
                                color: _unreachable ? _offline : _online,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 7),
                            Flexible(
                              child: Text(
                                status,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(color: _inkMuted),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Semantics(
                  label: 'Trackpad for ${widget.device.name}',
                  hint: 'Drag to move, tap to click',
                  child: GestureDetector(
                    key: const ValueKey<String>('trackpad-pad'),
                    behavior: HitTestBehavior.opaque,
                    onTap: _tap,
                    onPanDown: (DragDownDetails details) {
                      _lastPointer = details.globalPosition;
                    },
                    onPanStart: (DragStartDetails details) {
                      final Offset? last = _lastPointer;
                      if (last != null) {
                        _dx += details.globalPosition.dx - last.dx;
                        _dy += details.globalPosition.dy - last.dy;
                      }
                      _lastPointer = details.globalPosition;
                      HapticFeedback.selectionClick();
                      setState(() => _touching = true);
                    },
                    onPanUpdate: (DragUpdateDetails details) {
                      _dx += details.delta.dx;
                      _dy += details.delta.dy;
                    },
                    onPanEnd: (_) {
                      _lastPointer = null;
                      setState(() => _touching = false);
                      unawaited(_flush());
                    },
                    onPanCancel: () {
                      _lastPointer = null;
                      setState(() => _touching = false);
                      unawaited(_flush());
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      curve: Curves.easeOutCubic,
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: _pad,
                        borderRadius: BorderRadius.circular(28),
                        border: Border.all(
                          color: _touching
                              ? _online.withValues(alpha: 0.55)
                              : _padBorder,
                          width: _touching ? 1.4 : 1,
                        ),
                      ),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Icon(
                              Icons.touch_app_outlined,
                              size: 34,
                              color: _inkMuted.withValues(alpha: 0.55),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'Drag to move',
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(
                                    color: _ink.withValues(alpha: 0.72),
                                    fontWeight: FontWeight.w500,
                                  ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Tap to click',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: _inkMuted),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 18),
              child: Text(
                'One finger on the pad moves the pointer. A tap clicks.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: _inkMuted, height: 1.4),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
