import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/local_ai_service.dart';
import 'package:nexus/core/ollama_service.dart';
import 'package:nexus/core/on_device_ai_service.dart';

/// A brain with nothing behind it: proof that the shell asks the *seam*, not
/// the chain underneath it, for an answer.
class _FakeBrain extends LocalAiService {
  @override
  Future<String> generateResponse(String prompt) async => 'answered: $prompt';

  /// One piece: the whole answer. The seam's contract has to hold for a brain
  /// that has nothing to stream, which is what the PC's Ollama is today.
  @override
  Stream<String> generateResponseStream(
    String prompt, {
    List<AiTurn> history = const <AiTurn>[],
  }) async* {
    yield await generateResponse(prompt);
  }
}

void main() {
  tearDown(() {
    LocalAiService.override = null;
    LocalAiService.resetDefault();
  });

  test('the shell asks the seam, and the fake is what answers', () async {
    LocalAiService.override = _FakeBrain.new;
    expect(
      await LocalAiService.current.generateResponse('are you there'),
      'answered: are you there',
    );
  });

  test('the shell gets this device first, then a PC', () {
    // The default is a chain, not a client: the on-device model is asked first
    // and the PC's Ollama covers the case where there is no model file. The
    // order is the privacy promise — a PC must never be asked while the phone
    // itself can answer — so it is pinned here.
    final LocalAiService current = LocalAiService.current;
    expect(current, isA<FallbackAiService>());
    final FallbackAiService chain = current as FallbackAiService;
    expect(chain.onDevice, isA<OnDeviceAiService>());
    expect(chain.pc, isA<OllamaService>());

    // One chain for the life of the app: rebuilding it per message would throw
    // away a loaded 470 MB model every time somebody spoke.
    expect(LocalAiService.current, same(chain));
  });

  test('the failure sentence names the two things a user can do', () {
    // Pinned word for word: this sentence is the only thing the user is told
    // when no brain could answer, and it is what the red notice shows. It used
    // to promise the on-device engine was coming; it is here, so the sentence
    // now names it and the PC.
    expect(
      kNexusOllamaUnreachableText,
      'No AI available. Download a model in Settings, or start Ollama on '
      'your PC.',
    );
  });
}
