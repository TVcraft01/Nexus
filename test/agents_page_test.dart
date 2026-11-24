// The Automations screen: the way into the agent core that Settings now offers.
//
// These tests drive the real service and the real store (a temp file), with a
// scripted runner standing in for the model — the same seam `agent_service_test`
// uses. Nothing here needs Ollama, a network, or a tool.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent/agent_records.dart';
import 'package:nexus/core/agent/agent_service.dart';
import 'package:nexus/core/agent/agent_store.dart';
import 'package:nexus/core/agent/risk.dart';
import 'package:nexus/core/agent/tool.dart';
import 'package:nexus/core/agent/verification.dart';
import 'package:nexus/main_ui.dart';

/// The store without its file: what this page needs to prove is what it writes
/// and what it draws, and the file itself is `agent_store_test`'s subject. A
/// widget test's fake clock does not let a real `writeAsString` finish, so using
/// the file here would test the harness rather than the screen.
class _MemoryAgentStore extends AgentStore {
  _MemoryAgentStore() : super(explicitPath: 'memory-only');

  @override
  Future<void> load() async {}

  @override
  Future<bool> save() async => true;
}

/// A tool that only reads, which is what a new automation is given by default.
class _ReadTool extends Tool {
  _ReadTool(this.name, this.description);

  @override
  final String name;

  @override
  final String description;

  @override
  final Map<String, ToolArg> args = const <String, ToolArg>{};

  @override
  RiskTier get risk => RiskTier.read;

  @override
  Future<String> run(Map<String, Object?> args) async => '$name: fine';

  @override
  Future<VerificationResult> verify(Map<String, Object?> args) async =>
      const VerificationResult.ok('fine');
}

void main() {
  late AgentStore store;
  late AgentService service;
  late int runs;

  final List<Tool> tools = <Tool>[
    _ReadTool('wifi_signal', 'Read the signal strength'),
  ];

  setUp(() async {
    store = _MemoryAgentStore();
    await store.load();
    runs = 0;
    service = AgentService(
      store: store,
      runner: (AgentDefinition agent) async {
        runs++;
        return const AgentOutcome('read 1 step, nothing changed');
      },
      tickEvery: const Duration(hours: 1),
    );
  });

  tearDown(() async {
    await service.dispose();
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: NexusTheme.light(),
        home: AgentsPage(store: store, service: service, tools: tools),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('an empty page says so and offers the one way in', (
    tester,
  ) async {
    await pump(tester);

    expect(find.byKey(kNexusAgentsPage), findsOneWidget);
    expect(find.textContaining('No automations yet'), findsOneWidget);
    expect(find.byKey(kNexusAgentNew), findsOneWidget);
  });

  testWidgets('the + writes a definition the next launch will find', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byKey(kNexusAgentNew));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(0), 'Wi-Fi check');
    await tester.enterText(
      find.byType(TextField).at(1),
      'Check my Wi-Fi signal',
    );
    await tester.enterText(
      find.byType(TextField).at(2),
      '9:00-18:00 on weekdays',
    );
    final Finder save = find.byKey(kNexusAgentSave);
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();

    final AgentDefinition? saved = store.agent('Wi-Fi check');
    expect(saved, isNotNull);
    expect(saved!.goal, 'Check my Wi-Fi signal');
    expect(saved.schedule, '9:00-18:00 on weekdays');
    // The reading tool was preselected; a change is the user's to grant.
    expect(saved.tools, <String>['wifi_signal']);
    expect(saved.status, AgentStatus.stopped);
    expect(find.byKey(nexusAgentRowKey('Wi-Fi check')), findsOneWidget);
  });

  testWidgets('a schedule it cannot read is refused, not saved', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(kNexusAgentNew));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(0), 'Wi-Fi check');
    await tester.enterText(find.byType(TextField).at(1), 'Check the signal');
    await tester.enterText(find.byType(TextField).at(2), 'every morning');
    final Finder save = find.byKey(kNexusAgentSave);
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(store.agent('Wi-Fi check'), isNull);
    expect(find.textContaining('Write the hours as 9:00-18:00'), findsOneWidget);
  });

  testWidgets('run now runs the agent and keeps what it said', (tester) async {
    await store.put(
      AgentDefinition(
        name: 'Wi-Fi check',
        goal: 'Check the signal',
        tools: <String>['wifi_signal'],
      ),
    );
    await pump(tester);

    await tester.tap(find.byKey(nexusAgentRowKey('Wi-Fi check')));
    await tester.pumpAndSettle();
    expect(find.text('Run now'), findsOneWidget);
    await tester.tap(find.text('Run now'));
    // Two frames: one starts the run, the next applies what it answered. A
    // spinner is on screen in between, so this cannot be a pumpAndSettle.
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();

    expect(runs, 1);
    expect(
      store.agent('Wi-Fi check')!.lastResult,
      'read 1 step, nothing changed',
    );
    expect(find.text('read 1 step, nothing changed'), findsWidgets);
  });

  testWidgets('halt all reaches the service, and resume clears it', (
    tester,
  ) async {
    await store.put(
      AgentDefinition(
        name: 'Wi-Fi check',
        goal: 'Check the signal',
        tools: <String>['wifi_signal'],
      ),
    );
    await pump(tester);

    await tester.tap(find.byKey(kNexusAgentsHalt));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Halt all'));
    await tester.pumpAndSettle();

    expect(service.halted, isTrue);
    expect(find.text('Everything is halted'), findsOneWidget);

    await tester.tap(find.byKey(kNexusAgentsResume));
    await tester.pumpAndSettle();

    expect(service.halted, isFalse);
    expect(find.text('Everything is halted'), findsNothing);
  });
}
