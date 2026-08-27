import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart';

/// Info about a newer Nexus release, if one exists.
class UpdateInfo {
  final String version;
  final String? downloadUrl;
  const UpdateInfo({required this.version, this.downloadUrl});
}

/// Cross-platform auto-update.
///
/// How it works: the app asks GitHub "what is the latest release?" on
/// startup. If it is newer than the running version, the app offers
/// "Update & restart" (Linux) or "Update & install" (Android).
///
/// - **Linux**: downloads the tarball, extracts next to the running install,
///   swaps directories, and relaunches itself.
/// - **Android**: downloads the APK and hands it to the system installer
///   (the OS shows "Do you want to install this update?").
///
/// If anything fails it says so — it never silently half-updates.
class Updater {
  /// The Android method channel used to open the APK installer.
  static const _androidChannel = MethodChannel('dev.nexus.nexus/installer');

  /// Compares semantic versions like "0.1.1" or "v0.1.1". Returns <0 if
  /// [a] is older than [b], 0 if equal, >0 if newer.
  static int compareVersions(String a, String b) {
    List<int> parts(String s) {
      final clean = s.trim().replaceFirst(RegExp(r'^v'), '');
      final main = clean.split('+').first.split('-').first;
      final list = main.split('.');
      while (list.length < 3) {
        list.add('0');
      }
      return list.take(3).map((p) => int.tryParse(p) ?? 0).toList();
    }

    final pa = parts(a);
    final pb = parts(b);
    for (var i = 0; i < 3; i++) {
      if (pa[i] != pb[i]) return pa[i] - pb[i];
    }
    return 0;
  }

  /// The expected asset name for the current platform.
  static String get _assetName {
    if (defaultTargetPlatform == TargetPlatform.android) {
      return 'nexus.apk';
    }
    return 'nexus-linux-x64.tar.gz';
  }

  /// Asks GitHub for the latest release and returns [UpdateInfo] when it is
  /// newer than [currentVersion]. [fetch] is injectable for tests.
  static Future<UpdateInfo?> checkForUpdate({
    required String currentVersion,
    String owner = 'TVcraft01',
    String repo = 'Nexus',
    Future<String> Function(String url)? fetch,
  }) async {
    final fetcher = fetch ?? _httpGet;
    try {
      final json = await _latestReleaseJson(fetcher, owner: owner, repo: repo);
      if (json == null) return null;
      final tag = json['tag_name'];
      if (tag is! String) return null;
      final version = tag.replaceFirst(RegExp(r'^v'), '');
      if (compareVersions(version, currentVersion) <= 0) return null;

      final info = UpdateInfo(
        version: version,
        downloadUrl: _assetUrl(json, _assetName),
      );
      debugPrint('NEXUS updater: update available v$version');
      return info;
    } catch (e) {
      debugPrint('NEXUS updater: check failed (${e.runtimeType}) — no update');
      return null;
    }
  }

  /// Fetches the latest release JSON from GitHub. Shared with cable pairing,
  /// which needs the same "what did we last publish?" answer.
  static Future<Map<String, dynamic>?> _latestReleaseJson(
    Future<String> Function(String url) fetch, {
    required String owner,
    required String repo,
  }) async {
    final body = await fetch('https://api.github.com/repos/$owner/$repo/releases/latest');
    final json = jsonDecode(body);
    return json is Map<String, dynamic> ? json : null;
  }

  /// Finds the download URL of [assetName] in a GitHub release JSON body.
  static String? _assetUrl(Map<String, dynamic> json, String assetName) {
    final assets = json['assets'];
    if (assets is! List) return null;
    for (final asset in assets) {
      if (asset is Map && asset['name'] == assetName) {
        return asset['browser_download_url'] as String?;
      }
    }
    return null;
  }

  /// The GitHub download URL of the latest published `nexus.apk`, if the
  /// latest release has one. Used by cable pairing to push the app to a
  /// phone that does not have it yet. [fetch] is injectable for tests.
  static Future<String?> latestApkUrl({
    String owner = 'TVcraft01',
    String repo = 'Nexus',
    Future<String> Function(String url)? fetch,
  }) async {
    final fetcher = fetch ?? _httpGet;
    try {
      final json = await _latestReleaseJson(fetcher, owner: owner, repo: repo);
      if (json == null) return null;
      return _assetUrl(json, 'nexus.apk');
    } catch (e) {
      debugPrint('NEXUS updater: latest APK lookup failed (${e.runtimeType})');
      return null;
    }
  }

  /// Downloads the update archive/APK to a temp file. Returns the path.
  static Future<String?> download(String url) async {
    final ext = defaultTargetPlatform == TargetPlatform.android ? '.apk' : '.tar.gz';
    final tmp = File('${Directory.systemTemp.path}/nexus-update-${DateTime.now().millisecondsSinceEpoch}$ext');
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != 200) return null;
      final sink = tmp.openWrite();
      await response.pipe(sink);
      await sink.close();
      return tmp.path;
    } catch (e) {
      return null;
    } finally {
      client.close();
    }
  }

  /// Applies a downloaded update:
  /// - **Linux**: extract, swap dirs, relaunch; needs [installDir].
  /// - **Android**: check the unknown-sources permission, hand the APK to the
  ///   system installer.
  ///
  /// Returns true when the update flow has been started (the app should
  /// step back and let the user/system finish).
  static Future<bool> applyUpdate(String archivePath, {String? installDir}) async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        final status = await _androidChannel.invokeMethod<String>('installApk', {
          'path': archivePath,
        });
        debugPrint('NEXUS updater: Android installer status: $status');
        // "launched" — installer open. "permission" — the app routed the
        // user to the system unknown-sources screen first; the install
        // continues automatically when they grant it and come back. Either
        // way the flow is in the user's hands, so it is not an error.
        return status == 'launched' || status == 'permission';
      } catch (e) {
        debugPrint('NEXUS updater: Android install failed: $e');
        return false;
      }
    }

    if (installDir == null) return false;
    if (!await extractAndSwap(archivePath, installDir)) return false;
    try {
      await Process.start(
        '$installDir${Platform.pathSeparator}nexus',
        const [],
        mode: ProcessStartMode.detached,
      );
    } catch (e) {
      debugPrint('NEXUS updater: relaunch failed: $e');
    }
    debugPrint('NEXUS updater: update applied, relaunching');
    return true;
  }

  /// Extracts the archive next to [installDir] and swaps the directories.
  /// Split out so the swap logic is unit-testable without relaunching.
  static Future<bool> extractAndSwap(String archivePath, String installDir) async {
    final tmp = Directory('$installDir.new');
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    tmp.createSync(recursive: true);

    final extract = await Process.run('tar', ['-xzf', archivePath, '-C', tmp.path]);
    if (extract.exitCode != 0) {
      debugPrint('NEXUS updater: extract failed: ${extract.stderr}');
      return false;
    }
    if (!File('${tmp.path}${Platform.pathSeparator}nexus').existsSync()) {
      debugPrint('NEXUS updater: archive has no nexus binary — refusing');
      return false;
    }

    // Swap: current install -> .old, new -> current.
    final old = Directory('$installDir.old');
    if (old.existsSync()) old.deleteSync(recursive: true);
    try {
      await Directory(installDir).rename('$installDir.old');
      await tmp.rename(installDir);
    } catch (e) {
      debugPrint('NEXUS updater: swap failed: $e');
      return false;
    }
    return true;
  }

  static Future<String> _httpGet(String url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.userAgentHeader, 'nexus-updater/1');
      final response = await request.close();
      return await response.transform(utf8.decoder).join();
    } finally {
      client.close();
    }
  }
}
