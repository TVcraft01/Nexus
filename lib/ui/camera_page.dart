// The camera, opened from the composer's camera button: a full-screen preview,
// one shutter, and an X.
//
// Deliberately not a camera *app*: no gallery, no recording, no settings. What
// is captured is copied into the conversation's attachment store and the path
// is what this page pops with, so the caller never sees a camera type and the
// page never sees a thread.
//
// A phone that cannot open a camera — a desktop build, a permission the user
// refused, a device with no lens — lands on [_CameraUnavailable] rather than a
// black screen: pressing a button and getting nothing back is the failure this
// page exists to avoid.
import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../core/attachments.dart';

/// The key on the shutter, so a test can press the one control that matters.
const Key kCameraShutter = ValueKey<String>('camera-shutter');

/// The key on the close button.
const Key kCameraClose = ValueKey<String>('camera-close');

/// The sentence shown when there is no camera to open.
const String kCameraUnavailableText =
    'No camera is available on this device.';

class CameraPage extends StatefulWidget {
  const CameraPage({super.key, this.cameras});

  /// Which cameras the device has. Null asks the plugin — the app's only
  /// behaviour — while a test states the answer, because a widget test host
  /// has no platform camera to enumerate and asking would simply never answer.
  @visibleForTesting
  final Future<List<CameraDescription>> Function()? cameras;

  /// Opens the camera and answers the kept photo's path, or null when the user
  /// backed out — or when the camera could not be used at all.
  static Future<String?> open(BuildContext context) {
    return Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        fullscreenDialog: true,
        builder: (BuildContext context) => const CameraPage(),
      ),
    );
  }

  @override
  State<CameraPage> createState() => _CameraPageState();
}

class _CameraPageState extends State<CameraPage> {
  CameraController? _controller;
  bool _starting = true;
  bool _busy = false;
  String? _error;
  String? _notice;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  /// Opens the first usable camera, preferring the one on the back of the
  /// phone. Every failure is a sentence, never a throw: the plugin's own
  /// exceptions differ by platform and by how the permission was refused.
  Future<void> _start() async {
    try {
      final List<CameraDescription> cameras =
          await (widget.cameras ?? availableCameras)();
      if (cameras.isEmpty) {
        if (mounted) {
          setState(() {
            _starting = false;
            _error = kCameraUnavailableText;
          });
        }
        return;
      }
      final CameraDescription description = cameras.firstWhere(
        (CameraDescription c) =>
            c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final CameraController controller = CameraController(
        description,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await controller.initialize();
      if (!mounted) {
        unawaited(controller.dispose());
        return;
      }
      setState(() {
        _controller = controller;
        _starting = false;
      });
    } catch (error) {
      debugPrint('CAMERA: could not open ($error)');
      if (!mounted) return;
      setState(() {
        _starting = false;
        _error = kCameraUnavailableText;
      });
    }
  }

  /// One shot: take it, keep it, and hand the path back. The shutter is
  /// disabled for the second it takes, so a double tap cannot take two photos
  /// and pop with one.
  Future<void> _capture() async {
    final CameraController? controller = _controller;
    if (controller == null || _busy || !controller.value.isInitialized) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      final XFile shot = await controller.takePicture();
      final String? kept = await AttachmentStore.instance.keep(
        shot.path,
        kind: AttachmentKind.photo,
      );
      if (!mounted) return;
      if (kept == null) {
        setState(() {
          _busy = false;
          _notice = 'The photo could not be read back.';
        });
        return;
      }
      Navigator.of(context).pop(kept);
    } catch (error) {
      debugPrint('CAMERA: shot failed ($error)');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _notice = 'The photo could not be taken.';
      });
    }
  }

  @override
  void dispose() {
    unawaited(_controller?.dispose());
    _controller = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final CameraController? controller = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          if (controller != null)
            Center(child: CameraPreview(controller))
          else if (_starting)
            const Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            _CameraUnavailable(message: _error ?? kCameraUnavailableText),
          SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: IconButton(
                  key: kCameraClose,
                  tooltip: 'Close',
                  icon: const Icon(Icons.close_rounded),
                  color: Colors.white,
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.black.withValues(alpha: 0.35),
                  ),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ),
          ),
          if (controller != null)
            SafeArea(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      if (_notice != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(
                            _notice!,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      _Shutter(busy: _busy, onTap: _capture),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The shutter: a white ring with a filled centre, the one control in the
/// middle of the frame where a thumb already is.
class _Shutter extends StatelessWidget {
  const _Shutter({required this.busy, required this.onTap});

  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Take photo',
      child: GestureDetector(
        key: kCameraShutter,
        onTap: busy ? null : onTap,
        child: Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 4),
          ),
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              width: busy ? 30 : 56,
              height: busy ? 30 : 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: busy ? Colors.white54 : Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// What a device with no usable camera shows: the reason, and the way out.
class _CameraUnavailable extends StatelessWidget {
  const _CameraUnavailable({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              Icons.no_photography_outlined,
              size: 38,
              color: Colors.white54,
            ),
            const SizedBox(height: 14),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 15),
            ),
            const SizedBox(height: 18),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }
}
