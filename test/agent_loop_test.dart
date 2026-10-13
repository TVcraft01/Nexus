// The agent loop, end to end in core: the model asks for a tool in its own
// words, the tool runs (a real folder listing, a spy fetch), what it found is
// handed back to the model, and the answer the user sees carries it.
//
// The four contracts this pins:
//   * an ask the model answers with list_local_files lists the *real* folder
//     and the real names reach the answer;
//   * "hello" is answered with no tool and one brain call;
//   * a tool the ask did not imply never runs, whatever the model wrote;
//   * a fumbled TOOL line falls back to a plain answer instead of crashing.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent_contract.dart';
import 'package:nexus/core/agent_loop.dart';
import 'package:nexus/core/agent_tools.dart';
import 'package:nexus/core/brain.dart';
import 'package:nexus/core/conversation.dart';
import 'package:nexus/core/conversation_engine.dart';

/// A brain whose replies are scripted, one per ask: either a fixed line, or a
/// function of the exchange it was handed — which is how a test proves what
/// the model was shown. Past the script it answers with nothing, the way a
/// model with nothing to say does.
class _ScriptedBrain extends LocalBrain {
  _ScriptedBrain(this.script);

  final List<Object> script;
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
    final entry = script[index];
    final text = entry is String
        ? entry
        : (entry as String Function(String, List<ChatTurn>))(system, history);
    // The seam's own contract: an empty reply is no reply, reachable or not.
    return (text: text.isEmpty ? null : text, reachable: true);
  }
}

/// A runner that records what it was asked. What it answers with never
/// matters: every test with a spy asserts the call was *not* made.
class _SpyRunner implements ToolRunner {
  final List<ToolCall> calls = [];

  @override
  Future<String> run(ToolCall call) async {
    calls.add(call);
    return 'nothing here';
  }
}

/// A runner held open until the test releases it — the window in which the
/// card says what is running.
class _GatedRunner implements ToolRunner {
  final calls = <ToolCall>[];
  final _gate = Completer<String>();

  @override
  Future<String> run(ToolCall call) {
    calls.add(call);
    return _gate.future;
  }

  void finish(String observation) => _gate.complete(observation);
}

/// The observation out of the history turn the loop handed the model,
/// stripped of the loop's own protocol markers.
String _observationIn(List<ChatTurn> history) =>
    history.last.content.split('\n').first.substring(toolResultPrefix.length);

void main() {
  test('the model lists the real Downloads folder and the names reach '
      'the answer', () async {
    final downloads = Directory.systemTemp.createTempSync('nexus_agent_tools');
    addTearDown(() => downloads.deleteSync(recursive: true));
    File('${downloads.path}/report.pdf').writeAsStringSync('x');
    File('${downloads.path}/holiday.jpg').writeAsStringSync('x');
    Directory('${downloads.path}/invoices').createSync();

    final runner = LocalToolRunner(
      roots: () async => {
        'downloads': downloads.path,
        'documents': '',
        'pictures': '',
      },
      fetch: (name, from) async => 'unused',
    );
    final brain = _ScriptedBrain([
      'TOOL:list_local_files {"dir": "Downloads"}',
      (system, history) => 'You have: ${_observationIn(history)}',
    ]);

    final reply = await ToolLoop(brain: brain, tools: runner).run(
      system: 'You are Nexus.',
      ask: 'what is in my downloads',
      history: const [(role: 'user', content: 'what is in my downloads')],
    );

    expect(reply.ran, ['list_local_files']);
    expect(
      reply.text,
      allOf(
        contains('report.pdf'),
        contains('holiday.jpg'),
        contains('invoices/'),
      ),
      reason: 'the real names have to survive the round trip into the answer',
    );
    // The model was shown the tool's finding — that turn is the loop.
    expect(brain.asks, hasLength(2));
    expect(brain.asks.last.history.last.content, startsWith(toolResultPrefix));
    expect(brain.asks.last.history.last.content, contains('report.pdf'));
    // And it was told the protocol it is expected to obey.
    expect(brain.asks.first.system, contains('TOOL:'));
    expect(brain.asks.first.system, contains('list_local_files'));
  });

  test('a plain hello is answered by the model alone, with no tool', () async {
    final runner = _SpyRunner();
    final brain = _ScriptedBrain(['Hi! How can I help?']);

    final reply = await ToolLoop(brain: brain, tools: runner).run(
      system: 'You are Nexus.',
      ask: 'hello',
      history: const [(role: 'user', content: 'hello')],
    );

    expect(reply.text, 'Hi! How can I help?');
    expect(reply.ran, isEmpty);
    expect(runner.calls, isEmpty);
    expect(brain.asks, hasLength(1), reason: 'one ask, one answer');
  });

  test('a tool the ask did not imply never runs, whatever the model wrote',
      () async {
    final runner = _SpyRunner();
    final brain = _ScriptedBrain([
      'TOOL:list_local_files {"dir": "Downloads"}',
    ]);

    final reply = await ToolLoop(brain: brain, tools: runner).run(
      system: 'You are Nexus.',
      ask: 'delete everything',
      history: const [(role: 'user', content: 'delete everything')],
    );

    expect(runner.calls, isEmpty);
    expect(reply.ran, isEmpty);
    // The whole reply was protocol, so there is nothing left to say and the
    // caller's own card (the teach question) stands.
    expect(reply.text, isNull);
  });

  test('a fumbled TOOL line falls back to a plain answer', () async {
    final runner = _SpyRunner();

    // Broken JSON: the line is protocol and is dropped; only the model's own
    // words are left to answer with.
    final withWords = await ToolLoop(
      brain: _ScriptedBrain(['Sorry — TOOL:list_local_files {oops']),
      tools: runner,
    ).run(
      system: 'You are Nexus.',
      ask: 'what is in my downloads',
      history: const [(role: 'user', content: 'what is in my downloads')],
    );
    expect(withWords.text, 'Sorry —');
    expect(runner.calls, isEmpty);

    // Pure protocol and nothing else: the model is asked once more without
    // the tool block — its chance to just answer — and with nothing to say
    // even then, the exchange falls back rather than showing a broken line.
    final silent = _ScriptedBrain(['TOOL:list_local_files {oops']);
    final onlyProtocol = await ToolLoop(brain: silent, tools: runner).run(
      system: 'You are Nexus.',
      ask: 'what is in my downloads',
      history: const [(role: 'user', content: 'what is in my downloads')],
    );
    expect(onlyProtocol.text, isNull);
    expect(onlyProtocol.reachable, isTrue);
    expect(silent.asks, hasLength(2));
    expect(
      silent.asks.last.system,
      isNot(contains('TOOL:')),
      reason: 'the retry must not invite another tool call',
    );

    // A tool that does not exist can never run — there is nothing to run.
    final invented = await ToolLoop(
      brain: _ScriptedBrain(['TOOL:delete_everything {"what": "everything"}']),
      tools: runner,
    ).run(
      system: 'You are Nexus.',
      ask: 'delete everything',
      history: const [(role: 'user', content: 'delete everything')],
    );
    expect(invented.text, isNull);
    expect(runner.calls, isEmpty);
  });

  test('a refused call still gets a plain answer from the model', () async {
    // The small-model failure this exists for: the 0.5B copies the prompt's
    // example even on "hello", so the gate refuses the call. Refusing must
    // not turn a greeting into a teach card — the model is asked once more
    // with no tools in sight, and its words are the answer.
    final runner = _SpyRunner();
    final brain = _ScriptedBrain([
      'TOOL:list_local_files {"dir": "Downloads"}',
      'Hello! How can I help?',
    ]);

    final reply = await ToolLoop(brain: brain, tools: runner).run(
      system: 'You are Nexus.',
      ask: 'hello',
      history: const [(role: 'user', content: 'hello')],
    );

    expect(reply.text, 'Hello! How can I help?');
    expect(reply.ran, isEmpty);
    expect(runner.calls, isEmpty);
    expect(brain.asks, hasLength(2));
    expect(brain.asks.first.system, contains('TOOL:'));
    expect(brain.asks.last.system, isNot(contains('TOOL:')));
  });

  test('the card names the folder while the tool runs, then the answer '
      'replaces it', () async {
    final runner = _GatedRunner();
    final brain = _ScriptedBrain([
      'TOOL:list_local_files {"dir": "Downloads"}',
      (system, history) => 'In Downloads: ${_observationIn(history)}',
    ]);
    final engine = ConversationEngine();
    addTearDown(engine.dispose);

    final exchange = engine.converse(
      brain: brain,
      input: 'what is in my downloads',
      original: const AgentDispatchResult(
        status: AgentResultStatus.needsInfo,
        dispatch: AgentClarification(
          question: 'What should "what is in my downloads" mean?',
          key: 'teach:what is in my downloads',
        ),
      ),
      context: () => const ConversationContext(),
      tools: runner,
    );

    // The window a person watches: the tool is running and the card says
    // what it is doing, as work in flight rather than an outcome.
    await pumpEventQueue();
    expect(runner.calls, hasLength(1));
    expect(ConversationEngine.speakableText(engine.last!), 'Looking in Downloads…');
    expect(engine.last!.pending, isTrue);

    runner.finish('The Downloads folder has 1 item: report.pdf.');
    await exchange;

    // One card, swapped twice: the answer landed on the card that named the
    // tool instead of appending a second one.
    expect(engine.entries.where((e) => e.result != null), hasLength(1));
    expect(engine.last!.pending, isFalse);
    expect(ConversationEngine.speakableText(engine.last!), contains('report.pdf'));
  });

  test('the listing tells emptiness, absence and unreadability apart',
      () async {
    final downloads = Directory.systemTemp.createTempSync('nexus_agent_empty');
    final missing = Directory.systemTemp.createTempSync('nexus_agent_missing');
    addTearDown(() {
      downloads.deleteSync(recursive: true);
      missing.deleteSync(recursive: true);
    });
    final runner = LocalToolRunner(
      roots: () async => {
        'downloads': '${downloads.path}/gone',
        'documents': '',
        'pictures': missing.path,
      },
      fetch: (name, from) async => 'unused',
    );

    expect(
      await runner.run(const ToolCall(NexusTool.listLocalFiles, {'dir': 'Pictures'})),
      'The Pictures folder is empty.',
    );
    expect(
      await runner.run(const ToolCall(NexusTool.listLocalFiles, {'dir': 'Downloads'})),
      'There is no Downloads folder here yet.',
    );
    expect(
      await runner.run(const ToolCall(NexusTool.listLocalFiles, {'dir': 'Documents'})),
      "I can't see the Documents folder on this device.",
    );
    expect(
      await runner.run(const ToolCall(NexusTool.listLocalFiles)),
      'Which folder? I can look in Downloads, Documents or Pictures.',
    );
    expect(
      await runner.run(const ToolCall(NexusTool.listLocalFiles, {'dir': 'Desktop'})),
      startsWith('Which folder?'),
    );
  });

  test('get_file hands the fetch the file and the bare device', () async {
    final asked = <(String, String?)>[];
    final runner = LocalToolRunner(
      roots: () async => const {},
      fetch: (name, from) async {
        asked.add((name, from));
        return 'Saved $name.';
      },
    );

    expect(
      await runner.run(
        const ToolCall(NexusTool.getFile, {
          'name': 'report.pdf',
          'from': 'my PC',
        }),
      ),
      'Saved report.pdf.',
    );
    expect(asked, [('report.pdf', 'PC')]);
    // A fetch the model did not name a device for asks the service to choose,
    // exactly like a typed "get report.pdf".
    await runner.run(const ToolCall(NexusTool.getFile, {'name': 'notes.txt'}));
    expect(asked.last, ('notes.txt', null));
  });
}
