// The real tools this app runs, and where their revert timer lives.
//
// Only tools that already existed are registered — three read-only network
// tools and three Wi-Fi settings tools. Nothing here is new, nothing is
// auto-allowed: an agent still has to name the tools it may use, and the gate
// still decides per step (the settings tools are medium risk, so a scheduled
// run skips them and an attended run has to ask).
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'registry.dart';
import 'tool.dart';
import 'tools/command_runner.dart';
import 'tools/net_change_tools.dart';
import 'tools/net_read_tools.dart';
import 'tools/revert_guard.dart';

/// The registry the product uses: the network tools, on this PC.
ToolRegistry realAgentTools({
  required RevertGuard guard,
  CommandRunner runner = const SystemCommandRunner(),
}) => ToolRegistry(<Tool>[
  ...networkReadTools(runner),
  ...networkChangeTools(runner: runner, guard: guard),
]);

/// The revert timer's state directory. Under [dataDir] when the app was given
/// one (tests, portable runs), else the app-support folder — the same place the
/// agent store and the run log live.
Future<Directory> agentRevertStateDir([String? dataDir]) async {
  if (dataDir != null && dataDir.trim().isNotEmpty) {
    return Directory('${dataDir.trim()}/revert');
  }
  final Directory support = await getApplicationSupportDirectory();
  return Directory('${support.path}/agent-revert');
}
