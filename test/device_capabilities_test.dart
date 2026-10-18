import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/services.dart'
    show MethodCall, MethodChannel, MissingPluginException;
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/device_capabilities.dart';
import 'package:nexus/core/llm.dart' show kLlmRamFloorBytes;
import 'package:nexus/core/mic_access.dart';
import 'package:nexus/core/speech.dart';

/// What this device can do, asked on devices it is not.
///
/// The whole value of [DeviceCapabilities] is that a screen never guesses from
/// the platform name, so these tests are the guesses that used to be in the
/// screens: an iPhone that cannot run the weights, a phone with no memory for
/// them, a desktop with no recognizer, a platform with no NFC handler to ask.
/// Every one of them is asserted twice — once for the capability helper and
/// once in the UI — so a screen cannot drift from the rule.
class _FakeSpeechInput extends SpeechInput {
  const _FakeSpeechInput({required this.available});

  @override
  final bool available;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel device = MethodChannel('dev.nexus.nexus/device');

  /// Answers the app's device channel with [answer], recording every call.
  List<MethodCall> stubDeviceChannel(Object? Function(MethodCall) answer) {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(device, (MethodCall call) async {
          calls.add(call);
          return answer(call);
        });
    // The handler goes away with the test, so no later case on this channel can
    // answer for a platform it is not.
    addTearDown(
      () => TestDefaultBinaryMessengerBinding
          .instance
          .defaultBinaryMessenger
          .setMockMethodCallHandler(device, null),
    );
    return calls;
  }

  // The permission memory is process-wide on purpose, so a test that sets it
  // must not leave it set for the next one.
  setUp(MicrophoneAccess.debugReset);
  tearDown(() {
    MicrophoneAccess.debugReset();
    SpeechInput.override = null;
    DeviceCapabilities.override = null;
  });

  group('the microphone', () {
    test('is there when the platform has a recognizer', () {
      SpeechInput.override = () => const _FakeSpeechInput(available: true);
      expect(const DeviceCapabilities().microphoneAvailable, isTrue);
    });

    test('is not there on a device whose build cannot listen', () {
      // What an iPhone or a desktop answers today: no recognizer wired up, so
      // the composer must not draw a microphone for it.
      SpeechInput.override = () => const _FakeSpeechInput(available: false);
      expect(const DeviceCapabilities().microphoneAvailable, isFalse);
    });

    test('is gone once the system has refused for good', () {
      SpeechInput.override = () => const _FakeSpeechInput(available: true);
      expect(const DeviceCapabilities().microphoneAvailable, isTrue);

      // Android's "Don't allow": there is no dialog left to show, so the button
      // is not offered at all — the settings page is the only way back, and the
      // dialog that says so is the one that appears while it is still a maybe.
      MicrophoneAccess.permanentlyDenied = true;
      expect(const DeviceCapabilities().microphoneAvailable, isFalse);
    });

    test('answers the awaited form of the same question', () async {
      SpeechInput.override = () => const _FakeSpeechInput(available: true);
      expect(await const DeviceCapabilities().hasMicrophone(), isTrue);
      SpeechInput.override = () => const _FakeSpeechInput(available: false);
      expect(await const DeviceCapabilities().hasMicrophone(), isFalse);
    });
  });

  group('the on-device model', () {
    test('runs where the build carries the engine and the memory fits', () {
      expect(
        const DeviceCapabilities(
          platformOverride: TargetPlatform.android,
          ramBytes: kLlmRamFloorBytes,
        ).supportsOnDeviceAi(),
        isTrue,
      );
      // Linux is where the weights were first downloaded and answered from —
      // the desktop build really does carry llama.cpp.
      expect(
        const DeviceCapabilities(
          platformOverride: TargetPlatform.linux,
          ramBytes: 32 * 1024 * 1024 * 1024,
        ).supportsOnDeviceAi(),
        isTrue,
      );
    });

    test('is not offered on a platform with no engine in the build', () {
      for (final TargetPlatform platform in <TargetPlatform>[
        TargetPlatform.iOS,
        TargetPlatform.macOS,
        TargetPlatform.windows,
        TargetPlatform.fuchsia,
      ]) {
        expect(
          DeviceCapabilities(
            platformOverride: platform,
            ramBytes: 32 * 1024 * 1024 * 1024,
          ).supportsOnDeviceAi(),
          isFalse,
          reason: '$platform has no build of the engine in this checkout',
        );
      }
    });

    test('is not offered to a device that cannot hold the weights', () {
      const DeviceCapabilities small = DeviceCapabilities(
        platformOverride: TargetPlatform.android,
        ramBytes: 2 * 1024 * 1024 * 1024,
      );
      expect(small.supportsOnDeviceAi(), isFalse);

      // One byte under the floor is under the floor: the check is the model's
      // size against the device's memory, not a feeling about it.
      expect(
        DeviceCapabilities(
          platformOverride: TargetPlatform.android,
          ramBytes: kLlmRamFloorBytes - 1,
        ).supportsOnDeviceAi(),
        isFalse,
      );
    });

    test('does not block a platform whose memory cannot be read', () {
      // Windows and macOS answer null to `totalRamBytes`; a device that cannot
      // be measured is not a device that has failed the measurement.
      expect(
        const DeviceCapabilities(
          platformOverride: TargetPlatform.linux,
        ).supportsOnDeviceAi(),
        isTrue,
      );
    });
  });

  group('the Android-only surfaces', () {
    test('the wake word and the launcher icon are Android, and only Android', () {
      expect(
        const DeviceCapabilities(
          platformOverride: TargetPlatform.android,
        ).supportsWakeWord,
        isTrue,
      );
      for (final TargetPlatform platform in <TargetPlatform>[
        TargetPlatform.iOS,
        TargetPlatform.linux,
        TargetPlatform.macOS,
        TargetPlatform.windows,
      ]) {
        expect(
          DeviceCapabilities(platformOverride: platform).supportsWakeWord,
          isFalse,
          reason: '$platform has no wake-word engine in this build',
        );
        expect(
          DeviceCapabilities(platformOverride: platform).supportsLauncherIcons,
          isFalse,
          reason: '$platform cannot switch a launcher icon',
        );
      }
    });

    test('spoken replies follow the speaker the shell actually has', () {
      SpeechOutput.override = () => const _SilentSpeechOutput();
      addTearDown(() => SpeechOutput.override = null);
      expect(
        const DeviceCapabilities(
          platformOverride: TargetPlatform.android,
        ).supportsSpokenReplies,
        isFalse,
      );
      expect(
        const DeviceCapabilities(
          platformOverride: TargetPlatform.iOS,
        ).supportsSpokenReplies,
        isFalse,
      );
    });

    test('is told the platform the app really runs on when not overridden', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      expect(const DeviceCapabilities().platform, TargetPlatform.iOS);
      expect(const DeviceCapabilities().isIOS, isTrue);
      expect(const DeviceCapabilities().isMobile, isTrue);
      expect(const DeviceCapabilities().isAndroid, isFalse);
    });
  });

  group('NFC', () {
    test('is absent where nothing answers the question', () async {
      // No handler at all: the honest answer is "no radio to offer", not a
      // thrown exception on its way to a crash reporter.
      expect(await const DeviceCapabilities().hasNfc(), isFalse);
    });

    test('is read from the platform when it has an answer', () async {
      stubDeviceChannel((MethodCall call) => call.method == 'hasNfc' ? true : null);
      expect(await const DeviceCapabilities().hasNfc(), isTrue);
    });

    test('can be stated by a test without a channel', () async {
      expect(
        await const DeviceCapabilities(hasNfcRadio: true).hasNfc(),
        isTrue,
      );
      expect(
        await const DeviceCapabilities(hasNfcRadio: false).hasNfc(),
        isFalse,
      );
    });
  });

  group('the way back from a refused permission', () {
    test('asks the platform to open its settings page', () async {
      final List<MethodCall> calls = stubDeviceChannel((_) => null);
      expect(await const DeviceCapabilities().openAppSettings(), isTrue);
      expect(calls.map((MethodCall call) => call.method), <String>[
        'openAppSettings',
      ]);
    });

    test('answers false, rather than throwing, when there is no such page', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(device, (MethodCall call) async {
            throw MissingPluginException('no page here');
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(device, null),
      );
      expect(await const DeviceCapabilities().openAppSettings(), isFalse);
    });
  });
}

/// A device with no speech engine: what `SpeechOutput.available` answers on a
/// platform this build has not wired up.
class _SilentSpeechOutput extends SpeechOutput {
  const _SilentSpeechOutput();

  @override
  bool get available => false;
}
