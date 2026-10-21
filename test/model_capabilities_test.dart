// Which features each brain unlocks, and the sentence a locked one shows.
//
// The table is the whole feature: these tests state it once for a reader and
// again for the compiler, so a future model added to the picker has to answer
// the question instead of inheriting "everything works".
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/ai_status.dart';
import 'package:nexus/core/model_capabilities.dart';
import 'package:nexus/core/on_device_model.dart';

void main() {
  tearDown(ModelCapabilities.debugReset);

  ModelCapabilities forBrain(NexusBrain brain) {
    ModelCapabilities.debugBrainOverride = brain;
    return ModelCapabilities.current;
  }

  group('the 0.5B model', () {
    test('answers chat, runs the fast path, and sees pictures', () {
      final ModelCapabilities caps = forBrain(NexusBrain.qwen);
      expect(caps.supportsArtifacts, isFalse);
      expect(caps.supportsWebSearch, isFalse);
      expect(caps.supportsVision, isTrue);
      expect(caps.supportsFastPath, isTrue);
    });

    test('names itself and says how to unlock the rest', () {
      final ModelCapabilities caps = forBrain(NexusBrain.qwen);
      expect(caps.modelName, 'Qwen 0.5B');
      // The title already says "Feature Locked"; the body is the reason, and it
      // names the model in the pocket rather than the one in a screenshot.
      final String artifact = caps.lockMessage(NexusFeature.artifacts);
      expect(artifact, startsWith('The current on-device model (Qwen 0.5B)'));
      expect(artifact, contains('too small to generate complex code'));
      expect(artifact, contains('Download Llama 3.2 1B'));
      expect(artifact, contains('connect to your PC'));

      // The web row does not promise that a download opens it: no on-device
      // model searches the web well enough to offer.
      final String web = caps.lockMessage(NexusFeature.webSearch);
      expect(web, contains('Connect to your PC'));
      expect(web, isNot(contains('Download')));
    });

    test('a bigger model is named as the one that is too small', () {
      final ModelCapabilities caps = forBrain(NexusBrain.llama);
      expect(
        caps.lockMessage(NexusFeature.webSearch),
        contains('Llama 3.2 1B'),
      );
    });
  });

  test('the 1B model unlocks artifacts and not the web', () {
    final ModelCapabilities caps = forBrain(NexusBrain.llama);
    expect(caps.supportsArtifacts, isTrue);
    expect(caps.supportsWebSearch, isFalse);
    expect(caps.supportsVision, isTrue);
  });

  test('the PC unlocks everything', () {
    final ModelCapabilities caps = forBrain(NexusBrain.pc);
    expect(caps.supportsArtifacts, isTrue);
    expect(caps.supportsWebSearch, isTrue);
    expect(caps.supportsVision, isTrue);
    expect(caps.supportsFastPath, isTrue);
  });

  test('no brain offers nothing', () {
    final ModelCapabilities caps = forBrain(NexusBrain.none);
    for (final NexusFeature feature in NexusFeature.values) {
      expect(caps.supports(feature), isFalse, reason: '$feature');
    }
    expect(caps.supportsVision, isFalse);
    expect(caps.supportsFastPath, isFalse);
  });

  group('what the probe found', () {
    test('the PC answering unlocks what the picker cannot', () {
      ModelCapabilities.observe(const AiStatus(AiSource.pc));
      expect(ModelCapabilities.current.supportsWebSearch, isTrue);
      expect(ModelCapabilities.current.supportsArtifacts, isTrue);
    });

    test('no AI at all locks everything, even the 1B selection', () {
      ModelChoice.override = () => ModelChoice(
        store: MemoryModelChoiceStore(OnDeviceModelChoice.llama.id),
      );
      addTearDown(() {
        ModelChoice.override = null;
        ModelChoice.debugReset();
      });
      ModelCapabilities.observe(const AiStatus(AiSource.none));
      expect(ModelCapabilities.current.supportsArtifacts, isFalse);
      expect(ModelCapabilities.current.supportsWebSearch, isFalse);
    });

    test('a device answering follows the picker, not a stale probe', () async {
      final ModelChoice selected = ModelChoice(
        store: MemoryModelChoiceStore(OnDeviceModelChoice.llama.id),
      );
      await selected.ensureLoaded();
      ModelChoice.override = () => selected;
      addTearDown(() {
        ModelChoice.override = null;
        ModelChoice.debugReset();
      });
      ModelCapabilities.observe(const AiStatus(AiSource.pc));
      expect(ModelCapabilities.current.supportsWebSearch, isTrue);

      // The model was downloaded while the app was running: the next look at
      // the brain says the device answers, and the PC capability goes away.
      ModelCapabilities.observe(const AiStatus(AiSource.onDevice));
      expect(ModelCapabilities.current.supportsWebSearch, isFalse);
      expect(ModelCapabilities.current.supportsArtifacts, isTrue);
    });
  });

  test('the lock subtitle names what unlocks the row', () {
    final ModelCapabilities caps = forBrain(NexusBrain.qwen);
    expect(caps.lockSubtitle(NexusFeature.artifacts), contains('Llama 3.2 1B'));
    expect(caps.lockSubtitle(NexusFeature.webSearch), 'Locked — needs your PC');
  });
}
