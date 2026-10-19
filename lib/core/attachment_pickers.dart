// The three ways a user can put a picture or a file into a conversation:
// the phone's own camera app, its gallery, and its file browser.
//
// Kept behind a seam for the reason every other platform call in this app is:
// a widget test has no gallery and no system file picker, and a composer test
// that reached one would either hang on a platform channel or open a dialog on
// whatever machine runs the suite. [AttachmentPickers.override] states the
// answer instead, exactly as [AttachmentStore.override] states the folder.
//
// The camera is deliberately the *system* camera app, not a preview of our own.
// A Flutter preview on some Samsung phones returns a black frame: the shutter
// fires before the sensor has exposed, and the encoder writes the dark frame.
// `ImagePicker` hands the shot to the phone's camera app, which owns its own
// warm-up and metering, and comes back with a file — the same path every major
// app uses when it needs a reliable photo.
//
// The pickers themselves are the packages the platform owns — `image_picker`
// for the camera and gallery (Android 13+ shows its own photo picker for the
// gallery, so no storage permission is asked) and `file_picker` for a document.
// All three answer a path this app can copy out of, which is what keeps the
// conversation's copy from pointing into another app's cache.
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show debugPrint, immutable, visibleForTesting;
import 'package:image_picker/image_picker.dart';

/// One thing the user picked: where it is, and what it is called.
@immutable
class PickedAttachment {
  const PickedAttachment({required this.path, required this.name});

  /// A path on this device. The pickers hand back a copy of the original, so
  /// the app can read it without asking for storage access.
  final String path;

  /// The name the user knows it by — the gallery file's or the document's.
  final String name;
}

/// The gallery and the file browser, behind one seam.
abstract class AttachmentPickers {
  /// Test seam, in the shape of [AttachmentStore.override]: a test states what
  /// the phone answered instead of touching a platform channel. The app never
  /// sets it.
  @visibleForTesting
  static AttachmentPickers Function()? override;

  static AttachmentPickers get current =>
      override?.call() ?? const DeviceAttachmentPickers();

  /// One picture from the phone's camera app, or null when the user backed out
  /// (or the camera could not open).
  Future<PickedAttachment?> captureImage();

  /// One picture from the gallery, or null when the user backed out (or the
  /// picker could not open).
  Future<PickedAttachment?> pickImage();

  /// One document from the file browser, or null when the user backed out.
  Future<PickedAttachment?> pickFile();
}

/// The real one: `image_picker` for the camera and photos, `file_picker` for
/// everything else.
class DeviceAttachmentPickers implements AttachmentPickers {
  const DeviceAttachmentPickers({@visibleForTesting this.camera});

  /// Test seam: what the system camera app answers. Null opens the real one.
  @visibleForTesting
  final Future<XFile?> Function()? camera;

  @override
  Future<PickedAttachment?> captureImage() async {
    try {
      final XFile? picked =
          await (camera?.call() ??
              ImagePicker().pickImage(
                source: ImageSource.camera,
                // The back lens is image_picker's default preference; the
                // system camera's own switch still offers the front one.
                // The same shrink as the gallery: the bubble is small and the
                // conversation's folder should not fill with 12 MP originals.
                maxWidth: 2048,
                maxHeight: 2048,
                imageQuality: 88,
                requestFullMetadata: false,
              ));
      if (picked == null) return null;
      return PickedAttachment(path: picked.path, name: picked.name);
    } catch (error) {
      debugPrint('ATTACH: the camera could not be opened ($error)');
      return null;
    }
  }

  @override
  Future<PickedAttachment?> pickImage() async {
    try {
      final XFile? picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        // A phone photo is several megabytes and the bubble is 150px tall;
        // shrinking on the way in keeps the conversation's folder small
        // without visibly changing what the user attached.
        maxWidth: 2048,
        maxHeight: 2048,
        imageQuality: 88,
        requestFullMetadata: false,
      );
      if (picked == null) return null;
      return PickedAttachment(path: picked.path, name: picked.name);
    } catch (error) {
      // A missing plugin, a picker that refused to open: the caller shows the
      // short sentence, and the log says which one it was.
      debugPrint('ATTACH: the gallery could not be opened ($error)');
      return null;
    }
  }

  @override
  Future<PickedAttachment?> pickFile() async {
    try {
      final PlatformFile? picked = await FilePicker.pickFile();
      if (picked == null) return null;
      final String? path = picked.path;
      if (path == null || !File(path).existsSync()) {
        debugPrint('ATTACH: the picked file has no local path');
        return null;
      }
      return PickedAttachment(path: path, name: picked.name);
    } catch (error) {
      debugPrint('ATTACH: the file browser could not be opened ($error)');
      return null;
    }
  }
}
