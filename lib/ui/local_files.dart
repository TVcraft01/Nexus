// What this device can do with a file it already holds — open it with the
// platform's own viewer, share it through the platform's own sheet, copy it
// somewhere the user picks. The three verbs behind the assistant's fetched-
// file card and the Files tab's Recent rows.
//
// Every mechanism here is one already in the tree: the Android device
// channel (ACTION_VIEW / ACTION_SEND through the app's FileProvider), the
// desktop's `xdg-open` through the injectable [CommandRunner], and
// file_selector's save dialog — which Android does not have, so "Save as…"
// falls back to another de-duplicated copy in Downloads.
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:url_launcher/url_launcher.dart' show launchUrl;

import '../core/system_command.dart';
import 'downloads_dir.dart';

const _deviceChannel = MethodChannel('dev.nexus.nexus/device');

/// Opens [path] with whatever this platform opens that kind of file with: an
/// ACTION_VIEW intent on Android (a content:// URI from the app's
/// FileProvider, so the viewer can actually read it), `xdg-open` on Linux,
/// and the system file handler elsewhere. Answers false when nothing here
/// could open it — the file is gone, or no app claimed the kind — so the
/// caller says so instead of looking broken.
Future<bool> openLocalFile(String path, {CommandRunner? run}) async {
  if (!File(path).existsSync()) return false;
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
      try {
        final raw = await _deviceChannel.invokeMapMethod<String, dynamic>(
          'openFile',
          {'path': path},
        );
        return raw?['ok'] == true;
      } catch (_) {
        return false;
      }
    case TargetPlatform.linux:
      try {
        await (run ?? systemCommandRunner)('xdg-open', [path]);
        return true;
      } catch (_) {
        return false;
      }
    default:
      try {
        return await launchUrl(Uri.file(path));
      } catch (_) {
        return false;
      }
  }
}

/// Shares [path] through the platform's own share sheet — an ACTION_SEND
/// chooser on Android. Desktop Linux has no share sheet to offer; that is a
/// real limitation, and false lets the card name it rather than pretend.
Future<bool> shareLocalFile(String path) async {
  if (!File(path).existsSync()) return false;
  if (defaultTargetPlatform != TargetPlatform.android) return false;
  try {
    final raw = await _deviceChannel.invokeMapMethod<String, dynamic>(
      'shareFile',
      {'path': path},
    );
    return raw?['ok'] == true;
  } catch (_) {
    return false;
  }
}

/// Copies the file at [path] to where the user wants it: their pick from the
/// system save dialog on desktop, or — on Android, which has no such dialog —
/// another copy in Downloads that never overwrites what is already there.
/// Answers the new path, or null when the user cancelled or it failed.
Future<String?> saveLocalFileAs(String path) async {
  final source = File(path);
  if (!source.existsSync()) return null;
  final name = path.split(Platform.pathSeparator).last;
  try {
    final location = await getSaveLocation(suggestedName: name);
    if (location == null) return null; // the user changed their mind
    await source.copy(location.path);
    return location.path;
  } on UnimplementedError {
    // No save dialog on this platform (Android) — the Downloads copy below.
  } catch (_) {
    return null;
  }
  try {
    final copy = await downloadsFilePath(name);
    await source.copy(copy);
    return copy;
  } catch (_) {
    return null;
  }
}
