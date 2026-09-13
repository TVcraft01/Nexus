import 'dart:io';

/// Runs a system program and returns its result.
///
/// Everything that shells out takes one of these, so the act of launching a
/// program has a single definition — and a single place the test suite can
/// neutralise. [LinuxSerialTransport] has injected its runners this way from
/// the start; this is the same shape for the rest.
typedef CommandRunner = Future<ProcessResult> Function(
  String program,
  List<String> arguments,
);

/// The runner used when nothing is injected: the real [Process.run].
///
/// The product never replaces this. `test/flutter_test_config.dart` does, for
/// every test in the package, because a suite run must not launch anything —
/// the desktop action backend would open a real browser through `xdg-open` and
/// pop a desktop notification through `notify-send`, and the network probe ran
/// the `tailscale` CLI. Tests that need to assert on a command pass their own
/// [CommandRunner] instead of relying on this default.
CommandRunner systemCommandRunner = Process.run;
