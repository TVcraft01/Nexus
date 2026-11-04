// How much a step can change, and therefore who has to agree to it.
//
// This is the whole safety model in one enum: a tool declares its tier once, at
// registration, and the executor reads it back off the registered tool. The
// model never writes a tier — it may only propose a step, and a step's tier is
// whatever the tool it names already is. See `docs/AGENT_CORE.md`.
enum RiskTier {
  /// Reading status. Nothing changes, so nothing has to be asked.
  read,

  /// Changes a setting. The tool's rollback puts it back.
  change,

  /// Loses data, or removes access.
  destructive,
}

extension RiskTierWording on RiskTier {
  /// The tier as a plan line says it, in words a person reads.
  String get label => switch (this) {
    RiskTier.read => 'reading',
    RiskTier.change => 'a change',
    RiskTier.destructive => 'destructive',
  };

  /// What the tier means for the question the user answers before it runs.
  String get promise => switch (this) {
    RiskTier.read => 'nothing changes',
    RiskTier.change =>
      'changes a setting, and I put it back if it does not verify',
    RiskTier.destructive =>
      'this loses data or access, and I put it back only if that is possible',
  };

  /// Whether the user is asked before a step of this tier runs.
  ///
  /// Reading is the only tier that may run without asking — and the executor,
  /// not the planner, is what enforces that.
  bool get needsApproval => this != RiskTier.read;
}
