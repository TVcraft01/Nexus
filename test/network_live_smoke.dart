// Item 3, on the actual PC: real numbers, a real change, a real rollback.
//
// Not part of the suite — no `_test` suffix — because it touches `nmcli` and the
// machine it runs on. Run it explicitly:
//
//   flutter test test/network_live_smoke.dart
//
// It never touches the connection in use. The change is made to a throwaway
// NetworkManager profile created for this run (autoconnect off, never
// activated), measured before and after, put back, and then deleted. The
// read-only tools are measured against the real link, and the timer is armed for
// the change exactly as it would be for a real one.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent/approval.dart';
import 'package:nexus/core/agent/executor.dart';
import 'package:nexus/core/agent/plan.dart';
import 'package:nexus/core/agent/plan_validator.dart';
import 'package:nexus/core/agent/registry.dart';
import 'package:nexus/core/agent/tool.dart';
import 'package:nexus/core/agent/tools/command_runner.dart';
import 'package:nexus/core/agent/tools/detached_runner.dart';
import 'package:nexus/core/agent/tools/net_change_tools.dart';
import 'package:nexus/core/agent/tools/net_read_tools.dart';
import 'package:nexus/core/agent/tools/revert_guard.dart';

/// One `nmcli` field of one connection, or null when it cannot be read.
Future<String?> _property(
  CommandRunner runner,
  String property,
  String connection,
) async {
  final result = await runner.run('nmcli', <String>[
    '-g',
    property,
    'connection',
    'show',
    connection,
  ]);
  return result.ok ? result.stdout.trim() : null;
}

void main() {
  const runner = SystemCommandRunner();
  final stateDir = Directory.systemTemp.createTempSync('nexus_live_guard');
  final profile = 'nexus-temp-${DateTime.now().millisecondsSinceEpoch}';
  var created = false;

  tearDown(() async {
    if (created) {
      await runner.run('nmcli', <String>['connection', 'delete', profile]);
    }
    if (stateDir.existsSync()) stateDir.deleteSync(recursive: true);
  });

  test(
    'live: read the real link, change a throwaway profile, roll it back',
    () async {
      // --- Read-only first: the numbers as they are. -------------------------
      final report = await readWifiReport(runner);
      final latency = await measureGatewayLatency(runner);
      // ignore: avoid_print
      print(
        'READ status: device=${report.device} connection=${report.connection} '
        'ssid=${report.ssid} band=${report.band} signal=${report.signal}% '
        'rate=${report.rate}',
      );
      // ignore: avoid_print
      print('READ latency: ${latency?.label ?? 'no gateway answer'}');
      expect(report.connected, isTrue, reason: 'the read tools need a link');

      final active = await runner.run('nmcli', <String>[
        '-t',
        '-f',
        'NAME',
        'connection',
        'show',
        '--active',
      ]);
      final activeBefore = active.stdout.trim();
      final device = report.device;

      // --- A throwaway profile, never activated. ----------------------------
      final added = await runner.run('nmcli', <String>[
        'connection',
        'add',
        'type',
        'wifi',
        'con-name',
        profile,
        'ifname',
        device,
        'ssid',
        'nexus-temp',
        'autoconnect',
        'no',
      ]);
      created = added.ok;
      expect(added.ok, isTrue, reason: 'nmcli add: ${added.reason}');

      final before = await _property(runner, '802-11-wireless.band', profile);
      // ignore: avoid_print
      print('PROFILE $profile band before: "${before ?? '(unreadable)'}"');

      // --- The change, through the tool and its timer. ----------------------
      final guard = RevertGuard(
        runner: const SystemDetachedRunner(),
        stateDir: stateDir,
        window: const Duration(seconds: 30),
      );
      final registry = ToolRegistry(<Tool>[
        ...networkReadTools(runner),
        ...networkChangeTools(runner: runner, guard: guard),
      ]);
      final validation = PlanValidator(registry).validate(
        ProposedPlan(
          goal: 'set the throwaway profile to 2.4 GHz only',
          steps: <ProposedStep>[
            ProposedStep(
              tool: 'wifi_band_set',
              args: <String, Object?>{'connection': profile, 'value': 'bg'},
              description:
                  'Set the Wi-Fi band of the throwaway profile to '
                  '2.4 GHz only',
            ),
          ],
        ),
      );
      expect(validation, isA<PlanAccepted>());
      final plan = (validation as PlanAccepted).plan;

      final executed = await Executor(registry: registry).run(
        plan,
        Approval.granted(plan: plan, words: 'live smoke', at: DateTime.now()),
      );
      expect(executed.status, ExecutionStatus.done);

      final after = await _property(runner, '802-11-wireless.band', profile);
      // ignore: avoid_print
      print(
        'PROFILE band after: "$after" (verified '
        '${executed.verified.single.verification.measured})',
      );
      expect(after, 'bg');

      // --- The rollback, actually run. --------------------------------------
      final rollback = plan.steps.single.rollback;
      expect(rollback, isNotNull);
      final undone = await rollback!();
      final restored = await _property(runner, '802-11-wireless.band', profile);
      // ignore: avoid_print
      print(
        'ROLLBACK ${undone.ok ? 'ok' : 'failed'}: ${undone.what} '
        '(profile band now "$restored")',
      );
      expect(undone.ok, isTrue);
      expect(restored, before);

      // --- The connection in use is untouched. ------------------------------
      final activeAfter = await runner.run('nmcli', <String>[
        '-t',
        '-f',
        'NAME',
        'connection',
        'show',
        '--active',
      ]);
      expect(activeAfter.stdout.trim(), activeBefore);
      // ignore: avoid_print
      print('ACTIVE unchanged: ${activeBefore.replaceAll('\n', ', ')}');

      // --- Clean up the profile. -------------------------------------------
      final deleted = await runner.run('nmcli', <String>[
        'connection',
        'delete',
        profile,
      ]);
      created = !deleted.ok;
      expect(deleted.ok, isTrue);
      final gone = await runner.run('nmcli', <String>[
        '-t',
        '-f',
        'NAME',
        'connection',
        'show',
      ]);
      expect(gone.stdout.contains(profile), isFalse);
    },
  );
}
