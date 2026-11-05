// The confirm-or-revert timer, offline: what it schedules, what it writes, and
// what it refuses.
//
// The timer itself is a detached shell script, so these tests read the script it
// produced (the sleep, the ack file, the revert, the lock) and drive its outcomes
// through the files it watches. The real detached process, and the case where
// the process that armed it is killed, are proven in
// `test/revert_survival_smoke.dart`.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent/tools/detached_runner.dart';
import 'package:nexus/core/agent/tools/revert_guard.dart';

/// Records the script it was asked to start, and whether it did.
class _FakeDetached implements DetachedRunner {
  final List<String> scripts = <String>[];
  bool failNext = false;

  @override
  Future<int> start(String scriptPath) async {
    if (failNext) throw const ProcessException('sh', <String>[], 'no');
    scripts.add(scriptPath);
    return 4242;
  }
}

void main() {
  late Directory dir;
  late _FakeDetached detached;
  late RevertGuard guard;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nexus_revert_guard');
    detached = _FakeDetached();
    guard = RevertGuard(runner: detached, stateDir: dir);
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test(
    'arming schedules a detached script that reverts after the window',
    () async {
      final ticket = await guard.arm(
        label: 'band on home',
        revertScript: "nmcli connection modify 'home' band ''",
      );

      expect(detached.scripts, hasLength(1));
      final script = File(detached.scripts.single).readAsStringSync();
      expect(script, contains('sleep 60'));
      expect(script, contains('keep'), reason: 'the confirmation file');
      expect(
        script,
        contains('revert.sh'),
        reason: 'the revert runs by itself',
      );
      expect(script, contains('echo reverted'));
      expect(script, contains('echo failed'));
      expect(script, contains('rm -f'), reason: 'the lock is released');

      final revert = File('${ticket.directory.path}/revert.sh')
          .readAsStringSync();
      expect(revert, contains("nmcli connection modify 'home' band ''"));
      expect(File('${dir.path}/pending').existsSync(), isTrue);
      expect(ticket.deadline.isAfter(DateTime.now()), isTrue);
      expect(guard.outcomeOf(ticket), RevertOutcome.pending);
    },
  );

  test(
    'confirming writes the ack, and the timer then reports confirmed',
    () async {
      final ticket = await guard.arm(label: 'dns', revertScript: 'true');

      guard.confirm(ticket);

      expect(File('${ticket.directory.path}/keep').existsSync(), isTrue);
      File('${ticket.directory.path}/result').writeAsStringSync('confirmed\n');
      expect(guard.outcomeOf(ticket), RevertOutcome.confirmed);
    },
  );

  test('a revert the timer performed is reported as reverted', () async {
    final ticket = await guard.arm(label: 'band', revertScript: 'true');

    File('${ticket.directory.path}/result').writeAsStringSync('reverted\n');

    expect(guard.outcomeOf(ticket), RevertOutcome.reverted);
  });

  test('a revert that failed is not reported as success', () async {
    final ticket = await guard.arm(label: 'band', revertScript: 'false');

    File('${ticket.directory.path}/result').writeAsStringSync('failed\n');

    expect(guard.outcomeOf(ticket), RevertOutcome.failed);
  });

  test(
    'one change at a time: a second arm inside the window is refused',
    () async {
      await guard.arm(label: 'first', revertScript: 'true');

      await expectLater(
        guard.arm(label: 'second', revertScript: 'true'),
        throwsA(isA<StateError>()),
      );
      expect(guard.pending, isTrue);
    },
  );

  test('a finished timer does not block the next change', () async {
    final first = await guard.arm(label: 'first', revertScript: 'true');
    File('${first.directory.path}/result').writeAsStringSync('confirmed\n');

    final second = await guard.arm(label: 'second', revertScript: 'true');

    expect(second.id, isNot(first.id));
    expect(detached.scripts, hasLength(2));
  });

  test('a timer that could not start leaves no lock behind', () async {
    detached.failNext = true;

    await expectLater(
      guard.arm(label: 'band', revertScript: 'true'),
      throwsA(isA<ProcessException>()),
    );
    expect(
      guard.pending,
      isFalse,
      reason: 'nothing can close a window that never opened',
    );
  });

  test('the revert script is a file, never an interpolated command line', () async {
    final ticket = await guard.arm(
      label: 'a name with a quote',
      revertScript: "nmcli connection modify 'it'\\''s mine' band bg",
    );

    // The awkward name is inside a quoted run of shell in its own file, so the
    // timer runs exactly that one command.
    final revert = File('${ticket.directory.path}/revert.sh')
        .readAsStringSync();
    expect(revert, contains("'it'\\''s mine'"));
    expect(
      revert.split('\n').where((line) => line.contains('nmcli')).length,
      1,
    );
  });
}
