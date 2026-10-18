// A photo or screenshot, full screen, on black, with one way out.
//
// The thread shows a thumbnail because a conversation is a list of lines; this
// is the page for looking at the picture itself. Black rather than the app's
// surface colour is deliberate: a photo's edges are only visible against
// nothing, and a raised grey panel around it reads as part of the picture.
//
// Pinch-to-zoom is on because a screenshot of a settings screen is exactly the
// kind of image a user wants to read closely, and it costs no controls.
import 'dart:io';

import 'package:flutter/material.dart';

/// The key on the close button, so a test can find the one control here.
const Key kImageViewerClose = ValueKey<String>('image-viewer-close');

/// The key on the "Send to…" button, drawn only when a screen passes [onSend].
const Key kImageViewerSend = ValueKey<String>('image-viewer-send');

class ImageViewerPage extends StatelessWidget {
  const ImageViewerPage({
    super.key,
    required this.path,
    this.caption,
    this.onSend,
  });

  /// What the "Send to…" button does, or null to draw no button.
  ///
  /// A callback rather than a call into the send sheet, because the sheet lives
  /// in the shell (`main_ui.dart`) and this page is deliberately not part of it:
  /// the viewer knows how to show a picture, and who can receive one is the
  /// screen's business.
  final VoidCallback? onSend;

  /// Where the file is. A path that no longer exists draws the notice below
  /// instead of an exception.
  final String path;

  /// What the bubble called it ("Photo attached"), shown quietly at the
  /// bottom. Optional: the page is still the whole answer without it.
  final String? caption;

  /// Opens the viewer over the current screen.
  static Future<void> open(
    BuildContext context,
    String path, {
    String? caption,
    VoidCallback? onSend,
  }) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (BuildContext context) =>
            ImageViewerPage(path: path, caption: caption, onSend: onSend),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          InteractiveViewer(
            minScale: 1,
            maxScale: 5,
            child: Center(
              child: Image.file(
                File(path),
                fit: BoxFit.contain,
                errorBuilder: (BuildContext context, Object error, _) =>
                    const _MissingImage(),
              ),
            ),
          ),
          if (caption != null && caption!.isNotEmpty)
            SafeArea(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 24),
                  child: Text(
                    caption!,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ),
              ),
            ),
          if (onSend != null)
            SafeArea(
              child: Align(
                alignment: Alignment.bottomRight,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: FilledButton.icon(
                    key: kImageViewerSend,
                    onPressed: onSend,
                    icon: const Icon(Icons.send_rounded, size: 16),
                    label: const Text('Send to…'),
                  ),
                ),
              ),
            ),
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: IconButton(
                  key: kImageViewerClose,
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
        ],
      ),
    );
  }
}

/// The picture is gone — the file was deleted, or the conversation outlived
/// the store. Saying so is better than an empty black screen the user reads as
/// a failure of the app itself.
class _MissingImage extends StatelessWidget {
  const _MissingImage();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.broken_image_outlined, size: 42, color: Colors.white54),
          SizedBox(height: 12),
          Text(
            'This image is no longer on the device.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white70,
              fontSize: 14,
              decoration: TextDecoration.none,
            ),
          ),
        ],
      ),
    );
  }
}
