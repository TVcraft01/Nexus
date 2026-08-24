import 'dart:convert';
import 'dart:typed_data';

/// One logical message in the Nexus mesh.
///
/// Plain frames carry messages that contain no secrets (presence pings, so
/// devices can be found and verified without any shared state). Everything
/// sensitive — pairing handshakes, clipboard text — travels inside an
/// encrypted frame (`{"enc": "<base64>"}`), see [MeshService].
class NexusMessage {
  final String type;
  final String from;
  final String? to;
  final Map<String, dynamic> payload;
  final String id;
  final int ts;

  const NexusMessage({
    required this.type,
    required this.from,
    this.to,
    this.payload = const {},
    required this.id,
    required this.ts,
  });

  static const ping = 'ping';
  static const pong = 'pong';
  static const pairRequest = 'pair-request';
  static const pairAccept = 'pair-accept';
  static const pairReject = 'pair-reject';
  static const clipboard = 'clipboard';
  static const clipboardAck = 'clipboard.ack';
  static const clipboardNotify = 'clipboard.notify';
  static const clipboardPull = 'clipboard.pull';
  static const fileList = 'file.list';
  static const fileListResult = 'file.list.result';
  static const fileGet = 'file.get';
  static const fileChunk = 'file.chunk';
  static const filePush = 'file.push';
  static const filePushAck = 'file.push.ack';
  static const fileDelete = 'file.delete';
  static const fileDeleteAck = 'file.delete.ack';
  static const fileOperation = 'file.operation';
  static const fileOperationAck = 'file.operation.ack';
  static const fileError = 'file.error';
  static const serialMsg = 'serial.msg'; // peer → host: forward a payload to a cable node
  static const serialUp = 'serial.up'; // host → peer: a payload from a cable node

  Map<String, dynamic> toJson() => {
    'type': type,
    'from': from,
    if (to != null) 'to': to,
    'payload': payload,
    'id': id,
    'ts': ts,
  };

  factory NexusMessage.fromJson(Map<String, dynamic> json) => NexusMessage(
    type: json['type'] as String,
    from: json['from'] as String,
    to: json['to'] as String?,
    payload: (json['payload'] as Map<String, dynamic>?) ?? const {},
    id: json['id'] as String,
    ts: (json['ts'] as num?)?.toInt() ?? 0,
  );

  String encodePlain() => jsonEncode(toJson());

  @override
  String toString() => 'NexusMessage($type from=$from id=$id)';
}

/// Splits a TCP byte stream into frames.
///
/// Wire format: 4-byte big-endian length prefix, then that many bytes of
/// UTF-8 JSON. This codec buffers partial reads, which TCP delivers in
/// arbitrary chunks.
class FrameDecoder {
  static const int maxFrameBytes = 1 << 20; // 1 MiB guard
  final BytesBuilder _buf = BytesBuilder(copy: false);

  void add(List<int> chunk) {
    if (_buf.length > maxFrameBytes * 2) {
      // A peer that floods us past the guard is not behaving — drop the
      // buffer and let the connection-level error handling take over.
      _buf.clear();
    }
    _buf.add(chunk);
  }

  /// Returns any complete frames currently buffered, in order. May return
  /// null when there is nothing complete yet.
  List<Uint8List>? takeFrames() {
    final bytes = _buf.toBytes();
    final frames = <Uint8List>[];
    var offset = 0;
    while (true) {
      if (bytes.length - offset < 4) break;
      final length = ByteData.sublistView(
        bytes,
        offset,
        offset + 4,
      ).getUint32(0);
      if (length > maxFrameBytes) {
        // Malformed/garbage frame — refuse the whole buffer.
        _buf.clear();
        return frames.isEmpty ? null : frames;
      }
      if (bytes.length - offset - 4 < length) break;
      frames.add(Uint8List.sublistView(bytes, offset + 4, offset + 4 + length));
      offset += 4 + length;
    }
    final remaining = bytes.sublist(offset);
    _buf.clear();
    if (remaining.isNotEmpty) _buf.add(remaining);
    return frames.isEmpty ? null : frames;
  }

  static Uint8List encodeFrame(List<int> payload) {
    final out = BytesBuilder(copy: false);
    final head = ByteData(4)..setUint32(0, payload.length);
    out.add(head.buffer.asUint8List());
    out.add(payload);
    return out.toBytes();
  }
}

/// Compact helper: bytes of a JSON-encoded map.
Uint8List encodeJson(Map<String, dynamic> json) =>
    Uint8List.fromList(utf8.encode(jsonEncode(json)));
