// The model manager: two models, one selection, two files.
//
// What matters here is not the picker's pixels (that is `main_ui_test.dart`) but
// the three things a wrong answer would break silently: the preference that
// remembers the choice, the file each choice reads and writes, and whether the
// brain follows the selection rather than the model it was built with.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/llm.dart';
import 'package:nexus/core/on_device_ai_service.dart';
import 'package:nexus/core/on_device_model.dart';

/// A fetcher that stands in for `Llm.download`: it writes the file the *model*
/// names, which is the one thing about a download these tests are checking.
class _FakeDownloader extends Llm {
  _FakeDownloader({required super.model, required this.dir})
    : super(modelsDir: () async => dir);

  final Directory dir;

  @override
  Future<bool> download({void Function(double progress)? onProgress}) async {
    onProgress?.call(1);
    File('${dir.path}/${model.name}.gguf').writeAsBytesSync(<int>[1, 2, 3]);
    return true;
  }

  bool disposed = false;

  @override
  Future<void> dispose() async => disposed = true;
}

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nexus_models');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  File fileFor(OnDeviceModelChoice choice) => File('${dir.path}/${choice.fileName}');

  group('the two choices', () {
    test('are the two models the app offers, with their sizes and files', () {
      expect(OnDeviceModelChoice.values, <OnDeviceModelChoice>[
        OnDeviceModelChoice.qwen,
        OnDeviceModelChoice.llama,
      ]);

      // The first model keeps the file name every installed phone already has:
      // renaming it would turn a downloaded 470 MB into a download.
      expect(OnDeviceModelChoice.qwen.fileName, 'model.gguf');
      expect(OnDeviceModelChoice.qwen.fileName, kOnDeviceModelFileName);
      expect(OnDeviceModelChoice.qwen.bytes, kPhoneModel.bytes);

      expect(
        OnDeviceModelChoice.llama.fileName,
        'llama-3.2-1b-instruct-q4_k_m.gguf',
      );
      expect(OnDeviceModelChoice.llama.bytes, kLlamaModel.bytes);
      expect(
        OnDeviceModelChoice.llama.bytes,
        greaterThan(OnDeviceModelChoice.qwen.bytes),
        reason: 'the smarter model is the bigger one',
      );
      // 770 MiB of weights, against 469 MiB — the numbers the picker shows.
      expect(OnDeviceModelChoice.llama.megabytes, 771);
      expect(OnDeviceModelChoice.qwen.megabytes, 469);
    });

    test('the llama weights are a pinned, hashed download', () {
      final LlmModel llama = OnDeviceModelChoice.llama.weights;
      expect(llama.url, startsWith('https://huggingface.co/'));
      expect(llama.url, contains('Llama-3.2-1B-Instruct-Q4_K_M.gguf'));
      expect(
        llama.url,
        contains('/resolve/b69aef112e9f895e6f98d7ae0949f72ff09aa401/'),
        reason: 'a pinned commit: a moving branch is a different file tomorrow',
      );
      expect(llama.sha256, hasLength(64));
      expect(llama.bytes, 807694368);
    });

    test('a stored id reads back as its choice, and junk reads as none', () {
      expect(
        OnDeviceModelChoice.byId(OnDeviceModelChoice.llama.id),
        OnDeviceModelChoice.llama,
      );
      expect(OnDeviceModelChoice.byId(null), isNull);
      expect(OnDeviceModelChoice.byId(''), isNull);
      expect(OnDeviceModelChoice.byId('a-model-this-build-never-had'), isNull);
    });
  });

  group('the selection', () {
    test('starts on the small model and survives a restart', () async {
      final MemoryModelChoiceStore store = MemoryModelChoiceStore();
      final ModelChoice first = ModelChoice(store: store);
      await first.ensureLoaded();
      expect(first.choice, OnDeviceModelChoice.qwen);

      await first.select(OnDeviceModelChoice.llama);
      expect(first.choice, OnDeviceModelChoice.llama);

      // A second object over the same store is what the next launch sees.
      final ModelChoice second = ModelChoice(store: store);
      expect(
        second.choice,
        OnDeviceModelChoice.qwen,
        reason: 'nothing is read until ensureLoaded, so the default is the '
            'answer before the preference has landed',
      );
      await second.ensureLoaded();
      expect(second.choice, OnDeviceModelChoice.llama);
    });

    test('a preference this build does not know leaves the default alone', () async {
      final ModelChoice choice = ModelChoice(
        store: MemoryModelChoiceStore('some-other-model'),
      );
      await choice.ensureLoaded();
      expect(choice.choice, OnDeviceModelChoice.qwen);
    });

    test('tells its listeners once per real change, and not at all for a no-op',
        () async {
      final ModelChoice choice = ModelChoice(store: MemoryModelChoiceStore());
      int notified = 0;
      choice.addListener(() => notified++);

      await choice.select(OnDeviceModelChoice.qwen);
      expect(notified, 0, reason: 'already selected');

      await choice.select(OnDeviceModelChoice.llama);
      expect(notified, 1);

      await choice.select(OnDeviceModelChoice.llama);
      expect(notified, 1);
    });
  });

  group('the file each choice owns', () {
    test('a model reads, downloads and deletes only its own file', () async {
      final OnDeviceModel llama = OnDeviceModel(
        choice: OnDeviceModelChoice.llama,
        directory: () async => dir,
        engine: () => _FakeDownloader(
          model: OnDeviceModelChoice.llama.weights,
          dir: dir,
        ),
      );

      expect(await llama.isPresent(), isFalse);
      expect(await llama.download(), isTrue);
      expect(fileFor(OnDeviceModelChoice.llama).existsSync(), isTrue);
      expect(
        fileFor(OnDeviceModelChoice.qwen).existsSync(),
        isFalse,
        reason: 'downloading one model must not touch the other one',
      );
      expect(await llama.isPresent(), isTrue);
      expect(llama.label, 'Llama 3.2 1B');

      // Both on disk at once: that is what two models is.
      File('${dir.path}/model.gguf').writeAsBytesSync(<int>[9]);
      expect(await llama.delete(), 3);
      expect(fileFor(OnDeviceModelChoice.llama).existsSync(), isFalse);
      expect(
        fileFor(OnDeviceModelChoice.qwen).existsSync(),
        isTrue,
        reason: 'the model that was not asked about is untouched',
      );
    });

    test('with no choice named it is about whichever is selected', () async {
      final ModelChoice choice = ModelChoice(store: MemoryModelChoiceStore());
      ModelChoice.override = () => choice;
      addTearDown(() {
        ModelChoice.override = null;
        ModelChoice.debugReset();
      });

      final OnDeviceModel model = OnDeviceModel(directory: () async => dir);
      expect(model.choice, OnDeviceModelChoice.qwen);
      expect(await model.file(), isA<File>().having(
        (File f) => f.path,
        'path',
        endsWith('/model.gguf'),
      ));

      await choice.select(OnDeviceModelChoice.llama);
      expect(model.choice, OnDeviceModelChoice.llama);
      expect(await model.file(), isA<File>().having(
        (File f) => f.path,
        'path',
        endsWith('/llama-3.2-1b-instruct-q4_k_m.gguf'),
      ));
      expect(model.label, 'Llama 3.2 1B');
    });
  });

  group('the brain follows the selection', () {
    test('a service built for the default model looks for the selected file',
        () async {
      final ModelChoice choice = ModelChoice(store: MemoryModelChoiceStore());
      ModelChoice.override = () => choice;
      addTearDown(() {
        ModelChoice.override = null;
        ModelChoice.debugReset();
      });

      // Only the 1B is on the disk.
      File('${dir.path}/llama-3.2-1b-instruct-q4_k_m.gguf')
          .writeAsBytesSync(<int>[1, 2, 3]);

      final OnDeviceAiService brain = OnDeviceAiService(
        model: OnDeviceModel(directory: () async => dir),
      );

      await choice.select(OnDeviceModelChoice.llama);
      expect(
        await brain.isModelPresent(),
        isTrue,
        reason: 'the service follows the picker, not the model it was built '
            'with — otherwise a switch would need a restart',
      );

      await choice.select(OnDeviceModelChoice.qwen);
      expect(await brain.isModelPresent(), isFalse);
    });

    test('an engine the caller supplied is the one that is released', () async {
      final ModelChoice choice = ModelChoice(store: MemoryModelChoiceStore());
      ModelChoice.override = () => choice;
      addTearDown(() {
        ModelChoice.override = null;
        ModelChoice.debugReset();
      });
      final _FakeDownloader fake = _FakeDownloader(
        model: kOnDeviceLlmModel,
        dir: dir,
      );
      final OnDeviceAiService brain = OnDeviceAiService(
        model: OnDeviceModel(directory: () async => dir),
        llm: fake,
      );
      // A supplied engine belongs to the caller's world — a fake runtime in a
      // test — and it must be the one used for every model, including after a
      // switch, or the test's fake would be silently replaced by a real engine.
      await choice.select(OnDeviceModelChoice.llama);
      await brain.dispose();
      expect(fake.disposed, isTrue);
    });
  });
}
