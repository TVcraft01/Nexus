// Item 4 of `docs/ROADMAP.md`: agent definitions as data, a background service
// that starts, pauses and runs them, and a local-only dashboard that drives it.
//
// Everything here runs offline and uses a real file and a real loopback HTTP
// server — the promises are about persistence, scheduling and access control,
// so a fake of any of the three would prove nothing.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent/agent_dashboard.dart';
import 'package:nexus/core/agent/agent_records.dart';
import 'package:nexus/core/agent/agent_service.dart';
import 'package:nexus/core/agent/agent_session.dart';
import 'package:nexus/core/agent/agent_store.dart';
import 'package:nexus/core/agent/action_log.dart';
import 'package:nexus/core/agent/executor.dart';
import 'package:nexus/core/agent/fake_device.dart';
import 'package:nexus/core/agent/fake_tools.dart';
import 'package:nexus/core/agent/plan_validator.dart';
import 'package:nexus/core/agent/planner.dart';
import 'package:nexus/core/agent/registry.dart';
import 'package:nexus/core/agent/working_hours.dart';

import 'agent_fixtures.dart';

/// A Wednesday at 10:00 — inside "9:00-18:00 on weekdays".
final DateTime _wednesday = DateTime(2026, 11, 4, 10);

AgentService _service(
  AgentStore store, {
  AgentRunner? runner,
  DateTime Function()? now,
}) => AgentService(
  store: store,
  runner: runner ?? (agent) async => const AgentOutcome('drafted a reply'),
  now: now ?? () => _wednesday,
);

Future<AgentDefinition> _saved(
  AgentStore store, {
  String name = 'Mail drafter',
  String? schedule = '9:00-18:00 on weekdays',
}) async {
  final AgentDefinition agent = AgentDefinition(
    name: name,
    goal: 'draft replies in my style',
    tools: <String>['mail_drafts'],
    schedule: schedule,
  );
  await store.put(agent);
  return agent;
}

/// One HTTP request with redirects left unfollowed, so a 303 is visible as one.
Future<(int, String)> _send(String url, {Map<String, String>? form}) async {
  final HttpClient client = HttpClient();
  try {
    final Uri uri = Uri.parse(url);
    final HttpClientRequest request = form == null
        ? await client.getUrl(uri)
        : await client.postUrl(uri);
    request.followRedirects = false;
    if (form != null) {
      request.headers.contentType = ContentType(
        'application',
        'x-www-form-urlencoded',
        charset: 'utf-8',
      );
      request.write(Uri(queryParameters: form).query);
    }
    final HttpClientResponse response = await request.close();
    return (response.statusCode, await utf8.decodeStream(response));
  } finally {
    client.close(force: true);
  }
}

void main() {
  late Directory dir;
  late AgentStore store;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('nexus-agents-');
    store = AgentStore(explicitPath: '${dir.path}/agents.json');
    await store.load();
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('a definition is data: it survives a save and a load', () async {
    final AgentDefinition agent = AgentDefinition(
      name: 'Mail drafter',
      goal: 'draft replies in my style, never send',
      tools: <String>['mail_drafts'],
      schedule: '9:00-18:00 on weekdays',
      approval: AgentApprovalPolicy.askDestructive,
      status: AgentStatus.running,
      lastRunAt: _wednesday,
      lastResult: 'drafted 2 replies',
    );
    expect(agent.draftsOnly, isTrue);
    await store.put(agent);

    // A second launch: nothing is memoised, so the only way this comes back is
    // out of the file.
    final AgentStore reloaded = AgentStore(
      explicitPath: '${dir.path}/agents.json',
    );
    await reloaded.load();
    final AgentDefinition read = reloaded.agent('Mail drafter')!;

    expect(read.goal, agent.goal);
    expect(read.tools, <String>['mail_drafts']);
    expect(read.schedule, '9:00-18:00 on weekdays');
    expect(read.approval, AgentApprovalPolicy.askDestructive);
    expect(read.status, AgentStatus.running);
    expect(read.lastRunAt, _wednesday);
    expect(read.lastResult, 'drafted 2 replies');
    expect(read.draftsOnly, isTrue);
  });

  test('a value the reader cannot understand falls back, it is not lost', () {
    final AgentDefinition read = AgentDefinition.fromJson(<String, Object?>{
      'name': 'Old agent',
      'goal': 'sort my mail',
      'tools': <Object?>['mail_drafts', 7],
      'approval': 'something from a newer build',
      'status': 'sleeping',
      'lastRunAt': 'not a date',
    });

    expect(read.tools, <String>['mail_drafts']);
    expect(read.approval, AgentApprovalPolicy.askEveryChange);
    expect(read.status, AgentStatus.stopped);
    expect(read.lastRunAt, isNull);
    expect(read.schedule, isNull);
  });

  test('start, pause and stop are recorded where the dashboard reads them', () async {
    await _saved(store);
    final AgentService service = _service(store);

    expect((await service.start('Mail drafter')).status, AgentStatus.running);
    expect(store.agent('Mail drafter')!.status, AgentStatus.running);

    // Pausing keeps the definition and the hours; only the status moves.
    final AgentDefinition paused = await service.pause('Mail drafter');
    expect(paused.status, AgentStatus.paused);
    expect(paused.schedule, '9:00-18:00 on weekdays');

    expect((await service.stop('Mail drafter')).status, AgentStatus.stopped);
    expect(
      () => service.pause('Mail drafter'),
      throwsA(isA<AgentServiceError>()),
      reason: 'a stopped agent is not running, so there is nothing to pause',
    );
    expect(
      () => service.start('Nobody'),
      throwsA(isA<AgentServiceError>()),
    );

    // And the status is on disk, not only in this process.
    final AgentStore reloaded = AgentStore(
      explicitPath: '${dir.path}/agents.json',
    );
    await reloaded.load();
    expect(reloaded.agent('Mail drafter')!.status, AgentStatus.stopped);
  });

  test('a schedule is read from the words the user typed', () {
    final AgentSchedule? weekdays = AgentSchedule.parse(
      '9:00-18:00 on weekdays',
    );
    expect(weekdays, isNotNull);
    expect(weekdays!.covers(_wednesday), isTrue);
    expect(
      weekdays.covers(DateTime(2026, 11, 4, 8, 59)),
      isFalse,
      reason: 'before the window',
    );
    expect(
      weekdays.covers(DateTime(2026, 11, 4, 18)),
      isFalse,
      reason: 'the end is exclusive, so a boundary cannot run twice',
    );
    expect(
      weekdays.covers(DateTime(2026, 11, 7, 10)),
      isFalse,
      reason: 'Saturday is not a weekday',
    );

    // The en dash the sessions write, and no day restriction.
    final AgentSchedule? anyDay = AgentSchedule.parse('08:00–12:00');
    expect(anyDay!.covers(DateTime(2026, 11, 8, 9)), isTrue);

    expect(AgentSchedule.parse('whenever'), isNull);
    expect(AgentSchedule.parse('18:00-9:00'), isNull);
    expect(AgentSchedule.parse('25:00-26:00'), isNull);
    expect(AgentSchedule.parse(null), isNull);
  });

  test('the service runs a due agent once a minute, never a paused one', () async {
    await _saved(store);
    var calls = 0;
    var now = _wednesday;
    final AgentService service = _service(
      store,
      runner: (agent) async {
        calls++;
        return AgentOutcome('ran ${agent.name}');
      },
      now: () => now,
    );

    // Stopped: a schedule alone does not run anything.
    expect(await service.tick(), isEmpty);
    expect(calls, 0);

    await service.start('Mail drafter');
    final first = await service.tick();
    expect(first, hasLength(1));
    expect(calls, 1);
    expect(first.single.result, 'ran Mail drafter');
    expect(first.single.ok, isTrue);

    // The same minute again: a timer that fired twice must not run twice.
    expect(await service.tick(), isEmpty);
    expect(calls, 1);

    now = _wednesday.add(const Duration(minutes: 1));
    expect(await service.tick(), hasLength(1));
    expect(calls, 2);

    await service.pause('Mail drafter');
    now = _wednesday.add(const Duration(minutes: 2));
    expect(await service.tick(), isEmpty);
    expect(calls, 2);

    // And outside the hours nothing runs either.
    await service.start('Mail drafter');
    now = DateTime(2026, 11, 4, 19);
    expect(await service.tick(), isEmpty);
    expect(calls, 2);
  });

  test('a run records what it said, and a failure is written down as one', () async {
    await _saved(store);
    final AgentService service = _service(
      store,
      runner: (agent) async => throw StateError('no mail tool on this PC'),
    );

    final AgentRun run = await service.runNow('Mail drafter');

    expect(run.ok, isFalse);
    expect(run.result, contains('no mail tool on this PC'));
    final AgentDefinition agent = store.agent('Mail drafter')!;
    expect(agent.lastResult, contains('it failed'));
    expect(agent.lastRunAt, _wednesday);
    expect(
      agent.status,
      AgentStatus.stopped,
      reason: 'a manual run does not switch a stopped agent on',
    );
    expect(service.runs.single.agent, 'Mail drafter');
  });

  test('the usage log records nothing until the user turns it on', () async {
    expect(store.usageOptIn, isFalse);
    await store.recordUsage(_wednesday);
    expect(store.recordedUsage, isEmpty);
    expect(
      store.mailUsage,
      isEmpty,
      reason: 'the session must not learn hours it was not allowed to keep',
    );
    expect(suggestWorkingHours(store.mailUsage), isNull);

    await store.setUsageOptIn(true);
    await store.recordUsage(DateTime(2026, 11, 4, 9, 15));
    await store.recordUsage(DateTime(2026, 11, 4, 17, 40));
    expect(store.mailUsage, hasLength(2));
    expect(suggestWorkingHours(store.mailUsage), isNotNull);

    // The choice itself is stored, and turning it off forgets the history.
    final AgentStore reloaded = AgentStore(
      explicitPath: '${dir.path}/agents.json',
    );
    await reloaded.load();
    expect(reloaded.usageOptIn, isTrue);
    expect(reloaded.mailUsage, hasLength(2));

    await reloaded.setUsageOptIn(false);
    expect(reloaded.mailUsage, isEmpty);
    expect(reloaded.recordedUsage, isEmpty);
  });

  test('the dashboard is loopback-only and needs its key', () async {
    final AgentDefinition agent = AgentDefinition(
      name: 'Mail <drafter>',
      goal: 'draft replies',
      tools: <String>['mail_drafts'],
      schedule: '9:00-18:00 on weekdays',
    );
    await store.put(agent);
    final AgentService service = _service(store);
    final AgentDashboard dashboard = AgentDashboard(
      service: service,
      token: 'testkey',
    );
    addTearDown(dashboard.stop);
    final String url = await dashboard.start();

    expect(url, startsWith('http://127.0.0.1:'));
    expect(url, contains('/testkey/'));

    // The page: the agents, from the store, escaped.
    final (int pageStatus, String page) = await _send(url);
    expect(pageStatus, HttpStatus.ok);
    expect(page, contains('Mail &lt;drafter&gt;'));
    expect(page, contains('9:00-18:00 on weekdays'));
    expect(page, contains('ask me before every change'));
    expect(page, isNot(contains('<drafter>')));

    // No key, no page — and the same answer as a path that does not exist.
    final (int noKey, _) = await _send('http://127.0.0.1:${dashboard.boundPort}/');
    expect(noKey, HttpStatus.notFound);
    final (int wrongKey, _) = await _send(
      'http://127.0.0.1:${dashboard.boundPort}/start',
      form: <String, String>{'name': 'Mail <drafter>'},
    );
    expect(wrongKey, HttpStatus.notFound);

    // An action is a POST.
    final (int wrongMethod, _) = await _send('${url}start');
    expect(wrongMethod, HttpStatus.methodNotAllowed);

    // start → pause → stop, through the same forms the page offers.
    final (int started, _) = await _send(
      '${url}start',
      form: <String, String>{'name': 'Mail <drafter>'},
    );
    expect(started, HttpStatus.seeOther);
    expect(store.agent('Mail <drafter>')!.status, AgentStatus.running);

    final (int runNow, _) = await _send(
      '${url}run',
      form: <String, String>{'name': 'Mail <drafter>'},
    );
    expect(runNow, HttpStatus.seeOther);
    expect(store.agent('Mail <drafter>')!.lastResult, isNotEmpty);

    await _send('${url}pause', form: <String, String>{'name': 'Mail <drafter>'});
    expect(store.agent('Mail <drafter>')!.status, AgentStatus.paused);
    await _send('${url}stop', form: <String, String>{'name': 'Mail <drafter>'});
    expect(store.agent('Mail <drafter>')!.status, AgentStatus.stopped);

    // A name that is not there is the asker's mistake, not a crash.
    final (int unknown, String unknownBody) = await _send(
      '${url}start',
      form: <String, String>{'name': 'Nobody'},
    );
    expect(unknown, HttpStatus.badRequest);
    expect(unknownBody, contains('no agent called'));

    // The usage switch is the same opt-in the store enforces.
    await _send('${url}usage', form: <String, String>{'on': 'yes'});
    expect(store.usageOptIn, isTrue);
  });

  test('the session lists an agent the store saved, with no model call', () async {
    await _saved(store);
    final ToolRegistry registry = ToolRegistry(fakeTools(FakeDevice()));
    final ScriptedBackend backend = ScriptedBackend(const <String, String>{});
    final AgentSession session = AgentSession(
      planner: Planner(backend: backend, registry: registry),
      validator: PlanValidator(registry),
      executor: Executor(registry: registry, log: AgentActionLog()),
      records: store,
    );

    final AgentTurn turn = await session.say('what agents do I have');

    expect(turn.say, contains('Mail drafter'));
    expect(turn.say, contains('draft replies in my style'));
    expect(turn.say, contains('Runs 9:00-18:00 on weekdays'));
    expect(
      backend.prompts,
      isEmpty,
      reason: 'a question about local records is answered from the record',
    );
  });
}
