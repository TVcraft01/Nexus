// What *this device* can do — one place that answers it, so no screen has to
// guess from `Platform.isAndroid`.
//
// The shell grew up on one phone, and the seams that reached the hardware grew
// up with it: `SpeechInput.available` is `defaultTargetPlatform == android`,
// launcher icons are an Android activity, the on-device model is a native
// library that ships in some builds and not others. Each of those answered its
// own question correctly and none of them could answer the UI's: *should this
// button be on screen at all?* A control that is drawn and inert is a control
// the user tries once and distrusts; a control that is not drawn, on a device
// that could never have used it, is simply a shorter screen.
//
// So this is the same shape as [SpeechInput] and [LocalAiService]: a small
// object with an honest answer, a static override for tests, and no platform
// channels where a platform check will do. It deliberately answers in
// *capabilities*, not platforms — "can this device listen", not "is it an
// Android" — because the second is the thing callers get subtly wrong when a
// new platform arrives.
//
// What it is not: a permission system. The microphone permission is asked on
// the gesture that needs it (see `mic_access.dart`) and the answer is
// remembered there; [hasMicrophone] reads that answer back rather than asking
// again, because a capability check must never put a dialog on screen by
// itself.
library;

import 'package:flutter/foundation.dart'
    show
        TargetPlatform,
        defaultTargetPlatform,
        debugPrint,
        visibleForTesting;
import 'package:flutter/services.dart' show MethodChannel;

import 'llm.dart' show kLlmRamFloorBytes, totalRamBytes;
import 'mic_access.dart';
import 'speech.dart';

/// Platforms whose builds in this checkout carry the on-device engine.
///
/// Proved rather than assumed: Android ships `libllamadart.so` and friends in
/// the APK, and Linux is where the weights were first downloaded and answered
/// from (see `docs/evidence/on_device_ai_20261018`). Adding a platform is one
/// line here, once its build really does carry the engine — which is the point
/// of the set: a device that would fail to load the model should never be
/// offered the 470 MB download.
const Set<TargetPlatform> kOnDeviceAiPlatforms = <TargetPlatform>{
  TargetPlatform.android,
  TargetPlatform.linux,
};

/// The sentence Settings shows where the download would be, on a device that
/// cannot run the model at all. It names the way out in the same breath, the
/// way every other notice in this app does.
const String kNoOnDeviceAiText =
    'On-device AI is not supported on this device. Connect to a PC.';

/// What this device has: a microphone, an NFC radio, a platform that can run a
/// model of its own.
///
/// Every answer is cheap and none of them throws. A capability check that could
/// fail the build of a screen would be worse than the thing it was checking —
/// an unsupported device gets *shorter UI*, never an error page.
class DeviceCapabilities {
  const DeviceCapabilities({
    this.platformOverride,
    this.ramBytes,
    this.hasNfcRadio,
  });

  /// A test seam, in the same shape as [SpeechInput.override]: a test states
  /// what the device is instead of running on it. The app never sets it.
  @visibleForTesting
  static DeviceCapabilities Function()? override;

  /// What the shell asks. Constant, because nothing here is expensive and
  /// [platform] is read at call time — a test that swaps the platform override
  /// under the app gets the new answer on the next rebuild.
  static DeviceCapabilities get current =>
      override?.call() ?? const DeviceCapabilities();

  /// The platform a test or a caller states, or null to ask the framework.
  ///
  /// Public and named for what it is — an override — because a field called
  /// `platform` sitting beside a getter of the same name is the kind of thing a
  /// reader has to unpick twice.
  final TargetPlatform? platformOverride;

  /// The physical memory this device has, or null for "could not be read".
  /// Injected by tests; [DeviceCapabilities.current] reads `/proc/meminfo`.
  final int? ramBytes;

  /// The NFC radio's own answer, when a platform reported one: null means "not
  /// asked yet", false means "no radio, or nobody answered".
  final bool? hasNfcRadio;

  /// The platform the app is running on, as [defaultTargetPlatform] reports it.
  TargetPlatform get platform => platformOverride ?? defaultTargetPlatform;

  bool get isAndroid => platform == TargetPlatform.android;

  bool get isIOS => platform == TargetPlatform.iOS;

  /// Android and iOS, the two places a *phone* design has to hold up.
  bool get isMobile => isAndroid || isIOS;

  /// Whether the microphone is there to be used: the platform has a recognizer
  /// at all ([SpeechInput.available]) and the user has not refused it for good.
  ///
  /// Synchronous, because it is a *drawing* decision — the composer asks it
  /// while building. The permission half is only ever as fresh as the last ask
  /// (see `mic_access.dart`); an app that has never asked and a user who has
  /// never refused both leave this true, which is exactly right: nothing has
  /// been refused yet.
  bool get microphoneAvailable {
    if (!SpeechInput.current.available) return false;
    return !MicrophoneAccess.permanentlyDenied;
  }

  /// The requested shape of the same question, for callers that treat
  /// capabilities as something to await (a future platform probe would live
  /// behind this). Today it is [microphoneAvailable] with a microtask in front.
  Future<bool> hasMicrophone() async => microphoneAvailable;

  /// Whether this device has an NFC radio Nexus could talk to.
  ///
  /// Asked of the platform once and remembered. No feature reads it yet —
  /// [hasNfc] exists so the first one that does has an answer to read instead
  /// of a channel call to write, and so a screen can be gated on it today.
  /// A platform with no handler (every desktop, iOS without CoreNFC wired up)
  /// answers false, which is the honest "nothing here to offer".
  Future<bool> hasNfc() async {
    final bool? known = hasNfcRadio;
    if (known != null) return known;
    try {
      final bool? has = await _channel.invokeMethod<bool>('hasNfc');
      return has ?? false;
    } catch (_) {
      // No radio, no channel, or no handler: the same answer to the user.
      return false;
    }
  }

  /// Whether this build could run the on-device model here.
  ///
  /// Two questions, in order: does this platform's build carry the engine
  /// ([kOnDeviceAiPlatforms]), and is there memory for the weights? A device
  /// whose memory cannot be read is not blocked on that ground — the RAM check
  /// is there to stop a 2 GB phone from being offered a model it will swap to
  /// death, not to be a second gate.
  bool supportsOnDeviceAi() {
    if (!kOnDeviceAiPlatforms.contains(platform)) return false;
    final int? ram = ramBytes ?? totalRamBytes();
    if (ram == null) return true;
    return ram >= kLlmRamFloorBytes;
  }

  /// Whether the wake word ("Hey Nexus") can be listened for here: it is
  /// openWakeWord over ONNX Runtime, which is bundled on Android only.
  bool get supportsWakeWord => isAndroid;

  /// Whether replies can be read out loud here — the platform's own text to
  /// speech, which this build wires up for Android (see `SpeechOutput`).
  bool get supportsSpokenReplies => SpeechOutput.current.available;

  /// Whether a launcher icon can be changed here — the Android activity
  /// aliases behind Settings → Customization.
  bool get supportsLauncherIcons => isAndroid;

  static const MethodChannel _channel = MethodChannel('dev.nexus.nexus/device');

  /// Opens this app's page in the OS settings, where a refused permission is
  /// turned back on. Never throws: the button that calls this is the user's way
  /// *out* of a dead end, and one that can itself fail is not a way out.
  Future<bool> openAppSettings() async {
    try {
      await _channel.invokeMethod<void>('openAppSettings');
      return true;
    } catch (error) {
      debugPrint('DEVICE: no settings page to open ($error)');
      return false;
    }
  }
}
