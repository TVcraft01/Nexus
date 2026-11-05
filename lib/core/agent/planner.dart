// The planner: the model's only way into the loop.
//
// It goes through the existing [TextGenerationBackend] seam, so the same
// planner runs behind an Ollama model, the in-app model or the phone's channel
// without knowing which. What comes back is text; [readProposal] is the only
// thing that turns it into steps, and it treats every field as untrusted — the
// tool name is a string the registry will have to recognise, and there is no
// field a tier could hide in.
//
// Three things make it reliable, in the order they cost:
//
//  1. a known goal (Wi-Fi status, signal, band, DNS, power save) is planned by
//     [PlanFastPath] without asking a model at all;
//  2. the model is constrained to a schema generated from the registered tools
//     when the backend supports structured output;
//  3. a plan the validator rejects is sent back with its faults, up to
//     [maxRepairs] times, and only then given up on.
//
// A reply that is not JSON is not a crash and not an empty plan: it is a
// [ProposedPlan] that is not [ProposedPlan.readable], which the validator
// rejects in words the user can read.
import 'dart:convert';

import '../local_ai_service.dart' show AiTurn;
import '../text_generation_backend.dart';
import 'fast_path.dart';
import 'plan.dart';
import 'plan_schema.dart';
import 'plan_validator.dart';
import 'registry.dart';

class Planner {
  Planner({
    required this.backend,
    required this.registry,
    PlanValidator? validator,
    PlanFastPath? fastPath,
    this.maxRepairs = 2,
  }) : validator = validator ?? PlanValidator(registry),
       fastPath = fastPath ?? PlanFastPath();

  final TextGenerationBackend backend;
  final ToolRegistry registry;
  final PlanValidator validator;

  /// Known goals answered without the model.
  final PlanFastPath fastPath;

  /// How many times a rejected plan is sent back with its faults. Two means up
  /// to three answers: enough for a wording mistake, short enough that a model
  /// which cannot do it does not hold the chat.
  final int maxRepairs;

  /// The plan shape as a JSON schema, generated from the registered tools.
  Map<String, Object?> get schema => planJsonSchema(registry);

  /// The prompt: the tools that exist, the ask, the schema, and the rules.
  ///
  /// The rules are short because a small model reads all of them or none: one
  /// tool per step, an argument it was never told goes in "questions" rather
  /// than a guess, and it never writes a risk tier — the tool already has one.
  /// The schema appears in the prompt as well as in the request, because
  /// Ollama's own guidance is that the decoder constraint and the prompt should
  /// say the same thing.
  String promptFor(String goal) =>
      '''
You plan one task at a time, from the tools below and nothing else:
${registry.catalogue()}

The ask: $goal

Answer with JSON and nothing else, matching this schema exactly:
${planSchemaText(registry)}

Rules:
- A tool name must come from the list. There is no other tool.
- Put every argument a step needs in its "args". If the user never said it, put one plain question in "questions" instead of guessing.
- Never write a risk tier: each tool already has one.
- A destructive step's description has to name the device it affects.
- If the ask is a question rather than something to do, leave "steps" empty and put what you need in "questions".
''';

  /// The second (and third) attempt: the same ask, with what was wrong.
  ///
  /// The faults are the validator's own sentences, not a paraphrase, so the
  /// model is corrected against the rule it actually broke.
  String repairPrompt({required String goal, required List<String> faults}) =>
      '''
Your last answer could not be used:
${faults.map((fault) => '- $fault').join('\n')}

The ask: $goal

Answer again with JSON only, matching this schema exactly:
${planSchemaText(registry)}

Fix exactly what is listed above and change nothing else. A tool name must come from the list, and a step may only carry the arguments its own tool declares — never another tool's. Anything the user never said is one question in "questions" rather than a guess or an invented argument.
''';

  /// Asks for a plan for [goal]: fast path first, then the model, then repairs.
  ///
  /// Streams each reply and reads it whole: a plan is one object, so there is
  /// nothing to do with half of it.
  Future<ProposedPlan> propose({
    required String goal,
    List<AiTurn> history = const <AiTurn>[],
  }) async {
    final known = fastPath.plan(goal);
    if (known != null) return known;

    var last = const ProposedPlan(goal: '', readable: false);
    var faults = const <String>[];
    for (var attempt = 0; attempt <= maxRepairs; attempt++) {
      final prompt = attempt == 0
          ? promptFor(goal)
          : repairPrompt(goal: goal, faults: faults);
      final reply = await _reply(prompt, history);
      final proposal = readProposal(reply, goal: goal);
      last = proposal;
      final validation = validator.validate(proposal);
      if (isAnswerable(validation)) {
        return attempt == 0
            ? proposal
            : _noted(
                proposal,
                'The model needed '
                '${attempt == 1 ? 'one repair' : '$attempt repairs'} before '
                'the plan was usable.',
              );
      }
      faults = validation is PlanRejected
          ? validation.faults
          : const <String>[];
    }
    return _noted(
      last,
      'I asked the model ${maxRepairs + 1} times and it still could not make '
      'a plan I can use.',
    );
  }

  Future<String> _reply(String prompt, List<AiTurn> history) async {
    final buffer = StringBuffer();
    final backend = this.backend;
    // Explicit cast: the declared type is the plain backend, so the capability
    // has to be named before its method can be called.
    final structured = backend is StructuredGeneration
        ? backend as StructuredGeneration
        : null;
    final Stream<String> stream = structured != null
        ? structured.generateStructured(
            prompt,
            schema: schema,
            history: history,
          )
        : backend.generateStream(prompt, history: history);
    await stream.forEach(buffer.write);
    return buffer.toString();
  }

  static ProposedPlan _noted(ProposedPlan plan, String note) => ProposedPlan(
    goal: plan.goal,
    steps: plan.steps,
    questions: plan.questions,
    notes: <String>[...plan.notes, note],
    readable: plan.readable,
  );
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
