import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

/// A lightweight relay client that lets two devices connect through a
/// WebSocket relay server when they can't reach each other directly.
///
/// The relay only forwards encrypted bytes — it cannot read the payload.
///
/// Usage:
///   1. Device A registers: `relay.register(myId, token)`
///   2. Device B tries direct connection first
///   3. If that fails, B calls: `relay.connect(myId, targetId, token)`
///   4. The relay pairs A and B, forwarding their encrypted TCP frames
///
class RelayClient {
  RelayClient({this.relayUrl = _defaultRelayUrl});

  static const _defaultRelayUrl = 'wss://nexus-relay.fly.dev/ws';
  final String relayUrl;

  WebSocketChannel? _channel;
  final _messageController = StreamController<RelayMessage>.broadcast();
  bool _connected = false;
  String? _myId;
  Timer? _heartbeat;

  /// Stream of messages from the relay (encrypted frames from peers).
  Stream<RelayMessage> get messages => _messageController.stream;

  /// Whether we are currently connected to the relay.
  bool get isConnected => _connected;

  /// Register this device with the relay. The relay will hold messages
  /// for this device until another device requests a connection.
  Future<void> register(String deviceId, String token) async {
    if (_connected) return;
    _myId = deviceId;
    try {
      _channel = WebSocketChannel.connect(Uri.parse(relayUrl));
      _channel!.stream.listen(
        _onMessage,
        onError: (_) => _disconnect(),
        onDone: _disconnect,
      );
      _connected = true;
      _send({'type': 'register', 'deviceId': deviceId, 'token': token});
      _heartbeat = Timer.periodic(const Duration(seconds: 30), (_) {
        _send({'type': 'ping'});
      });
    } catch (_) {
      _connected = false;
    }
  }

  /// Request a connection to [targetId]. Returns true if the relay
  /// successfully paired us, false if the target is not registered.
  Future<bool> connect(String targetId) async {
    if (!_connected || _myId == null) return false;
    _send({'type': 'connect', 'from': _myId, 'to': targetId});
    // Wait for a response (paired or error)
    final completer = Completer<bool>();
    late final StreamSubscription sub;
    sub = messages.listen((msg) {
      if (msg.type == 'paired' && !completer.isCompleted) {
        completer.complete(true);
        sub.cancel();
      }
      if (msg.type == 'error' && !completer.isCompleted) {
        completer.complete(false);
        sub.cancel();
      }
    });
    // Timeout after 5 seconds
    Timer(const Duration(seconds: 5), () {
      if (!completer.isCompleted) {
        completer.complete(false);
        sub.cancel();
      }
    });
    return completer.future;
  }

  /// Send encrypted data to the relay for forwarding to the paired peer.
  void send(List<int> data) {
    _send({'type': 'data', 'data': base64Encode(data)});
  }

  void _send(Map<String, dynamic> msg) {
    _channel?.sink.add(jsonEncode(msg));
  }

  void _onMessage(dynamic raw) {
    try {
      final json = jsonDecode(raw as String) as Map<String, dynamic>;
      final type = json['type'] as String? ?? '';
      switch (type) {
        case 'data':
          final data = json['data'] as String?;
          if (data != null) {
            _messageController.add(
              RelayMessage(type: type, data: base64Decode(data)),
            );
          }
        case 'paired':
          _messageController.add(const RelayMessage(type: 'paired'));
        case 'error':
          _messageController.add(
            RelayMessage(type: 'error', error: json['message'] as String?),
          );
        case 'pong':
          // Keep-alive response, nothing to do.
          break;
      }
    } catch (_) {
      // Malformed message, ignore.
    }
  }

  void _disconnect() {
    _connected = false;
    _heartbeat?.cancel();
    _channel?.sink.close();
    _channel = null;
  }

  /// Disconnect from the relay.
  void dispose() {
    _disconnect();
    _messageController.close();
  }
}

/// A message received from the relay.
class RelayMessage {
  final String type;
  final List<int>? data;
  final String? error;

  const RelayMessage({required this.type, this.data, this.error});
}
