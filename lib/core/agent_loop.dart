// The agent loop: the model decides which tool to call, the tool runs, the
// model is told what it found, and then it answers. That round trip is the
// gap between a chatbot and an assistant — the model acts through the verbs
// the app already has instead of only talking about them.
//
// One exchange, at most [ToolLoop.maxSteps] tool calls, and every step
// checked by [toolRefusal] before anything runs. The loop owns the protocol
// (the TOOL line, the observation handed back) and nothing else: the tools
// themselves live in `agent_tools.dart`, and the brain behind it is the same
// [LocalBrain] seam the assistant already talks to — so an Ollama model, the
// in-app model, or the phone's tiny-brain channel all drive the same loop.
import 'agent_tools.dart';
import 'brain.dart';

/// What the model is told before its result: the observation on its own
/// line, so the loop's own protocol and the tool's words stay separable.
const String toolResultPrefix = 'Tool result: ';

/// The sentence that follows an observation, asking for the answer the user
/// sees. Written as one turn instead of a separate system prompt because the
/// model's chat template already has the conversation open.
const String _answerInstruction =
    'Answer the user now in one or two short sentences, using only this '
    'result.';

/// One exchange through the loop: the model's final [text] (null when it had
/// nothing to say and no tool ran — the caller's fallback then stands),
/// whether the brain was [reachable], and which tools ran, in order.
typedef ToolLoopReply = ({String? text, bool reachable, List<String> ran});

class ToolLoop {
  const ToolLoop({required this.brain, this.tools, this.maxSteps = 2});

  /// The model being asked. The loop adds the tool block to whatever system
  /// prompt the caller built; everything else about the exchange — health,
  /// reachability, the thread — is the caller's.
  final LocalBrain brain;

  /// The tools this device wired. Null means this device has none: the loop
  /// is then one plain brain call, exactly what the assistant did before
  /// there was a loop at all.
  final ToolRunner? tools;

  /// How many tool calls one exchange may make. Small on purpose: a tool call
  /// is a detour, and a small model that keeps asking for tools is looping,
  /// not working.
  final int maxSteps;

  /// Answers one ask, running tools along the way. [onRunning] fires with the
  /// call the moment it is accepted and before it runs, so a caller can say
  /// what is happening while it happens. Never throws: a brain that fails
  /// answers null, which is the seam's own contract.
  Future<ToolLoopReply> run({
    required String system,
    required String ask,
    required List<ChatTurn> history,
    double temperature = 0.7,
    int maxTokens = 300,
    void Function(ToolCall call)? onRunning,
  }) async {
    final runner = tools;
    final turns = [...history];
    final ran = <String>[];
    String? lastObservation;
    while (true) {
      final reply = await brain.reply(
        // The tool block is added here, not by the caller: the words the
        // model is told and the parser that reads it back are one file's
        // business.
        system: runner == null ? system : toolSystemPrompt(system),
        history: turns,
        temperature: temperature,
        maxTokens: maxTokens,
      );
      final text = reply.text;
      if (text == null) {
        // Nothing from the model. A tool did run, so what it found is the
        // truth to answer with — better than the caller's fallback, which
        // knows nothing about the tool.
        return (text: lastObservation, reachable: reply.reachable, ran: ran);
      }
      if (runner == null) return (text: text, reachable: true, ran: ran);
      final request = readToolRequest(text);
      final call = request.call;
      if (call == null ||
          toolRefusal(call, ask) != null ||
          ran.length >= maxSteps) {
        // Nothing runnable: no call, a call the ask did not imply, or the
        // detour budget spent. The model's own words, minus any TOOL line,
        // are the answer; a tool that already ran leaves its finding as the
        // answer when the model then says nothing itself.
        final answer = request.text.isNotEmpty ? request.text : lastObservation;
        if (answer != null) return (text: answer, reachable: true, ran: ran);
        // Nothing was said and nothing ran — a small model that reached for
        // a tool it may not have, or fumbled one. One more ask, without the
        // tool block: the model is not choosing now, only answering. This is
        // the difference between "I can't do that" and being asked what a
        // sentence means when the model clearly understood it.
        final plain = await brain.reply(
          system: system,
          history: history,
          temperature: temperature,
          maxTokens: maxTokens,
        );
        // The plain prompt carries no tool block, but a model can still
        // write one; strip it for the same reason the loop strips it
        // everywhere else — protocol syntax is never the user's answer.
        final retry = readToolRequest(plain.text ?? '').text;
        return (
          text: retry.isEmpty ? null : retry,
          reachable: plain.reachable,
          ran: ran,
        );
      }
      ran.add(call.name);
      onRunning?.call(call);
      final observation = await runner.run(call);
      lastObservation = observation;
      turns
        ..add((role: 'assistant', content: text))
        ..add((
          role: 'user',
          content: '$toolResultPrefix$observation\n$_answerInstruction',
        ));
    }
  }
}
