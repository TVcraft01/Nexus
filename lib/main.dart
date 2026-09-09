import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show DeviceOrientation, SystemChrome, SystemUiOverlayStyle;
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

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

/// Android cable provisioning arrives as a `nexus://pair?...` initial route.
/// Keep this parser small and strict: it is only a transport for the existing
/// pairing code, never a long-lived credential.
Map<String, String>? _initialPairingPayload() {
  if (defaultTargetPlatform != TargetPlatform.android) return null;
  final route = WidgetsBinding.instance.platformDispatcher.defaultRouteName;
  if (!route.startsWith('nexus://pair')) return null;
  try {
    final uri = Uri.parse(route);
    if (uri.host != 'pair') return null;
    final address = uri.queryParameters['address'];
    final port = uri.queryParameters['port'];
    final code = uri.queryParameters['code'];
    final expires = int.tryParse(uri.queryParameters['expires'] ?? '');
    if (address == null || port == null || code == null || expires == null) {
      return null;
    }
    if (DateTime.now().millisecondsSinceEpoch > expires) return null;
    if (int.tryParse(port) == null || code.length < 4) return null;
    return {'address': address, 'port': port, 'code': code};
  } catch (_) {
    return null;
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS) {
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  }

  final dataDir = Platform.environment['NEXUS_DATA_DIR'];

  if (defaultTargetPlatform == TargetPlatform.linux && dataDir == null) {
    if (!await _ensureSingleInstance()) {
      debugPrint('NEXUS: another instance is already running — showing it.');
      exit(0);
    }
  }

  final store = NexusStore(
    explicitPath: dataDir == null
        ? null
        : '$dataDir${Platform.pathSeparator}state.json',
  );
  await store.load();

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

  // A PC that has just provisioned this Android device launches Nexus with a
  // one-time pairing URI. Pair immediately so the user never has to copy a
  // code or type 127.0.0.1/port by hand.
  final pairing = _initialPairingPayload();
  if (pairing != null) {
    final result = await mesh.pairWith(
      address: pairing['address']!,
      port: int.parse(pairing['port']!),
      code: pairing['code']!,
    );
    debugPrint(
      result.ok
          ? 'NEXUS cable: automatic pairing succeeded'
          : 'NEXUS cable: automatic pairing failed: ${result.error}',
    );
  }

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
        continue;
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

  if (defaultTargetPlatform == TargetPlatform.linux) {
    await _initSystemTray();
  }

  runApp(NexusApp(mesh: mesh));
}

const int _singletonPort = 51824;

Future<bool> _ensureSingleInstance() async {
  try {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      _singletonPort,
      timeout: const Duration(milliseconds: 400),
    );
    socket.add(utf8.encode('show\n'));
    await socket.flush();
    socket.destroy();
    return false;
  } catch (_) {}
  try {
    final server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      _singletonPort,
    );
    server.listen((socket) {
      socket.listen(
        (_) {
          windowManager.show();
          windowManager.focus();
          _windowHidden = false;
          socket.destroy();
        },
        onDone: () => socket.destroy(),
        onError: (_) => socket.destroy(),
      );
    });
    return true;
  } catch (_) {
    return false;
  }
}

Future<void> _initSystemTray() async {
  final tray = TrayManager.instance;
  await tray.setIcon('assets/tray_icon.png');
  try {
    await tray.setToolTip('Nexus — your devices, one system');
  } catch (_) {}

  final menu = Menu(
    items: [
      MenuItem(label: 'Show Nexus', onClick: (_) => _showWindow()),
      MenuItem.separator(),
      MenuItem(label: 'Quit', onClick: (_) => _quitApp()),
    ],
  );
  await tray.setContextMenu(menu);
  tray.addListener(_TrayListener());
}

final windowManager = WindowManager.instance;
bool _windowHidden = false;
bool _quitting = false;

void _showWindow() {
  if (_windowHidden) {
    windowManager.show();
    windowManager.focus();
    _windowHidden = false;
  }
}

Future<void> _quitApp() async {
  _quitting = true;
  await TrayManager.instance.destroy();
  await windowManager.setPreventClose(false);
  await windowManager.destroy();
  exit(0);
}

class _TrayListener extends TrayListener {
  @override
  void onTrayIconMouseDown() {
    _showWindow();
  }
}

class NexusApp extends StatefulWidget {
  final MeshService mesh;
  const NexusApp({super.key, required this.mesh});

  @override
  State<NexusApp> createState() => _NexusAppState();
}

class _NexusAppState extends State<NexusApp> with WindowListener {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    if (defaultTargetPlatform == TargetPlatform.linux) {
      windowManager.addListener(this);
      windowManager.setPreventClose(true);
    }
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) =>
          widget.mesh.setForeground(state == AppLifecycleState.resumed),
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    if (defaultTargetPlatform == TargetPlatform.linux) {
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  @override
  void onWindowClose() {
    if (_quitting) return;
    windowManager.hide();
    _windowHidden = true;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nexus',
      debugShowCheckedModeBanner: false,
      theme: buildNexusTheme(),
      home: HomeShell(mesh: widget.mesh),
    );
  }
}
