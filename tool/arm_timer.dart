// Dev-only: arm a revert timer and exit at once.
//
// The point is to have a process that schedules the timer and then goes away, so
// `test/revert_survival_smoke.dart` can kill it and prove the timer still fires.
// The app itself never runs this; the tool exists so the claim "the revert runs
// even if the thing that armed it is gone" can be checked by hand too:
//
//   dart run tool/arm_timer.dart /tmp/nexus-revert-demo 4
//   kill -9 <the pid it was>
//   cat /tmp/nexus-revert-demo/setting.txt   # back to "original" after 4s
import 'dart:io';

import 'package:nexus/core/agent/tools/detached_runner.dart';
import 'package:nexus/core/agent/tools/revert_guard.dart';

Future<void> main(List<String> args) async {
  final dir = Directory(args.isEmpty ? '/tmp/nexus-revert-demo' : args.first)
    ..createSync(recursive: true);
  final seconds = args.length > 1 ? int.parse(args[1]) : 5;
  final setting = File('${dir.path}/setting.txt')..writeAsStringSync('changed');
  final guard = RevertGuard(
    runner: const SystemDetachedRunner(),
    stateDir: Directory('${dir.path}/guard'),
    window: Duration(seconds: seconds),
  );
  final ticket = await guard.arm(
    label: 'demo',
    revertScript: 'echo original > "${setting.path}"',
  );
  stdout.writeln('ARMED ${ticket.directory.path}');
}
