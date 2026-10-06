// The two folders Nexus reads from and writes into, decided in one place.
//
// One owner for both rules — the folder a device *serves* files from and the
// folder it *saves* a download into — because they used to be decided in two
// files with two different fallback chains, and on Android the save root
// quietly resolved to the app's own external folder. That folder is real and
// writable, but the Files app hides it: the user asks for `report.pdf`, the
// bytes land, and looking in Files → Downloads shows nothing, so the app
// reads as broken while it is only hidden.
//
// Android is the one platform where the two roots differ in a way the user
// notices. The shared Download folder — what a person means by "my Downloads"
// — is only writable with the "All files access" toggle. Granted, downloads
// land in `/storage/emulated/0/Download`. Not granted, they land in the app's
// own external folder, and [appScopedDownloadNote] says so in the result
// rather than letting the app look like it did nothing.
//
// The branch that matters is decided by [resolveDownloadRoot] /
// [resolveServeRoot], which take the platform facts as arguments, so a test
// pins "granted / denied / desktop" without a phone.
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:path_provider/path_provider.dart'
    show
        getApplicationDocumentsDirectory,
        getDownloadsDirectory,
        getExternalStorageDirectory;

/// Local channel to the Android side (see MainActivity): the "All files
/// access" state, the real shared-storage root, and the settings screen.
const _channel = MethodChannel('dev.nexus.nexus/storage');

/// A resolved storage folder, and whether the user can actually see it.
class StorageRoot {
  final String path;

  /// Android only: [path] sits inside the app's own external folder
  /// (`Android/data/<package>/…`), which the Files app hides. False everywhere
  /// else, and whenever the shared storage is in use.
  final bool appScoped;

  const StorageRoot(this.path, {this.appScoped = false});
}

/// Android's "All files access" toggle. Always true on other platforms.
Future<bool> allFilesAccess() async {
  if (!Platform.isAndroid) return true;
  try {
    return await _channel.invokeMethod<bool>('allFilesAccess') ?? false;
  } catch (_) {
    return false;
  }
}

/// Android's shared storage root (e.g. `/storage/emulated/0`), or null when it
/// cannot be read yet. Null everywhere else.
Future<String?> sharedStorageRoot() async {
  if (!Platform.isAndroid) return null;
  try {
    return await _channel.invokeMethod<String>('sharedRoot');
  } catch (_) {
    return null;
  }
}

/// Opens the system "All files access" screen for this app. No-op elsewhere.
Future<void> openAllFilesAccessSettings() async {
  if (!Platform.isAndroid) return;
  try {
    await _channel.invokeMethod<void>('openAllFilesAccessSettings');
  } catch (_) {
    // Channel unavailable (tests) — nothing to open.
  }
}

/// What a fetch result says when the file landed in the app's own folder
/// instead of the user's Downloads. The result already names the path; this
/// says why it is not where they looked, and what to change.
const String appScopedDownloadNote =
    "It went into Nexus's own app folder, which the Files app hides — allow "
    '"All files access" for Nexus in Settings to save straight to Downloads.';

/// Where a download lands, from the platform facts. Android with all-files
/// access gets the shared `Download` folder; without it, the app-scoped folder
/// path_provider hands back. Desktop keeps its old order: path_provider's
/// Downloads, then `$HOME/Downloads`, then the documents folder.
@visibleForTesting
StorageRoot resolveDownloadRoot({
  required bool android,
  bool allFilesAccess = false,
  String? sharedRoot,
  String? platformDownloads,
  String? home,
  String? documents,
}) {
  if (android) {
    if (allFilesAccess && sharedRoot != null && sharedRoot.isNotEmpty) {
      return StorageRoot('$sharedRoot/Download');
    }
    if (platformDownloads != null && platformDownloads.isNotEmpty) {
      return StorageRoot(platformDownloads, appScoped: true);
    }
    return StorageRoot(documents ?? '', appScoped: true);
  }
  if (platformDownloads != null && platformDownloads.isNotEmpty) {
    return StorageRoot(platformDownloads);
  }
  if (home != null && home.isNotEmpty) {
    return StorageRoot('$home${Platform.pathSeparator}Downloads');
  }
  return StorageRoot(documents ?? '');
}

/// Where this device serves files from: the shared storage on Android once
/// "All files access" is granted (so the peer sees every photo and download),
/// the app's own folder otherwise, and the home folder on desktop.
@visibleForTesting
StorageRoot resolveServeRoot({
  required bool android,
  bool allFilesAccess = false,
  String? sharedRoot,
  String? external,
  String? home,
  String? documents,
}) {
  if (android) {
    if (allFilesAccess && sharedRoot != null && sharedRoot.isNotEmpty) {
      return StorageRoot(sharedRoot);
    }
    if (external != null && external.isNotEmpty) {
      return StorageRoot(external, appScoped: true);
    }
    return StorageRoot(documents ?? '', appScoped: true);
  }
  if (home != null && home.isNotEmpty) return StorageRoot(home);
  return StorageRoot(documents ?? '');
}

/// The folder downloads land in. [override] is the tests'/harness's own dir;
/// `NEXUS_DOWNLOADS_DIR` does the same from the environment.
Future<StorageRoot> downloadRoot({String? override}) async {
  if (override != null && override.isNotEmpty) return StorageRoot(override);
  final env = Platform.environment['NEXUS_DOWNLOADS_DIR'];
  if (env != null && env.isNotEmpty) return StorageRoot(env);
  final android = Platform.isAndroid;
  return resolveDownloadRoot(
    android: android,
    allFilesAccess: android && await allFilesAccess(),
    sharedRoot: android ? await sharedStorageRoot() : null,
    platformDownloads: await _platformDownloads(),
    home: Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'],
    documents: await _documents(),
  );
}

/// The folder this device serves files from. [override] is the mesh's injected
/// root; `NEXUS_SERVED_ROOT` does the same from the environment so an
/// unattended harness can serve a scratch directory instead of the real home.
Future<StorageRoot> serveRoot({String? override}) async {
  if (override != null && override.isNotEmpty) return StorageRoot(override);
  final env = Platform.environment['NEXUS_SERVED_ROOT'];
  if (env != null && env.isNotEmpty) return StorageRoot(env);
  final android = Platform.isAndroid;
  return resolveServeRoot(
    android: android,
    allFilesAccess: android && await allFilesAccess(),
    sharedRoot: android ? await sharedStorageRoot() : null,
    external: android ? await _externalFilesDir() : null,
    home: Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'],
    documents: await _documents(),
  );
}

Future<String?> _platformDownloads() async {
  try {
    return (await getDownloadsDirectory())?.path;
  } catch (_) {
    return null;
  }
}

Future<String?> _externalFilesDir() async {
  try {
    return (await getExternalStorageDirectory())?.path;
  } catch (_) {
    // No external storage (emulator, odd device) — the caller falls back.
    return null;
  }
}

Future<String?> _documents() async {
  try {
    return (await getApplicationDocumentsDirectory()).path;
  } catch (_) {
    return null;
  }
}
