import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show debugPrint, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart';

import '../core/system_command.dart';

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

/// A fetched answer: the body and the status it arrived with.
///
/// The status is carried because it *is* the reason. GitHub answers 403 when it
/// is rate-limiting a network and 404 when nothing is published, and both of
/// those bodies decode as JSON — so a check that dropped the status could only
/// report "no update", which is how a phone on a carrier network came to be
/// told it was up to date when nothing had been checked.
class UpdateResponse {
  final int status;
  final String body;
  const UpdateResponse(this.status, this.body);
}

/// What came of looking for an update: the release to install when there is
/// one, and — when there is not — whether that answer is real or the check
/// itself could not be made.
///
/// The distinction is the whole point: "nothing newer" is a fact Nexus can
/// state, "GitHub refused to answer" is not, and the two must never render as
/// the same sentence.
class UpdateCheck {
  final UpdateInfo? info;

  /// Why the check could not be made, in the user's terms. Null when it could.
  final String? failure;

  const UpdateCheck(this.info, {this.failure});

  /// The check ran and there is nothing newer to install.
  static const UpdateCheck upToDate = UpdateCheck(null);

  bool get failed => failure != null;
}

/// What came of handing an update to the platform.
enum UpdateApply {
  /// Linux: unpacked, swapped in and relaunched.
  applied,

  /// Android: the system installer is open — the user confirms the install
  /// there, and the app is replaced when they do.
  installerOpened,

  /// Android: this app may not install packages yet. The platform has opened
  /// the settings screen that grants it and is holding the downloaded file, so
  /// the install resumes by itself on return — the user just needs to be told
  /// what that screen was for.
  needsPermission,

  /// Nothing was handed over: say so and name the manual path.
  failed,
}

/// What the hand-off needs the user to know, or null when it needs no words.
///
/// One owner for these sentences: the phone's update path is the one a user
/// actually walks, and "nothing was said at all" was what made it look broken.
String? updateHandoffNote(UpdateApply outcome) => switch (outcome) {
      UpdateApply.applied || UpdateApply.failed => null,
      UpdateApply.installerOpened =>
        'The Android installer is open — confirm the install there.',
      UpdateApply.needsPermission =>
        'Allow Nexus to install this update on the screen that just opened — '
            'the install continues by itself when you come back.',
    };

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

  static String _latestReleaseUrl(String owner, String repo) =>
      'https://api.github.com/repos/$owner/$repo/releases/latest';

  static Future<UpdateCheck> checkForUpdate({
    required String currentVersion,
    String owner = 'TVcraft01',
    String repo = 'Nexus',
    Future<UpdateResponse> Function(String url)? fetch,
  }) async {
    final assetName = _assetName;
    if (assetName == null) {
      return const UpdateCheck(
        null,
        failure: 'no Nexus build is published for this platform',
      );
    }

    final fetcher = fetch ?? _httpGet;
    final UpdateResponse response;
    try {
      response = await fetcher(_latestReleaseUrl(owner, repo));
    } catch (e) {
      debugPrint('NEXUS updater: check failed (${e.runtimeType})');
      return const UpdateCheck(
        null,
        failure: 'the network could not reach GitHub',
      );
    }
    if (response.status != 200) {
      final failure = _reasonFor(response.status);
      debugPrint('NEXUS updater: check failed — $failure');
      return UpdateCheck(null, failure: failure);
    }

    Map<String, dynamic>? json;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) json = decoded;
    } catch (_) {
      json = null;
    }
    final tag = json?['tag_name'];
    if (tag is! String) {
      return const UpdateCheck(
        null,
        failure: 'GitHub answered something Nexus could not read',
      );
    }

    final version = tag.replaceFirst(RegExp(r'^v'), '');
    if (compareVersions(version, currentVersion) <= 0) {
      return UpdateCheck.upToDate;
    }

    final downloadUrl = _assetUrl(json!, assetName);
    if (downloadUrl == null) {
      final failure = 'v$version is published without a $assetName build';
      debugPrint('NEXUS updater: $failure');
      return UpdateCheck(null, failure: failure);
    }

    debugPrint('NEXUS updater: update available v$version');
    return UpdateCheck(UpdateInfo(
      version: version,
      downloadUrl: downloadUrl,
      releaseUrl: json['html_url'] as String?,
    ));
  }

  /// Why a non-200 answer happened, in the user's terms.
  ///
  /// GitHub rate-limits by network, not by client, so a 403 on a phone is a
  /// whole carrier IP being throttled — the answer a user most needs to hear,
  /// and the one that must never be softened into "up to date".
  static String _reasonFor(int status) {
    if (status == 403 || status == 429) {
      return 'GitHub is rate-limiting this network — try again in a few minutes';
    }
    if (status == 404) return 'no Nexus release is published yet';
    return 'GitHub answered $status';
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
    Future<UpdateResponse> Function(String url)? fetch,
  }) async {
    final fetcher = fetch ?? _httpGet;
    try {
      final response = await fetcher(_latestReleaseUrl(owner, repo));
      if (response.status != 200) return null;
      final json = jsonDecode(response.body);
      if (json is! Map<String, dynamic>) return null;
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

  /// Hands [archivePath] to the platform.
  ///
  /// The three Android answers are deliberately distinct. `permission` means
  /// Android opened the "install unknown apps" screen and kept the file: the
  /// install resumes by itself on return, so it is not a failure — and it is
  /// not a silent success either, which is what a bool turned it into.
  static Future<UpdateApply> applyUpdate(
    String archivePath, {
    String? installDir,
  }) async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        final status = await _androidChannel.invokeMethod<String>('installApk', {
          'path': archivePath,
        });
        debugPrint('NEXUS updater: Android installer status: $status');
        return switch (status) {
          'launched' => UpdateApply.installerOpened,
          'permission' => UpdateApply.needsPermission,
          _ => UpdateApply.failed,
        };
      } catch (e) {
        debugPrint('NEXUS updater: Android install failed: $e');
        return UpdateApply.failed;
      }
    }

    if (defaultTargetPlatform != TargetPlatform.linux || installDir == null) {
      return UpdateApply.failed;
    }
    if (!await extractAndSwap(archivePath, installDir)) {
      return UpdateApply.failed;
    }
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
    return UpdateApply.applied;
  }

  /// [run] unpacks the archive. The product leaves it null and uses the system
  /// runner; a test passes one so the suite never shells out to `tar`.
  static Future<bool> extractAndSwap(
    String archivePath,
    String installDir, {
    CommandRunner? run,
  }) async {
    final tmp = Directory('$installDir.new');
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    tmp.createSync(recursive: true);

    final extract = await (run ?? systemCommandRunner)('tar', [
      '-xzf',
      archivePath,
      '-C',
      tmp.path,
    ]);
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

  static Future<UpdateResponse> _httpGet(String url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.userAgentHeader, 'nexus-updater/1');
      final response = await request.close();
      // The body is read either way: an error status still carries GitHub's
      // own explanation, and the caller decides what the status means.
      return UpdateResponse(
        response.statusCode,
        await response.transform(utf8.decoder).join(),
      );
    } finally {
      client.close();
    }
  }
}
