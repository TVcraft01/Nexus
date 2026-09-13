import 'dart:async';
import 'dart:io';

import 'package:nexus/core/system_command.dart';

/// Every test in this package runs with system commands neutralised.
///
/// A suite run must not launch anything. Before this file existed a full
/// `flutter test` opened a real browser (the desktop action backend's
/// `xdg-open` for a web search), popped two desktop notifications
/// (`notify-send`, one of them five seconds later from a background `sh`),
/// unpacked archives with `tar`, and probed the `tailscale` CLI — which made
/// the run depend on the desktop session and time out on a busy machine.
///
/// Tests that need to assert on a command pass their own [CommandRunner] and
/// record it. Nothing else can reach the system, including tests written later,
/// because the default only ever returns "the program ran and said nothing".
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  systemCommandRunner = _nothing;
  await testMain();
}

Future<ProcessResult> _nothing(String program, List<String> arguments) async =>
    ProcessResult(0, 0, '', '');
