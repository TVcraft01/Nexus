// The on-device model seam: a small language model that runs inside the app
// on phones, for everyday questions — local, offline, no cloud, mirroring
// how the mic and speaker seams are done. Real inference plugs into the
// `dev.nexus.nexus/tiny_brain` channel on the Android side; until then the
// platform answers honestly with null and the distributed brain escalates
// over the mesh — a phone without a tiny model is still a full assistant.
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show MethodChannel;

import 'brain.dart' show ChatTurn;

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
  const TinyBrain();

  /// Test seam, like [SpeechInput.override]: a fake on-device model for
  /// tests, so routing is provable without hardware.
  @visibleForTesting
  static TinyBrain Function()? override;

  static TinyBrain get current => override?.call() ?? const TinyBrain();

  /// The tiny model's name when one is installed on this device, or null —
  /// honest: there is no on-device model yet. Never throws.
  Future<String?> modelName() async {
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