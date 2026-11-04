// The planner: the model's only way into the loop.
//
// It goes through the existing [TextGenerationBackend] seam, so the same
// planner runs behind an Ollama model, the in-app model or the phone's channel
// without knowing which. What comes back is text; [readProposal] is the only
// thing that turns it into steps, and it treats every field as untrusted — the
// tool name is a string the registry will have to recognise, and there is no
// field a tier could hide in.
//
// A reply that is not JSON is not a crash and not an empty plan: it is a
// [ProposedPlan] that is not [ProposedPlan.readable], which the validator
// rejects in words the user can read.
import 'dart:convert';

import '../local_ai_service.dart' show AiTurn;
import '../text_generation_backend.dart';
import 'plan.dart';
import 'registry.dart';

class Planner {
  Planner({required this.backend, required this.registry});

  final TextGenerationBackend backend;
  final ToolRegistry registry;

  /// The prompt: the tools that exist, the ask, and the JSON shape wanted.
  ///
  /// The rules are short because a small model reads all of them or none: one
  /// tool per step, an argument it was never told goes in "questions" rather
  /// than a guess, and it never writes a risk tier — the tool already has one.
  String promptFor(String goal) =>
      '''
You plan one task at a time, from the tools below and nothing else:
${registry.catalogue()}

The ask: $goal

Answer with JSON and nothing else, in this shape:
{"goal": "the ask in one sentence", "steps": [{"tool": "a name from the list", "args": {}, "description": "one plain sentence"}], "questions": []}

Rules:
- A tool name must come from the list. There is no other tool.
- Put every argument a step needs in its "args". If the user never said it, put a question in "questions" instead of guessing.
- Never write a risk tier: each tool already has one.
- A destructive step's description has to name the device it affects.
- If the ask is a question rather than something to do, leave "steps" empty and put what you need in "questions".
''';

  /// Asks the model for a plan for [goal].
  ///
  /// Streams the reply and reads it whole: a plan is one object, so there is
  /// nothing to do with half of it.
  Future<ProposedPlan> propose({
    required String goal,
    List<AiTurn> history = const <AiTurn>[],
  }) async {
    final buffer = StringBuffer();
    await backend
        .generateStream(promptFor(goal), history: history)
        .forEach(buffer.write);
    return readProposal(buffer.toString(), goal: goal);
  }
}

/// Reads a model reply as a plan, or says it could not.
///
/// Tolerant about the wrapping — a fenced block or a sentence before the JSON
/// are both forgiven — and strict about the contents: a step that is not an
/// object, or whose tool is not text, is not a step.
ProposedPlan readProposal(String reply, {required String goal}) {
  final int start = reply.indexOf('{');
  final int end = reply.lastIndexOf('}');
  if (start < 0 || end <= start) {
    return ProposedPlan(goal: goal, readable: false);
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(reply.substring(start, end + 1));
  } on FormatException {
    return ProposedPlan(goal: goal, readable: false);
  }
  if (decoded is! Map) {
    return ProposedPlan(goal: goal, readable: false);
  }

  final map = Map<String, Object?>.from(decoded);
  final notes = <String>[];
  if (map.containsKey('risk')) {
    notes.add("The model wrote a risk tier; I ignored it and used the tool's.");
  }

  final questions = <String>[
    for (final question in map['questions'] as List? ?? const <Object?>[])
      if (question.toString().trim().isNotEmpty) question.toString().trim(),
  ];

  final steps = <ProposedStep>[];
  for (final raw in map['steps'] as List? ?? const <Object?>[]) {
    if (raw is! Map) {
      notes.add('A step was not an object, so I skipped it.');
      continue;
    }
    final step = Map<String, Object?>.from(raw);
    if (step.containsKey('risk')) {
      notes.add('The model wrote a risk tier for a step; I ignored it.');
    }
    final args = step['args'] is Map
        ? Map<String, Object?>.from(step['args'] as Map)
        : <String, Object?>{};
    if (args.remove('risk') != null) {
      notes.add(
        "The model put a risk tier in a step's arguments; I removed "
        'it.',
      );
    }
    steps.add(
      ProposedStep(
        tool: (step['tool'] ?? '').toString().trim(),
        args: args,
        description: (step['description'] ?? '').toString(),
      ),
    );
  }

  final stated = (map['goal'] ?? '').toString().trim();
  return ProposedPlan(
    goal: stated.isEmpty ? goal : stated,
    steps: steps,
    questions: questions,
    notes: notes,
  );
}
