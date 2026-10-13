import 'dart:async';

import 'package:flutter/widgets.dart';

import 'mesh_service.dart';

/// Releases the mesh's listening socket when the Flutter engine goes away.
///
/// An Activity recreation (or any engine detach/reattach) in the same process
/// used to leave the old `ServerSocket` bound: nothing in `lib/` called
/// `MeshService.stop()`, so the dead listener kept holding the canonical port
/// 51820 while the new engine's mesh fell back to an ephemeral port — and
/// peers kept dialling the stale route. Observing `detached` (plus `stop()`
/// in the owning widget's `dispose`) is what lets the next engine reclaim
/// 51820.
///
/// The foreground/background distinction is preserved: only `detached` stops
/// the mesh. Every other transition just tunes the clipboard poll rate, so a
/// backgrounded app keeps serving while using less battery.
class MeshLifecycleObserver extends WidgetsBindingObserver {
  MeshLifecycleObserver(this._mesh);

  final MeshService _mesh;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _mesh.setForeground(state == AppLifecycleState.resumed);
    if (state == AppLifecycleState.detached) {
      // Fire-and-forget: `stop()` closes the listener first (see
      // `MeshService.stop`), so even if the isolate dies mid-teardown the
      // socket — the one resource a recreated engine cannot reclaim — is
      // already released.
      unawaited(_mesh.stop());
    }
  }
}
