// The distributed brain — one assistant living everywhere. A phone runs a
// tiny on-device model for everyday questions (local, offline, no cloud),
// and when a question is too big or the tiny model is unsure or fails, the
// phone hands it over the mesh to a paired device with a stronger brain
// (the PC), whose reply comes back. The conversation engine never knows:
// this is a [LocalBrain] like any other, so the whole routing lives behind
// the seam Phase 1 established.
import '../mesh/mesh_service.dart';
import 'brain.dart';
import 'tiny_brain.dart';

/// Below this confidence the on-device model's answer is not good enough to
/// stand alone — the question escalates to a stronger brain.
const kEscalateBelowConfidence = 0.6;

/// A brain that lives across the mesh: the on-device [tiny] model first,
/// then escalation to the first paired peer that advertises a brain of its
/// own (see [MeshService.brainPeerIds]). Honest at every step — when no
/// brain anywhere can answer, the reply is null and the engine falls back
/// to its normal teach flow, exactly as it does with no local brain at all.
class DistributedBrain extends LocalBrain {
  final MeshService mesh;

  /// The on-device model seam; null when this device has none.
  final TinyBrain? tiny;

  /// How long one mesh handoff may take before it counts as unreachable.
  final Duration handoffTimeout;

  /// Answers below this confidence escalate to the stronger brain.
  final double escalateBelowConfidence;

  DistributedBrain({
    required this.mesh,
    this.tiny,
    this.handoffTimeout = const Duration(seconds: 30),
    this.escalateBelowConfidence = kEscalateBelowConfidence,
  });

  @override
  Future<String?> availableModel({bool refresh = false}) async {
    final name = await tiny?.modelName();
    if (name != null && name.isNotEmpty) return name;
    final peers = mesh.brainPeerIds;
    return peers.isEmpty ? null : 'mesh:${peers.first}';
  }

  @override
  Future<BrainReply> reply({
    required String system,
    required List<ChatTurn> history,
    double temperature = 0.7,
    int maxTokens = 300,
  }) async {
    // 1) The on-device model first: everyday questions stay on the phone.
    final device = tiny;
    if (device != null) {
      final answer = await device.ask(system: system, history: history);
      if (answer != null &&
          answer.confidence >= escalateBelowConfidence) {
        return (text: answer.text, reachable: true);
      }
      // No answer, or an unsure one — this question is too big: escalate.
    }
    // 2) Hand the question to a paired device with a stronger brain. Try
    //    each brain-capable peer in turn; the first real answer wins, and
    //    an offline or refusing peer is just skipped.
    for (final peerId in mesh.brainPeerIds) {
      final reply = await mesh.requestBrainAnswer(
        peerId,
        system: system,
        history: history,
        timeout: handoffTimeout,
      );
      if (reply != null && reply.text != null) return reply;
    }
    // 3) No brain anywhere could answer — honest, like a missing Ollama.
    return (text: null, reachable: false);
  }
}