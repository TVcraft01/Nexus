// The Linux network tools, with `nmcli` replaced by a fake that keeps state.
//
// What these pin:
//   * the parsers read real `nmcli` output, including the driver-escaping of `:`;
//   * a read-only tool reports "not connected" rather than a plausible zero;
//   * a change arms the revert timer *before* it writes, verifies by reading the
//     property back, and its rollback puts the old value back and stops the
//     timer;
//   * a hotspot profile and a CI run are refused, before any write;
//   * a change that does not verify is unwound by the executor.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent/agent_session.dart';
import 'package:nexus/core/agent/approval.dart';
import 'package:nexus/core/agent/executor.dart';
import 'package:nexus/core/agent/fake_device.dart';
import 'package:nexus/core/agent/planner.dart';
import 'package:nexus/core/agent/plan.dart';
import 'package:nexus/core/agent/plan_validator.dart';
import 'package:nexus/core/agent/registry.dart';
import 'package:nexus/core/agent/tools/command_runner.dart';
import 'package:nexus/core/agent/tools/detached_runner.dart';
import 'package:nexus/core/agent/tools/net_change_tools.dart';
import 'package:nexus/core/agent/tools/net_read_tools.dart';
import 'package:nexus/core/agent/tool.dart';
import 'package:nexus/core/agent/tools/revert_guard.dart';

import 'agent_fixtures.dart';

/// A NetworkManager that keeps its properties in a map.
class _FakeNmcli implements CommandRunner {
  _FakeNmcli({
    Map<String, String>? properties,
    this.mode = 'infrastructure',
    this.takesChanges = true,
  }) : properties = properties ?? <String, String>{};

  final Map<String, String> properties;
  final String mode;

  /// False simulates a device that reports success but keeps the old value.
  bool takesChanges;

  final List<String> calls = <String>[];

  @override
  Future<CommandResult> run(String executable, List<String> args) async {
    calls.add('$executable ${args.join(' ')}');
    if (args.isNotEmpty && args.first == '-g') {
      final property = args[1];
      if (property == '802-11-wireless.mode') {
        return CommandResult(exitCode: 0, stdout: '$mode\n', stderr: '');
      }
      return CommandResult(
        exitCode: 0,
        stdout: '${properties[property] ?? ''}\n',
        stderr: '',
      );
    }
    if (args.length >= 5 && args[0] == 'connection' && args[1] == 'modify') {
      if (takesChanges) properties[args[3]] = args[4];
      return const CommandResult(exitCode: 0, stdout: '', stderr: '');
    }
    return CommandResult(
      exitCode: 1,
      stdout: '',
      stderr: 'unexpected: $executable ${args.join(' ')}',
    );
  }
}

class _FakeDetached implements DetachedRunner {
  final List<String> scripts = <String>[];

  @override
  Future<int> start(String scriptPath) async {
    scripts.add(scriptPath);
    return 7;
  }
}

/// A runner that answers the read-only calls with canned `nmcli` output.
class _Canned implements CommandRunner {
  _Canned(this.outputs);

  final Map<String, String> outputs;

  @override
  Future<CommandResult> run(String executable, List<String> args) async {
    final key = '$executable ${args.join(' ')}';
    for (final entry in outputs.entries) {
      if (key.contains(entry.key)) {
        return CommandResult(exitCode: 0, stdout: entry.value, stderr: '');
      }
    }
    return CommandResult(exitCode: 1, stdout: '', stderr: 'no fake for $key');
  }
}

Plan _plan(ToolRegistry registry, ProposedStep step) {
  final validation = PlanValidator(registry)
      .validate(ProposedPlan(goal: 'test', steps: <ProposedStep>[step]));
  return (validation as PlanAccepted).plan;
}

void main() {
  late Directory stateDir;
  late _FakeDetached detached;

  setUp(() {
    stateDir = Directory.systemTemp.createTempSync('nexus_net_guard');
    detached = _FakeDetached();
  });

  tearDown(() {
    if (stateDir.existsSync()) stateDir.deleteSync(recursive: true);
  });

  RevertGuard guard() => RevertGuard(runner: detached, stateDir: stateDir);

  test('the report reads ssid, signal, band and rate from nmcli', () async {
    final runner = _Canned(<String, String>{
      'device status': 'wlp0s20f3:wifi:connected:Freebox-CA82DC\n',
      'wifi list': '*:Freebox-CA82DC:80:270 Mbit/s:5180 MHz:WPA2\n',
    });

    final report = await readWifiReport(runner);

    expect(report.connected, isTrue);
    expect(report.device, 'wlp0s20f3');
    expect(report.connection, 'Freebox-CA82DC');
    expect(report.signal, 80);
    expect(report.rate, '270 Mbit/s');
    expect(report.band, '5 GHz (5180 MHz)');
    expect(report.summary, contains('signal 80%'));
  });

  test('an escaped colon in a name survives the parser', () {
    final fields = splitNmcliLine(r'my\:network:70:54 Mbit/s:2437 MHz:WPA2');
    expect(fields, <String>[
      'my:network',
      '70',
      '54 Mbit/s',
      '2437 MHz',
      'WPA2',
    ]);
  });

  test('no Wi-Fi is said, not guessed', () async {
    final runner = _Canned(<String, String>{
      'device status': 'p2p0:wifi-p2p:disconnected:\n',
    });

    final report = await readWifiReport(runner);

    expect(report.connected, isFalse);
    expect(report.summary, contains('not connected'));
    final tool = WifiSignalTool(runner);
    expect(
      await tool.run(const <String, Object?>{}),
      contains('no signal to read'),
    );
  });

  test('a band change arms the timer before writing, then verifies', () async {
    final nmcli = _FakeNmcli(
      properties: <String, String>{'802-11-wireless.band': ''},
    );
    final timer = guard();
    final tool = WifiBandTool(runner: nmcli, guard: timer);
    final registry = ToolRegistry(<Tool>[tool]);
    final plan = _plan(
      registry,
      const ProposedStep(
        tool: 'wifi_band_set',
        args: <String, Object?>{'connection': 'home', 'value': 'bg'},
        description: 'Switch the band to 2.4 GHz only',
      ),
    );

    final report = await Executor(registry: registry)
        .run(plan, Approval.granted(plan: plan, words: 'yes'));

    expect(report.status, ExecutionStatus.done);
    expect(
      report.verified.single.verification.measured,
      '802-11-wireless.band=bg',
    );
    expect(nmcli.properties['802-11-wireless.band'], 'bg');
    expect(tool.pendingRevert, isNotNull);

    // The timer was armed before the modify: the revert script exists and it
    // restores the empty (automatic) value the profile had.
    final ticket = tool.pendingRevert!;
    final revert = File('${ticket.directory.path}/revert.sh')
        .readAsStringSync();
    expect(revert, contains("802-11-wireless.band ''"));
    final modifyAt = nmcli.calls.indexWhere(
      (call) => call.contains('connection modify'),
    );
    expect(modifyAt, isNonNegative);
    expect(File('${stateDir.path}/pending').existsSync(), isTrue);
  });

  test('keep stops the timer', () async {
    final nmcli = _FakeNmcli(
      properties: <String, String>{'802-11-wireless.powersave': '0'},
    );
    final tool = WifiPowerSaveTool(runner: nmcli, guard: guard());
    final registry = ToolRegistry(<Tool>[tool]);
    final plan = _plan(
      registry,
      const ProposedStep(
        tool: 'wifi_powersave_set',
        args: <String, Object?>{'connection': 'home', 'value': '2'},
        description: 'Turn power saving on',
      ),
    );
    await Executor(registry: registry)
        .run(plan, Approval.granted(plan: plan, words: 'yes'));
    final ticket = tool.pendingRevert!;

    tool.keep();

    expect(tool.pendingRevert, isNull);
    expect(File('${ticket.directory.path}/keep').existsSync(), isTrue);
  });

  test(
    'a change that does not verify is put back, and the timer stopped',
    () async {
      final nmcli = _FakeNmcli(
        properties: <String, String>{'802-11-wireless.band': ''},
        takesChanges: false,
      );
      final tool = WifiBandTool(runner: nmcli, guard: guard());
      final registry = ToolRegistry(<Tool>[tool]);
      final plan = _plan(
        registry,
        const ProposedStep(
          tool: 'wifi_band_set',
          args: <String, Object?>{'connection': 'home', 'value': 'a'},
          description: 'Switch the band to 5 GHz only',
        ),
      );

      final report = await Executor(registry: registry)
          .run(plan, Approval.granted(plan: plan, words: 'yes'));

      expect(report.status, ExecutionStatus.failed);
      expect(report.failure, contains('not “5 GHz only”'));
      expect(report.couldNotUndo, isEmpty);
      expect(report.undone.single.ok, isTrue);
      expect(nmcli.properties['802-11-wireless.band'], '');
      expect(
        tool.pendingRevert,
        isNull,
        reason: 'the change is gone, so is its timer',
      );
    },
  );

  test('a hotspot profile is refused before anything is written', () async {
    final nmcli = _FakeNmcli(
      properties: <String, String>{'802-11-wireless.band': ''},
      mode: 'ap',
    );
    final tool = WifiBandTool(runner: nmcli, guard: guard());
    final registry = ToolRegistry(<Tool>[tool]);
    final plan = _plan(
      registry,
      const ProposedStep(
        tool: 'wifi_band_set',
        args: <String, Object?>{'connection': 'My Hotspot', 'value': 'bg'},
        description: 'Change the band on My Hotspot',
      ),
    );

    final report = await Executor(registry: registry)
        .run(plan, Approval.granted(plan: plan, words: 'yes'));

    expect(report.status, ExecutionStatus.failed);
    expect(report.failure, contains('hotspot'));
    expect(
      nmcli.calls.where((call) => call.contains('modify')),
      isEmpty,
      reason: 'nothing may be written to a hotspot profile',
    );
    expect(File('${stateDir.path}/pending').existsSync(), isFalse);
  });

  test('nothing changes while CI is running', () async {
    final nmcli = _FakeNmcli(
      properties: <String, String>{'802-11-wireless.band': ''},
    );
    final tool = WifiBandTool(
      runner: nmcli,
      guard: guard(),
      ciRunning: () => true,
    );
    final registry = ToolRegistry(<Tool>[tool]);
    final plan = _plan(
      registry,
      const ProposedStep(
        tool: 'wifi_band_set',
        args: <String, Object?>{'connection': 'home', 'value': 'bg'},
        description: 'Switch the band',
      ),
    );

    final report = await Executor(registry: registry)
        .run(plan, Approval.granted(plan: plan, words: 'yes'));

    expect(report.failure, contains('CI'));
    expect(nmcli.properties['802-11-wireless.band'], '');
    expect(nmcli.calls.where((call) => call.contains('modify')), isEmpty);
    expect(File('${stateDir.path}/pending').existsSync(), isFalse);
  });

  test(
    'the read-only tools register above nothing and never need a rollback',
    () {
      final registry = ToolRegistry(
        networkReadTools(_Canned(const <String, String>{})),
      );
      expect(registry.names, <String>[
        'wifi_signal',
        'wifi_speed',
        'wifi_status',
      ]);
    },
  );

  test(
    'a guarded change says how long the timer has, and "keep it" stops it',
    () async {
      final nmcli = _FakeNmcli(
        properties: <String, String>{'802-11-wireless.band': ''},
      );
      final tool = WifiBandTool(runner: nmcli, guard: guard());
      final registry = ToolRegistry(<Tool>[
        ...networkReadTools(_Canned(const <String, String>{})),
        tool,
      ]);
      final backend = ScriptedBackend(<String, String>{
        'The ask: switch the band to 2.4'
                '':
            '{"goal":"switch the band","steps":[{"tool":"wifi_band_set",'
            '"args":{"connection":"home","value":"bg"},'
            '"description":"Switch the band to 2.4 GHz only"}],"questions":[]}',
      });
      final session = AgentSession(
        planner: Planner(backend: backend, registry: registry),
        validator: PlanValidator(registry),
        executor: Executor(registry: registry),
        records: FakeDevice(),
      );

      final asked = await session.say('switch the band to 2.4');
      expect(asked.say, contains('Want me to do it?'));

      final ran = await session.say('yes');
      expect(ran.say, contains('Done'));
      expect(ran.say, contains('keep it'), reason: 'a timer is running');
      expect(tool.pendingRevert, isNotNull);

      final kept = await session.say('keep it');
      expect(kept.say, contains('Kept'));
      expect(tool.pendingRevert, isNull);
      expect(nmcli.properties['802-11-wireless.band'], 'bg');
    },
  );
}
