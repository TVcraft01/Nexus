/// The services the app starts before it draws its first frame.
///
/// One place that answers three questions the shell used to answer in pieces:
/// who this device is, where its state lives, and what the mesh is listening
/// on. `lib/main.dart` → `main_ui.main()` and the preserved `main_old.dart`
/// both call [startAppServices], so a process has one identity, one store and
/// one mesh rather than two answers that drift apart.
///
/// The order below is the whole point of the file:
///
///   1. the store is loaded, so an id the device already has is read rather
///      than replaced;
///   2. an identity is created and saved only when the store has none;
///   3. it is installed into [PairIdentity], so the QR, the discovery
///      announcements and the file link all speak the same id;
///   4. the mesh starts — and binds TCP 51820 — *before* the file link, which
///      is what makes the file link take 51821 on a new build and 51820 on a
///      build where nothing is on 51820 (see `FileTransferService.start`).
library;

import 'dart:io' show File, Platform;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;

import '../mesh/mesh_service.dart';
import 'capability_probe.dart' show CapabilityProbe;
import 'identity.dart';
import 'pair_invite.dart' show PairIdentity;
import 'store.dart';

/// Everything a launched Nexus owns for as long as it runs.
///
/// Passed down by constructor rather than reached through a static: the mesh
/// needs an identity and a store, and a process-scoped singleton of a class
/// with required constructor arguments is exactly the kind of "it is always
/// there" that a test cannot state.
class AppServices {
  AppServices({
    required this.store,
    required this.identity,
    required this.mesh,
  });

  final NexusStore store;
  final DeviceInfo identity;
  final MeshService mesh;
}

/// This platform, spelled the way [DeviceInfo] and the mesh spell it.
///
/// `TargetPlatform.name` is right for most of them and wrong for two — the
/// same correction `defaultPairPlatformToken` makes for the pairing code, so a
/// device is described the same way by the store, the mesh and the QR.
String appPlatformToken([TargetPlatform? platform]) =>
    switch (platform ?? defaultTargetPlatform) {
      TargetPlatform.android => 'android',
      TargetPlatform.iOS => 'ios',
      TargetPlatform.macOS => 'macos',
      TargetPlatform.windows => 'windows',
      TargetPlatform.linux => 'linux',
      _ => 'other',
    };

/// Loads the device's state, settles its identity, and starts the mesh.
///
/// [dataDir] is a test seam: a directory to keep `state.json` in instead of the
/// platform's app-support folder. [clipboard] and [capabilityProbe] are passed
/// through to the mesh for the same reason the mesh accepts them — a test that
/// cannot run a platform channel or a hardware probe states one instead.
Future<AppServices> startAppServices({
  String? dataDir,
  ClipboardBackend? clipboard,
  CapabilityProbe? capabilityProbe,
}) async {
  final NexusStore store = NexusStore(
    explicitPath: dataDir == null
        ? null
        : '$dataDir${Platform.pathSeparator}state.json',
  );
  await store.load();

  DeviceInfo identity = store.identity;
  if (identity.id.isEmpty || identity.id == 'unknown') {
    final String platform = appPlatformToken();
    identity = DeviceInfo(
      id: generateDeviceId(),
      name: defaultDeviceName(platform),
      platform: platform,
    );
    store.setIdentity(identity);
    await store.save();
  }

  // Every surface that names this device reads this one id from here on.
  // Below `PairIdentity.override`, so a test that states who it is still wins.
  PairIdentity.install(identity);

  final MeshService mesh = MeshService(
    identity: identity,
    store: store,
    clipboard: clipboard ?? devClipboardFromEnvironment(),
    capabilityProbe: capabilityProbe,
  );
  await mesh.start();
  return AppServices(store: store, identity: identity, mesh: mesh);
}

/// Stops the mesh — and with it the Android foreground service and the
/// listening socket on 51820 — and leaves the process able to start again.
Future<void> stopAppServices(AppServices services) => services.mesh.stop();

/// A clipboard kept in a file, turned on only by `NEXUS_CLIPBOARD_FILE=<path>`.
///
/// Two windows on one desk share one OS clipboard, which makes a clipboard that
/// travels between them impossible to watch: copying in one is copying in both,
/// and an echo looks exactly like a delivery. A file per instance is the seam
/// [ClipboardBackend] was left for. Unset — the ordinary case — returns null and
/// the mesh keeps the platform clipboard it always had.
ClipboardBackend? devClipboardFromEnvironment() {
  final String path = (Platform.environment['NEXUS_CLIPBOARD_FILE'] ?? '')
      .trim();
  if (path.isEmpty) return null;
  return _FileClipboard(path);
}

/// One text file standing in for the system clipboard. Missing or empty reads
/// as "nothing was copied", which is what the real one answers too.
class _FileClipboard implements ClipboardBackend {
  _FileClipboard(this.path);

  final String path;

  @override
  Future<String?> readText() async {
    try {
      final File file = File(path);
      if (!await file.exists()) return null;
      final String text = (await file.readAsString()).trim();
      return text.isEmpty ? null : text;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> writeText(String text) async {
    final File file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(text, flush: true);
  }
}
