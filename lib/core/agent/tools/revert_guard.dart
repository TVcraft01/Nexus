// The confirm-or-revert timer for a change that could cut the connection.
//
// A change that might take the network away from the person making it needs a
// way back that does not depend on the thing that could go away. So the revert
// is a *separate, detached* process: it is started before the change, it sleeps
// for [window], and it puts the old settings back unless a confirmation file
// appeared in the meantime. If Nexus, the editor, or the whole desktop session
// disappears, the timer is still there and still reverts — that is the reason
// it is a shell script and not a Dart timer.
//
// One change at a time is enforced by a lock file: arming a second change while
// the first is still inside its window throws, because two pending reverts are
// two ways to end up with neither.
import 'dart:io';

import 'detached_runner.dart';

/// A tool whose last change is waiting for its keep-or-revert window.
///
/// The session asks its tools this after a plan runs, so it can tell the user a
/// timer is ticking and offer the word that stops it. It lives here, with the
/// ticket type, rather than in the network tools: anything that can take
/// something away can use it.
abstract interface class PendingRevert {
  RevertTicket? get pendingRevert;

  /// The user kept it: the timer will not put it back.
  void keep();
}

class RevertTicket {
  const RevertTicket({
    required this.id,
    required this.label,
    required this.deadline,
    required this.directory,
  });

  final String id;

  /// What was changed, in the user's words.
  final String label;

  /// When the revert fires if nothing confirms first.
  final DateTime deadline;

  final Directory directory;
}

enum RevertOutcome {
  /// The timer has not decided yet.
  pending,

  /// The user kept the change.
  confirmed,

  /// The timer put the old settings back.
  reverted,

  /// The timer tried to revert and the revert itself failed.
  failed,
}

class RevertGuard {
  RevertGuard({
    required this.runner,
    required this.stateDir,
    this.window = const Duration(seconds: 60),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final DetachedRunner runner;

  /// Where the timer's files live: one directory per change, plus the lock.
  final Directory stateDir;

  /// How long the change has to prove itself before it is put back.
  final Duration window;

  final DateTime Function() _now;

  File get _lock => File('${stateDir.path}/pending');

  /// Whether a change is inside its window right now.
  bool get pending => _lock.existsSync();

  /// Schedules the revert for [label] and returns the ticket.
  ///
  /// [revertScript] is a shell fragment that restores the previous settings; it
  /// is written to its own file and run by the timer, never interpolated into a
  /// command line, so a connection name with a space in it cannot turn into a
  /// second command.
  Future<RevertTicket> arm({
    required String label,
    required String revertScript,
  }) async {
    stateDir.createSync(recursive: true);
    _releaseFinished();

    if (_lock.existsSync()) {
      throw StateError(
        'another network change is still waiting for its timer: '
        '${_lock.readAsStringSync().trim()}',
      );
    }

    final id = '${_now().millisecondsSinceEpoch}';
    final dir = Directory('${stateDir.path}/$id')..createSync(recursive: true);
    final revert = File('${dir.path}/revert.sh')
      ..writeAsStringSync('#!/bin/sh\nset -u\n$revertScript\n');
    final ack = File('${dir.path}/keep');
    final result = File('${dir.path}/result');
    final script = File('${dir.path}/timer.sh')
      ..writeAsStringSync('''
#!/bin/sh
sleep ${window.inSeconds}
if [ -f "${ack.path}" ]; then
  echo confirmed > "${result.path}"
else
  if sh "${revert.path}" > "${dir.path}/revert.log" 2>&1; then
    echo reverted > "${result.path}"
  else
    echo failed > "${result.path}"
  fi
fi
rm -f "${_lock.path}"
''');

    // The lock goes down *before* the process starts: a timer that failed to
    // start must not leave a window that nothing will close.
    _lock.writeAsStringSync(id);
    try {
      await runner.start(script.path);
    } catch (_) {
      _lock.deleteSync();
      rethrow;
    }

    return RevertTicket(
      id: id,
      label: label,
      deadline: _now().add(window),
      directory: dir,
    );
  }

  /// The user kept the change: the timer will not revert it.
  void confirm(RevertTicket ticket) {
    File('${ticket.directory.path}/keep')
        .writeAsStringSync(_now().toIso8601String());
  }

  /// What the timer decided, without waiting.
  RevertOutcome outcomeOf(RevertTicket ticket) {
    final file = File('${ticket.directory.path}/result');
    if (!file.existsSync()) return RevertOutcome.pending;
    return switch (file.readAsStringSync().trim()) {
      'confirmed' => RevertOutcome.confirmed,
      'reverted' => RevertOutcome.reverted,
      'failed' => RevertOutcome.failed,
      _ => RevertOutcome.pending,
    };
  }

  /// Waits for the timer to decide, up to [timeout].
  Future<RevertOutcome> settle(
    RevertTicket ticket, {
    Duration timeout = const Duration(seconds: 90),
  }) async {
    final until = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(until)) {
      final outcome = outcomeOf(ticket);
      if (outcome != RevertOutcome.pending) return outcome;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return RevertOutcome.pending;
  }

  /// Clears a lock whose timer already finished, so a crash between the result
  /// and the lock removal cannot block every later change forever.
  void _releaseFinished() {
    if (!_lock.existsSync()) return;
    final id = _lock.readAsStringSync().trim();
    if (File('${stateDir.path}/$id/result').existsSync()) {
      _lock.deleteSync();
    }
  }
}
