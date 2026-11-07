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
    show TargetPlatform, debugPrint, defaultTargetPlatform;

import '../mesh/mesh_service.dart';
import 'agent/agent_dashboard.dart';
import 'agent/agent_records.dart' show AgentDefinition;
import 'agent/agent_runner.dart';
import 'agent/agent_service.dart';
import 'agent/agent_store.dart';
import 'agent/agent_tools.dart';
import 'agent/executor.dart';
import 'agent/kill_switch.dart';
import 'agent/ollama_backend.dart';
import 'agent/plan_validator.dart';
import 'agent/planner.dart';
import 'agent/registry.dart';
import 'agent/run_log.dart';
import 'agent/tools/detached_runner.dart';
import 'agent/tools/revert_guard.dart';
import 'agent/undo.dart';
import 'text_generation_backend.dart';
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
    this.agents,
    this.agentService,
    this.dashboard,
  });

  final NexusStore store;
  final DeviceInfo identity;
  final MeshService mesh;

  /// Agent definitions and the opt-in usage log, on this device's disk.
  final AgentStore? agents;

  /// The background service that starts, pauses and runs agents on schedule.
  final AgentService? agentService;

  /// The local-only dashboard for those agents, when this platform serves one.
  final AgentDashboard? dashboard;
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
  AgentRunner? agentRunner,
  TextGenerationBackend? agentBackend,
  ToolRegistry? agentTools,
  bool? startAgentDashboard,
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

  // Agent definitions are data, so they are read before anything can run: a
  // launch that restored no agents would show an empty dashboard and quietly
  // forget everything the user already made.
  final AgentStore agents = AgentStore(
    explicitPath: dataDir == null
        ? null
        : '$dataDir${Platform.pathSeparator}agents.json',
  );
  await agents.load();

  // The audit log is not the usage log: it records what agents did and why,
  // on by default, and it never feeds the working-hours offer.
  final RunLog runLog = RunLog(
    explicitPath: dataDir == null
        ? null
        : '$dataDir${Platform.pathSeparator}agent-runs.jsonl',
  );
  await runLog.load();

  // One switch, shared by the service and the executor, so "halt all" reaches
  // a run that is already walking its steps.
  final KillSwitch halt = KillSwitch();

  final UndoJournal undo = UndoJournal();

  AgentRunner runner;
  if (agentRunner != null) {
    runner = agentRunner;
  } else if (agentBackend != null ||
      agentTools != null ||
      _wiresRealAgents()) {
    // The desktop path: the installed Ollama model plans and the real network
    // tools run. On a phone neither is built unless a caller states one — a
    // phone has no Ollama here, and its honest answer is that it has no model
    // rather than a run that fails on every tick.
    final ToolRegistry tools =
        agentTools ??
        realAgentTools(
          guard: RevertGuard(
            runner: const SystemDetachedRunner(),
            stateDir: await agentRevertStateDir(dataDir),
          ),
        );
    final TextGenerationBackend backend = agentBackend ?? OllamaBackend();
    runner = PlannedAgentRunner(
      planner: Planner(backend: backend, registry: tools),
      validator: PlanValidator(tools),
      executor: Executor(registry: tools, killSwitch: halt),
      runLog: runLog,
      killSwitch: halt,
      undo: undo,
    ).call;
    debugPrint(
      'NEXUS agents: real runs via the planner, ${tools.names.length} tools',
    );
  } else {
    // No model and no tool set are wired into this build, so the honest answer
    // is that nothing ran — not a run that pretends to have planned.
    runner = _nothingToRunYet;
  }
  final AgentService agentService = AgentService(
    store: agents,
    runner: runner,
    halt: halt,
    undo: undo,
    runLog: runLog,
  );

  AgentDashboard? dashboard;
  if (startAgentDashboard ?? _servesDashboard()) {
    final AgentDashboard candidate = AgentDashboard(service: agentService);
    try {
      final String url = await candidate.start();
      dashboard = candidate;
      // The URL carries a per-launch key, so it can only be read here; the
      // developer log is where the user finds it.
      debugPrint('NEXUS agents dashboard: $url');
    } catch (error) {
      // A port that is taken is not worth the launch: the agents still run.
      debugPrint('NEXUS agents: dashboard not started: $error');
    }
  }
  agentService.startTicking();

  return AppServices(
    store: store,
    identity: identity,
    mesh: mesh,
    agents: agents,
    agentService: agentService,
    dashboard: dashboard,
  );
}

/// Whether this launch plans agent runs for real: a desktop, never a phone (no
/// Ollama there), and never a test run.
bool _wiresRealAgents() {
  if ((Platform.environment['FLUTTER_TEST'] ?? 'false') != 'false') {
    return false;
  }
  return switch (defaultTargetPlatform) {
    TargetPlatform.linux ||
    TargetPlatform.macOS ||
    TargetPlatform.windows => true,
    _ => false,
  };
}

/// Whether this launch serves the agents dashboard. A desktop, never a phone —
/// the dashboard is a page for the PC Nexus runs on — and never a test run.
bool _servesDashboard() {
  if ((Platform.environment['FLUTTER_TEST'] ?? 'false') != 'false') {
    return false;
  }
  return switch (defaultTargetPlatform) {
    TargetPlatform.linux ||
    TargetPlatform.macOS ||
    TargetPlatform.windows => true,
    _ => false,
  };
}

/// What a run does until a model and a tool set are wired in: it says plainly
/// that it had nothing to do, rather than reporting work it did not do.
Future<AgentOutcome> _nothingToRunYet(AgentDefinition agent) async =>
    AgentOutcome(
      'nothing ran: no language model and tool set are wired into this build '
      'yet, so the run for “${agent.goal}” had nothing it could plan with',
      ok: false,
    );

/// Stops the dashboard, the agents' timer, and the mesh — and with it the
/// Android foreground service and the listening socket on 51820 — and leaves
/// the process able to start again.
Future<void> stopAppServices(AppServices services) async {
  await services.dashboard?.stop();
  await services.agentService?.dispose();
  await services.mesh.stop();
}

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
