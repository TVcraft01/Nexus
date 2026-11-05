// Starting a process that outlives the caller.
//
// The revert timer must run even if Nexus or the editor driving it loses its
// connection, so it cannot be a Dart future, a timer, or anything else that
// lives in this process. It is a script started detached: it holds no handle on
// the app, it is not in the agent loop, and killing the app does not reach it.
import 'dart:io';

abstract class DetachedRunner {
  /// Starts [scriptPath] detached and returns its pid.
  ///
  /// Throws when the process cannot be started at all — a change whose revert
  /// could not be scheduled must not be applied, so the caller treats this as
  /// fatal, not as a warning.
  Future<int> start(String scriptPath);
}

class SystemDetachedRunner implements DetachedRunner {
  const SystemDetachedRunner();

  @override
  Future<int> start(String scriptPath) async {
    final process = await Process.start(
      'sh',
      <String>[scriptPath],
      // The whole point: no connection to this process, no stdio, no exit
      // signal delivered when the parent goes away.
      mode: ProcessStartMode.detached,
    );
    return process.pid;
  }
}
