// The seam for on-device and external text generation engines.
//
// Encapsulates the token streaming contract so alternative backends (such as
// llama.cpp via llamadart, Stanford's NCM, or remote inference) can be
// swapped without rewriting the assistant shell or UI.
library;

import 'local_ai_service.dart' show AiTurn;

/// Abstract interface for text generation engines that yield streamed tokens.
abstract class TextGenerationBackend {
  /// Streams response tokens for [prompt] as they are generated.
  ///
  /// [history] carries earlier conversation turns, oldest first.
  Stream<String> generateStream(String prompt, {List<AiTurn>? history});
}

/// A backend that can be constrained to a JSON schema.
///
/// Ollama accepts a schema in its `format` field on `/api/generate` and
/// `/api/chat` (structured outputs, since 0.5.0) and its decoder then only
/// produces text that fits. This is a capability rather than another parameter
/// on [TextGenerationBackend] so a backend that cannot do it does not have to
/// pretend: the planner asks with the schema when it is available, and falls
/// back to the prompt alone when it is not.
abstract interface class StructuredGeneration {
  /// Streams one reply that fits [schema].
  Stream<String> generateStructured(
    String prompt, {
    required Map<String, Object?> schema,
    List<AiTurn>? history,
  });
}
