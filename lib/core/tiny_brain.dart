// The on-device model seam: a small language model that runs inside the app
// on phones, for everyday questions — local, offline, no cloud, mirroring
// how the mic and speaker seams are done.
//
// There are two ways a device can have one. A build that carries the in-app
// model ([Llm], the same runtime the desktop uses) answers in Dart, on
// whatever platform it runs on; a build with no model of its own asks the
// platform over the `dev.nexus.nexus/tiny_brain` channel, and a platform
// without one answers honestly with null — the distributed brain then
// escalates over the mesh, so a phone with no tiny model is still a full
// assistant.
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show MethodChannel;

import 'brain.dart' show ChatTurn;
import 'llm.dart';

/// One answer from the on-device model, with the model's own confidence
/// (0..1). A low-confidence answer is an everyday question gone sideways —
/// the distributed brain escalates it to a stronger brain instead of
/// repeating it as truth.
class TinyAnswer {
  final String text;
  final double confidence;

  const TinyAnswer({required this.text, required this.confidence});
}

class TinyBrain {
  /// The in-app model, when this build runs one ([Llm]). Null leaves the seam
  /// to the platform channel, exactly as it was before a model shipped inside
  /// the app.
  final Llm? llm;

  const TinyBrain({this.llm});

  /// Test seam, like [SpeechInput.override]: a fake on-device model for
  /// tests, so routing is provable without hardware.
  @visibleForTesting
  static TinyBrain Function()? override;

  static TinyBrain get current => override?.call() ?? const TinyBrain();

  /// The tiny model's name when one is installed on this device, or null when
  /// there is none to name. Never throws.
  Future<String?> modelName() async {
    final model = llm;
    if (model != null) return model.modelName();
    try {
      return await _channel.invokeMethod<String>('modelName');
    } catch (_) {
      return null;
    }
  }

  /// One answer for [system] + [history], or null when no on-device model
  /// is available or it could not answer. Never throws — a quiet null just
  /// means the question escalates.
  Future<TinyAnswer?> ask({
    required String system,
    required List<ChatTurn> history,
  }) async {
    final model = llm;
    if (model != null) {
      final text = await model.completeChat(
        system: system,
        history: history,
        maxTokens: 200,
      );
      if (text.isEmpty) return null;
      // A model that answered is not "unsure": the confidence gate exists to
      // catch a tiny model that reports doubt, and this one either has an
      // answer or has nothing. Escalation stays where it belongs — on no
      // answer at all.
      return TinyAnswer(text: text, confidence: 1);
    }
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>('ask', {
        'system': system,
        'history': [
          for (final turn in history)
            {'role': turn.role, 'content': turn.content},
        ],
      });
      if (raw == null) return null;
      final text = raw['text']?.toString();
      final confidence = (raw['confidence'] as num?)?.toDouble();
      if (text == null || text.isEmpty || confidence == null) return null;
      return TinyAnswer(text: text, confidence: confidence);
    } catch (_) {
      return null;
    }
  }

  static const _channel = MethodChannel('dev.nexus.nexus/tiny_brain');
}