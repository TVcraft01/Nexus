import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show
        DeviceOrientation,
        MethodChannel,
        SystemChrome,
        SystemUiOverlayStyle;
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'core/app_services.dart';
import 'core/cable_pairing.dart';
import 'core/llm.dart';
import 'core/services/icon_service.dart';
import 'mesh/gateway.dart';
import 'mesh/mesh_lifecycle.dart';
import 'mesh/mesh_service.dart';
import 'ui/components/nexus_ui.dart' show NexusCupertinoTheme, NexusTextScaling;
import 'ui/home_shell.dart';
import 'ui/theme.dart';

/// Warm-start cable provisioning: MainActivity forwards every incoming
/// `nexus://pair` intent here (see onNewIntent), so an already-running Nexus
/// completes the automatic pairing handshake exactly like a cold start.
/// The payload is validated strictly by CablePairing before anything fires.
const _provisionChannel = MethodChannel('dev.nexus.nexus/provisioning');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Which launcher icon Nexus wears is a manifest component on Android, so the
  // stored choice is settled once the engine is up — on every start, and again
  // whenever the system theme changes while the app is open. Not awaited: the
  // first frame must not wait on a preference read, and the service reports its
  // own failures rather than the launch path's.
  unawaited(IconService.instance.attach());

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

  // The same start the launched shell uses — one store, one identity, one
  // mesh, and the identity installed into `PairIdentity` so a QR shown from
  // either entry point names the same device.
  final AppServices services = await startAppServices(dataDir: dataDir);
  final store = services.store;
  final mesh = services.mesh;

  // A PC that has just provisioned this Android device launches Nexus with a
  // one-time pairing URI. Pair immediately so the user never has to copy a
  // code or type 127.0.0.1/port by hand. On a cold start the link arrives as
  // the launch route; while the app is already running it arrives through
  // MainActivity.onNewIntent below. Both paths share the same strict parser
  // and handshake, so provisioning completes however the app was started.
  final pairing = CablePairing.parseProvisioningUri(
    WidgetsBinding.instance.platformDispatcher.defaultRouteName,
  );
  if (pairing != null) {
    await CablePairing.attemptAutoPair(mesh, pairing);
  }

  _provisionChannel.setMethodCallHandler((call) async {
    if (call.method == 'pairPayload' && call.arguments is String) {
      final payload =
          CablePairing.parseProvisioningUri(call.arguments as String);
      if (payload != null) {
        await CablePairing.attemptAutoPair(mesh, payload);
      }
    }
    return null;
  });

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

  // The model that runs inside Nexus — built at the one point every launch
  // passes through, and warmed up in the background on purpose: a first
  // launch has a model file to fetch (470 MB, about 1 GiB on a desktop), and
  // that must happen while the user is doing something else, never while they
  // are waiting for an answer. Best effort throughout: a machine that cannot
  // fetch or run a model keeps working exactly as it did without one.
  final llm = Llm.forThisDevice();
  unawaited(llm.warmUp());

  runApp(NexusApp(mesh: mesh, llm: llm));
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
  /// The in-app model, built in `main` so the first launch starts fetching it
  /// before the first frame. Null builds one on demand — a test that never
  /// asks it anything pays nothing for that.
  final Llm? llm;
  final MeshService mesh;
  const NexusApp({super.key, required this.mesh, this.llm});

  @override
  State<NexusApp> createState() => _NexusAppState();
}

class _NexusAppState extends State<NexusApp> with WindowListener {
  late final MeshLifecycleObserver _meshLifecycle;

  @override
  void initState() {
    super.initState();
    if (defaultTargetPlatform == TargetPlatform.linux) {
      windowManager.addListener(this);
      windowManager.setPreventClose(true);
    }
    // Owns the mesh's socket lifetime: on engine detach (Activity
    // recreation in the same process) the old listener must go away, or the
    // new engine misses the canonical port and peers keep a stale route.
    _meshLifecycle = MeshLifecycleObserver(widget.mesh);
    WidgetsBinding.instance.addObserver(_meshLifecycle);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(_meshLifecycle);
    // The engine is going away with this widget: release the listener so a
    // recreated engine in this process reclaims 51820. (Desktop quit exits
    // the process, which releases sockets by itself; a hidden window keeps
    // the mesh intentionally, so this must not run on window hide.)
    unawaited(widget.mesh.stop());
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
      // The Cupertino widgets the app now builds (the tab bar, a pushed
      // page's navigation bar, a sheet, an iOS alert, the switches) read
      // their colours from a CupertinoTheme whose default is *light*. The
      // builder sits above the navigator, so every route inherits the app's
      // own dark theme instead of a black title on a black page.
      // Text follows the phone's text-size setting, clamped to the range the
      // layouts are built for (NexusType.minScale–maxScale); both wrappers sit
      // above the navigator so every route inherits them.
      builder: (context, child) => NexusTextScaling(
        child: NexusCupertinoTheme(child: child ?? const SizedBox.shrink()),
      ),
      home: HomeShell(mesh: widget.mesh, llm: widget.llm),
    );
  }
}
