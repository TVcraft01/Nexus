import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart' show MethodChannel, ServicesBinding;

/// Where the connection supervisor hears about the network changing
/// underneath it: WiFi coming back after sleep, WiFi handing over to
/// cellular, the radio dropping and returning.
///
/// Without this, a link that died because the network went away is only
/// retried when its backoff comes round — up to a minute of nothing while the
/// network is already back. The supervisor treats every event here as "the
/// waits measured against the old network are void" and reconnects at once.
///
/// Android is the only platform with a source: a phone is suspended, roams
/// off WiFi and loses radios in ways a desktop never does, so MainActivity
/// registers a `ConnectivityManager` network callback and forwards every
/// transition over the `dev.nexus.nexus/network_events` channel. That needs no
/// new permission — `ACCESS_NETWORK_STATE` is already declared for the mesh's
/// own discovery.
///
/// The push side is registered by hand rather than through
/// `EventChannel.receiveBroadcastStream`, because that helper *reports* a
/// missing platform handler as a framework error: any build or test harness
/// with no native side answering would fail loudly instead of simply never
/// firing. Here a missing handler is an exception this class catches, the same
/// way `SyncService` copes with a stripped build.
///
/// Elsewhere the stream is simply empty, and nothing else changes: the
/// heartbeat still notices a dead link in seconds, it just is not told that
/// the cause was the network.
class ConnectivityMonitor {
  static const _channel = MethodChannel('dev.nexus.nexus/network_events');

  static Stream<void>? _changes;

  /// Broadcast stream of network transitions. Empty off Android, and empty
  /// where there is no Flutter binding to carry a channel at all.
  static Stream<void> get changes => _changes ??= _open();

  static Stream<void> _open() {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return const Stream<void>.empty();
    }
    if (!_bindingReady) return const Stream<void>.empty();
    late StreamController<void> controller;
    controller = StreamController<void>.broadcast(
      onListen: () async {
        _channel.setMethodCallHandler((call) async {
          if (call.method == 'networkChanged') controller.add(null);
          return null;
        });
        try {
          await _channel.invokeMethod<void>('listen');
        } catch (_) {
          // Nothing on the other end answering (no engine, a stripped build):
          // the heartbeat's own timeout still catches a dead link, it just
          // does not know the network was the cause.
        }
      },
      onCancel: () async {
        _channel.setMethodCallHandler(null);
        try {
          await _channel.invokeMethod<void>('cancel');
        } catch (_) {}
      },
    );
    return controller.stream;
  }

  /// Whether a binding exists to carry the channel. Reading
  /// [ServicesBinding.instance] before it is initialized throws, which is the
  /// only way to ask.
  static bool get _bindingReady {
    try {
      ServicesBinding.instance;
      return true;
    } catch (_) {
      return false;
    }
  }
}
