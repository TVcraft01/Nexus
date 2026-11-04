// The two acceptance conversations from `docs/ROADMAP.md` item 2, offline.
//
// Conversation A: "Hi I want to set up my wifi" → "Want me to do it?" → "Yes"
// → progress → "Done, set for best speed and guests handled". Every stage is
// asserted: the plan, the approval, the verification and the report.
//
// Conversation B: "Can you automatically read my email and answer like me" →
// three things it could do → the user picks 2 → an agent is created and the
// user is told where to see it → "will it work all the time?" → hours learned
// from three weeks of the usage log → the user picks 1. Auto-send stays off.
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent/action_log.dart';
import 'package:nexus/core/agent/agent_session.dart';
import 'package:nexus/core/agent/executor.dart';
import 'package:nexus/core/agent/fake_device.dart';
import 'package:nexus/core/agent/fake_tools.dart';
import 'package:nexus/core/agent/plan_validator.dart';
import 'package:nexus/core/agent/planner.dart';
import 'package:nexus/core/agent/registry.dart';
import 'package:nexus/core/agent/risk.dart';

import 'agent_fixtures.dart';

/// One session, wired to the scripted model, the fake device and the in-memory
/// log — the whole core, with nothing outside it.
class _Harness {
  _Harness(Map<String, String> script)
    : device = FakeDevice(),
      backend = ScriptedBackend(script) {
    registry = ToolRegistry(fakeTools(device));
    log = AgentActionLog();
    executor = Executor(registry: registry, log: log);
    session = AgentSession(
      planner: Planner(backend: backend, registry: registry),
      validator: PlanValidator(registry),
      executor: executor,
      records: device,
    );
  }

  final FakeDevice device;
  final ScriptedBackend backend;
  late final ToolRegistry registry;
  late final AgentActionLog log;
  late final Executor executor;
  late final AgentSession session;
}

Map<String, String> get _bothConversations => <String, String>{
  'The ask: $wifiAsk': wifiPlanScript,
  'The ask: $mailAsk': mailNeedsScript,
  'The ask: draft replies in my style, you approve each': mailAgentScript,
  'The ask: Run Mail drafter 09:00–18:00 on weekdays': mailHoursScript,
};

void main() {
  test(
    'A: "set up my wifi" is planned, approved, run, verified and reported',
    () async {
      final harness = _Harness(_bothConversations);

      final asked = await harness.session.say(wifiAsk);

      // The plan, before anything has run.
      expect(asked.state, SessionState.awaitingApproval);
      expect(asked.say, contains('Want me to do it?'));
      final plan = asked.plan!;
      expect(plan.steps.map((step) => step.tool), ['wifi_status', 'wifi_set']);
      expect(
        plan.steps.first.risk,
        RiskTier.read,
        reason: 'the tier comes off the registered tool',
      );
      expect(plan.steps.last.risk, RiskTier.change);
      expect(asked.say, contains('reading'));
      expect(asked.say, contains('changes a setting'));
      expect(harness.device.band, '2.4ghz', reason: 'nothing runs before yes');
      expect(harness.device.guestNetwork, isFalse);
      expect(harness.log.isEmpty, isTrue);

      final ran = await harness.session.say('Yes');

      // The approval: granted, in the user's words, covering the exact steps.
      expect(ran.approval!.granted, isTrue);
      expect(ran.approval!.words, 'Yes');
      expect(ran.approval!.steps, hasLength(2));
      expect(ran.approval!.covers(plan.steps.last), isTrue);

      // Progress while it runs.
      expect(ran.progress, hasLength(2));
      expect(ran.progress.first, 'Look at the current Wi-Fi settings');

      // The verification, read back off the device.
      final report = ran.execution!;
      expect(report.status, ExecutionStatus.done);
      expect(report.verified, hasLength(2));
      expect(report.verified.last.verification.ok, isTrue);
      expect(report.verified.last.verification.measured, contains('band=auto'));
      expect(harness.device.band, 'auto');
      expect(harness.device.guestNetwork, isTrue);

      // The report: one sentence, backed by what was measured.
      expect(ran.say, contains('Done'));
      expect(ran.say, contains('best speed'));
      expect(ran.say, contains('guest'));
      expect(ran.say, contains('Measured'));

      // And the log holds one line per step that ran, newest first.
      expect(harness.log.entries, hasLength(2));
      expect(harness.log.entries.first.tool, 'wifi_set');
      expect(harness.log.entries.first.approved, contains('Yes'));
      expect(harness.log.entries.last.tool, 'wifi_status');
    },
  );

  test('A: a no runs nothing and says so', () async {
    final harness = _Harness(_bothConversations);
    await harness.session.say(wifiAsk);

    final no = await harness.session.say('No, not now');

    expect(no.approval!.granted, isFalse);
    expect(no.say, contains('Nothing ran'));
    expect(harness.device.band, '2.4ghz');
    expect(harness.device.guestNetwork, isFalse);
    expect(harness.log.isEmpty, isTrue);
  });

  test('B: drafts-only agent, then hours counted from the usage log', () async {
    final harness = _Harness(_bothConversations);

    final needs = await harness.session.say(mailAsk);

    // It asks what it needs, numbered, before making anything.
    expect(needs.state, SessionState.awaitingChoice);
    expect(needs.say, contains('1. read my mail and sort it'));
    expect(needs.say, contains('2. draft replies in my style'));
    expect(needs.say, contains('3. send replies automatically'));
    expect(harness.device.savedAgents, isEmpty);
    expect(harness.log.isEmpty, isTrue);

    final created = await harness.session.say('2');

    // The agent exists, is drafts-only, and the user is told where to see it.
    expect(created.say, contains('Done'));
    expect(created.say, contains('Mail drafter'));
    expect(created.say, contains('what agents do I have'));
    final agent = harness.device.agent('Mail drafter')!;
    expect(agent.tools, ['mail_drafts']);
    expect(agent.draftsOnly, isTrue);
    expect(harness.device.mailAutoSend, isFalse);
    expect(created.plan!.steps.map((step) => step.tool), ['agent_create']);
    expect(created.execution!.status, ExecutionStatus.done);
    expect(harness.log.entries.single.tool, 'agent_create');
    expect(
      harness.log.entries.every((entry) => entry.tool != 'mail_auto_send'),
      isTrue,
      reason: 'auto-send stays off: no step may turn it on',
    );

    final hours = await harness.session.say('will it work all the time?');

    // The offer comes from the log, not from a model.
    expect(hours.state, SessionState.awaitingChoice);
    expect(hours.say, contains('3 weeks'));
    expect(hours.say, contains('09:00'));
    expect(hours.say, contains('weekdays'));
    expect(hours.say, contains('1. Run Mail drafter'));
    expect(agent.schedule, isNull);

    final scheduled = await harness.session.say('1');

    expect(scheduled.execution!.status, ExecutionStatus.done);
    expect(
      harness.device.agent('Mail drafter')!.schedule,
      '9:00-18:00 on weekdays',
    );
    expect(scheduled.say, contains('Done'));
    expect(harness.device.mailAutoSend, isFalse);
    expect(
      harness.log.entries.every((entry) => entry.tool != 'mail_auto_send'),
      isTrue,
    );
  });

  test(
    'B: asking what agents exist answers from the store, not a model',
    () async {
      final harness = _Harness(_bothConversations);
      await harness.session.say(mailAsk);
      await harness.session.say('2');
      final promptsBefore = harness.backend.prompts.length;

      final listed = await harness.session.say('what agents do I have');

      expect(listed.say, contains('Mail drafter'));
      expect(listed.say, contains('Runs only when you ask'));
      expect(
        harness.backend.prompts,
        hasLength(promptsBefore),
        reason: 'this is a question about local records; no model is asked',
      );
    },
  );
}
