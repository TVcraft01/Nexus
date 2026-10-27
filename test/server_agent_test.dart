// The Server Agent's promises, checked where a user would test them.
//
// Three things have to be true and are asserted here rather than described in a
// comment: a sentence only reaches a playbook it matches, nothing runs before
// the user presses the red button, and what runs is exactly the pre-approved
// command list — never words the user typed.
import 'dart:async' show Completer;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/server_playbooks.dart';
import 'package:nexus/core/ssh_service.dart';
import 'package:nexus/core/local_ai_service.dart';
import 'package:nexus/core/memory_service.dart';
import 'package:nexus/core/server_explorer.dart';
import 'package:nexus/main_ui.dart'
    show NexusTheme, SettingsTab, kNexusServerAgentRow;
import 'package:nexus/ui/server_agent_page.dart';
import 'package:nexus/ui/theme.dart';

/// A change handler the settings screen wants and this test never calls.
void _noop(bool _) {}

/// A runner that records what it was asked to run and answers with one line per
/// command. No socket, no server, no waiting.
class _FakeRunner implements SshRunner {
  _FakeRunner(this.target, {this.answers = const <String, List<String>>{}});

  @override
  final SshTarget target;

  /// Canned output per command. Anything unlisted answers one line saying it
  /// ran, which is enough for the playbook tests.
  final Map<String, List<String>> answers;

  final List<String> commands = <String>[];
  bool closed = false;

  @override
  Stream<SshOutput> run(String command) async* {
    commands.add(command);
    final List<String> lines = answers[command] ?? <String>['ran: $command'];
    for (final String line in lines) {
      yield SshLine(line);
    }
    yield const SshExit(0);
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

/// A runner that is deliberately slow: it answers nothing until [gate] opens.
/// The only way to see the page while an exploration is still running.
class _GatedRunner implements SshRunner {
  _GatedRunner(this.target, this.gate);

  @override
  final SshTarget target;

  final Completer<void> gate;

  @override
  Stream<SshOutput> run(String command) async* {
    await gate.future;
    yield SshLine('ran: $command');
    yield const SshExit(0);
  }

  @override
  Future<void> close() async {}
}

/// A brain with one answer. Records what it was asked, so a test can check the
/// server's own output reached the prompt.
class _FakeBrain implements LocalAiService {
  _FakeBrain(this.answer, {this.failing = false});

  final String answer;
  final bool failing;
  final List<String> prompts = <String>[];

  @override
  Future<String> generateResponse(String prompt) async {
    prompts.add(prompt);
    if (failing) throw StateError('no model loaded');
    return answer;
  }

  @override
  Stream<String> generateResponseStream(
    String prompt, {
    List<AiTurn> history = const <AiTurn>[],
  }) async* {
    yield await generateResponse(prompt);
  }
}

/// Where the fake runner lands once the page actually connects. A box rather
/// than a late local: no connection happens until a playbook is confirmed, so
/// the value is genuinely absent for most of a test.
class _Harness {
  _FakeRunner? runner;
}

/// The page, on the app's own theme, with a fake way to reach the server.
Future<_Harness> _pumpPage(
  WidgetTester tester, {
  Map<String, List<String>> answers = const <String, List<String>>{},
  LocalAiService? brain,
  MemoryService? memory,
}) async {
  // A phone-shaped surface: the default 800×600 is shorter than any phone this
  // page ships on, and the terminal would be off-screen for reasons that have
  // nothing to do with the page.
  tester.view.physicalSize = const Size(430, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final _Harness harness = _Harness();
  await tester.pumpWidget(
    MaterialApp(
      theme: buildNexusTheme(),
      home: ServerAgentPage(
        connect: (SshTarget target) async =>
            harness.runner = _FakeRunner(target, answers: answers),
        brain: brain,
        memory: memory,
      ),
    ),
  );
  await tester.pump();
  return harness;
}

Future<void> _fillLogin(WidgetTester tester) async {
  await tester.enterText(find.byKey(kNexusServerHost), '10.0.0.5:2222');
  await tester.enterText(find.byKey(kNexusServerUser), 'pi');
  await tester.enterText(find.byKey(kNexusServerPassword), 'secret');
  await tester.pump();
}

void main() {
  group('intent matching', () {
    test('a request to build a Minecraft server picks the playbook', () {
      expect(playbookForIntent('make a Minecraft server'), setupMinecraft);
      expect(
        playbookForIntent('Set up a minecraft server please'),
        setupMinecraft,
      );
      expect(playbookForIntent('install minecraft'), setupMinecraft);
      expect(playbookForIntent('spin up minecraft'), setupMinecraft);
    });

    test('a remark about Minecraft is not a request', () {
      expect(playbookForIntent('I played minecraft yesterday'), isNull);
      expect(playbookForIntent('minecraft is fun'), isNull);
      expect(playbookForIntent('make a website'), isNull);
      expect(playbookForIntent(''), isNull);
      expect(playbookForIntent('   '), isNull);
    });

    test('the playbook is the only shell text, and it is pinned', () {
      final List<String> commands = setupMinecraft.commands;
      expect(commands, isNotEmpty);
      expect(
        commands.every((c) => !c.contains('rm -rf /')),
        isTrue,
        reason: 'the playbook may replace its own container, never a directory',
      );
      expect(
        commands.any((c) => c.contains('-p 25565:25565')),
        isTrue,
        reason: 'the port is the promise the screen makes',
      );
      expect(commands.any((c) => c.contains('itzg/minecraft-server')), isTrue);
      // Every privileged step uses `sudo -n`: on a server without passwordless
      // sudo it must fail with a line, not hang on a prompt nothing can answer.
      for (final String command in commands) {
        if (command.contains('sudo')) {
          expect(
            command.contains('sudo -n'),
            isTrue,
            reason: 'privileged command without -n: $command',
          );
        }
      }
    });
  });

  group('Server Agent page', () {
    testWidgets('a matched sentence asks for confirmation, then runs exactly '
        'the playbook', (WidgetTester tester) async {
      final _Harness harness = await _pumpPage(tester);
      await _fillLogin(tester);

      await tester.enterText(
        find.byKey(kNexusServerComposer),
        'make a minecraft server',
      );
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      // The dialog exists before anything runs, and it shows the commands.
      expect(find.text('Run Minecraft server?'), findsOneWidget);
      expect(find.textContaining('-p 25565:25565'), findsOneWidget);
      expect(find.byKey(kNexusServerExecute), findsOneWidget);

      await tester.tap(find.byKey(kNexusServerExecute));
      await tester.pumpAndSettle();

      // The fake proves which strings were actually sent: the playbook's, in
      // order, and nothing the user typed. It also proves the address field's
      // own port reached the connection instead of the default 22.
      final _FakeRunner runner = harness.runner!;
      expect(runner.commands, setupMinecraft.commands);
      expect(runner.target.host, '10.0.0.5');
      expect(runner.target.port, 2222);
      expect(runner.closed, isTrue);
      expect(find.byKey(kNexusServerTerminal), findsOneWidget);
      expect(
        find.textContaining('Minecraft server is running'),
        findsOneWidget,
      );
      expect(find.textContaining('ran: sudo -n docker pull'), findsOneWidget);
    });

    testWidgets('cancelling the dialog runs nothing', (
      WidgetTester tester,
    ) async {
      final _Harness harness = await _pumpPage(tester);
      await _fillLogin(tester);

      await tester.enterText(
        find.byKey(kNexusServerComposer),
        'build a minecraft server',
      );
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(harness.runner, isNull, reason: 'no connection was ever opened');
      expect(find.textContaining('ran:'), findsNothing);
      expect(find.text('Not explored yet'), findsOneWidget);
    });

    testWidgets('a sentence with no playbook says so and opens no dialog', (
      WidgetTester tester,
    ) async {
      await _pumpPage(tester);
      await _fillLogin(tester);

      await tester.enterText(
        find.byKey(kNexusServerComposer),
        'make me a website',
      );
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      expect(find.byKey(kNexusServerExecute), findsNothing);
      expect(find.text(kNoPlaybookText), findsOneWidget);
    });

    testWidgets('a login left empty is named before a dialog appears', (
      WidgetTester tester,
    ) async {
      await _pumpPage(tester);

      await tester.enterText(
        find.byKey(kNexusServerComposer),
        'make a minecraft server',
      );
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      expect(find.byKey(kNexusServerExecute), findsNothing);
      expect(
        find.text('Fill in the server address and the username first.'),
        findsOneWidget,
      );
    });

    testWidgets('a playbook row opens the same confirmation a sentence does', (
      WidgetTester tester,
    ) async {
      await _pumpPage(tester);
      await _fillLogin(tester);

      await tester.tap(find.text('Minecraft server'));
      await tester.pumpAndSettle();

      expect(find.text('Run Minecraft server?'), findsOneWidget);
      expect(find.byKey(kNexusServerExecute), findsOneWidget);
    });
  });

  testWidgets('Settings carries a row that opens the page', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: NexusTheme.light(),
        home: const Scaffold(
          body: SettingsTab(darkMode: false, onDarkModeChanged: _noop),
        ),
      ),
    );
    await tester.pump();

    final Finder row = find.byKey(kNexusServerAgentRow);
    await tester.scrollUntilVisible(
      row,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    await tester.tap(row);
    await tester.pumpAndSettle();

    expect(find.byKey(kNexusServerAgentPage), findsOneWidget);
  });

  group('Curiosity Engine', () {
    test(
      'every exploration command is read-only and one of the known tools',
      () {
        expect(kExplorationCommands, isNotEmpty);
        for (final ExplorationCommand probe in kExplorationCommands) {
          final String program = probe.command.split(' ').first;
          expect(
            kReadOnlyPrograms,
            contains(program),
            reason: '${probe.command} is not a read-only probe',
          );
          expect(
            probe.command.contains(RegExp(r'[>|;&`$]')),
            isFalse,
            reason: '${probe.command} contains a shell operator',
          );
          expect(
            probe.command.contains('sudo'),
            isFalse,
            reason: '${probe.command} escalates',
          );
        }
      },
    );

    test(
      'explore reads every probe, asks the model and remembers the answer',
      () async {
        final MemoryService memory = MemoryService(store: MemoryMemoryStore());
        final _FakeBrain brain = _FakeBrain(
          'A small home server: four cores, 8 GB of RAM, Docker installed, no '
          'GPU.',
        );
        final _FakeRunner runner = _FakeRunner(
          const SshTarget(host: '10.0.0.5', username: 'pi', password: 'x'),
          answers: const <String, List<String>>{
            'lscpu': <String>['Model name: Intel N100'],
            'free -h': <String>['Mem: 8.0Gi'],
          },
        );
        final ServerExplorer explorer = ServerExplorer(
          connect: (SshTarget target) async => runner,
          brain: brain,
          memory: memory,
        );

        final ServerReport report = await explorer.explore(runner.target);

        expect(runner.commands, kExplorationCommands.map((p) => p.command));
        expect(runner.closed, isTrue);
        expect(report.summary, contains('four cores'));
        expect(report.remembered, isTrue);
        expect(report.topic, 'server_10.0.0.5');
        expect(report.raw, contains('Model name: Intel N100'));
        expect(brain.prompts.single, contains('Model name: Intel N100'));
        expect(brain.prompts.single, contains('2-sentence summary'));
        expect(memory.notes.single.topic, 'server_10.0.0.5');
        expect(memory.notes.single.fact, contains('four cores'));
      },
    );

    test('no model means no summary, but the reads still happened', () async {
      final MemoryService memory = MemoryService(store: MemoryMemoryStore());
      final _FakeBrain brain = _FakeBrain('unused', failing: true);
      final _FakeRunner runner = _FakeRunner(
        const SshTarget(host: '10.0.0.6', username: 'pi', password: 'x'),
        answers: const <String, List<String>>{
          'uname -a': <String>['Linux box 6.1.0 #1 SMP x86_64 GNU/Linux'],
        },
      );

      final ServerReport report = await ServerExplorer(
        connect: (SshTarget target) async => runner,
        brain: brain,
        memory: memory,
      ).explore(runner.target);

      expect(report.summary, isNull);
      expect(report.summaryError, isNotNull);
      expect(report.remembered, isFalse);
      expect(report.raw, contains('Linux box'));
      expect(memory.notes, isEmpty);
    });

    testWidgets(
      'Explore Server shows the summary and can reveal the raw reads',
      (WidgetTester tester) async {
        final MemoryService memory = MemoryService(store: MemoryMemoryStore());
        final _FakeBrain brain = _FakeBrain(
          'A modest Linux box with four cores and Docker, used for a Minecraft '
          'server. No GPU was found.',
        );
        final _Harness harness = await _pumpPage(
          tester,
          brain: brain,
          memory: memory,
          answers: const <String, List<String>>{
            'lscpu': <String>['Model name: Intel N100'],
            'free -h': <String>['Mem: 8.0Gi'],
          },
        );
        await _fillLogin(tester);

        await tester.tap(find.byKey(kNexusServerExplore));
        await tester.pumpAndSettle();

        expect(
          harness.runner!.commands,
          kExplorationCommands.map((p) => p.command),
        );
        expect(find.byKey(kNexusServerSummary), findsOneWidget);
        expect(find.textContaining('A modest Linux box'), findsOneWidget);
        expect(
          find.text('Saved to memory as server_10.0.0.5'),
          findsOneWidget,
          reason: 'the card says where the summary landed',
        );

        await tester.tap(find.text('Terminal'));
        await tester.pumpAndSettle();
        expect(find.byKey(kNexusServerTerminal), findsOneWidget);
        expect(find.textContaining('Model name: Intel N100'), findsOneWidget);
      },
    );
  });

  testWidgets('an exploration says it is exploring until the reads finish', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(430, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final Completer<void> gate = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildNexusTheme(),
        home: ServerAgentPage(
          connect: (SshTarget target) async => _GatedRunner(target, gate),
          brain: _FakeBrain('A quiet little box with Docker on it.'),
          memory: MemoryService(store: MemoryMemoryStore()),
        ),
      ),
    );
    await tester.pump();
    await _fillLogin(tester);

    await tester.tap(find.byKey(kNexusServerExplore));
    await tester.pump();

    // The button says what is happening, and the raw reads are on screen as
    // they land — the wait is the server talking, not a spinner.
    expect(find.text('Exploring…'), findsOneWidget);
    expect(find.byKey(kNexusServerTerminal), findsOneWidget);

    // The summary half explains the wait too, rather than sitting empty.
    await tester.tap(find.text('Summary'));
    await tester.pump();
    expect(find.textContaining('Reading the server'), findsOneWidget);

    gate.complete();
    await tester.pumpAndSettle();

    expect(find.text('Exploring…'), findsNothing);
    expect(find.textContaining('A quiet little box'), findsOneWidget);
  });

  group('SshService', () {
    test(
      'an unreachable server becomes a sentence, not a stack trace',
      () async {
        final SshService service = SshService(
          const SshTarget(
            host: '127.0.0.1',
            port: 1,
            username: 'pi',
            password: 'x',
          ),
        );
        await expectLater(service.run('true'), emitsError(isA<SshFailure>()));
        await service.close();
      },
    );
  });
}
