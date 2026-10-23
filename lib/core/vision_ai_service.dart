// The eyes that actually see — a vision-language model on this phone, through
// llama.cpp.
//
// ML Kit reads text and names objects — fast, and blind to everything else. A
// photo of a room gets "Indoor, Table, Chair", which is a list, not a
// description. This service puts a VLM behind the same seam: the picture and the
// question go to the model together, and the answer is a sentence about the
// picture rather than a pile of labels a text model then guesses from.
//
// Two models, because one size did not fit. Moondream2 1.8B describes a scene
// well and needs ~1.3 GB of runtime memory; measured on an A25 (5.5 GB) it
// loaded, could not finish a generation, and Android's low-memory killer reaped
// the app. SmolVLM 500M is 545 MB of files and fits that phone. So the service
// prefers the model that fits the memory it has:
//
//   * Moondream2 when it is downloaded and there is room for its working set;
//   * SmolVLM when it is downloaded and Moondream is absent or too big;
//   * ML Kit when neither is installed, or neither fits.
//
// Three rules shape everything here:
//
//   * a VLM is optional. 1.8 GB (or 545 MB) of weights is a download the user
//     asks for, never one that happens behind a photo;
//   * a load that cannot fit is refused. Refusing to load is a sentence; being
//     killed mid-generation is a lost conversation with no answer saved;
//   * a failure is a sentence, never a throw. Every caller is drawing a bubble,
//     so an unreadable image, a model that will not load, or a projector the
//     runtime rejects all end in the fallback and, if that fails too, in words.
//
// Both pairs are pinned by URL and sha256 like every other model this app
// downloads: `Llm` owns download-and-verify, and this file points it at two
// names per model. Guards: test/vision_ai_service_test.dart.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:llamadart/llamadart.dart';
import 'package:path_provider/path_provider.dart';

import 'llm.dart';
import 'ml_vision_service.dart';
import 'on_device_ai_service.dart' show OnDeviceAiService;
import 'vision_ai.dart';

/// What Settings › Brain calls the small model.
const String kVisionSmallLabel = 'SmolVLM 500M';

/// What Settings › Brain calls the large one.
const String kVisionLargeLabel = 'Moondream2 1.8B';

/// What the question is when the user attached a picture and said nothing.
const String kVisionDescribePrompt =
    'Describe this image in one or two short sentences.';

/// How long an answer about a picture may be. A description is a sentence or
/// two; a model allowed 400 tokens answers with a paragraph the bubble clips.
const int kVisionMaxTokens = 160;

/// The longest edge the model is handed, in pixels.
///
/// The runtime does not resize media, and a 12 MP photo is 48 MB of decoded
/// pixels the phone would pay for to describe a room. 512 keeps the aspect ratio
/// and loses nothing either model can use; SmolVLM's own encoder works at 512.
const int kVisionImageEdge = 512;

/// A copy of [source] no larger than [kVisionImageEdge] on its long edge.
///
/// Null means "pass the original": the picture is already small enough, or it
/// could not be decoded (a corrupt file, a format `dart:ui` does not read) and
/// the model should be given the file the user chose rather than nothing. The
/// caller deletes the returned file's folder once the answer is in.
Future<File?> prepareVisionImage(String source) async {
  try {
    final Uint8List bytes = await File(source).readAsBytes();
    final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(
      bytes,
    );
    final ui.ImageDescriptor descriptor = await ui.ImageDescriptor.encoded(
      buffer,
    );
    if (math.max(descriptor.width, descriptor.height) <= kVisionImageEdge) {
      return null;
    }
    // The long edge is the one capped; the other follows the aspect ratio, so a
    // portrait and a landscape both fit in the same budget.
    final ui.Codec codec = descriptor.width >= descriptor.height
        ? await descriptor.instantiateCodec(targetWidth: kVisionImageEdge)
        : await descriptor.instantiateCodec(targetHeight: kVisionImageEdge);
    final ui.Image image = (await codec.getNextFrame()).image;
    final ByteData? png = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    image.dispose();
    if (png == null) return null;
    final Directory dir = Directory.systemTemp.createTempSync('nexus_vision');
    final File scaled = File('${dir.path}/photo.png');
    await scaled.writeAsBytes(
      png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
    );
    return scaled;
  } on Object catch (error) {
    debugPrint('VISION: could not prepare $source ($error)');
    return null;
  }
}

/// How long the weights stay loaded after the last picture.
///
/// The same trade as the chat brain's idle unload, shorter because this model is
/// bigger: hundreds of megabytes held for a follow-up question nobody may ask is
/// memory the rest of the phone wants back.
const Duration kVisionIdleUnload = Duration(minutes: 2);

/// One downloadable vision model: the text half, the projector that gives it
/// eyes, the memory it needs, and the prompt shape it was trained on.
///
/// The prompt is a property of the pair rather than a branch in the inference:
/// Moondream2 ships no chat template and answers a bare `Question:` line, while
/// SmolVLM expects its own `<|im_start|>User:` turn around the image. A model
/// added later brings its own format instead of editing a switch.
class VisionModelPair {
  const VisionModelPair({
    required this.id,
    required this.label,
    required this.blurb,
    required this.weights,
    required this.projector,
    required this.workingSetBytes,
    required this.prompt,
  });

  /// Stable across builds; used in logs and in the failed-load set.
  final String id;

  /// What the user reads.
  final String label;

  /// One line under it: what this model is for.
  final String blurb;

  /// The text half of the model.
  final LlmModel weights;

  /// The multimodal projector: the eyes.
  final LlmModel projector;

  /// Free memory required before loading, in bytes.
  ///
  /// Not the file size: llama.cpp maps the weights, so the bytes on disk are
  /// reclaimable page cache. What cannot be reclaimed is the KV cache, the image
  /// decode and the activations around them — plus enough left for Android not
  /// to reap the app.
  final int workingSetBytes;

  /// The whole prompt for [question], including the model's own turn markers.
  final String Function(String question) prompt;

  /// The weights' file on disk — the name [Llm] writes.
  String get weightsFileName => '${weights.name}.gguf';

  /// The projector's file on disk.
  String get projectorFileName => '${projector.name}.gguf';

  /// Both files together, in bytes — what the Settings row quotes.
  int get bytes => weights.bytes + projector.bytes;

  /// That size in megabytes, rounded up, the way every other row says it.
  int get megabytes => (bytes + 1024 * 1024 - 1) ~/ (1024 * 1024);
}

/// SmolVLM 500M-Instruct, Q8_0 with a Q8_0 projector: 545 MB of files.
///
/// The one this phone can hold. Prompt is the model's own chat template, with
/// `<image>` where the projector's marker belongs; llamadart rewrites that
/// placeholder to the marker the runtime reports.
const VisionModelPair kVisionSmall = VisionModelPair(
  id: 'smolvlm-500m',
  label: kVisionSmallLabel,
  blurb: 'Fast. Fits this phone.',
  weights: LlmModel(
    name: 'smolvlm-500m-instruct-q8_0',
    url:
        'https://huggingface.co/ggml-org/SmolVLM-500M-Instruct-GGUF/resolve/'
        '72e986006ef53e37cdd3f6d4241c90b0f01df376/'
        'SmolVLM-500M-Instruct-Q8_0.gguf',
    sha256: '9d4612de6a42214499e301494a3ecc2be0abdd9de44e663bda63f1152fad1bf4',
    bytes: 436806912,
  ),
  projector: LlmModel(
    name: 'mmproj-smolvlm-500m-instruct-q8_0',
    url:
        'https://huggingface.co/ggml-org/SmolVLM-500M-Instruct-GGUF/resolve/'
        '72e986006ef53e37cdd3f6d4241c90b0f01df376/'
        'mmproj-SmolVLM-500M-Instruct-Q8_0.gguf',
    sha256: 'd1eb8b6b23979205fdf63703ed10f788131a3f812c7b1f72e0119d5d81295150',
    bytes: 108783360,
  ),
  // Measured headroom: 545 MB of files plus KV cache, image encode and compute
  // buffers, with room left for the rest of the phone.
  workingSetBytes: 1024 * 1024 * 1024,
  prompt: _smolVlmPrompt,
);

/// Moondream2 1.8B, Q4_K with its f16 projector: 1745 MB of files.
///
/// The better describer, for a device that can spare the memory. Measured on the
/// A25 (5.5 GB): loading at 1.86 GB free succeeded, generation took the phone to
/// 0.59 GB, and the low-memory killer reaped the app before the answer — twice.
const VisionModelPair kVisionLarge = VisionModelPair(
  id: 'moondream2-1.8b',
  label: kVisionLargeLabel,
  blurb: 'Best descriptions. Needs about 2.5 GB free.',
  weights: LlmModel(
    name: 'moondream2-q4_k',
    url:
        'https://huggingface.co/salivosa/moondream2-gguf/resolve/'
        'd91951d08f2c19da126277e15137c3bcfd53597a/moondream2-q4_k.gguf',
    sha256: '77baaa54e41cbfc24e305ee15f58ff2aca198517f658368f1be072d07b51f99d',
    bytes: 919494048,
  ),
  projector: LlmModel(
    name: 'moondream2-mmproj-f16',
    url:
        'https://huggingface.co/salivosa/moondream2-gguf/resolve/'
        'd91951d08f2c19da126277e15137c3bcfd53597a/moondream2-mmproj-f16.gguf',
    sha256: '4cc1cb3660d87ff56432ebeb7884ad35d67c48c7b9f6b2856f305e39c38eed8f',
    bytes: 909777984,
  ),
  workingSetBytes: 2560 * 1024 * 1024,
  prompt: _moondreamPrompt,
);

/// The models this build knows, smallest first — the order Settings lists them
/// in.
const List<VisionModelPair> kVisionPairs = <VisionModelPair>[
  kVisionSmall,
  kVisionLarge,
];

String _smolVlmPrompt(String question) =>
    '<|im_start|>User:<image>$question<end_of_utterance>\nAssistant:';

String _moondreamPrompt(String question) =>
    '\n\nQuestion: $question\n\nAnswer:';

/// One file's fetch, as a test swaps it: answer true only when a verified file
/// is on disk.
typedef VisionFileFetcher = Future<bool> Function(
  LlmModel model, {
  void Function(double)? onProgress,
});

/// The two files behind [pair], and the only place that names them.
///
/// A file check, not a load: the Settings row asks this on every visit, and the
/// thread asks it before a photo. Neither may cost a model load.
class VisionModelFiles {
  const VisionModelFiles(this.pair, {this.directory, this.fetch});

  /// The model whose files these are.
  final VisionModelPair pair;

  /// Where the files live, or null for the app's documents directory. A test
  /// points this at a temp folder.
  final Future<Directory> Function()? directory;

  /// The fetch, or null for a real one through [Llm]. A test writes the file
  /// without a socket, which is how the row's states are walkable.
  final VisionFileFetcher? fetch;

  Future<Directory> directoryFor() async {
    final Future<Directory> Function()? chosen = directory;
    if (chosen != null) return chosen();
    return getApplicationDocumentsDirectory();
  }

  /// The text model's file, whether or not it exists.
  Future<File> weightsFile() async =>
      File('${(await directoryFor()).path}/${pair.weightsFileName}');

  /// The projector's file, whether or not it exists.
  Future<File> projectorFile() async =>
      File('${(await directoryFor()).path}/${pair.projectorFileName}');

  /// True only when *both* files are here and neither is empty.
  ///
  /// A model without its projector is a text model, and a half download is what
  /// a killed process leaves behind: both are "not installed", not "almost".
  /// Never throws — a Settings row may not break because a channel is missing.
  Future<bool> isPresent() async {
    try {
      final File weights = await weightsFile();
      final File projector = await projectorFile();
      return weights.existsSync() &&
          weights.lengthSync() > 0 &&
          projector.existsSync() &&
          projector.lengthSync() > 0;
    } on Object catch (error) {
      debugPrint('VISION: no model directory ($error)');
      return false;
    }
  }

  /// The bytes the two files occupy, or 0 when they are not both here.
  Future<int> sizeBytes() async {
    try {
      final List<File> files = <File>[
        await weightsFile(),
        await projectorFile(),
      ];
      return files.fold<int>(
        0,
        (int total, File file) =>
            total + (file.existsSync() ? file.lengthSync() : 0),
      );
    } on Object catch (error) {
      debugPrint('VISION: no model size ($error)');
      return 0;
    }
  }

  /// Fetches both files, reporting progress from 0 to 1, and answers true only
  /// when both verified files are on disk.
  ///
  /// The second file is not started until the first is complete and hashed: a
  /// projector without its weights is dead weight, and a failure halfway leaves
  /// only a `.part` behind either way.
  Future<bool> download({void Function(double progress)? onProgress}) async {
    final int totalBytes = pair.bytes;
    int done = 0;
    for (final LlmModel model in <LlmModel>[pair.weights, pair.projector]) {
      final int base = done;
      void report(double progress) => onProgress?.call(
        ((base + progress * model.bytes) / totalBytes).clamp(0.0, 1.0),
      );
      final VisionFileFetcher? fetch = this.fetch;
      bool fetched;
      if (fetch != null) {
        fetched = await fetch(model, onProgress: report);
      } else {
        final Llm llm = Llm(model: model, modelsDir: directoryFor);
        try {
          fetched = await llm.download(onProgress: report);
        } finally {
          // This Llm exists only to fetch; nothing asked a runtime of it.
          await llm.dispose();
        }
      }
      if (!fetched) return false;
      done += model.bytes;
    }
    onProgress?.call(1);
    return true;
  }

  /// Deletes both files (and any `.part` a killed download left), answering how
  /// many bytes that freed. Missing is not an error.
  Future<int> delete() async {
    int freed = 0;
    try {
      for (final File file in <File>[
        await weightsFile(),
        await projectorFile(),
      ]) {
        for (final File target in <File>[file, File('${file.path}.part')]) {
          if (!target.existsSync()) continue;
          freed += target.lengthSync();
          target.deleteSync();
        }
      }
    } on Object catch (error) {
      debugPrint('VISION: could not delete the model ($error)');
    }
    return freed;
  }
}

/// A vision-language model, as far as this file is concerned: load the weights
/// and their projector, answer one prompt about one picture, unload.
///
/// [LlamadartVisionInference] is the real one. Tests state a fake, so the
/// fallback order, the memory guard and the prompt shape are provable without a
/// model, a native library, or a photo.
abstract class VisionInference {
  Future<void> load({
    required String weightsPath,
    required String projectorPath,
    required int threads,
  });

  /// What [imagePath] shows, in answer to [prompt] — the model's whole turn,
  /// markers included. May throw; the caller treats a throw as "no answer from
  /// the eyes", never as a crash.
  Future<String> describe({required String imagePath, required String prompt});

  Future<void> unload();
}

/// A VLM through llamadart, with its multimodal projector.
///
/// The raw-prompt path ([LlamaEngine.generate]) rather than the chat one on
/// purpose: both models here bring their own turn markers in [VisionModelPair]
/// (Moondream2 has no chat template at all), so a chat layer would be a second
/// opinion about a format that is already decided.
class LlamadartVisionInference implements VisionInference {
  LlamaEngine? _engine;

  @override
  Future<void> load({
    required String weightsPath,
    required String projectorPath,
    required int threads,
  }) async {
    await unload();
    final LlamaEngine engine = await LlamaEngine.load(
      LlamaModel(
        ModelSource.path(weightsPath),
        projector: ModelSource.path(projectorPath),
      ),
      params: ModelParams(contextSize: 2048, numberOfThreads: threads),
    );
    try {
      final LlamaEngineCapabilities capabilities = await engine.capabilities;
      if (!capabilities.supportsVision) {
        // A projector the runtime loaded but does not report as vision would
        // reject the image anyway; failing here names the real problem.
        throw StateError('The projector does not provide vision input.');
      }
      _engine = engine;
      debugPrint('VISION: ${await engine.getBackendName()} ready');
    } on Object {
      // A half-loaded runtime owns the weights' mapping and the projector's
      // context; dropping only the Dart reference would keep both.
      await engine.dispose();
      rethrow;
    }
  }

  @override
  Future<String> describe({
    required String imagePath,
    required String prompt,
  }) async {
    final LlamaEngine? engine = _engine;
    if (engine == null) throw StateError('describe() before load()');
    // A downscaled copy, when the photo is large. The model is given one file
    // and the folder goes when the answer does.
    final File? prepared = await prepareVisionImage(imagePath);
    try {
      final StringBuffer answer = StringBuffer();
      await engine
          .generate(
            prompt,
            params: GenerationParams(maxTokens: kVisionMaxTokens, temp: 0.2),
            parts: <LlamaContentPart>[
              LlamaImageContent(path: prepared?.path ?? imagePath),
            ],
          )
          .forEach(answer.write);
      return answer.toString().trim();
    } finally {
      if (prepared != null) {
        try {
          prepared.parent.deleteSync(recursive: true);
        } on Object catch (error) {
          debugPrint('VISION: could not remove the prepared photo ($error)');
        }
      }
    }
  }

  @override
  Future<void> unload() async {
    final LlamaEngine? engine = _engine;
    _engine = null;
    if (engine == null) return;
    await engine.dispose();
  }
}

/// The eyes the app installs: the best model this phone has room for, or ML
/// Kit when it has none.
///
/// A singleton behind [VisionAiService.current], which builds a service per
/// call: the engine and its memory live here, not in the caller.
class VlmVisionService extends VisionAiService {
  /// The app-wide instance. `VlmVisionService.new` is this object, so it can be
  /// installed as [VisionAiService.defaultFactory] without losing the engine.
  factory VlmVisionService() => instance;

  static final VlmVisionService instance = VlmVisionService._();

  VlmVisionService._()
    : filesFor = VisionModelFiles.new,
      _inference = LlamadartVisionInference.new,
      _fallback = MlVisionService.new;

  /// A service with stated files, engine and fallback — for tests only.
  @visibleForTesting
  factory VlmVisionService.test({
    required VisionModelFiles Function(VisionModelPair) filesFor,
    VisionInference Function()? inference,
    VisionAiService Function()? fallback,
  }) => VlmVisionService._with(
    filesFor,
    inference ?? LlamadartVisionInference.new,
    fallback ?? MlVisionService.new,
  );

  VlmVisionService._with(this.filesFor, this._inference, this._fallback);

  /// The files behind [pair]. One place builds them, so Settings can download
  /// and inspect exactly what inference will load.
  final VisionModelFiles Function(VisionModelPair pair) filesFor;

  final VisionInference Function() _inference;
  final VisionAiService Function() _fallback;

  VisionInference? _engine;
  VisionModelPair? _loadedPair;
  Future<void>? _loading;
  Timer? _idle;
  Future<void> _tail = Future<void>.value();
  bool _anyPresent = false;
  bool _checked = false;

  /// Pairs whose load failed this session. A model that would not load on the
  /// first photo is not going to load on the second, and retrying means paying
  /// for the failure again while the user waits.
  final Set<String> _loadFailed = <String>{};

  /// True when either pair of eyes is here: a downloaded model, or ML Kit.
  ///
  /// The model's answer is a file check that [refresh] caches. Before the first
  /// refresh this reports ML Kit's answer, which is the one that was true before
  /// the user downloaded anything.
  @override
  bool get available => _anyPresent || _fallback().available;

  /// Re-reads whether any pair is installed, and forgets failed loads — a
  /// download or a delete is a new situation.
  Future<void> refresh() async {
    bool present = false;
    for (final VisionModelPair pair in kVisionPairs) {
      if (await filesFor(pair).isPresent()) {
        present = true;
        break;
      }
    }
    _anyPresent = present;
    _checked = true;
    _loadFailed.clear();
    if (!present) await _shutdown();
  }

  /// A sentence about [imagePath], from the best model that fits and is here,
  /// and from ML Kit when none does.
  ///
  /// The fallback receives [onEvidence], so the bubble still draws the OCR text
  /// and labels it always drew. The model needs none: its answer *is* the
  /// description, and showing a caption of it underneath would say it twice.
  @override
  Future<String> describe(
    String imagePath, {
    String question = '',
    VisionEvidenceCallback? onEvidence,
  }) async {
    final VisionModelPair? pair = await _pairFor();
    if (pair != null) {
      final String seen = await _serial(
        () => _describeWithModel(pair, imagePath, question),
      );
      if (seen.isNotEmpty) return seen;
    }
    return _fallback().describe(
      imagePath,
      question: question,
      onEvidence: onEvidence,
    );
  }

  /// The best pair that is installed and fits right now, or null.
  ///
  /// Largest first: a phone with room gets the better description, and a phone
  /// without room falls to the small model instead of the kernel.
  Future<VisionModelPair?> _pairFor() async {
    if (!_checked) await refresh();
    for (final VisionModelPair pair in <VisionModelPair>[
      kVisionLarge,
      kVisionSmall,
    ]) {
      if (_loadFailed.contains(pair.id)) continue;
      if (!await filesFor(pair).isPresent()) continue;
      final int? free = await OnDeviceAiService.availableMemory();
      if (free != null && free < pair.workingSetBytes) {
        debugPrint(
          'VISION: ${pair.label} needs ${pair.workingSetBytes} bytes, $free '
          'free — smaller eyes instead',
        );
        continue;
      }
      debugPrint('VISION: ${pair.label} with ${free ?? 'unknown'} bytes free');
      return pair;
    }
    return null;
  }

  /// One picture through [pair], or '' when there is nothing usable to show.
  /// Never throws: the caller is drawing a bubble.
  Future<String> _describeWithModel(
    VisionModelPair pair,
    String imagePath,
    String question,
  ) async {
    final VisionInference? engine = await _ensureLoaded(pair);
    if (engine == null) return '';
    try {
      final String asked = question.trim().isEmpty
          ? kVisionDescribePrompt
          : question.trim();
      final String answer = await engine.describe(
        imagePath: imagePath,
        prompt: pair.prompt(asked),
      );
      _scheduleIdleUnload();
      return answer.trim();
    } on Object catch (error) {
      // An unreadable file, a runtime that ran out of room, a projector that
      // disagrees with the weights: all of them are "no answer from the model",
      // and the fallback is the honest next step.
      debugPrint(
        'VISION: ${pair.label} could not describe $imagePath ($error)',
      );
      await _shutdown();
      return '';
    }
  }

  /// The loaded engine for [pair], loading it once if needed, or null.
  Future<VisionInference?> _ensureLoaded(VisionModelPair pair) async {
    final VisionInference? ready = _engine;
    if (ready != null && _loadedPair?.id == pair.id) return ready;
    final Future<void>? running = _loading;
    if (running != null) {
      await running;
      if (_loadedPair?.id == pair.id) return _engine;
    }
    final Future<void> work = _load(pair);
    _loading = work;
    try {
      await work;
    } finally {
      if (identical(_loading, work)) _loading = null;
    }
    return _loadedPair?.id == pair.id ? _engine : null;
  }

  Future<void> _load(VisionModelPair pair) async {
    // One model at a time: switching pairs with the old engine still resident
    // would hold two sets of weights on a phone that could not hold one.
    await _shutdown();
    try {
      final VisionModelFiles files = filesFor(pair);
      final File weights = await files.weightsFile();
      final File projector = await files.projectorFile();
      final VisionInference engine = _inference();
      await engine.load(
        weightsPath: weights.path,
        projectorPath: projector.path,
        threads: Platform.numberOfProcessors.clamp(1, 4),
      );
      _engine = engine;
      _loadedPair = pair;
    } on Object catch (error) {
      debugPrint('VISION: could not load ${pair.label} ($error)');
      _loadFailed.add(pair.id);
    }
  }

  /// Runs picture work one at a time: the runtime allows one generation, and
  /// two photos attached together are two requests.
  Future<T> _serial<T>(Future<T> Function() work) {
    final Future<T> result = _tail.then((_) => work());
    _tail = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  void _scheduleIdleUnload() {
    _idle?.cancel();
    _idle = Timer(kVisionIdleUnload, () {
      unawaited(_shutdown());
      debugPrint(
        'VISION: model unloaded after idle '
        '(${kVisionIdleUnload.inSeconds}s)',
      );
    });
  }

  Future<void> _shutdown() async {
    _idle?.cancel();
    _idle = null;
    final VisionInference? engine = _engine;
    _engine = null;
    _loadedPair = null;
    if (engine == null) return;
    await engine.unload();
  }
}
