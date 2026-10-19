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
//
// Two Android-specific rules decide whether the photo that comes back is a
// photo at all, and both are measured rather than assumed:
//
//   * **the sensor needs a moment.** `initialize()` answers when the camera is
//     open, not when the first frame has been exposed. Shots taken in that
//     window came back completely black on the A25 — the sensor was still
//     ramping, and the encoder wrote the dark frame. So the shutter is not
//     offered until the preview has had [_warmUpDelay] to settle.
//   * **the bytes are copied while the camera is open.** `takePicture()`
//     answers with a file in the plugin's cache, and it is the controller that
//     flushes it. The copy into the attachment store is awaited *before* the
//     page pops (and therefore before the controller is disposed), because a
//     copy taken after disposal can read a half-written JPEG — which decodes
//     to black.
import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../core/attachments.dart';

/// The key on the shutter, so a test can press the one control that matters.
const Key kCameraShutter = ValueKey<String>('camera-shutter');

/// The key on the close button.
const Key kCameraClose = ValueKey<String>('camera-close');

/// The sentence shown when there is no camera to open.
const String kCameraUnavailableText = 'No camera is available on this device.';

/// How long the preview is allowed to run before the shutter is offered.
///
/// Not a spinner: the preview is already visible and live, so the wait is the
/// half-second before a button becomes usable, which is what a camera app does
/// while its metering settles. 300 ms is long enough for the first exposed
/// frame on the A25 and short enough that nobody presses twice.
const Duration _warmUpDelay = Duration(milliseconds: 300);

/// A camera as this page uses it: open, see, take one picture, close.
///
/// The plugin's [CameraController] is the real implementation ([PluginCamera]).
/// The seam exists because a widget test has no lens, and because the order of
/// these four operations is the difference between a photo and a black
/// rectangle — that order is what the tests pin.
abstract class CameraSession {
  Future<void> initialize();

  bool get initialized;

  /// The live preview, drawn by whichever controller is behind this session.
  Widget preview();

  Future<XFile> takePicture();

  Future<void> dispose();
}

/// The camera plugin's controller, behind [CameraSession].
class PluginCamera implements CameraSession {
  PluginCamera(CameraDescription description)
    : _controller = CameraController(
        description,
        // `high` rather than `max`. The largest preset asks a mid-range phone
        // for a frame bigger than the JPEG encoder can finish in time, and an
        // out-of-memory kill during capture loses the picture entirely. `high`
        // is still 1280×720, more than this app shows or sends.
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

  final CameraController _controller;

  @override
  bool get initialized => _controller.value.isInitialized;

  @override
  Future<void> initialize() => _controller.initialize();

  @override
  Widget preview() => CameraPreview(_controller);

  @override
  Future<XFile> takePicture() => _controller.takePicture();

  @override
  Future<void> dispose() => _controller.dispose();
}

class CameraPage extends StatefulWidget {
  const CameraPage({super.key, this.cameras, this.session});

  /// Which cameras the device has. Null asks the plugin — the app's only
  /// behaviour — while a test states the answer, because a widget test host
  /// has no platform camera to enumerate and asking would simply never answer.
  @visibleForTesting
  final Future<List<CameraDescription>> Function()? cameras;

  /// How a camera is turned into a session. Null uses [PluginCamera]; a test
  /// states its own for the same reason it states [cameras] — there is no
  /// lens — and because the capture order is what it wants to watch.
  @visibleForTesting
  final CameraSession Function(CameraDescription)? session;

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
  CameraSession? _session;
  bool _starting = true;

  /// Whether the sensor has had its warm-up. Until it has, the shutter is drawn
  /// disabled and does nothing: a shot taken on a dark sensor is a black photo.
  bool _warm = false;
  bool _busy = false;
  String? _error;
  String? _notice;
  Timer? _warmUp;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  /// Opens the first usable camera, preferring the one on the back of the
  /// phone. Every failure is a sentence, never a throw: the plugin's own
  /// exceptions differ by platform and by how the permission was refused.
  Future<void> _start() async {
    CameraSession? opened;
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
        (CameraDescription c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final CameraSession session = (widget.session ?? PluginCamera.new)(
        description,
      );
      opened = session;
      await session.initialize();
      if (!mounted) {
        unawaited(session.dispose());
        return;
      }
      setState(() {
        _session = session;
        _starting = false;
      });
      // The preview is live now; the shutter waits for the sensor to catch up.
      _warmUp = Timer(_warmUpDelay, () {
        if (mounted) setState(() => _warm = true);
      });
    } catch (error) {
      debugPrint('CAMERA: could not open ($error)');
      // A controller that opened and then failed to initialize still holds the
      // camera; leaving it is how the next attempt finds the lens busy.
      if (opened != null) unawaited(opened.dispose());
      if (!mounted) return;
      setState(() {
        _starting = false;
        _error = kCameraUnavailableText;
      });
    }
  }

  /// One shot: take it, copy it somewhere permanent, and hand the path back.
  ///
  /// The copy is awaited *here*, while the controller is still alive: the page
  /// pops only after the store has the bytes, and the controller is disposed
  /// with the widget. Doing it the other way round — pop, then copy — is the
  /// shape that produces a black or truncated photo on Android, because
  /// `takePicture`'s file is still being written by the camera service when
  /// the controller goes away.
  Future<void> _capture() async {
    final CameraSession? session = _session;
    if (session == null || _busy || !_warm || !session.initialized) {
      return;
    }
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      final XFile shot = await session.takePicture();
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
    _warmUp?.cancel();
    _warmUp = null;
    unawaited(_session?.dispose());
    _session = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final CameraSession? session = _session;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          if (session != null)
            Center(child: session.preview())
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
          if (session != null)
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
                      _Shutter(busy: _busy || !_warm, onTap: _capture),
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
