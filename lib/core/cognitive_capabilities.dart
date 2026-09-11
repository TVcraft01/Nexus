import 'cognitive_state.dart';

/// A small registry Nexus can rebuild whenever devices appear, disappear, or
/// install an update. The registry describes capabilities, not arbitrary
/// permissions: execution remains owned by the existing device executor.
class CapabilityRegistry {
  const CapabilityRegistry();

  CognitiveState advertise(
    CognitiveState state,
    Iterable<NexusCapability> capabilities,
  ) {
    final next = Map<String, NexusCapability>.from(state.capabilities);
    for (final capability in capabilities) {
      next[capability.id] = capability;
    }
    return state.copyWith(capabilities: next);
  }

  CognitiveState removeProvider(CognitiveState state, String providerId) {
    final next = Map<String, NexusCapability>.from(state.capabilities)
      ..removeWhere((_, value) => value.providerId == providerId);
    return state.copyWith(capabilities: next);
  }

  /// Produces a compact description suitable for a local model's context.
  /// Only advertised capabilities are included; this prevents the model from
  /// hallucinating a tool that no connected device actually provides.
  String context(CognitiveState state) {
    final available = state.capabilities.values.where((c) => c.available);
    if (available.isEmpty) return 'Available Nexus capabilities: none.';
    final lines = [
      for (final capability in available)
        '- ${capability.id}: ${capability.description} (provider: ${capability.providerId})',
    ];
    return 'Available Nexus capabilities:\n${lines.join('\n')}';
  }
}
