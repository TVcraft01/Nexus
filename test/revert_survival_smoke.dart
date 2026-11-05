// The revert timer, for real, surviving the process that armed it.
//
// Not in the suite (no `_test` suffix): it starts a `dart run` child, waits for
// it to arm the timer, kills it with SIGKILL, and then asserts that the old
// value comes back anyway. That is the "simulate a lost connection" case — the
// arming process is gone the way Nexus or the editor would be, and the revert
// still runs because it is a detached shell process, not a Dart future.
//
//   flutter test test/revert_survival_smoke.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the timer reverts after the process that armed it is killed', () async {
    final dir = Directory.systemTemp.createTempSync('nexus_revert_survival');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final setting = File('${dir.path}/setting.txt')
      ..writeAsStringSync('changed');

    final armed = Completer<void>();
    final output = <String>[];
    final process = await Process.start('dart', <String>[
      'run',
      'tool/arm_timer.dart',
      dir.path,
      '4',
    ]);
    process.stdout.transform(utf8.decoder).listen((chunk) {
      output.add(chunk);
      if (chunk.contains('ARMED') && !armed.isCompleted) armed.complete();
    });
    process.stderr.transform(utf8.decoder).listen(output.add);

    await armed.future.timeout(
      const Duration(seconds: 180),
      onTimeout: () => throw StateError('never armed: ${output.join()}'),
    );
    process.kill(ProcessSignal.sigkill);
    await process.exitCode;

    // Killed inside the window, so nothing has been put back yet by the app.
    expect(setting.readAsStringSync().trim(), 'changed');

    final until = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(until) &&
        setting.readAsStringSync().trim() != 'original') {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }

    expect(
      setting.readAsStringSync().trim(),
      'original',
      reason:
          'the detached timer has to revert without the process that '
          'armed it, or a dropped connection is unrecoverable',
    );
  });
}
