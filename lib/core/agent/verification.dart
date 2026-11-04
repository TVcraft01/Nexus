// What a tool measured after it ran.
//
// A command exiting 0 is evidence that a command ran, not that the world
// changed. A step is done only when the tool has read the change back off the
// device and found it there, so the result of the read-back is the only thing
// the executor accepts as done.
class VerificationResult {
  const VerificationResult._({
    required this.ok,
    required this.measured,
    required this.reason,
  });

  /// The change was read back from the device and it is there.
  const VerificationResult.ok(String measured)
    : this._(ok: true, measured: measured, reason: '');

  /// The device does not show the change, for [reason].
  const VerificationResult.failed(String reason)
    : this._(ok: false, measured: '', reason: reason);

  final bool ok;

  /// What was read back — the numbers a report cites instead of a return code.
  final String measured;

  /// Why the read-back did not show the change. Empty when [ok].
  final String reason;
}
