import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../core/pair_payload.dart';
import 'theme.dart';

/// Full-screen camera view that scans a Nexus pairing QR and pops with the
/// parsed [PairPayload] (or null if the user backs out).
class ScanQrPage extends StatefulWidget {
  const ScanQrPage({super.key});

  @override
  State<ScanQrPage> createState() => _ScanQrPageState();
}

class _ScanQrPageState extends State<ScanQrPage> {
  final MobileScannerController _controller = MobileScannerController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
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
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('That QR is not a Nexus pairing code. Keep scanning.'),
      duration: Duration(seconds: 2),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Scan a Nexus code', style: TextStyle(fontSize: 16)),
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.no_photography_outlined, size: 44, color: Colors.white54),
                    const SizedBox(height: 16),
                    const Text(
                      'The camera could not start.',
                      style: TextStyle(color: Colors.white, fontSize: 16),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Allow the camera permission for Nexus in your phone’s '
                      'settings, then come back here.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.7)),
                    ),
                    const SizedBox(height: 20),
                    OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Back'),
                    ),
                  ],
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
                borderRadius: BorderRadius.circular(20),
              ),
            ),
          ),
          Positioned(
            bottom: 40,
            left: 0,
            right: 0,
            child: Text(
              'Point at the QR code on the other device',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.85)),
            ),
          ),
        ],
      ),
    );
  }
}
