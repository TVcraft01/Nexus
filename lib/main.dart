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

  // Only one desktop instance at a time: closing the window hides to the
  // tray, so relaunching the app must bring that window back — not start a
  // second process that grabs an ephemeral port and adds a second tray icon.
  // Skipped when NEXUS_DATA_DIR is set (deliberate second instance).
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

  // Linux: set up system tray so the app stays alive when the window is
  // closed — the mesh keeps running, clipboard sync works, and paired
  // devices can still reach this machine.
  if (defaultTargetPlatform == TargetPlatform.linux) {
    await _initSystemTray();
  }

  runApp(NexusApp(mesh: mesh));
}

/// The localhost port the first instance binds. A second launch tries to
/// connect to it; if something answers, that something is the running app,
/// so the second process signals it to show its window and exits. Kept free
/// of the mesh (51820), discovery (51822) and gateway (51823) ports.
const int _singletonPort = 51824;

/// Returns true if this process is (now) the single instance. When another
/// instance is already running, tells it to bring its window to the front
/// and returns false — the caller should exit.
Future<bool> _ensureSingleInstance() async {
  // Can we reach a running instance? Then signal it and go away.
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
  } catch (_) {
    // Nothing listening — try to become the singleton.
  }
  try {
    final server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      _singletonPort,
    );
    server.listen((socket) {
      socket.listen(
        (_) {
          // A second launch asked us to appear — show and focus the window
          // even if it is already visible but sitting behind other windows.
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
    // Lost the race between connect and bind — someone else is the instance.
    return false;
  }
}

/// Sets up the system tray icon with Show / Quit menu.
Future<void> _initSystemTray() async {
  final tray = TrayManager.instance;
  await tray.setIcon('assets/tray_icon.png');
  await tray.setToolTip('Nexus — your devices, one system');

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

/// Set the moment the user picks "Quit". Guards [onWindowClose] so a real
/// quit is never turned back into a hide-to-tray.
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
  // Drop the tray icon, stop intercepting the window close, then close the
  // window for real. destroy() fires the close event — onWindowClose sees the
  // flag and lets it through instead of hiding to tray. exit(0) is the final
  // word if the close path ever stalls.
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

  @override
  void onTrayIconRightMouseDown() {
    // Right-click shows the context menu (handled by tray_manager).
  }
}

class NexusApp extends StatefulWidget {
  final MeshService mesh;
  const NexusApp({super.key, required this.mesh});

  @override
  State<NexusApp> createState() => _NexusAppState();
}

class _NexusAppState extends State<NexusApp> with WindowListener {
  @override
  void initState() {
    super.initState();
    if (defaultTargetPlatform == TargetPlatform.linux) {
      windowManager.addListener(this);
      windowManager.setPreventClose(true);
    }
  }

  @override
  void dispose() {
    if (defaultTargetPlatform == TargetPlatform.linux) {
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  @override
  void onWindowClose() {
    // A real quit (tray → Quit) must close, not hide to tray.
    if (_quitting) return;
    // Hide to tray instead of quitting — the mesh stays alive.
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
