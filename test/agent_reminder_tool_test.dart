// The set_reminder tool, end to end in core: the model names what and when
// in its own words, the runner registers with the real engine, what it
// found is handed back to the model, and the answer the user sees carries
// the time. Plus the parser's three time forms and the spent-mark rule.
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent_loop.dart';
import 'package:nexus/core/agent_tools.dart';
import 'package:nexus/core/brain.dart';
import 'package:nexus/core/reminders.dart';

/// A brain whose replies are scripted, one per ask — the same shape as the
/// agent loop test's, local so this file stands alone.
class _ScriptedBrain extends LocalBrain {
  _ScriptedBrain(this.script);

  final List<String Function()> script;
  final List<({String system, List<ChatTurn> history})> asks = [];

  @override
  Future<String?> availableModel({bool refresh = false}) async => 'qwen2.5';

  @override
  Future<BrainReply> reply({
    required String system,
    required List<ChatTurn> history,
    double temperature = 0.7,
    int maxTokens = 300,
  }) async {
    final index = asks.length;
    asks.add((system: system, history: history));
    if (index >= script.length) return (text: null, reachable: true);
    final text = script[index]();
    return (text: text.isEmpty ? null : text, reachable: true);
  }
}

/// A runner wired like the product: the real engine behind the remind seam.
/// What the engine says is what the model is told.
LocalToolRunner _runner(ReminderEngine engine) => LocalToolRunner(
  fetch: (name, from) async => 'unused',
  remind: (what, when) async {
    engine.register(what, when);
    return 'Reminder set for ${reminderClockLabel(when)} — I\'ll tell you then.';
  },
);

/// Runs one ask through the loop: the scripted tool line, then the model's
/// answer from the observation.
Future<ToolLoopReply> _ask(
  _ScriptedBrain brain,
  ToolRunner runner,
  String ask,
) => ToolLoop(brain: brain, tools: runner).run(
  system: 'You are Nexus.',
  ask: ask,
  history: [(role: 'user', content: ask)],
);

void main() {
  // Saturday 8:00am — "at 6pm" is later today, never ambiguous.
  final t0 = DateTime(2026, 9, 6, 8);

  test('"remind me to take milk at 6pm" emits the tool and stores it', () async {
    Reminders.nowOverride = () => t0;
    addTearDown(() => Reminders.nowOverride = null);
    final engine = ReminderEngine();
    addTearDown(engine.dispose);
    final brain = _ScriptedBrain([
      () => 'TOOL:set_reminder {"what": "take milk", "when": "18:00"}',
      () => 'Set for this evening.',
    ]);

    final reply = await _ask(
      brain,
      _runner(engine),
      'remind me to take milk at 6pm',
    );

    expect(reply.ran, ['set_reminder']);
    expect(engine.reminders, hasLength(1));
    expect(engine.reminders.single.text, 'take milk');
    expect(engine.reminders.single.dueAt, DateTime(2026, 9, 6, 18));
    expect(engine.reminders.single.fired, isFalse);
    expect(brain.asks.first.system, contains('set_reminder'));
  });

  test('"remind me in 20 minutes to call mom" stores a future time', () async {
    Reminders.nowOverride = () => t0;
    addTearDown(() => Reminders.nowOverride = null);
    final engine = ReminderEngine();
    addTearDown(engine.dispose);
    final brain = _ScriptedBrain([
      () => 'TOOL:set_reminder {"what": "call mom", "when": "in 20 minutes"}',
      () => 'Set.',
    ]);

    final reply = await _ask(
      brain,
      _runner(engine),
      'remind me in 20 minutes to call mom',
    );

    expect(reply.ran, ['set_reminder']);
    expect(engine.reminders, hasLength(1));
    expect(engine.reminders.single.text, 'call mom');
    expect(
      engine.reminders.single.dueAt,
      t0.add(const Duration(minutes: 20)),
    );
  });

  test('"remind me tomorrow at 9 to send the report" stores tomorrow', () async {
    Reminders.nowOverride = () => t0;
    addTearDown(() => Reminders.nowOverride = null);
    final engine = ReminderEngine();
    addTearDown(engine.dispose);
    final brain = _ScriptedBrain([
      () =>
          'TOOL:set_reminder {"what": "send the report", "when": "tomorrow at 9"}',
      () => 'Set.',
    ]);

    final reply = await _ask(
      brain,
      _runner(engine),
      'remind me tomorrow at 9 to send the report',
    );

    expect(reply.ran, ['set_reminder']);
    expect(engine.reminders, hasLength(1));
    expect(engine.reminders.single.dueAt, DateTime(2026, 9, 7, 9));
  });

  test('a fired reminder is marked fired and never re-fires', () async {
    Reminders.nowOverride = () => t0;
    addTearDown(() => Reminders.nowOverride = null);
    final engine = ReminderEngine();
    addTearDown(engine.dispose);
    final fired = <Reminder>[];
    final persisted = <List<Reminder>>[];
    engine.onFired = fired.add;
    engine.onPersist = persisted.add;

    engine.register('take milk', DateTime(2026, 9, 6, 18));
    expect(engine.reminders.single.fired, isFalse);

    Reminders.nowOverride = () => DateTime(2026, 9, 6, 18, 1);
    engine.check();
    expect(fired, hasLength(1));
    expect(engine.reminders.single.fired, isTrue);
    expect(persisted.last.single.fired, isTrue);

    // An hour later, and after a reseed from the spent store line: silence.
    Reminders.nowOverride = () => DateTime(2026, 9, 6, 19);
    engine.check();
    expect(fired, hasLength(1), reason: 'one shot — no re-fire');
    final fresh = ReminderEngine();
    addTearDown(fresh.dispose);
    fresh.onFired = fired.add;
    fresh.seed(persisted.last.map((r) => '{"id":"${r.id}","text":"${r.text}",'
        '"dueAt":"${r.dueAt.toIso8601String()}","fired":true}'));
    fresh.check();
    expect(fired, hasLength(1), reason: 'a spent seed never rings');
  });

  test('a "when" the tool cannot place asks the user instead of guessing', () async {
    Reminders.nowOverride = () => t0;
    addTearDown(() => Reminders.nowOverride = null);
    final engine = ReminderEngine();
    addTearDown(engine.dispose);
    final brain = _ScriptedBrain([
      () => 'TOOL:set_reminder {"what": "take milk", "when": "whenever"}',
      () => 'What time?',
    ]);

    final reply = await ToolLoop(brain: brain, tools: _runner(engine)).run(
      system: 'You are Nexus.',
      ask: 'remind me to take milk whenever',
      history: const [(role: 'user', content: 'remind me to take milk whenever')],
    );

    expect(reply.ran, ['set_reminder']);
    expect(engine.reminders, isEmpty, reason: 'nothing stored on a guess');
    expect(
      brain.asks.last.history.last.content,
      contains('What time should I remind you to take milk?'),
    );
  });

  test('a set_reminder the ask did not imply never runs', () async {
    final engine = ReminderEngine();
    addTearDown(engine.dispose);
    var registered = 0;
    final runner = LocalToolRunner(
      fetch: (name, from) async => 'unused',
      remind: (what, when) async {
        registered++;
        return 'set';
      },
    );
    final brain = _ScriptedBrain([
      () => 'TOOL:set_reminder {"what": "x", "when": "18:00"}',
    ]);

    final reply = await ToolLoop(brain: brain, tools: runner).run(
      system: 'You are Nexus.',
      ask: 'hello',
      history: const [(role: 'user', content: 'hello')],
    );

    expect(registered, 0);
    expect(reply.ran, isEmpty);
  });

  test('parseReminderWhen: the three forms, the roll-forward, the refuse', () {
    // Absolute: already past rolls to tomorrow — never fires at once.
    expect(parseReminderWhen('18:00', t0), DateTime(2026, 9, 6, 18));
    expect(parseReminderWhen('6pm', t0), DateTime(2026, 9, 6, 18));
    expect(parseReminderWhen('6:30pm', t0), DateTime(2026, 9, 6, 18, 30));
    expect(
      parseReminderWhen('6am', t0),
      DateTime(2026, 9, 7, 6),
      reason: '6am already passed -> tomorrow',
    );
    expect(parseReminderWhen('at 6pm', t0), DateTime(2026, 9, 6, 18));
    // Relative.
    expect(
      parseReminderWhen('in 20 minutes', t0),
      t0.add(const Duration(minutes: 20)),
    );
    expect(
      parseReminderWhen('in 2 hours', t0),
      t0.add(const Duration(hours: 2)),
    );
    // Day-anchored.
    expect(parseReminderWhen('tomorrow at 9', t0), DateTime(2026, 9, 7, 9));
    expect(
      parseReminderWhen('tomorrow at 9:30pm', t0),
      DateTime(2026, 9, 7, 21, 30),
    );
    // Refusals: not a time, out of range, or empty.
    expect(parseReminderWhen('whenever', t0), isNull);
    expect(parseReminderWhen('at the store', t0), isNull);
    expect(parseReminderWhen('25:00', t0), isNull);
    expect(parseReminderWhen('in 0 minutes', t0), isNull);
    expect(parseReminderWhen('', t0), isNull);
  });
}
