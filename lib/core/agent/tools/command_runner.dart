// Running a program and reading what it said.
//
// One seam, so the network tools can be tested without `nmcli` and the real
// thing can be swapped in at the top. Errors are values, not exceptions: a
// missing binary is exactly the thing a tool has to report to the user ("I
// can't see NetworkManager on this PC"), and an exception would turn that into
// a crash in the executor's unwind path instead.
import 'dart:io';

class CommandResult {
  const CommandResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;

  bool get ok => exitCode == 0;

  /// The first non-empty line of stderr, or of stdout — what a failure should
  /// show the user.
  String get reason {
    for (final line in stderr.split('\n')) {
      if (line.trim().isNotEmpty) return line.trim();
    }
    for (final line in stdout.split('\n')) {
      if (line.trim().isNotEmpty) return line.trim();
    }
    return 'exit code $exitCode';
  }
}

abstract class CommandRunner {
  Future<CommandResult> run(String executable, List<String> args);
}

class SystemCommandRunner implements CommandRunner {
  const SystemCommandRunner();

  @override
  Future<CommandResult> run(String executable, List<String> args) async {
    try {
      final result = await Process.run(executable, args);
      return CommandResult(
        exitCode: result.exitCode,
        stdout: result.stdout.toString(),
        stderr: result.stderr.toString(),
      );
    } on ProcessException catch (error) {
      return CommandResult(exitCode: 127, stdout: '', stderr: error.message);
    }
  }
}
