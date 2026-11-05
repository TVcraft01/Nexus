// The JSON schema the model is constrained to, built from the registry.
//
// Ollama's structured outputs take a JSON schema in the `format` field and the
// decoder only produces text that fits it (documented for `/api/generate` and
// `/api/chat`). The schema here is generated from the tools that are actually
// registered, so the tool list in the prompt and the tool enum in the schema
// cannot drift apart: a name the registry does not have is not a name the
// decoder can produce.
//
// One branch per tool, not one shared `args` object. A shared object is a union
// of every tool's arguments, and a small model then puts `connection` on
// `wifi_status` because the schema allowed it — measured on llama3.2, that was
// the whole of the planner's remaining failure rate. With a branch per tool,
// the arguments a step may carry are that tool's arguments and nothing else.
//
// `args` lists its properties but does not make them required: a decoder forced
// to fill a value the user never said would invent one, and asking is the rule.
import 'dart:convert';

import 'registry.dart';
import 'tool.dart';

/// The plan shape, as a schema, for the tools in [registry].
Map<String, Object?> planJsonSchema(ToolRegistry registry) {
  final tools = <Tool>[...registry.tools]
    ..sort((a, b) => a.name.compareTo(b.name));
  return <String, Object?>{
    'type': 'object',
    'properties': <String, Object?>{
      'goal': <String, Object?>{'type': 'string'},
      'steps': <String, Object?>{
        'type': 'array',
        'items': <String, Object?>{'anyOf': <Object?>[for (final tool in tools) _stepSchema(tool)]},
      },
      'questions': <String, Object?>{
        'type': 'array',
        'items': <String, Object?>{'type': 'string'},
      },
    },
    'required': <String>['goal', 'steps', 'questions'],
  };
}

/// One tool's step: its own name, and only its own arguments.
Map<String, Object?> _stepSchema(Tool tool) => <String, Object?>{
  'type': 'object',
  'properties': <String, Object?>{
    'tool': <String, Object?>{
      'type': 'string',
      'enum': <String>[tool.name],
    },
    'args': <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        for (final entry in tool.args.entries)
          entry.key: _typeSchema(entry.value.type),
      },
      'additionalProperties': false,
    },
    'description': <String, Object?>{'type': 'string'},
  },
  'required': <String>['tool', 'args', 'description'],
  'additionalProperties': false,
};

Map<String, Object?> _typeSchema(ArgType type) => switch (type) {
  ArgType.text => <String, Object?>{'type': 'string'},
  ArgType.flag => <String, Object?>{'type': 'boolean'},
  ArgType.whole => <String, Object?>{'type': 'integer'},
};

/// The same schema as text, for the prompt.
///
/// Ollama's docs recommend passing the schema in the prompt as well as in
/// `format`: the format constrains the decoder, the prompt tells the model what
/// it is being constrained to, and a small model needs both.
String planSchemaText(ToolRegistry registry) =>
    const JsonEncoder.withIndent('  ').convert(planJsonSchema(registry));
