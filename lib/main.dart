import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show DeviceOrientation, SystemChrome, SystemUiOverlayStyle;

import 'core/identity.dart';
import 'core/store.dart';
import 'mesh/gateway.dart';
import 'mesh/mesh_service.dart';
import 'ui/home_shell.dart';
import 'ui/theme.dart';

String _platformName(TargetPlatform platform) {
  switch (platform) {
    case TargetPlatform.android:
      return 'android';
    case TargetPlatform.linux:
      return 'linux';
    case TargetPlatform.windows:
      return 'windows';
    case TargetPlatform.macOS:
      return 'macos';
    case TargetPlatform.iOS:
      return 'ios';
    default:
      return 'other';
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Phones stay portrait: the app has no landscape content (no video, no
  // wide tables), so rotation only fights the user. Desktops stay free.
  if (defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS) {
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  }

  // NEXUS_DATA_DIR lets you run a second instance with its own identity
  // (e.g. two copies of the app on one computer to test the mesh).
  final dataDir = Platform.environment['NEXUS_DATA_DIR'];
  final store = NexusStore(
    explicitPath: dataDir == null
        ? null
        : '$dataDir${Platform.pathSeparator}state.json',
  );
  await store.load();

  // First run: create a stable identity for this device.
  var identity = store.identity;
  if (identity.id == 'unknown') {
    final platform = _platformName(defaultTargetPlatform);
    identity = DeviceInfo(
      id: generateDeviceId(),
      name: defaultDeviceName(platform),
      platform: platform,
    );
    store.setIdentity(identity);
    await store.save();
  }

  final mesh = MeshService(identity: identity, store: store);
  await mesh.start();

  // Linux: expose the mesh to the file manager via a localhost gateway that
  // tools/nexusfs.py mounts as folders ("Nexus Devices" in Nemo). The token
  // is persisted so a running mount survives an app restart; the daemon reads
  // it from the store at mount time.
  if (defaultTargetPlatform == TargetPlatform.linux) {
    final token = store.gatewayToken ?? MeshGateway.newToken();
    store.gatewayToken = token;
    await store.save();
    for (var port = store.gatewayPort; port < store.gatewayPort + 5; port++) {
      try {
        final gateway = MeshGateway(mesh: mesh, token: token, port: port);
        await gateway.start();
        store.gatewayPort = port;
        await store.save();
        debugPrint('NEXUS gateway: listening on 127.0.0.1:$port');
        break;
      } on SocketException {
        continue; // port busy (another instance?) — try the next one
      }
    }
  }

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: NexusColors.bg,
      systemNavigationBarColor: NexusColors.surface,
      systemNavigationBarDividerColor: NexusColors.surface,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarIconBrightness: Brightness.light,
      systemNavigationBarContrastEnforced: false,
    ),
  );
  runApp(NexusApp(mesh: mesh));
}

class NexusApp extends StatelessWidget {
  final MeshService mesh;
  const NexusApp({super.key, required this.mesh});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nexus',
      debugShowCheckedModeBanner: false,
      theme: buildNexusTheme(),
      home: HomeShell(mesh: mesh),
    );
  }
}
