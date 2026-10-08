import 'dart:async';

import 'package:flutter/cupertino.dart'
    show CupertinoButton, CupertinoNavigationBar, CupertinoPageScaffold;
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../core/pair_payload.dart';
import 'theme.dart';

/// Full-screen camera view that scans a Nexus pairing QR and pops with the
/// parsed [PairPayload] (or null if the user backs out).
///
/// iOS chrome: a translucent bar floating over the camera, the one way out on
/// the left, and the guidance on the camera itself. The "that code was not
/// ours" message is a pill on the view rather than a snackbar, because a
/// snackbar is drawn by a Scaffold and this page — being a pushed page with no
/// Scaffold above it — would have shown it on the screen *behind* this one.
class ScanQrPage extends StatefulWidget {
  const ScanQrPage({super.key});

  @override
  State<ScanQrPage> createState() => _ScanQrPageState();
}

class _ScanQrPageState extends State<ScanQrPage> {
  final MobileScannerController _controller = MobileScannerController();

  /// The last thing the camera saw that was not a Nexus code, cleared on the
  /// same two-second clock the message always had.
  String? _notice;
  Timer? _noticeTimer;

  @override
  void dispose() {
    _noticeTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _showNotice(String message) {
    _noticeTimer?.cancel();
    setState(() => _notice = message);
    _noticeTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _notice = null);
    });
  }

  void _onDetect(BarcodeCapture capture) {
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null) continue;
      final payload = PairPayload.parse(raw);
      if (payload != null) {
        Navigator.pop(context, payload);
        return;
      }
    }
    // A QR was seen but it isn't a Nexus pairing code — tell the user and
    // keep scanning.
    _showNotice('That QR is not a Nexus pairing code. Keep scanning.');
  }

  @override
  Widget build(BuildContext context) {
    final white = Colors.white.withValues(alpha: 0.85);
    return CupertinoPageScaffold(
      backgroundColor: Colors.black,
      navigationBar: CupertinoNavigationBar(
        // Translucent: the framework blurs what is behind the bar, so the
        // camera keeps filling the screen and the bar reads as a layer over it
        // rather than a black stripe.
        backgroundColor: Colors.black.withValues(alpha: 0.55),
        border: Border(
          bottom: BorderSide(
            color: Colors.white.withValues(alpha: 0.12),
            width: 0.5,
          ),
        ),
        middle: const Text('Scan a Nexus code'),
      ),
      child: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(NexusSpace.xxl),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.no_photography_outlined,
                      size: 44,
                      color: Colors.white54,
                    ),
                    const SizedBox(height: NexusSpace.lg),
                    Text(
                      'The camera could not start.',
                      style: NexusType.rowTitle.copyWith(color: Colors.white),
                    ),
                    const SizedBox(height: NexusSpace.sm),
                    Text(
                      'Allow the camera permission for Nexus in your phone’s '
                      'settings, then come back here.',
                      textAlign: TextAlign.center,
                      style: NexusType.body.copyWith(
                        color: Colors.white.withValues(alpha: 0.7),
                      ),
                    ),
                    const SizedBox(height: NexusSpace.xl),
                    CupertinoButton(
                      color: NexusColors.accent,
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Back'),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_notice != null)
            Positioned(
              top: NexusSpace.xxl,
              left: NexusSpace.page,
              right: NexusSpace.page,
              child: Center(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.72),
                    borderRadius: NexusRadius.pill,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: NexusSpace.lg,
                      vertical: NexusSpace.sm,
                    ),
                    child: Text(
                      _notice!,
                      textAlign: TextAlign.center,
                      style: NexusType.caption.copyWith(color: Colors.white),
                    ),
                  ),
                ),
              ),
            ),
          // A quiet frame so it is clear where to point the camera.
          Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                border: Border.all(color: NexusColors.accent, width: 2.5),
                borderRadius: BorderRadius.circular(NexusRadius.xl),
              ),
            ),
          ),
          Positioned(
            bottom: NexusSpace.huge,
            left: 0,
            right: 0,
            child: Text(
              'Point at the QR code on the other device',
              textAlign: TextAlign.center,
              style: NexusType.body.copyWith(color: white),
            ),
          ),
        ],
      ),
    );
  }
}
