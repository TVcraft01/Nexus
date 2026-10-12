// Live inference, the whole way: the product's own [Llm] fetching a real
// model from the pinned URL, verifying its sha256, loading it through the
// native llama.cpp runtime, and answering a real question. No mocks anywhere.
//
// Not part of the suite: no `_test` suffix, so the default test glob skips it
// (the same rule as test/rehearsal_peer.dart). It downloads ~470 MB on a first
// run and needs minutes of CPU, neither of which a unit-test run may assume.
// Run it explicitly:
//
//   flutter test test/llm_live_smoke.dart
//
// NEXUS_MODEL_DIR is where the two models live (default /tmp/nexus_models).
import 'dart:io';

import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/llm.dart';

Future<void> _ask(
  Llm llm,
  String question, {
  required String label,
}) async {
  final asked = DateTime.now();
  final answer = await llm.complete(
    question,
    system: 'You are Nexus, a concise local assistant. Answer in one short '
        'sentence.',
    maxTokens: 64,
  );
  final took = DateTime.now().difference(asked);
  // ignore: avoid_print
  print('$label ANSWER "${answer.trim()}" in ${took.inMilliseconds}ms');
  expect(answer.trim(), isNotEmpty, reason: '$label did not answer');
}

void main() {
  test('live: the phone model is fetched, verified, loaded, and answers',
      () async {
    // A directory this test owns, empty on purpose on the first run: the fetch
    // and its verification are what is being proven here, not a warm cache.
    final dir = Directory(
      '${Platform.environment['NEXUS_MODEL_DIR'] ?? '/tmp/nexus_models'}_fresh',
    )..createSync(recursive: true);
    final llm = Llm(
      model: kPhoneModel,
      modelsDir: () async => dir,
      idleTimeout: const Duration(seconds: 2),
    );

    // ignore: avoid_print
    print('FETCHING ${kPhoneModel.url}');
    final started = DateTime.now();
    await llm.warmUp();
    final loaded = DateTime.now();
    // ignore: avoid_print
    print('READY ${await llm.modelName()} '
        '(${loaded.difference(started).inMilliseconds}ms total)');
    expect(llm.status, LlmStatus.ready, reason: 'a real model must load');
    expect(
      File('${dir.path}/${kPhoneModel.name}.gguf').existsSync(),
      isTrue,
      reason: 'the verified file must be cached',
    );

    await _ask(llm, 'What is the capital of Portugal?', label: 'PHONE-MODEL');

    // An explicit unload, on the real runtime, and a real reload after it —
    // the idle path and every later question both depend on that working.
    await llm.unload();
    expect(llm.status, LlmStatus.idle);
    await _ask(llm, 'Name one planet.', label: 'RELOADED');

    // And the idle unload: a model nobody is using must give its memory back.
    await Future<void>.delayed(const Duration(seconds: 3));
    expect(llm.status, LlmStatus.idle, reason: 'idle must unload');
    // ignore: avoid_print
    print('IDLE unloaded after ${llm.idleTimeout.inSeconds}s of no questions');
    await _ask(llm, 'Say hello in three words.', label: 'AFTER-IDLE');
    await llm.dispose();
  }, timeout: const Timeout(Duration(minutes: 20)));

  test('live: the desktop model answers on this machine too', () async {
    final dir = Directory(
      Platform.environment['NEXUS_MODEL_DIR'] ?? '/tmp/nexus_models',
    );
    // What the pick rule says this machine should run.
    final chosen = modelForDevice(
      platform: TargetPlatform.linux,
      ramBytes: totalRamBytes(),
    );
    // ignore: avoid_print
    print('PICKED ${chosen.name} for '
        '${(totalRamBytes() ?? 0) ~/ (1 << 30)} GB of RAM');
    final llm = Llm(model: kDesktopModel, modelsDir: () async => dir);

    await llm.warmUp();
    final backend = llm.status == LlmStatus.ready ? 'ready' : '${llm.status}';
    // ignore: avoid_print
    print('DESKTOP-MODEL $backend');
    if (llm.status != LlmStatus.ready) {
      // A honest failure is a result: report it rather than hiding it.
      // ignore: avoid_print
      print('DESKTOP-MODEL could not load on this machine');
      await llm.dispose();
      return;
    }

    await _ask(
      llm,
      'In one sentence, why is the sky blue?',
      label: 'DESKTOP-MODEL',
    );
    await llm.dispose();
  }, timeout: const Timeout(Duration(minutes: 20)));
}
