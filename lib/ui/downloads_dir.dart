import 'dart:io';

import 'package:path_provider/path_provider.dart'
    show getApplicationDocumentsDirectory, getDownloadsDirectory;

/// Where a downloaded or fetched file lands: the platform's Downloads folder
/// when there is one, else `$HOME/Downloads`, else the app documents folder.
///
/// One owner for the rule the Files tab and the assistant's fetch both follow,
/// so a file fetched by asking and one downloaded by hand arrive in the same
/// place.
///
/// `NEXUS_DOWNLOADS_DIR`, when set, wins over all of the above. It exists so an
/// unattended harness can keep a run's fetched files inside its own directory
/// instead of the developer's real Downloads folder; unset, behavior is
/// unchanged.
Future<String> downloadsDirectory() async {
  final override = Platform.environment['NEXUS_DOWNLOADS_DIR'];
  if (override != null && override.isNotEmpty) return override;
  try {
    final dir = await getDownloadsDirectory();
    if (dir != null) return dir.path;
  } catch (_) {}
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home != null && home.isNotEmpty) {
    return '$home${Platform.pathSeparator}Downloads';
  }
  final docs = await getApplicationDocumentsDirectory();
  return docs.path;
}

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
