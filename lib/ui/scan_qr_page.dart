import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart'
    show CupertinoButton, CupertinoNavigationBar, CupertinoPageScaffold;
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../core/pair_payload.dart';
import '../core/qr_pairing.dart';
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
      // rawValue is the source of truth: some scanner builds hand back a
      // parsed URL/display string instead — log both and prefer raw.
      final raw = barcode.rawValue ?? barcode.displayValue;
      debugPrint(
        'NEXUS scan: raw=${raw == null ? '<null>' : raw.length > 120 ? '${raw.substring(0, 120)}…' : raw} '
        'format=${barcode.format} type=${barcode.type}',
      );
      if (raw == null) continue;
      final qr = QrPairingToken.parse(raw);
      if (qr != null) {
        debugPrint(
          'NEXUS scan: v2 qr pid=${qr.pairingId} code=${qr.code} '
          '(request only — no data read, no pairing yet)',
        );
        Navigator.pop(context, qr);
        return;
      }
      final payload = PairPayload.parse(raw);
      if (payload != null) {
        debugPrint('NEXUS scan: legacy v1 code (manual-entry path)');
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
            errorBuilder: (context, error) {
              debugPrint('NEXUS scan: camera error $error');
              return Center(
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
              );
            },
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
          // A quiet frame so it is clear where to point the camera, with the
          // sentence that says what to do with it directly underneath.
          //
          // One block, not two: a frame centred in the screen and a sentence
          // pinned to its bottom edge meet in the middle on a short screen —
          // a phone held sideways draws the words across the frame.
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final double side = math.min(
                240,
                math.max(120, constraints.maxHeight - 160),
              );
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Container(
                      width: side,
                      height: side,
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: NexusColors.accent,
                          width: 2.5,
                        ),
                        borderRadius: BorderRadius.circular(NexusRadius.xl),
                      ),
                    ),
                    const SizedBox(height: NexusSpace.lg),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: NexusSpace.page,
                      ),
                      child: Text(
                        'Point at the QR code on the other device',
                        textAlign: TextAlign.center,
                        style: NexusType.body.copyWith(color: white),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
