import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show debugPrint, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart';

/// Info about a newer Nexus release, if one exists.
class UpdateInfo {
  final String version;
  final String? downloadUrl;
  final String? releaseUrl;
  const UpdateInfo({
    required this.version,
    this.downloadUrl,
    this.releaseUrl,
  });
}

/// Cross-platform update discovery and application.
///
/// Linux and Android have an automatic install path. Windows can discover a
/// newer release and open its GitHub release page; replacing a running Windows
/// executable safely requires a separate updater process and is deliberately
/// not attempted here.
class Updater {
  static const _androidChannel = MethodChannel('dev.nexus.nexus/installer');

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

  static String? get _assetName {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'nexus.apk';
      case TargetPlatform.linux:
        return 'nexus-linux-x64.tar.gz';
      case TargetPlatform.windows:
        return 'nexus-windows-x64.zip';
      case TargetPlatform.macOS:
      case TargetPlatform.iOS:
      case TargetPlatform.fuchsia:
        return null;
    }
  }

  static Future<UpdateInfo?> checkForUpdate({
    required String currentVersion,
    String owner = 'TVcraft01',
    String repo = 'Nexus',
    Future<String> Function(String url)? fetch,
  }) async {
    final assetName = _assetName;
    if (assetName == null) return null;

    final fetcher = fetch ?? _httpGet;
    try {
      final json = await _latestReleaseJson(fetcher, owner: owner, repo: repo);
      if (json == null) return null;
      final tag = json['tag_name'];
      if (tag is! String) return null;
      final version = tag.replaceFirst(RegExp(r'^v'), '');
      if (compareVersions(version, currentVersion) <= 0) return null;

      final downloadUrl = _assetUrl(json, assetName);
      if (downloadUrl == null) {
        debugPrint(
          'NEXUS updater: v$version exists but has no $assetName asset',
        );
        return null;
      }

      final releaseUrl = json['html_url'] as String?;
      debugPrint('NEXUS updater: update available v$version');
      return UpdateInfo(
        version: version,
        downloadUrl: downloadUrl,
        releaseUrl: releaseUrl,
      );
    } catch (e) {
      debugPrint('NEXUS updater: check failed (${e.runtimeType}) — no update');
      return null;
    }
  }

  static Future<Map<String, dynamic>?> _latestReleaseJson(
    Future<String> Function(String url) fetch, {
    required String owner,
    required String repo,
  }) async {
    final body = await fetch(
      'https://api.github.com/repos/$owner/$repo/releases/latest',
    );
    final json = jsonDecode(body);
    return json is Map<String, dynamic> ? json : null;
  }

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

  static Future<String?> download(String url) async {
    final ext = switch (defaultTargetPlatform) {
      TargetPlatform.android => '.apk',
      TargetPlatform.windows => '.zip',
      _ => '.tar.gz',
    };
    final tmp = File(
      '${Directory.systemTemp.path}/nexus-update-${DateTime.now().millisecondsSinceEpoch}$ext',
    );
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

  static Future<bool> applyUpdate(
    String archivePath, {
    String? installDir,
  }) async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        final status = await _androidChannel.invokeMethod<String>('installApk', {
          'path': archivePath,
        });
        debugPrint('NEXUS updater: Android installer status: $status');
        return status == 'launched' || status == 'permission';
      } catch (e) {
        debugPrint('NEXUS updater: Android install failed: $e');
        return false;
      }
    }

    if (defaultTargetPlatform != TargetPlatform.linux || installDir == null) {
      return false;
    }
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

    final old = Directory('$installDir.old');
    if (old.existsSync()) old.deleteSync(recursive: true);
    try {
      await Directory(installDir).rename(old.path);
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
