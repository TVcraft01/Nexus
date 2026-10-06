import 'dart:io';

import '../core/storage_roots.dart';

/// Where a downloaded or fetched file lands. One owner for the rule the Files
/// tab and the assistant's fetch both follow, so a file fetched by asking and
/// one downloaded by hand arrive in the same place — see [downloadRoot] for
/// how that place is decided per platform.
///
/// On Android with "All files access" granted this is the shared
/// `/storage/emulated/0/Download` the user sees in Files; without it, the
/// app's own folder (which Files hides), and the fetch result says so.
Future<String> downloadsDirectory() async =>
    (await downloadRoot()).path;

/// A path for [name] under [inDirectory] (or [downloadsDirectory]) that does
/// not overwrite an existing file — "report (1).pdf" when "report.pdf" is
/// already there.
Future<String> downloadsFilePath(String name, {String? inDirectory}) async {
  final dir = inDirectory ?? await downloadsDirectory();
  var path = '$dir${Platform.pathSeparator}$name';
  var n = 1;
  while (File(path).existsSync()) {
    path =
        '$dir${Platform.pathSeparator}'
        '${name.replaceFirst(RegExp(r'(\.[^.]*)?$'), ' ($n)\$1')}';
    n++;
  }
  return path;
}
