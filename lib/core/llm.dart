// The on-device model: a small language model that runs *inside* Nexus — in
// this process, on this device, through llama.cpp. No server, no cloud, no
// account, no network once the model file is here. This is the brain the
// assistant already knows how to talk to (the same seam Ollama fills on a
// desktop and the tiny-model channel fills on a phone), with a real model
// behind it.
//
// Three jobs, and nothing else:
//   * keep a model file — fetch it once from a pinned URL, prove the bytes are
//     the file we asked for (sha256), cache it, never fetch it twice;
//   * run it — load lazily on the first question, unload when idle so a phone
//     is not holding weights nobody is using;
//   * pick the right one — the small model on a phone, the larger one on a
//     machine that can afford it: one rule, stated once, in [modelForDevice].
//
// Everything about *how* a model is run lives behind [LlmRuntime], so the
// decisions that matter here — laziness, the idle unload, the serial queue,
// the download-and-verify — are provable in tests with no native library and
// no model file. Guards: test/llm_test.dart.
import 'dart:async';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugPrint, defaultTargetPlatform;
import 'package:llamadart/llamadart.dart';
import 'package:path_provider/path_provider.dart';

import 'brain.dart' show ChatTurn;

/// One model file Nexus can run: what it is called, exactly where it comes
/// from, and the hash that proves the download is that exact file.
///
/// [url] is pinned to a commit, not a branch: `main` on a model hub can move
/// under us, and a hash pins the bytes but says nothing about *where* they
/// came from — together they mean the same file, from the same place, every
/// time. [bytes] is what the download reports against; [sha256] is what makes
/// a truncated or swapped file a failed download instead of a model.
class LlmModel {
  final String name;
  final String url;
  final String sha256;
  final int bytes;

  const LlmModel({
    required this.name,
    required this.url,
    required this.sha256,
    required this.bytes,
  });

  /// What the user sees where the model is named — brand, size class, and the
  /// quantization, because "0.5b" alone does not say what runs.
  String get label => name
      .replaceFirst('-instruct-', ' ')
      .replaceFirst('q4_k_m', 'q4')
      .replaceFirst('qwen2.5-', 'Qwen2.5 ');

  /// Megabytes, rounded — for logs and status lines, never for a decision.
  int get megabytes => (bytes + 1024 * 1024 - 1) ~/ (1024 * 1024);
}

/// The phone model: Qwen2.5 0.5B Instruct, Q4_K_M — 470 MB of weights that
/// leave room for the rest of the phone. Published by Qwen, Apache-2.0.
const kPhoneModel = LlmModel(
  name: 'qwen2.5-0.5b-instruct-q4_k_m',
  url: 'https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/'
      '9217f5db79a29953eb74d5343926648285ec7e67/'
      'qwen2.5-0.5b-instruct-q4_k_m.gguf',
  sha256: '74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db',
  bytes: 491400032,
);

/// The desktop model: Qwen2.5 1.5B Instruct, Q4_K_M — 1.04 GiB, which a real
/// machine has and a phone should not be asked for.
const kDesktopModel = LlmModel(
  name: 'qwen2.5-1.5b-instruct-q4_k_m',
  url: 'https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/'
      '91cad51170dc346986eccefdc2dd33a9da36ead9/'
      'qwen2.5-1.5b-instruct-q4_k_m.gguf',
  sha256: '6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e',
  bytes: 1117320736,
);

/// Below this much physical memory a machine gets the small model even if it
/// is a desktop: 1.5B Q4_K_M plus its context wants about 1.6 GB of RAM while
/// it is loaded, and a machine with less cannot hold it next to its own work.
const int kLlmRamFloorBytes = 4 * 1024 * 1024 * 1024;

/// Which model this device should run.
///
/// Phones get the small one, full stop: on a phone the memory is shared with
/// everything else the user is doing, and the larger model's advantage is not
/// one a phone can spend. Desktops get the larger one when the machine really
/// has the memory for it, the small one when it does not — and when we cannot
/// tell, the small one, because a model that fits is worth more than a model
/// that does not.
LlmModel modelForDevice({
  required TargetPlatform platform,
  required int? ramBytes,
}) {
  if (platform == TargetPlatform.android || platform == TargetPlatform.iOS) {
    return kPhoneModel;
  }
  if (ramBytes != null && ramBytes >= kLlmRamFloorBytes) return kDesktopModel;
  return kPhoneModel;
}

/// Total physical memory, or null where there is no way to ask.
///
/// Read straight from /proc/meminfo rather than through a plugin: it is the
/// same file on Android and Linux, it needs no permission, and it keeps this
/// decision free of platform channels. Windows and macOS return null and get
/// the small model — the honest answer to "how much memory does this machine
/// have" is not one we can get here, and guessing high is the one wrong guess
/// that breaks the app.
int? totalRamBytes() {
  try {
    final info = File('/proc/meminfo').readAsStringSync();
    final match = RegExp(
      r'^MemTotal:\s+(\d+) kB',
      multiLine: true,
    ).firstMatch(info);
    if (match == null) return null;
    return int.parse(match.group(1)!) * 1024;
  } catch (_) {
    return null;
  }
}

/// What the model is doing right now, for a status line and for tests.
///
/// [downloading] and [loading] are the honest middle states: the model is
/// coming, and a question asked now cannot be answered by it.
enum LlmStatus {
  /// Nothing loaded, nothing in flight. The file may or may not be cached.
  idle,

  /// Fetching the model file (first run, or a cleared cache).
  downloading,

  /// Reading weights into memory.
  loading,

  /// Loaded and able to answer.
  ready,

  /// No model, and no way to get one (no download, failed hash, no runtime).
  unavailable,
}

/// The inference runtime, as far as [Llm] is concerned: load a GGUF, answer
/// messages, unload. [LlamaCppRuntime] is the real one; tests inject a fake so
/// the lifecycle here is provable without a native library or a model file.
abstract class LlmRuntime {
  /// Load [modelPath] and be ready to generate. Throwing is allowed — the
  /// caller treats a throw as "no model", never as "try again harder".
  Future<void> load(
    String modelPath, {
    required int contextSize,
    required int threads,
  });

  /// One answer to one exchange, complete. [messages] is the whole prompt:
  /// a system turn (if any) first, then user/assistant turns in order.
  Future<String> generate(
    List<ChatTurn> messages, {
    required int maxTokens,
    required double temperature,
  });

  /// The same exchange as [generate], token by token.
  ///
  /// It is required rather than defaulted on purpose: every implementation of
  /// this seam is inside this repository, and a runtime that quietly answered a
  /// stream request with one big piece would be a streaming regression nobody
  /// could see in a passing test. A runtime that has no stream to offer yields
  /// its whole answer as its only piece — that is a decision each fake makes in
  /// one line, not a default that hides a missing implementation.
  Stream<String> generateStream(
    List<ChatTurn> messages, {
    required int maxTokens,
    required double temperature,
  });

  /// Free the loaded model. The runtime object stays usable: a later
  /// [load] must work, because that is exactly what the idle unload does.
  Future<void> unload();

  /// Free everything, for good.
  Future<void> dispose();
}

/// The real runtime: llama.cpp through llamadart, in a worker isolate, with
/// the model's own chat template applied by the engine (Qwen2.5-Instruct's
/// ChatML) rather than hand-rendered here — the template is a property of the
/// model, and the packaging knows it better than this file does.
class LlamaCppRuntime implements LlmRuntime {
  LlamaEngine? _engine;

  @override
  Future<void> load(
    String modelPath, {
    required int contextSize,
    required int threads,
  }) async {
    final engine = await LlamaEngine.load(
      LlamaModel(ModelSource.parse(modelPath)),
      params: ModelParams(contextSize: contextSize, numberOfThreads: threads),
    );
    _engine = engine;
    // Name the runtime that actually answered — reports should never guess
    // between llama.cpp and a delegate that quietly took over.
    debugPrint('LLM: ${await engine.getBackendName()} ready, '
        'ctx $contextSize, ${threads}t');
  }

  /// One answer, complete — the same stream [generateStream] hands out, joined.
  ///
  /// Deliberately the streaming path with a join on the end rather than
  /// llama.cpp's own one-shot: one code path means a streaming regression cannot
  /// hide behind a passing one-shot test, and the engine applies the model's
  /// chat template identically either way.
  @override
  Future<String> generate(
    List<ChatTurn> messages, {
    required int maxTokens,
    required double temperature,
  }) =>
      generateStream(
        messages,
        maxTokens: maxTokens,
        temperature: temperature,
      ).join();

  @override
  Stream<String> generateStream(
    List<ChatTurn> messages, {
    required int maxTokens,
    required double temperature,
  }) {
    final engine = _engine;
    if (engine == null) throw StateError('generateStream() before load()');
    return engine
        .create(
          [
            for (final turn in messages)
              LlamaChatMessage.fromText(
                role: _role(turn.role),
                text: turn.content,
              ),
          ],
          params: GenerationParams(maxTokens: maxTokens, temp: temperature),
        )
        // The non-empty content deltas, in order — llama.cpp's raw pieces,
        // before any caller decides how to render them.
        .textDeltas();
  }

  @override
  Future<void> unload() async {
    final engine = _engine;
    _engine = null;
    if (engine == null) return;
    // Dispose rather than only unloadModel(): a disposed engine is a known
    // state, and the next load builds a fresh one. Reusing an engine whose
    // model was pulled out from under it is the state this package documents
    // as a future throw; there is nothing here worth that risk.
    await engine.dispose();
  }

  @override
  Future<void> dispose() => unload();

  static LlamaChatRole _role(String role) => switch (role) {
    'system' => LlamaChatRole.system,
    'assistant' => LlamaChatRole.assistant,
    _ => LlamaChatRole.user,
  };
}

/// A small language model on this device.
///
/// Nothing here runs until somebody asks a question: construction is free, the
/// download starts on the first [complete] (or an explicit [warmUp]), and the
/// model is dropped from memory [idleTimeout] after the last answer. One
/// exchange runs at a time — the queue is here because two callers (a typed
/// question and a spoken one) can arrive together, and the runtime underneath
/// allows exactly one generation at a time.
class Llm {
  final LlmModel model;

  /// How long the loaded model is kept after the last answer. Long enough
  /// that follow-up questions do not pay for a reload, short enough that a
  /// phone left alone gives its memory back.
  final Duration idleTimeout;

  /// Prompt context, in tokens. Bounded on purpose: the chat history handed
  /// here is already trimmed, and KV cache memory grows with this number.
  final int contextSize;

  final int _threads;
  final LlmRuntime _runtime;
  final Future<Directory> Function() _modelsDir;

  LlmStatus _status = LlmStatus.idle;
  bool _disposed = false;
  Future<void>? _preparing;
  Future<bool>? _fetching;
  Timer? _idle;
  Future<void> _tail = Future.value();

  Llm({
    required this.model,
    LlmRuntime? runtime,
    Future<Directory> Function()? modelsDir,
    this.idleTimeout = const Duration(minutes: 5),
    this.contextSize = 2048,
    int? threads,
  }) : _runtime = runtime ?? LlamaCppRuntime(),
       _modelsDir = modelsDir ?? _defaultModelsDir,
       _threads = threads ?? Platform.numberOfProcessors.clamp(1, 4);

  /// The model for *this* device ([modelForDevice]), with the real runtime.
  factory Llm.forThisDevice({
    TargetPlatform? platform,
    int? ramBytes,
    LlmRuntime? runtime,
    Future<Directory> Function()? modelsDir,
    Duration idleTimeout = const Duration(minutes: 5),
  }) => Llm(
    model: modelForDevice(
      platform: platform ?? defaultTargetPlatform,
      ramBytes: ramBytes ?? totalRamBytes(),
    ),
    runtime: runtime,
    modelsDir: modelsDir,
    idleTimeout: idleTimeout,
  );

  LlmStatus get status => _status;
  bool get isReady => _status == LlmStatus.ready;

  /// Where model files live: one directory for this app, next to the rest of
  /// its support data — persistent (a 470 MB download must survive a restart)
  /// and private, which a cache directory is not promised to be.
  static Future<Directory> _defaultModelsDir() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/models');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// The name of the model on this device, or null when there is not one yet:
  /// the file is cached and complete, or it is not. Cheap on purpose — the
  /// status line asks this, and it must not cost a load. Never throws: it is
  /// asked from a status line, and a status line may not break the screen.
  Future<String?> modelName() async {
    try {
      if (await _cachedFile().then((file) => file.existsSync())) {
        return model.label;
      }
    } on Object catch (e) {
      debugPrint('LLM: no model directory ($e)');
    }
    return null;
  }

  /// Load the model if needed, without asking anything of it — the first
  /// launch calls this so the download happens while the user is busy with
  /// something else, not while they are waiting for an answer. Never throws.
  Future<void> warmUp() => _prepare(waitForDownload: true);

  /// Fetches the model file if it is not already cached, reporting progress
  /// from 0 to 1 as the bytes arrive, and returns true only when a verified
  /// file is on disk. It does not load the model: a download is something the
  /// user starts and watches in Settings, and loading is something that happens
  /// when a question is asked.
  ///
  /// A download already in flight (started by a first question or a warm-up) is
  /// shared rather than duplicated; in that case the progress callback is not
  /// called for this request, because the fetch on the wire belongs to the
  /// caller who started it. Never throws — a failure is a false.
  Future<bool> download({void Function(double progress)? onProgress}) async {
    if (_disposed) return false;
    final file = await _cachedFile();
    if (file.existsSync()) {
      onProgress?.call(1);
      return true;
    }
    return _ensureFile(file, onProgress: onProgress);
  }

  /// One answer to one prompt, as one user turn. [system] becomes the system
  /// turn ahead of it; the model's own template is applied by the runtime.
  Future<String> complete(
    String prompt, {
    int maxTokens = 300,
    String? system,
    double temperature = 0.6,
  }) {
    return _enqueue(
      [
        if (system != null) (role: 'system', content: system),
        (role: 'user', content: prompt),
      ],
      maxTokens: maxTokens,
      temperature: temperature,
    );
  }

  /// One answer to one prompt, token by token — the streaming twin of
  /// [complete], with the same queue, the same lazy load and the same idle
  /// unload behind it. An empty stream is the honest no, exactly as '' is for
  /// [complete]; a failure mid-answer is an error on the stream, so a caller
  /// that has already shown words can say the answer stopped instead of
  /// pretending it was complete.
  Stream<String> completeStream(
    String prompt, {
    int maxTokens = 300,
    String? system,
    double temperature = 0.6,
  }) {
    return _stream(
      [
        if (system != null) (role: 'system', content: system),
        (role: 'user', content: prompt),
      ],
      maxTokens: maxTokens,
      temperature: temperature,
    );
  }

  /// The queued, lazily-loaded generation both call shapes share.
  ///
  /// One generation at a time, whichever shape asked: the stream holds its
  /// place in the same queue [complete] uses until its last token has been
  /// handed over, so a typed question and a spoken one cannot interleave on a
  /// runtime that allows exactly one at a time.
  Stream<String> _stream(
    List<ChatTurn> messages, {
    required int maxTokens,
    required double temperature,
  }) async* {
    if (!await _prepare(waitForDownload: false)) return;
    if (_disposed) return;
    final Completer<void> gate = Completer<void>();
    final Future<void> previous = _tail;
    _tail = gate.future;
    try {
      await previous;
      await for (final String piece in _runtime.generateStream(
        messages,
        maxTokens: maxTokens,
        temperature: temperature,
      )) {
        yield piece;
      }
    } on Object catch (e) {
      // Thrown rather than swallowed: the caller may already be showing half
      // an answer, and it is the only one that can say so.
      debugPrint('LLM: streaming generation failed ($e)');
      rethrow;
    } finally {
      if (!gate.isCompleted) gate.complete();
      _scheduleIdleUnload();
    }
  }

  /// One answer to a whole exchange — the shape the assistant's brain uses:
  /// a system prompt (the persona and what Nexus knows about its person) plus
  /// the recent turns.
  Future<String> completeChat({
    required String system,
    required List<ChatTurn> history,
    int maxTokens = 300,
    double temperature = 0.6,
  }) {
    return _enqueue(
      [(role: 'system', content: system), ...history],
      maxTokens: maxTokens,
      temperature: temperature,
    );
  }

  /// The streaming twin of [completeChat]: the same messages, one token at a
  /// time. Live conversation is the caller — it has a turn to keep in mind and
  /// a page that wants to show the answer arriving.
  Stream<String> completeChatStream({
    required String system,
    required List<ChatTurn> history,
    int maxTokens = 300,
    double temperature = 0.6,
  }) {
    return _stream(
      [(role: 'system', content: system), ...history],
      maxTokens: maxTokens,
      temperature: temperature,
    );
  }

  /// Free the loaded model now (the file stays).
  Future<void> unload() async {
    _idle?.cancel();
    _idle = null;
    if (_status != LlmStatus.ready) return;
    await _runtime.unload();
    _status = LlmStatus.idle;
  }

  /// Free everything. After this the instance is done; a fresh one is the way
  /// back, exactly like the engine underneath.
  Future<void> dispose() async {
    _disposed = true;
    _idle?.cancel();
    _idle = null;
    await _runtime.dispose();
    _status = LlmStatus.idle;
  }

  /// Answers one exchange, or '' when there is no model to answer with.
  ///
  /// The empty string is the honest no: this never throws, because every
  /// caller is a conversation that must keep working when the model is not
  /// there — a phone that has not finished its first download is still a
  /// full assistant, just one that asks a peer or says it does not know.
  Future<String> _enqueue(
    List<ChatTurn> messages, {
    required int maxTokens,
    required double temperature,
  }) async {
    if (!await _prepare(waitForDownload: false)) return '';
    if (_disposed) return '';
    final answer = _tail.then((_) async {
      final text = await _runtime.generate(
        messages,
        maxTokens: maxTokens,
        temperature: temperature,
      );
      return text.trim();
    });
    // The queue is the answer itself, with failures swallowed: one bad
    // exchange must not poison the next one's place in line.
    _tail = answer.then((_) {}, onError: (Object _) {});
    try {
      final text = await answer;
      _scheduleIdleUnload();
      return text;
    } on Object catch (e) {
      debugPrint('LLM: generation failed ($e)');
      _scheduleIdleUnload();
      return '';
    }
  }

  /// Makes the model ready to answer, at most once at a time.
  ///
  /// The wait a question is allowed is the whole point of this method. A
  /// model *loading* takes seconds and the user just asked something: wait for
  /// it, bounded, so a phone that cannot load its model still answers promptly
  /// (with the truth) instead of hanging. A model *downloading* takes minutes
  /// of somebody else's network: never wait for that — answer honestly now,
  /// let the fetch run, and let the next question find a model.
  ///
  /// With [waitForDownload] true (warmUp, and the real-inference smoke test)
  /// the caller has said it is willing to wait for the fetch too; it is the
  /// same single in-flight download either way.
  Future<bool> _prepare({required bool waitForDownload}) async {
    if (_disposed) return false;
    if (_status == LlmStatus.ready) return true;

    var inFlight = _preparing;
    if (inFlight == null) {
      final work = _bringUp(waitForDownload: waitForDownload);
      _preparing = work;
      inFlight = work;
      unawaited(work.whenComplete(() {
        if (identical(_preparing, work)) _preparing = null;
      }));
    }
    if (waitForDownload) {
      await inFlight;
      return _status == LlmStatus.ready;
    }
    if (_status == LlmStatus.downloading) return false;
    await inFlight.timeout(const Duration(seconds: 20), onTimeout: () {});
    return _status == LlmStatus.ready;
  }

  Future<void> _bringUp({required bool waitForDownload}) async {
    try {
      final file = await _cachedFile();
      if (!file.existsSync()) {
        if (!waitForDownload) {
          // Not on this question's time. Start it anyway — the next question
          // is a different question, and it may well find a model.
          unawaited(_ensureFile(file));
          return;
        }
        if (!await _ensureFile(file)) return;
      }
      _status = LlmStatus.loading;
      await _runtime.load(file.path, contextSize: contextSize, threads: _threads);
      _status = LlmStatus.ready;
    } on Object catch (e) {
      debugPrint('LLM: no model ($e)');
      _status = LlmStatus.unavailable;
    }
  }

  Future<File> _cachedFile() async {
    final dir = await _modelsDir();
    return File('${dir.path}/${model.name}.gguf');
  }

  /// One fetch per model file, however many callers ask for it: a warm-up
  /// racing a first question must not download 470 MB twice into one path.
  Future<bool> _ensureFile(File target, {void Function(double)? onProgress}) {
    final running = _fetching;
    if (running != null) return running;
    final work = _download(target, onProgress: onProgress);
    _fetching = work;
    unawaited(work.whenComplete(() {
      if (identical(_fetching, work)) _fetching = null;
    }));
    return work;
  }

  /// Fetches the model file into the cache, verifying it is the exact file
  /// we asked for before it is allowed to become the model.
  ///
  /// Written as a download into a `.part` file, hashed while it streams and
  /// renamed only on a match, so a killed process, a dropped connection, or a
  /// truncating proxy leaves a `.part` behind — never a half model that
  /// llama.cpp would load and answer nonsense from.
  Future<bool> _download(
    File target, {
    void Function(double)? onProgress,
  }) async {
    if (_disposed) return false;
    final part = File('${target.path}.part');
    _status = LlmStatus.downloading;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      debugPrint('LLM: fetching ${model.name} (${model.megabytes} MB)');
      final request = await client.getUrl(Uri.parse(model.url));
      final response = await request.close();
      if (response.statusCode != 200) {
        debugPrint('LLM: ${model.url} answered ${response.statusCode}');
        _status = LlmStatus.unavailable;
        return false;
      }
      final digest = Sha256().toSync().newHashSink();
      final sink = part.openWrite();
      var received = 0;
      var reported = 0;
      var shownPercent = -1;
      onProgress?.call(0);
      try {
        await for (final chunk in response) {
          sink.add(chunk);
          digest.add(chunk);
          received += chunk.length;
          // One line per 25%, so a first run can be watched without a
          // progress bar in the UI; reports read these lines.
          final percent = received * 100 ~/ model.bytes;
          if (percent >= reported + 25) {
            reported = percent - percent % 25;
            debugPrint('LLM: ${model.name} $reported%');
          }
          // The bar is repainted per whole percent, not per socket chunk: a
          // 470 MB fetch arrives in thousands of chunks, and a setState for
          // each of them is work the user cannot see.
          if (percent >= shownPercent + 1) {
            shownPercent = percent;
            onProgress?.call((received / model.bytes).clamp(0.0, 1.0));
          }
        }
      } finally {
        await sink.close();
        digest.close();
      }
      final actual = digest.hashSync().bytes
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join();
      if (actual != model.sha256) {
        debugPrint('LLM: ${model.name} failed its hash '
            '($actual != ${model.sha256}) — discarded');
        if (part.existsSync()) part.deleteSync();
        _status = LlmStatus.unavailable;
        return false;
      }
      part.renameSync(target.path);
      onProgress?.call(1);
      debugPrint('LLM: ${model.name} cached (${model.megabytes} MB, hash ok)');
      // A file, not a loaded model: the next question still has to load it.
      _status = LlmStatus.idle;
      return true;
    } on Object catch (e) {
      debugPrint('LLM: no model download ($e)');
      _status = LlmStatus.unavailable;
      return false;
    } finally {
      client.close(force: true);
    }
  }

  void _scheduleIdleUnload() {
    _idle?.cancel();
    _idle = Timer(idleTimeout, () {
      unawaited(() async {
        if (_status != LlmStatus.ready) return;
        await _runtime.unload();
        _status = LlmStatus.idle;
        debugPrint('LLM: ${model.name} unloaded after idle '
            '(${idleTimeout.inSeconds}s)');
      }());
    });
  }
}
