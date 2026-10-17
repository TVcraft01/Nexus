// Where the brain status line says the answer will come from.
//
// One lie is worth a test: on a phone the brain is always a
// [DistributedBrain] — not because a PC is involved, but because Android
// cannot run Ollama — and since the model now ships inside the app, that
// brain answers with this device's own model. The line reported exactly that
// as "your PC (via mesh)", so the phone's user read that their words went to
// the PC while they never left the phone. Guards: _brainStatusLine in
// lib/ui/assistant_view.dart.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/brain.dart';
import 'package:nexus/core/distributed_brain.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/llm.dart';
import 'package:nexus/core/query_log.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/core/tiny_brain.dart';
import 'package:nexus/mesh/mesh_service.dart';
import 'package:nexus/ui/assistant_view.dart';
import 'package:nexus/ui/theme.dart';

/// A runtime that answers without a native library — this file is about the
/// status line, not about inference (test/llm_test.dart owns that).
class _FakeRuntime implements LlmRuntime {
  @override
  Future<void> load(
    String modelPath, {
    required int contextSize,
    required int threads,
  }) async {}

  @override
  Future<String> generate(
    List<ChatTurn> messages, {
    required int maxTokens,
    required double temperature,
  }) async => 'answered locally';

  @override
  Stream<String> generateStream(
    List<ChatTurn> messages, {
    required int maxTokens,
    required double temperature,
  }) async* {
    yield await generate(
      messages,
      maxTokens: maxTokens,
      temperature: temperature,
    );
  }

  @override
  Future<void> unload() async {}

  @override
  Future<void> dispose() async {}
}

/// A brain that answers from a paired device — the model name is the only
/// thing that says so, which is what the status line now reads.
class _MeshModelBrain extends LocalBrain {
  @override
  Future<String?> availableModel({bool refresh = false}) async => 'mesh:peer-pc';

  @override
  Future<BrainReply> reply({
    required String system,
    required List<ChatTurn> history,
    double temperature = 0.7,
    int maxTokens = 300,
  }) async => (text: 'from the pc', reachable: true);
}

Widget _harness(MeshService mesh, LocalBrain brain) => MaterialApp(
  theme: buildNexusTheme(),
  home: Scaffold(body: AssistantView(mesh: mesh, brain: brain)),
);

/// A temp models directory with (or without) the phone model's file cached.
Directory _modelsDir({required bool withModel}) {
  final dir = Directory.systemTemp.createTempSync('nexus_status_line');
  if (withModel) {
    File('${dir.path}/${kPhoneModel.name}.gguf').writeAsBytesSync([1, 2, 3]);
  }
  return dir;
}

void main() {
  testWidgets('a phone answering with its own model says so', (tester) async {
    final store = NexusStore(
      explicitPath:
          '${Directory.systemTemp.createTempSync('bsl_own').path}/s.json',
    )..clipboardSync = true;
    final mesh = MeshService(
      identity: DeviceInfo(id: 'test-phone', name: 'Test phone', platform: 'android'),
      store: store,
    );
    final dir = _modelsDir(withModel: true);
    final brain = DistributedBrain(
      mesh: mesh,
      tiny: TinyBrain(
        llm: Llm(
          model: kPhoneModel,
          runtime: _FakeRuntime(),
          modelsDir: () async => dir,
        ),
      ),
    );

    try {
      await tester.pumpWidget(_harness(mesh, brain));
      await tester.pump();

      // The model is on this device and nothing is paired, so the line
      // says so — and does not claim the answer will come from a PC.
      expect(find.textContaining('On this device'), findsOneWidget);
      expect(find.textContaining('your PC (via mesh)'), findsNothing);
      expect(find.textContaining('No model loaded'), findsNothing);
    } finally {
      QueryLog.i.resetForTest();
      await mesh.stop();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  testWidgets('a brain that really lives on the peer still says so',
      (tester) async {
    final store = NexusStore(
      explicitPath:
          '${Directory.systemTemp.createTempSync('bsl_mesh').path}/s.json',
    )..clipboardSync = true;
    final mesh = MeshService(
      identity: DeviceInfo(id: 'test-phone', name: 'Test phone', platform: 'android'),
      store: store,
    );

    try {
      await tester.pumpWidget(_harness(mesh, _MeshModelBrain()));
      await tester.pump();

      expect(find.textContaining('Brain: your PC (via mesh)'), findsOneWidget);
      expect(find.textContaining('Local brain:'), findsNothing);
    } finally {
      QueryLog.i.resetForTest();
      await mesh.stop();
    }
  });

  testWidgets('a phone with no model yet still offers the thing it can do',
      (tester) async {
    final store = NexusStore(
      explicitPath:
          '${Directory.systemTemp.createTempSync('bsl_none').path}/s.json',
    )..clipboardSync = true;
    final mesh = MeshService(
      identity: DeviceInfo(id: 'test-phone', name: 'Test phone', platform: 'android'),
      store: store,
    );
    final dir = _modelsDir(withModel: false);
    final brain = DistributedBrain(
      mesh: mesh,
      tiny: TinyBrain(
        llm: Llm(
          model: kPhoneModel,
          runtime: _FakeRuntime(),
          modelsDir: () async => dir,
        ),
      ),
    );

    try {
      await tester.pumpWidget(_harness(mesh, brain));
      await tester.pump();

      // No model, no peer: the phone-only line says so plainly — and never
      // "install Ollama", which a phone cannot do.
      expect(find.textContaining('No model loaded'), findsOneWidget);
      expect(find.textContaining('install Ollama'), findsNothing);
    } finally {
      QueryLog.i.resetForTest();
      await mesh.stop();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });
}
