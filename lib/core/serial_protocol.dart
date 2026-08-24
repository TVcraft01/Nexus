import 'dart:convert';
import 'dart:typed_data';

/// The wire protocol spoken between the Nexus app and a microcontroller
/// (ESP32, etc.) attached over a USB serial cable.
///
/// Each message is one line of UTF-8 JSON terminated by `\n`. Messages are
/// tiny (a few hundred bytes max) and hand-rollable on a microcontroller
/// with no JSON library, which is why this is deliberately simpler than the
/// length-prefixed TCP framing used over the mesh.
///
/// Message types:
/// - `ann`  (node → host): presence. Sent on boot and every few seconds so
///   the host can (re)discover the node and know it is still alive.
/// - `hello`(host → node): ask for an immediate `ann` (e.g. right after the
///   cable is plugged in).
/// - `ping` (host → node) / `pong` (node → host): explicit liveness probe.
/// - `msg`  (host → node): a small command/payload for the node to act on.
/// - `up`   (node → host): a small payload from the node (sensor reading,
///   button press, …).
/// - `pair` (host → node): confirm the node is paired with this host so the
///   node can persist/light up a status LED.
///
/// A node advertises its capabilities in `ann` so the app never offers it
/// things it cannot do (clipboard, file transfer, …). The node is assumed to
/// only support `ping` + `msg` unless it says otherwise.
class SerialMessage {
  static const int maxLineBytes = 4096;

  /// Announce: node → host. Always the first thing a node sends.
  static const ann = 'ann';
  /// Ask for an announce: host → node.
  static const hello = 'hello';
  static const ping = 'ping';
  static const pong = 'pong';
  /// Command payload: host → node.
  static const msg = 'msg';
  /// Status payload: node → host.
  static const up = 'up';
  /// Pairing confirmation: host → node.
  static const pair = 'pair';

  final String t;
  final Map<String, dynamic> fields;

  const SerialMessage(this.t, [this.fields = const {}]);

  String get id => fields['id'] as String? ?? '';
  String get name => fields['name'] as String? ?? '';
  List<String> get caps =>
      (fields['caps'] as List?)?.whereType<String>().toList() ??
      const ['ping', 'msg'];

  Map<String, dynamic> toJson() => {'t': t, ...fields};

  /// Encodes as a single JSON line + newline.
  String encode() => '${jsonEncode(toJson())}\n';

  factory SerialMessage.fromJson(Map<String, dynamic> json) {
    final t = json['t'] as String? ?? '';
    final fields = Map<String, dynamic>.from(json)..remove('t');
    return SerialMessage(t, fields);
  }

  static SerialMessage announce({
    required String id,
    required String name,
    List<String> caps = const ['ping', 'msg'],
    String fw = '',
  }) => SerialMessage(ann, {
    'id': id,
    'name': name,
    'caps': caps,
    if (fw.isNotEmpty) 'fw': fw,
  });

  static SerialMessage helloMsg() => const SerialMessage(hello);
  static SerialMessage pingMsg() => const SerialMessage(ping);
  static SerialMessage pongMsg() => const SerialMessage(pong);

  static SerialMessage msgTo(String? to, Map<String, dynamic> data) =>
      SerialMessage(msg, {if (to != null && to.isNotEmpty) 'to': to, 'data': data});

  static SerialMessage upFrom(Map<String, dynamic> data) =>
      SerialMessage(up, {'data': data});

  static SerialMessage pairOk(String name) => SerialMessage(pair, {'ok': true, 'name': name});
}

/// Splits a serial byte stream into complete lines, buffering partial lines.
///
/// Serial transports deliver bytes in arbitrary chunks; this accumulates
/// until a `\n` and hands out one decoded message at a time. Non-JSON or
/// over-long lines are dropped defensively (a node should never send those,
/// and a garbled line must not wedge the host).
class SerialLineDecoder {
  final BytesBuilder _buf = BytesBuilder(copy: false);

  /// Feed a chunk of bytes, returns the messages completed by this chunk.
  List<SerialMessage> add(List<int> bytes) {
    _buf.add(bytes);
    final out = <SerialMessage>[];
    while (true) {
      final all = _buf.toBytes();
      final idx = all.indexOf(0x0a); // '\n'
      if (idx < 0) break;
      final line = all.sublist(0, idx);
      final rest = all.sublist(idx + 1);
      _buf.clear();
      _buf.add(rest);
      if (line.length > SerialMessage.maxLineBytes) continue;
      final text = utf8.decode(line, allowMalformed: true).trim();
      if (text.isEmpty) continue;
      try {
        final json = jsonDecode(text);
        if (json is Map<String, dynamic>) {
          out.add(SerialMessage.fromJson(json));
        }
      } catch (_) {
        // Garbage line — skip it and keep going.
      }
    }
    if (_buf.length > SerialMessage.maxLineBytes * 2) {
      _buf.clear(); // runaway node — don't buffer forever
    }
    return out;
  }

  void clear() => _buf.clear();
}
