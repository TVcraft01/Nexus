// The in-app model, as a brain the assistant already knows how to talk to.
//
// The seam was built for this: [LocalBrain] is what the conversation engine
// asks when a phrase is not a command ("hello", "why is the sky blue"), and
// until now the *only* thing behind it was an Ollama server on the same
// machine — a dependency, not a brain. This adapter puts a model that ships
// with Nexus behind the same seam: [Llm] loads it, runs it, and gets out of
// the way. Everything the engine does — the Thinking card, the teach-card
// restore, brain health, the mesh escalation around it — is unchanged,
// because nothing above this file can tell the difference.
//
// [fallback] is the honest answer to "what if this device's model can't?": a
// first launch still fetching its weights, a hash that failed, a platform the
// runtime does not build for. Then the machine's own Ollama — when there is
// one — answers, and without one the reply is null and the assistant says it
// does not know, which is what it did before any of this existed.
import 'brain.dart';
import 'llm.dart';

class LocalModelBrain extends LocalBrain {
  /// The model that runs inside this app.
  final Llm llm;

  /// Asked only when the in-app model cannot answer at all.
  final LocalBrain? fallback;

  LocalModelBrain({required this.llm, this.fallback});

  @override
  Future<String?> availableModel({bool refresh = false}) async {
    // The file being there is the price of admission — not the model being
    // loaded. A status line must not cost a load, and a model that is cached
    // but cold can still answer the next question.
    final name = await llm.modelName();
    if (name != null) return name;
    return fallback?.availableModel(refresh: refresh);
  }

  @override
  Future<BrainReply> reply({
    required String system,
    required List<ChatTurn> history,
    double temperature = 0.7,
    int maxTokens = 300,
  }) async {
    final text = await llm.completeChat(
      system: system,
      history: history,
      maxTokens: maxTokens,
      temperature: temperature,
    );
    if (text.isNotEmpty) return (text: text, reachable: true);
    final other = fallback;
    if (other != null) {
      final reply = await other.reply(
        system: system,
        history: history,
        temperature: temperature,
        maxTokens: maxTokens,
      );
      if (reply.text != null) return reply;
    }
    // No answer anywhere. "The model is not on this device yet" and "the model
    // answered with nothing" are different facts — only the first is an
    // offline brain, and only the engine's health line should hear about it.
    return (text: null, reachable: llm.status == LlmStatus.ready);
  }
}
