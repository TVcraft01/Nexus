// The two things a user can put into a conversation besides words: a photo
// from the camera, and a screenshot of the phone.
//
// The words matter as much as the bytes. Each attachment leaves a caption in
// the thread ("Photo attached") and is given to the brain as a bracketed
// sentence instead of its pixels — the local model this app ships cannot see
// images, and a prompt that pretended otherwise would be a lie the model then
// answers. One place decides both strings so the thread and the prompt can
// never drift apart.
//
// Files are copied out of the camera's and the screenshot's own temporary
// folders into one attachments folder, because the conversation is persisted
// and a thumbnail that pointed at a cache file would be a grey box after the
// next restart. When that folder cannot be reached — a desktop run, a widget
// test — the capture's own path is kept: the picture is still on screen for
// this session, which is better than refusing the attachment outright.
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:path_provider/path_provider.dart'
    show getApplicationDocumentsDirectory;

/// What the user attached.
enum AttachmentKind {
  photo,
  screenshot;

  /// The line the thread shows under (and speaks of) the picture.
  String get caption => switch (this) {
    AttachmentKind.photo => kPhotoCaption,
    AttachmentKind.screenshot => kScreenshotCaption,
  };

  /// What the brain is handed in place of the picture. Bracketed on purpose:
  /// it reads as an annotation about the turn, not as something the user
  /// typed, so a model quoting it back is obviously quoting.
  String get prompt => switch (this) {
    AttachmentKind.photo => kPhotoPrompt,
    AttachmentKind.screenshot => kScreenshotPrompt,
  };

  /// The word a failure message uses, e.g. "The photo did not come back."
  String get noun => switch (this) {
    AttachmentKind.photo => 'photo',
    AttachmentKind.screenshot => 'screenshot',
  };

  /// The tooltip on the composer button that starts one.
  String get action => switch (this) {
    AttachmentKind.photo => 'Take a photo',
    AttachmentKind.screenshot => 'Share a screen',
  };
}

/// The caption left in the thread by a camera photo.
const String kPhotoCaption = 'Photo attached';

/// The caption left in the thread by a screen capture.
const String kScreenshotCaption = 'Screenshot attached';

/// What the brain is told when the user attaches a photo. The model cannot
/// see the image; this sentence is what it gets instead.
const String kPhotoPrompt = '[User attached a photo]';

/// What the brain is told when the user attaches a screenshot.
const String kScreenshotPrompt = '[User attached a screenshot]';

/// Keeps captured images where the conversation can find them again.
///
/// Deliberately tiny: one folder, one copy, one answer. The interesting
/// decisions — where the folder is, and what happens when there is none — are
/// arguments, so a test drives both without a phone.
class AttachmentStore {
  AttachmentStore({Future<Directory?> Function()? directory})
    : _directory = directory ?? _defaultDirectory;

  /// Test seam, in the same shape as [ChatLog.override]: a test states where
  /// attachments live instead of touching the platform. The app never sets it.
  @visibleForTesting
  static AttachmentStore Function()? override;

  /// The app's store: the one Settings' "clear conversation" and the composer
  /// share.
  static AttachmentStore get instance => override?.call() ?? AttachmentStore();

  final Future<Directory?> Function() _directory;

  /// Android's app documents folder, which survives a restart and needs no
  /// permission. Created on first use.
  static Future<Directory?> _defaultDirectory() async {
    try {
      final Directory documents = await getApplicationDocumentsDirectory();
      // Awaited inside the try so a refused mkdir is caught here rather than
      // surfacing as an unhandled error in the caller's future.
      return await Directory('${documents.path}/attachments').create(
        recursive: true,
      );
    } catch (error) {
      // No path provider (desktop, tests): the capture's own file is enough.
      debugPrint('ATTACH: no documents folder ($error)');
      return null;
    }
  }

  /// Copies [sourcePath] into the store and answers where it now lives.
  ///
  /// Answers [sourcePath] unchanged when the copy cannot be made, so a capture
  /// is never thrown away because a folder was not there. A source that has
  /// already gone missing answers null — there is no picture to keep.
  Future<String?> keep(String sourcePath, {required AttachmentKind kind}) async {
    final File source = File(sourcePath);
    if (!await source.exists()) return null;
    final Directory? folder = await _directory();
    if (folder == null) return sourcePath;
    try {
      final String extension = _extensionOf(sourcePath);
      final String name =
          '${kind.name}-${DateTime.now().millisecondsSinceEpoch}$extension';
      final File target = await source.copy('${folder.path}/$name');
      return target.path;
    } catch (error) {
      debugPrint('ATTACH: could not keep the ${kind.noun} ($error)');
      return sourcePath;
    }
  }

  /// Deletes every kept file — what "clear conversation" means for pictures.
  /// A missing folder is already the goal, so it is not a failure.
  Future<void> clear() async {
    final Directory? folder = await _directory();
    if (folder == null) return;
    try {
      if (await folder.exists()) await folder.delete(recursive: true);
    } catch (error) {
      debugPrint('ATTACH: could not clear attachments ($error)');
    }
  }

  /// The source file's extension, lower-cased, or `.jpg` when it has none —
  /// a camera that hands back a bare path still yields a decodable name.
  static String _extensionOf(String path) {
    final int dot = path.lastIndexOf('.');
    if (dot <= 0 || dot == path.length - 1) return '.jpg';
    final String extension = path.substring(dot).toLowerCase();
    return extension.length > 5 ? '.jpg' : extension;
  }
}
