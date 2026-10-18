// One screenshot of this phone, taken through Android's own MediaProjection
// API — the dialog the user sees is the platform's, not a Nexus imitation.
//
// A capture is a single frame, not a mirror that stays open: the projection is
// granted, one image is read, and the projection is torn down before the path
// comes back. That is why this answers a file rather than a stream — there is
// nothing left running once it answers.
//
// Every answer is a [ScreenCaptureResult], never an exception. A user who
// declined the system dialog and a phone that cannot screenshot at all are
// both ordinary outcomes of pressing the button, and both deserve a sentence
// instead of a red screen.
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException, PlatformException;

/// The channel MainActivity answers on (see `SCREEN_CHANNEL` there).
const MethodChannel _channel = MethodChannel('dev.nexus.nexus/screen');

/// What a capture attempt ended with: a file, or the reason there is none.
class ScreenCaptureResult {
  const ScreenCaptureResult(this.path, [this.message]);

  /// Where the PNG landed, or null when nothing was captured.
  final String? path;

  /// The sentence to show the user when [path] is null. Null on success.
  final String? message;

  bool get ok => path != null;

  @override
  String toString() => ok ? 'ScreenCaptureResult($path)' : 'ScreenCaptureResult($message)';
}

/// Takes one screenshot of this device.
///
/// Outside Android there is nothing to ask: the answer says so in the same
/// shape a refusal does, so the caller has one path to draw.
class ScreenCapture {
  const ScreenCapture._();

  /// Test seam in the same shape as [AttachmentStore.override]: a widget test
  /// decides what a capture answers without a projection dialog. The app never
  /// sets it.
  @visibleForTesting
  static Future<ScreenCaptureResult> Function()? override;

  /// Asks the platform for one frame. The user's answer to the system dialog is
  /// the whole gate — a refusal comes back here as a sentence.
  static Future<ScreenCaptureResult> capture() async {
    final Future<ScreenCaptureResult> Function()? fake = override;
    if (fake != null) return fake();
    if (!Platform.isAndroid) {
      return const ScreenCaptureResult(
        null,
        'Screen capture needs an Android phone.',
      );
    }
    try {
      final String? path = await _channel.invokeMethod<String>('capture');
      if (path == null || path.isEmpty) {
        return const ScreenCaptureResult(
          null,
          'The screenshot did not come back.',
        );
      }
      return ScreenCaptureResult(path);
    } on PlatformException catch (error) {
      return ScreenCaptureResult(
        null,
        error.message ?? 'The screenshot could not be taken.',
      );
    } on MissingPluginException {
      return const ScreenCaptureResult(
        null,
        'Screen capture is not available in this build.',
      );
    } catch (error) {
      return ScreenCaptureResult(
        null,
        'The screenshot could not be taken ($error).',
      );
    }
  }
}
