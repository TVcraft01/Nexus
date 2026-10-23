// Neural Circuit Model (NCM) inference engine.
//
// Placeholder for future on-device NCM text generation.
library;

import 'local_ai_service.dart' show AiTurn;
import 'text_generation_backend.dart';

/// Text generation backend targeting Stanford's Neural Circuit Model (NCM).
class NcmBackend implements TextGenerationBackend {
  const NcmBackend();

  @override
  Stream<String> generateStream(
    String prompt, {
    List<AiTurn>? history,
  }) {
    throw UnimplementedError('NCM backend is not yet available on this device.');
  }
}
