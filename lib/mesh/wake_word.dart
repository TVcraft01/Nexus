import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter/services.dart' show EventChannel, MethodChannel;
import 'package:open_wake_word/open_wake_word.dart';

/// The wake word ("Hey Jarvis" placeholder; a trained `nexus.onnx` later).
///
/// Fully offline: audio is captured on the phone, scored on the phone by the
/// openWakeWord ONNX engine, and discarded chunk by chunk. Nothing is
/// recorded, uploaded, or kept — a detection is the only thing that ever
/// leaves this controller, as a callback.
///
/// Asset layout: [melAsset], [embAsset], and [keywordAsset] name Flutter
/// assets declared in pubspec.yaml. Swapping the placeholder for the custom
/// model is a one-line change: point [keywordAsset] at `nexus.onnx`.
class WakeWordModels {
  static const melAsset = 'assets/wake/melspectrogram.onnx';
  static const embAsset = 'assets/wake/embedding_model.onnx';

  /// One-line swap path: replace with 'assets/wake/nexus.onnx' when the
  /// custom model is trained. Everything else stays the same.
  static const keywordAsset = 'assets/wake/hey_jarvis_v0.1.onnx';

  /// What the Settings row names while the placeholder is in use.
  static const keywordSpoken = 'Hey Jarvis';
}

/// The inference engine behind [WakeWordController], extracted so tests can
/// drive detection without a microphone, ONNX runtime, or platform channel.
abstract class WakeWordEngine {
  Future<bool> init();
  void processAudio(Int16List chunk);
  bool get isActivated;
  void destroy();
}

/// The real on-device openWakeWord engine (FFI + ONNX Runtime).
class OpenWakeWordEngine implements WakeWordEngine {
  @override
  Future<bool> init() => OpenWakeWord.init(
    melModelAssetPath: WakeWordModels.melAsset,
    embModelAssetPath: WakeWordModels.embAsset,
    wwModelAssetPaths: [WakeWordModels.keywordAsset],
  );

  @override
  void processAudio(Int16List chunk) => OpenWakeWord.processAudio(chunk);

  @override
  bool get isActivated => OpenWakeWord.isActivated();

  @override
  void destroy() => OpenWakeWord.destroy();
}

/// Platform side of the wake word: the Kotlin AudioRecord loop. The same
/// channel name the tests mock, so toggle/start/stop are provable headlessly.
class WakeWordPlatform {
  WakeWordPlatform({MethodChannel? channel, EventChannel? audio})
    : channel =
          channel ?? const MethodChannel('dev.nexus.nexus/wake_word'),
      // Default StandardMethodCodec — the same codec the Kotlin
      // EventChannel uses, so PCM bytes cross unchanged.
      audio = audio ?? const EventChannel('dev.nexus.nexus/wake_word_audio');

  final MethodChannel channel;
  final EventChannel audio;

  /// The PCM chunk stream, as a method (not a field read) so tests can
  /// substitute a fake without touching a real EventChannel.
  Stream<dynamic> audioStream() => audio.receiveBroadcastStream();

  /// Starts the native audio loop (requests RECORD_AUDIO first on the
  /// platform side). Returns true when the loop is running.
  Future<bool> start() async {
    try {
      return await channel.invokeMethod<bool>('start') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> stop() async {
    try {
      await channel.invokeMethod<void>('stop');
    } catch (_) {
      // Stopping is best-effort; the loop also dies with the service.
    }
  }

  /// Best-effort: brings the app to the front so the Listening state is
  /// visible. Detection still arms the mic even when this returns false.
  Future<bool> bringToFront() async {
    try {
      return await channel.invokeMethod<bool>('bringToFront') ?? false;
    } catch (_) {
      return false;
    }
  }
}

/// Listens for the wake word and fires [onWake]; owns the 5-second silence
/// timeout that returns an unanswered wake to idle.
///
/// Lifecycle: [start] inits the engine and the native loop; audio chunks
/// arriving on the event channel are scored until [isActivated], which fires
/// [onWake] once per detection (a short cooldown suppresses re-fires while
/// the user is already talking). [beginUtteranceWindow] starts the 5-second
/// timer after arming the mic; [heardSpeech] cancels it. [stop] releases
/// everything. All native calls funnel through [WakeWordPlatform], which is
/// why the four contract tests can run with no microphone.
class WakeWordController {
  WakeWordController({
    WakeWordEngine? engine,
    WakeWordPlatform? platform,
    this.cooldown = const Duration(seconds: 3),
    this.listenWindow = const Duration(seconds: 5),
  }) : engine = engine ?? OpenWakeWordEngine(),
       platform = platform ?? WakeWordPlatform();

  final WakeWordEngine engine;
  final WakeWordPlatform platform;

  /// Re-fire guard after a detection, so one utterance wakes once.
  final Duration cooldown;

  /// How long the armed mic waits for speech before going idle silently.
  final Duration listenWindow;

  /// Fired on each detection (after cooldown). The owner arms the mic.
  void Function()? onWake;

  /// Fired when the listen window expired with no speech. The owner stops.
  void Function()? onSilenceTimeout;

  bool _running = false;
  bool get running => _running;

  StreamSubscription<dynamic>? _audioSub;
  DateTime? _lastFire;
  Timer? _windowTimer;

  /// Starts detection: engine init, then the native audio loop. False when
  /// either half refused (permission denied, no mic, engine failed).
  Future<bool> start() async {
    if (_running) return true;
    final ready = await engine.init();
    if (!ready) {
      debugPrint('NEXUS wake: engine init failed');
      return false;
    }
    final loop = await platform.start();
    if (!loop) {
      engine.destroy();
      debugPrint('NEXUS wake: native audio loop refused');
      return false;
    }
    _audioSub = platform.audioStream().listen(
      _onAudio,
      onError: (_) {},
    );
    _running = true;
    debugPrint('NEXUS wake: listening for "${WakeWordModels.keywordSpoken}"');
    return true;
  }

  /// Stops the loop and releases the engine. Safe to call when idle.
  Future<void> stop() async {
    _windowTimer?.cancel();
    _windowTimer = null;
    await _audioSub?.cancel();
    _audioSub = null;
    if (_running) {
      await platform.stop();
      engine.destroy();
      _running = false;
      debugPrint('NEXUS wake: stopped');
    }
  }

  void _onAudio(dynamic event) {
    if (!_running || event is! Uint8List || event.isEmpty) return;
    final bytes = event;
    final chunk = Int16List(bytes.length ~/ 2);
    final data = ByteData.sublistView(bytes);
    for (var i = 0; i < chunk.length; i++) {
      chunk[i] = data.getInt16(i * 2, Endian.little);
    }
    engine.processAudio(chunk);
    if (!engine.isActivated) return;
    final now = DateTime.now();
    if (_lastFire != null && now.difference(_lastFire!) < cooldown) return;
    _lastFire = now;
    debugPrint('NEXUS wake: detected "${WakeWordModels.keywordSpoken}"');
    onWake?.call();
  }

  /// Arms the 5-second window after the mic is listening. Silence (no
  /// [heardSpeech]) fires [onSilenceTimeout] and the owner goes idle.
  void beginUtteranceWindow() {
    _windowTimer?.cancel();
    _windowTimer = Timer(listenWindow, () {
      debugPrint('NEXUS wake: silence timeout, back to idle');
      onSilenceTimeout?.call();
    });
  }

  /// Speech arrived: the window served its purpose.
  void heardSpeech() {
    _windowTimer?.cancel();
    _windowTimer = null;
  }

  @visibleForTesting
  void fireWakeForTest() => onWake?.call();
}

/// App-wide access to the one wake-word controller. Settings (which owns the
/// toggle but not the assistant) and the assistant (which owns the mic
/// callbacks) meet here instead of threading an instance through widgets.
/// [ensure] and [WakeWordController.start] are both idempotent, so the
/// toggle and the assistant's own startup can each call without coordinating.
class WakeWord {
  static WakeWordController? _current;

  static WakeWordController ensure() => _current ??= WakeWordController();

  @visibleForTesting
  static void resetForTest() {
    _current = null;
  }
}
