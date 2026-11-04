// What happened when a step was put back.
//
// Rollback is best-effort, and its failures are said out loud: a plan that
// half-applied and then went quiet is worse than one that failed and said so.
class RollbackResult {
  const RollbackResult._({required this.ok, required this.what});

  /// The previous state is back.
  const RollbackResult.ok(String what) : this._(ok: true, what: what);

  /// It could not be put back, for [reason].
  const RollbackResult.failed(String reason) : this._(ok: false, what: reason);

  final bool ok;

  /// What was restored, or why it could not be.
  final String what;
}
