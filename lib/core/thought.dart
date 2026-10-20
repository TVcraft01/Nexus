// Reading a model reply as two things: the reasoning it wrote down, and the
// answer it actually meant to give.
//
// The prompt asks for `<thought>…</thought>`, but a small on-device model does
// not always keep that promise and answers with a plain `Thought:` label
// instead. Both shapes are read in one place so the stream, the finished reply,
// the spoken sentence and a conversation reloaded from disk cannot disagree
// about which part is the answer.
//
// This lives in `core` because the chat log needs it when it reads an answer
// written before reasoning was stored separately: a `Thought:` paragraph in an
// old transcript must come back as a collapsed grey bubble, not as the
// assistant saying its working-out out loud.
library;

import 'package:flutter/foundation.dart' show immutable;

/// One reply split around its `<thought>` block.
///
/// [answer] is what belongs in the main bubble, [reasoning] is what belongs in
/// the collapsible one, and [thinking] is true while the reasoning has not been
/// followed by an answer yet — which is the window in which its bubble streams.
@immutable
class NexusThoughtSplit {
  const NexusThoughtSplit({
    required this.answer,
    required this.reasoning,
    required this.thinking,
  });

  final String answer;
  final String reasoning;
  final bool thinking;
}

/// Splits a model reply around its reasoning.
///
/// The prompt asks for `<thought>…</thought>`, but a small on-device model does
/// not always keep that promise: Qwen 0.5B answers with a plain `Thought:`
/// label instead. Both shapes are read here, beside each other, so the stream
/// and the finished reply cannot disagree about which part is the answer.
///
/// A labelled reply is split at the first double newline: everything before it
/// is reasoning and everything after it is the answer. Without a double
/// newline, the last labelled block is the answer and the blocks before it are
/// reasoning. A single labelled block stays an answer rather than hiding the
/// model's only useful sentence behind a collapsed bubble. A normal
/// multi-paragraph answer with no label is left whole: two paragraphs are not
/// evidence that the first one is working-out.
///
/// [finished] is false while the stream is still arriving. Until the answer
/// has arrived, labelled text stays in the reasoning bubble and the main bubble
/// is the placeholder. A standalone call defaults to a finished reply.
NexusThoughtSplit splitNexusThought(String text, {bool finished = true}) {
  const String open = '<thought>';
  const String close = '</thought>';
  final int start = text.indexOf(open);
  if (start < 0) {
    final RegExpMatch? label = _reasoningLabel.firstMatch(text);
    if (label != null) {
      return _splitLabelledReasoning(text, label, finished: finished);
    }
    return NexusThoughtSplit(
      answer: _withoutPartialTag(text, open),
      reasoning: '',
      thinking: false,
    );
  }
  final int end = text.indexOf(close, start + open.length);
  final String reasoning = end < 0
      ? text.substring(start + open.length)
      : text.substring(start + open.length, end);
  final String answer = end < 0
      ? text.substring(0, start)
      : '${text.substring(0, start)}${text.substring(end + close.length)}';
  return NexusThoughtSplit(
    answer: answer.trim(),
    reasoning: reasoning.trim(),
    thinking: end < 0,
  );
}

/// The labels a small model writes when it forgets the tags. Anchored to a line
/// start so a sentence that happens to contain the word "reasoning:" mid-line
/// is not mistaken for a reasoning block.
final RegExp _reasoningLabel = RegExp(
  r'^[ \t]*(?:thought|thinking|reasoning):[ \t]*',
  caseSensitive: false,
  multiLine: true,
);

/// Splits `Thought: …`, `Thinking: …` or `Reasoning: …` into the same two
/// pieces the tag path returns.
NexusThoughtSplit _splitLabelledReasoning(
  String text,
  RegExpMatch label, {
  required bool finished,
}) {
  final String before = text.substring(0, label.start).trim();
  final String after = text.substring(label.end);
  final int divider = after.indexOf('\n\n');
  if (divider >= 0) {
    final String reasoning = _withoutReasoningLabels(
      after.substring(0, divider),
    );
    final String answer = after.substring(divider + 2).trim();
    if (answer.isNotEmpty) {
      return NexusThoughtSplit(
        answer: _joinParagraphs(before, answer),
        reasoning: reasoning,
        thinking: false,
      );
    }
    if (!finished) {
      return NexusThoughtSplit(
        answer: before,
        reasoning: reasoning,
        thinking: true,
      );
    }
    // The stream ended on the divider. Fall through to the labelled blocks so
    // a conclusion in the last one is not thrown away.
  }
  if (!finished) {
    return NexusThoughtSplit(
      answer: before,
      reasoning: _withoutReasoningLabels(after),
      thinking: true,
    );
  }
  final List<String> blocks = _reasoningBlocks(after);
  if (blocks.length > 1) {
    final String answer = blocks.removeLast();
    return NexusThoughtSplit(
      answer: _joinParagraphs(before, answer),
      reasoning: blocks.join('\n').trim(),
      thinking: false,
    );
  }
  return NexusThoughtSplit(
    answer: _joinParagraphs(before, _withoutReasoningLabels(after)),
    reasoning: '',
    thinking: false,
  );
}

/// Every labelled block after the first label, with the labels removed.
List<String> _reasoningBlocks(String text) {
  final List<RegExpMatch> matches = _reasoningLabel.allMatches(text).toList();
  if (matches.isEmpty) return const <String>[];
  final List<String> blocks = <String>[];
  // The first label was consumed by the caller, so the text before the next
  // label is a block too — without this the first thought disappears whenever
  // the model labels every line.
  final String first = text.substring(0, matches.first.start).trim();
  if (first.isNotEmpty) blocks.add(first);
  for (int i = 0; i < matches.length; i++) {
    final int start = matches[i].end;
    final int end = i + 1 < matches.length ? matches[i + 1].start : text.length;
    final String block = text.substring(start, end).trim();
    if (block.isNotEmpty) blocks.add(block);
  }
  return blocks;
}

String _withoutReasoningLabels(String text) =>
    text.replaceAll(_reasoningLabel, '').trim();

String _joinParagraphs(String before, String after) {
  final String first = before.trim();
  final String second = after.trim();
  if (first.isEmpty) return second;
  if (second.isEmpty) return first;
  return '$first\n\n$second';
}

/// Drops a trailing fragment of [tag] — `<thou`, for example — that the stream
/// has not finished writing.
String _withoutPartialTag(String text, String tag) {
  final int lt = text.lastIndexOf('<');
  if (lt < 0 || text.length - lt >= tag.length) return text;
  final String fragment = text.substring(lt).toLowerCase();
  return tag.startsWith(fragment) ? text.substring(0, lt).trimRight() : text;
}
