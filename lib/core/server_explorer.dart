// What Nexus learns about a server before it touches it.
//
// The playbooks in server_playbooks.dart change a machine. Before any of that,
// the user deserves to know what the machine *is* — and so does the assistant,
// because "what is my server?" is a question it should be able to answer from
// memory instead of guessing.
//
// This file is a read-only tour: seven commands that print facts and nothing
// else, run through the same [SshRunner] the playbooks use. The list is closed
// and auditable on purpose. There is no `sudo`, no redirection, no pipe, and no
// tool that writes — and a test asserts exactly that, because "read-only" is a
// promise the command list has to keep, not a label on a screen.
//
// The raw output is kept (the page can show it for checking), and a local model
// turns it into two sentences. If there is no model, there is still a report:
// the reads happened, and raw output is more honest than no answer.
import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, immutable;

import 'local_ai_service.dart';
import 'memory_service.dart';
import 'ssh_service.dart';

/// One read-only probe and what it is for.
@immutable
class ExplorationCommand {
  const ExplorationCommand({required this.command, required this.about});

  /// The exact string sent over the connection. No shell operators: the SSH
  /// server runs it as a program, not as a script.
  final String command;

  /// What the line is called when the raw output is shown.
  final String about;
}

/// The programs an exploration command is allowed to be. Anything not here is
/// not a probe; it is a change, and changes belong to a playbook.
const Set<String> kReadOnlyPrograms = <String>{
  'uname',
  'lscpu',
  'free',
  'df',
  'lsusb',
  'docker',
  'nvidia-smi',
};

/// The tour, in the order it is run: identity, then the three resources that
/// decide what can run on the machine, then the two capabilities Nexus cares
/// about. Every one of these prints and exits.
const List<ExplorationCommand> kExplorationCommands = <ExplorationCommand>[
  ExplorationCommand(command: 'uname -a', about: 'System'),
  ExplorationCommand(command: 'lscpu', about: 'CPU'),
  ExplorationCommand(command: 'free -h', about: 'Memory'),
  ExplorationCommand(command: 'df -h', about: 'Disk'),
  ExplorationCommand(command: 'lsusb', about: 'USB'),
  ExplorationCommand(command: 'docker -v', about: 'Docker'),
  ExplorationCommand(command: 'nvidia-smi', about: 'GPU'),
];

/// The topic a server's summary lives under in the Memory Vault.
String serverMemoryTopic(String host) => 'server_$host';

/// What one command answered.
@immutable
class ServerRead {
  const ServerRead({
    required this.probe,
    required this.lines,
    required this.exitCode,
  });

  final ExplorationCommand probe;
  final List<String> lines;

  /// Null when the server did not report one. A missing tool is usually 127;
  /// that is not an error here, it is the answer "not installed".
  final int? exitCode;

  /// True when the command printed something. `nvidia-smi` on a machine with no
  /// GPU prints nothing and exits non-zero, which is a fact about the machine,
  /// not a failure of the exploration.
  bool get answered => lines.isNotEmpty;
}

/// Everything one exploration found.
@immutable
class ServerReport {
  const ServerReport({
    required this.target,
    required this.reads,
    this.summary,
    this.summaryError,
    this.remembered = false,
  });

  final SshTarget target;
  final List<ServerRead> reads;

  /// The model's two sentences, or null when there was no model to write them.
  final String? summary;

  /// Why there is no summary, in a sentence the page can show.
  final String? summaryError;

  /// Whether the summary reached the Memory Vault.
  final bool remembered;

  /// The topic the summary is saved under.
  String get topic => serverMemoryTopic(target.host);

  /// The raw output, in the order it was read — the evidence behind [summary].
  String get raw => readRaw();

  /// The raw output as one block, optionally limited to probes that answered.
  /// [without] drops the probes whose answer is not worth reading.
  String readRaw({bool answeredOnly = false}) {
    final StringBuffer out = StringBuffer();
    for (final ServerRead read in reads) {
      if (answeredOnly && !read.answered) continue;
      if (out.isNotEmpty) out.write('\n\n');
      out
        ..writeln('\$ ${read.probe.command}')
        ..write(read.lines.join('\n'));
    }
    return out.toString().trimRight();
  }
}

/// Runs the tour and asks the local model to describe what it found.
class ServerExplorer {
  ServerExplorer({this.connect, this.brain, this.memory});

  /// How to reach a server. Null means [SshService].
  final SshConnector? connect;

  /// The model that writes the summary. Null means [LocalAiService.current].
  final LocalAiService? brain;

  /// Where the summary is kept. Null means [MemoryService.instance].
  final MemoryService? memory;

  /// Reads [target] and summarises it.
  ///
  /// [onLine] receives every command as it is sent and every line as it comes
  /// back, so a screen can show the reads happening rather than a spinner that
  /// proves nothing.
  Future<ServerReport> explore(
    SshTarget target, {
    void Function(String line)? onLine,
  }) async {
    final SshRunner runner =
        await (connect?.call(target) ??
            Future<SshRunner>.value(SshService(target)));

    final List<ServerRead> reads = <ServerRead>[];
    try {
      for (final ExplorationCommand probe in kExplorationCommands) {
        onLine?.call('\$ ${probe.command}');
        final List<String> lines = <String>[];
        int? code;
        await for (final SshOutput event in runner.run(probe.command)) {
          switch (event) {
            case SshLine(:final String text):
              lines.add(text);
              onLine?.call(text);
            case SshExit(code: final int? exitCode):
              code = exitCode;
          }
        }
        reads.add(ServerRead(probe: probe, lines: lines, exitCode: code));
      }
    } finally {
      await runner.close();
    }

    final ServerReport withoutSummary = ServerReport(
      target: target,
      reads: reads,
    );

    String? summary;
    String? summaryError;
    try {
      final String answer = await (brain ?? LocalAiService.current)
          .generateResponse(serverSummaryPrompt(withoutSummary));
      final String cleaned = answer.trim();
      if (cleaned.isNotEmpty) summary = cleaned;
    } catch (error) {
      summaryError =
          'No local model answered, so there is no summary. The raw output '
          'above is everything the server said.';
      debugPrint('EXPLORE: no summary ($error)');
    }

    var remembered = false;
    if (summary != null) {
      try {
        remembered = await (memory ?? MemoryService.instance).rememberFact(
          withoutSummary.topic,
          summary,
        );
      } catch (error) {
        debugPrint('EXPLORE: could not remember the summary ($error)');
      }
    }

    return ServerReport(
      target: target,
      reads: reads,
      summary: summary,
      summaryError: summaryError,
      remembered: remembered,
    );
  }
}

/// The prompt. Pinned in one place so the wording is reviewable, and so a test
/// can assert the server's own output is inside it rather than trusting that it
/// was pasted in.
String serverSummaryPrompt(ServerReport report) {
  final String evidence = report.readRaw(answeredOnly: true);
  // A home server's `lscpu` plus `df -h` is a few kilobytes; a desktop's is
  // more. The cap keeps a 0.5B model inside its context instead of truncated
  // mid-sentence, and it is the reason the raw view exists.
  final String clipped = evidence.length <= 8000
      ? evidence
      : '${evidence.substring(0, 8000)}\n[output clipped]';
  return 'You are an expert sysadmin. Read this raw server output and write a '
      '2-sentence summary of what this server is and what it can do. Include '
      'CPU, RAM, and if Docker/GPU is available.\n\n$clipped';
}
