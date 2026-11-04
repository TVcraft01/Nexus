// The stop button.
//
// Checked by the executor before *every* step, not once at the start: the point
// of a kill switch is that the thing you want stopped stops now, including
// between step two and step three. Tripping it never claims to undo work — that
// is the rollback path — and it stays tripped until the user resets it, so a
// plan cannot slip through a moment after the panic.
class KillSwitch {
  bool _tripped = false;

  bool get tripped => _tripped;

  void trip() => _tripped = true;

  /// The user's own reset. Nothing tripped it on their behalf.
  void reset() => _tripped = false;
}
