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
    LocalAiService.memoryContext = null;
    LocalAiService.customInstructions = null;
    LocalAiService.resetDefault();
  });

  test('the shell asks the seam, and the fake is what answers', () async {
    LocalAiService.override = _FakeBrain.new;
    expect(
      await LocalAiService.current.generateResponse('are you there'),
      'answered: are you there',
    );
  });

  test('the shell routes through the hive, with this device and a PC behind it', () {
    // The default is the router, not a client: a paired PC that answers Ollama
    // is asked first, and the phone's own model covers the case where it does
    // not. Both brains are wired here, once, and the router chooses per answer.
    final LocalAiService current = LocalAiService.current;
    expect(current, isA<HiveRouter>());
    final HiveRouter router = current as HiveRouter;
    expect(router.onDevice, isA<OnDeviceAiService>());
    expect(router.pc, isA<OllamaService>());

    // One router for the life of the app: rebuilding it per message would throw
    // away a loaded 470 MB model every time somebody spoke.
    expect(LocalAiService.current, same(router));
  });

  test('a custom instruction joins memory in the system turn', () {
    LocalAiService.memoryContext = () =>
        'What I remember:\n- TVCraft is the user.';
    LocalAiService.customInstructions = () =>
        'The user is TVCraft. Always answer in French.';

    final String system = LocalAiService.systemWithMemory('You are Nexus.');
    expect(system, startsWith('You are Nexus.'));
    expect(system, contains('TVCraft is the user'));
    expect(
      system,
      contains(
        'Standing instructions from the user. Follow them in every answer:\n'
        'The user is TVCraft. Always answer in French.',
      ),
    );
  });

  test('an empty custom instruction leaves the prompt untouched', () {
    LocalAiService.customInstructions = () => '   ';
    expect(LocalAiService.systemWithMemory('You are Nexus.'), 'You are Nexus.');
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
