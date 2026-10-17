// Where the next answer will come from — one question, asked once, answered in
// the same words the Settings row uses.
//
// There are exactly three states, and they are not "online/offline": the model
// may be on this device (the first choice, and the only one that works on a
// train), the PC's Ollama may be reachable (the fallback a user who already
// runs Ollama gets for free), or there may be no brain at all (the state that
// makes the download button matter). [LocalAiService.current] tries them in
// that order, so this is the same decision reported rather than made.
library;

import 'on_device_model.dart';
import 'ollama_service.dart';

/// Which brain would answer right now.
enum AiSource {
  /// A model file is on this device.
  onDevice,

  /// The PC's Ollama answered its `/api/tags`.
  pc,

  /// Neither: the chat will show a notice, not an answer.
  none,
}

/// The answer to "where do the words come from", with the label the user reads.
class AiStatus {
  const AiStatus(this.source);

  final AiSource source;

  /// The value in the Settings row — the three phrases this app uses for the
  /// three states, everywhere.
  String get label => switch (source) {
    AiSource.onDevice => 'On-Device (Loaded)',
    AiSource.pc => 'PC (Ollama)',
    AiSource.none => 'No AI available',
  };

  /// One line under the row saying what that means for the user, in the order
  /// they would act on it.
  String get detail => switch (source) {
    AiSource.onDevice =>
      'Answers on this device. No network, no account, nothing leaves it.',
    AiSource.pc =>
      'Answers come from your PC over the local network. Works while you are '
          'on the same Wi-Fi.',
    AiSource.none => 'Download the model below, or start Ollama on your PC.',
  };

  /// A test seam: a widget test states which brain it is looking at instead of
  /// waiting on a socket. The app never sets it.
  static Future<AiStatus> Function()? debugProbeOverride;

  /// Checks the device first, then the PC — the same order
  /// [LocalAiService.current] tries them in.
  ///
  /// [model] and [pc] exist so a test (and the Settings screen, which already
  /// holds a model) can point the probe at the same files and the same client
  /// the row is about. Neither probe throws: this decides what to say, and a
  /// status line that cannot be computed is "no AI available", not a crash.
  static Future<AiStatus> detect({
    OnDeviceModel model = const OnDeviceModel(),
    OllamaService pc = const OllamaService(),
  }) async {
    final override = debugProbeOverride;
    if (override != null) return override();
    if (await model.isPresent()) return const AiStatus(AiSource.onDevice);
    if (await pc.isReachable()) return const AiStatus(AiSource.pc);
    return const AiStatus(AiSource.none);
  }
}
