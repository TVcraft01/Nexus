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
  final separator = Platform.pathSeparator;
  // The counter goes before the extension, so a second "report.pdf" becomes
  // "report (1).pdf". A leading dot is part of the name, not an extension, so
  // a dotfile becomes ".gitignore (1)" rather than growing a second suffix.
  // This used to be a `replaceFirst` with a `\$1` in the replacement, which
  // Dart does not expand — the literal "$1" ended up in the filename.
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  final extension = dot > 0 ? name.substring(dot) : '';
  var path = '$dir$separator$name';
  var n = 1;
  while (File(path).existsSync()) {
    path = '$dir$separator$stem ($n)$extension';
    n++;
  }
  return path;
}
