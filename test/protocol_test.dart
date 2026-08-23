import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/protocol.dart';

void main() {
  group('NexusMessage', () {
    test('roundtrips through JSON', () {
      final msg = NexusMessage(
        type: NexusMessage.ping,
        from: 'device-a',
        to: 'device-b',
        payload: {'name': 'My phone', 'port': 51820},
        id: 'abc123',
        ts: 1234567890,
      );
      final decoded = NexusMessage.fromJson(jsonDecode(msg.encodePlain()) as Map<String, dynamic>);
      expect(decoded.type, NexusMessage.ping);
      expect(decoded.from, 'device-a');
      expect(decoded.to, 'device-b');
      expect(decoded.payload['name'], 'My phone');
      expect(decoded.payload['port'], 51820);
      expect(decoded.id, 'abc123');
      expect(decoded.ts, 1234567890);
    });
  });

  group('FrameDecoder', () {
    test('decodes a single frame', () {
      final payload = encodeJson({'hello': 'world'});
      final frame = FrameDecoder.encodeFrame(payload);
      final decoder = FrameDecoder()..add(frame);
      final frames = decoder.takeFrames();
      expect(frames, isNotNull);
      expect(frames!.length, 1);
      expect((jsonDecode(utf8.decode(frames.first)) as Map)['hello'], 'world');
    });

    test('decodes frames split across arbitrary chunk boundaries', () {
      final f1 = FrameDecoder.encodeFrame(encodeJson({'n': 1}));
      final f2 = FrameDecoder.encodeFrame(encodeJson({'n': 2}));
      final f3 = FrameDecoder.encodeFrame(encodeJson({'n': 3}));
      final stream = [...f1, ...f2, ...f3];

      final decoder = FrameDecoder();
      final collected = <Map<String, dynamic>>[];
      // Feed in awkward slices (1 byte, then 3 bytes, then the rest).
      var i = 0;
      for (final size in [1, 3, 5, 7]) {
        final end = (i + size).clamp(0, stream.length);
        if (end > i) {
          decoder.add(Uint8List.fromList(stream.sublist(i, end)));
          final frames = decoder.takeFrames();
          if (frames != null) {
            for (final f in frames) {
              collected.add(jsonDecode(utf8.decode(f)) as Map<String, dynamic>);
            }
          }
          i = end;
        }
      }
      // Feed the tail.
      if (i < stream.length) {
        decoder.add(Uint8List.fromList(stream.sublist(i)));
        final frames = decoder.takeFrames();
        if (frames != null) {
          for (final f in frames) {
            collected.add(jsonDecode(utf8.decode(f)) as Map<String, dynamic>);
          }
        }
      }
      expect(collected.map((m) => m['n']), [1, 2, 3]);
    });

    test('no frames when only a partial header arrives', () {
      final frame = FrameDecoder.encodeFrame(encodeJson({'x': 1}));
      final decoder = FrameDecoder()..add(frame.sublist(0, 3));
      expect(decoder.takeFrames(), isNull);
    });

    test('rejects oversized frames', () {
      final decoder = FrameDecoder();
      final big = ByteData(4)..setUint32(0, FrameDecoder.maxFrameBytes + 1);
      decoder.add(big.buffer.asUint8List());
      expect(decoder.takeFrames(), isNull); // refuses without throwing
    });
  });
}
