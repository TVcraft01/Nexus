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
