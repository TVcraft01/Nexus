// Live tool probe: the real model, the product's own loop, a real folder.
//
// The one question a unit test cannot answer: can the model that ships in the
// app actually write a `TOOL:` line the loop understands — and when it does,
// does the loop turn it into a real file listing and an answer a person could
// read? This runs [Llm] fetching and verifying the pinned model files, then
// [ToolLoop] against [LocalModelBrain] and a real Downloads folder, and prints
// every step: the model's raw words, what the parser made of them, what the
// gate decided, and the answer the loop produced.
//
// Not part of the suite (no `_test` suffix, the same rule as
// test/llm_live_smoke.dart): it downloads ~1.5 GB on a first run and needs
// minutes of CPU. Run it explicitly:
//
//   flutter test test/llm_tool_probe.dart
//
// NEXUS_MODEL_DIR caches the model files (default /tmp/nexus_models).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent_loop.dart';
import 'package:nexus/core/agent_tools.dart';
import 'package:nexus/core/brain.dart';
import 'package:nexus/core/llm.dart';
import 'package:nexus/core/local_model_brain.dart';

const _persona =
    'You are Nexus, a concise local assistant on the user\'s own devices.';

/// One probe line. A helper so the lint ignore has one home, not one per fact.
void _say(String line) {
  // ignore: avoid_print
  print(line);
}

/// Runs both questions against one model: the file ask (a tool is available
/// and is the point) and a plain hello (nothing should run).
Future<void> _probe(LlmModel model, String label) async {
  final dir = Directory(
    Platform.environment['NEXUS_MODEL_DIR'] ?? '/tmp/nexus_models',
  )..createSync(recursive: true);
  // The folder the listing reads, with the names a real one would have.
  final downloads = Directory.systemTemp.createTempSync('nexus_tool_probe');
  File('${downloads.path}/report.pdf').writeAsStringSync('x');
  File('${downloads.path}/holiday.jpg').writeAsStringSync('x');
  Directory('${downloads.path}/invoices').createSync();

  final llm = Llm(
    model: model,
    modelsDir: () async => dir,
    idleTimeout: const Duration(minutes: 2),
  );
  _say('$label FETCHING ${model.url}');
  final started = DateTime.now();
  await llm.warmUp();
  _say(
    '$label READY status=${llm.status} '
    'in ${DateTime.now().difference(started).inSeconds}s',
  );
  if (llm.status != LlmStatus.ready) {
    _say('$label could not load on this machine — no probe');
    await llm.dispose();
    return;
  }

  final brain = LocalModelBrain(llm: llm);
  final runner = LocalToolRunner(
    roots: () async => {
      'downloads': downloads.path,
      'documents': '',
      'pictures': '',
    },
    fetch: (name, from) async => 'No paired device in this probe.',
  );

  for (final ask in const ['what is in my downloads?', 'hello']) {
    final history = <ChatTurn>[(role: 'user', content: ask)];

    // What the model wrote, verbatim — the fact this probe exists to show.
    final raw = await brain.reply(
      system: toolSystemPrompt(_persona),
      history: history,
      maxTokens: 200,
    );
    final request = readToolRequest(raw.text ?? '');
    final call = request.call;
    _say('$label ASK "$ask"');
    _say('$label   RAW ${raw.text == null ? '(nothing)' : '"${raw.text}"'}');
    _say(
      '$label   PARSED ${call == null ? 'no tool' : '${call.name} ${call.arguments}'}',
    );
    if (call != null) {
      final refusal = toolRefusal(call, ask);
      _say('$label   GATE ${refusal ?? 'allowed'}');
    }

    // Then the loop itself — what the assistant would really answer.
    final reply = await ToolLoop(brain: brain, tools: runner).run(
      system: _persona,
      ask: ask,
      history: history,
      maxTokens: 200,
    );
    _say(
      '$label   LOOP ran=${reply.ran} reachable=${reply.reachable} '
      'answer="${reply.text}"',
    );
  }

  await llm.dispose();
  downloads.deleteSync(recursive: true);
}

void main() {
  test('live: the desktop model can call a tool', () async {
    await _probe(kDesktopModel, 'DESKTOP-1.5B');
  }, timeout: const Timeout(Duration(minutes: 45)));

  test('live: the phone model can call a tool', () async {
    await _probe(kPhoneModel, 'PHONE-0.5B');
  }, timeout: const Timeout(Duration(minutes: 30)));
}
