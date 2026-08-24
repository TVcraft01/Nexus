import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/serial_protocol.dart';

void main() {
  group('SerialMessage', () {
    test('announce encodes a single JSON line', () {
      final msg = SerialMessage.announce(
        id: 'esp32-abc123',
        name: 'Nexus ESP32',
        caps: ['ping', 'msg'],
        fw: '0.1.0',
      );
      final line = msg.encode();
      expect(line.endsWith('\n'), isTrue);
      final decoded = SerialMessage.fromJson(
        jsonDecode(line.trim()) as Map<String, dynamic>,
      );
      expect(decoded.t, SerialMessage.ann);
      expect(decoded.id, 'esp32-abc123');
      expect(decoded.name, 'Nexus ESP32');
      expect(decoded.caps, ['ping', 'msg']);
    });

    test('caps default to ping+msg when absent', () {
      const msg = SerialMessage('ann', {'id': 'x', 'name': 'y'});
      expect(msg.caps, ['ping', 'msg']);
    });

    test('hello/ping/pong round trip', () {
      expect(SerialMessage.helloMsg().t, SerialMessage.hello);
      expect(SerialMessage.pingMsg().t, SerialMessage.ping);
      expect(SerialMessage.pongMsg().t, SerialMessage.pong);
    });

    test('msg carries a payload and omits empty to', () {
      final line = SerialMessage.msgTo(null, {'blink': true}).encode();
      expect(line, contains('"data":{"blink":true}'));
      expect(line, isNot(contains('"to"')));
    });
  });

  group('SerialLineDecoder', () {
    test('decodes complete lines from a single chunk', () {
      final decoder = SerialLineDecoder();
      final msgs = decoder.add(utf8.encode('{"t":"hello"}\n{"t":"ping"}\n'));
      expect(msgs.length, 2);
      expect(msgs[0].t, SerialMessage.hello);
      expect(msgs[1].t, SerialMessage.ping);
    });

    test('buffers partial lines across chunks', () {
      final decoder = SerialLineDecoder();
      expect(decoder.add(utf8.encode('{"t":"ann","id":"esp')), isEmpty);
      expect(decoder.add(utf8.encode('-1"}')), isEmpty);
      final msgs = decoder.add(utf8.encode('\n'));
      expect(msgs.single.id, 'esp-1');
    });

    test('drops garbage lines without wedging', () {
      final decoder = SerialLineDecoder();
      expect(decoder.add(utf8.encode('not json\n')), isEmpty);
      final msgs = decoder.add(utf8.encode('{"t":"ping"}\n'));
      expect(msgs.single.t, SerialMessage.ping);
    });

    test('handles multiple messages in one chunk and CRLF', () {
      final decoder = SerialLineDecoder();
      final msgs = decoder.add(utf8.encode('{"t":"pong"}\r\n{"t":"hello"}\r\n'));
      expect(msgs.length, 2);
      expect(msgs[0].t, SerialMessage.pong);
      expect(msgs[1].t, SerialMessage.hello);
    });

    test('does not buffer forever on a runaway node', () {
      final decoder = SerialLineDecoder();
      // No newline for 9 KiB — beyond the guard, so the buffer resets.
      decoder.add(List.filled(9000, 0x61));
      expect(decoder.add(utf8.encode('{"t":"ping"}\n')), hasLength(1));
    });
  });
}
