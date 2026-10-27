// The launched path's action runner.
//
// Until this existed, `DeviceExecutor` — the one class that does something on
// this device — was constructed only by the legacy assistant view, which the
// shipped entry point does not build. A peer-initiated request therefore had no
// runner at all on the launched path, and a pass that wired the receiving half
// without this would have "worked" in a test and done nothing in the app.
//
// Two shells are tested, because the interesting difference is the one without
// services: a widget test must not construct platform backends it cannot run.
import 'dart:io' show Directory;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent_contract.dart';
import 'package:nexus/core/app_services.dart';
import 'package:nexus/core/device_actions.dart';
import 'package:nexus/core/paired_devices.dart';
import 'package:nexus/main_ui.dart' show DevicesTab, NexusTheme, launchedExecutor;

/// Records what the executor asked the platform to do, so "the request ran" is
/// an observation rather than a return value the executor could fake.
class _RecordingBackend implements DeviceActionBackend {
  final List<(String action, Map<String, dynamic> args)> calls =
      <(String, Map<String, dynamic>)>[];

  @override
  Future<ActionResult> run(String action, Map<String, dynamic> args) async {
    calls.add((action, args));
    return ActionResult(true, 'ran $action');
  }

  @override
  Future<(double, double)?> currentLocation() async => null;

  @override
  Future<bool> openLinkChooser(String url, String title) async => false;
}

void main() {
  late Directory tmp;
  late AppServices services;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('nexus-launched-exec-');
    services = await startAppServices(dataDir: tmp.path);
    addTearDown(() async {
      await stopAppServices(services);
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
  });

  test('a shell with no services has no executor, and does not build one', () {
    // The seam itself: null in, null out. A widget test that built the shell on
    // its own must not reach for platform backends it cannot run.
    expect(launchedExecutor(null), isNull);
  });

  test('a launched shell builds one, and a request runs on it', () async {
    final _RecordingBackend backend = _RecordingBackend();
    final executor = launchedExecutor(services, deviceBackend: backend);

    expect(executor, isNotNull);

    final AgentRequest request = AgentRequest(
      requestId: 'launched-1',
      target: services.identity.id,
      action: AgentActions.flashlightToggle,
      arguments: const <String, dynamic>{'state': 'on'},
    );
    final ActionResult outcome = await executor!.run(request);
    expect(outcome.ok, isTrue, reason: outcome.message);

    // The action reached the platform backend — the whole point of the seam.
    expect(
      backend.calls.map(((String, Map<String, dynamic>) c) => c.$1),
      contains(AgentActions.flashlightToggle),
    );
  });

  testWidgets('the Devices tab is handed the executor the shell owns', (
    tester,
  ) async {
    final _RecordingBackend backend = _RecordingBackend();
    final executor = launchedExecutor(services, deviceBackend: backend);

    // A shell with no services: the tab is present, and honest about having
    // nothing to run a peer's request with.
    await tester.pumpWidget(
      MaterialApp(
        theme: NexusTheme.light(),
        home: const Scaffold(body: DevicesTab()),
      ),
    );
    expect(tester.widget<DevicesTab>(find.byType(DevicesTab)).executor, isNull);

    // The launched shell: one mesh, one executor, and the tab holds *that*
    // instance rather than reaching for one of its own.
    PairedDevices.override = PairedDevices.new;
    addTearDown(() => PairedDevices.override = null);
    await tester.pumpWidget(
      MaterialApp(
        theme: NexusTheme.light(),
        home: Scaffold(
          body: DevicesTab(mesh: services.mesh, executor: executor),
        ),
      ),
    );
    await tester.pump();

    expect(
      identical(
        tester.widget<DevicesTab>(find.byType(DevicesTab)).executor,
        executor,
      ),
      isTrue,
    );
  });
}
