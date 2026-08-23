import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/pair_payload.dart';

void main() {
  group('PairPayload.build', () {
    test('builds a nexus://pair URI with the code and details', () {
      final uri = PairPayload.build(
        id: 'device-1',
        name: 'My PC',
        port: 51820,
        code: 'ABCD-2345',
        ip: '192.168.1.100',
      );
      expect(uri, startsWith('nexus://pair?'));
      expect(uri, contains('id=device-1'));
      expect(uri, contains('port=51820'));
      expect(uri, contains('code=ABCD-2345'));
      expect(uri, contains('ip=192.168.1.100'));
    });

    test('omits ip when not known', () {
      final uri = PairPayload.build(id: 'd', name: 'n', port: 51820, code: 'ABCD-2345');
      expect(uri.contains('ip='), isFalse);
    });
  });

  group('PairPayload.parse', () {
    test('roundtrips a built payload', () {
      final uri = PairPayload.build(
        id: 'device-1',
        name: 'My PC',
        port: 51820,
        code: 'abcd-2345', // lowercase must be normalized
        ip: '192.168.1.100',
      );
      final payload = PairPayload.parse(uri);
      expect(payload, isNotNull);
      expect(payload!.id, 'device-1');
      expect(payload.name, 'My PC');
      expect(payload.port, 51820);
      expect(payload.code, 'ABCD-2345'); // uppercased
      expect(payload.ip, '192.168.1.100');
    });

    test('handles URL-encoded names', () {
      final uri = 'nexus://pair?v=1&id=d1&name=My%20Linux%20PC&port=51820&code=WXYZ-9876';
      final payload = PairPayload.parse(uri);
      expect(payload, isNotNull);
      expect(payload!.name, 'My Linux PC');
      expect(payload.code, 'WXYZ-9876');
    });

    test('rejects non-Nexus QR content', () {
      expect(PairPayload.parse('https://example.com'), isNull);
      expect(PairPayload.parse('hello world'), isNull);
      expect(PairPayload.parse(''), isNull);
    });

    test('rejects malformed pairing payloads', () {
      expect(PairPayload.parse('nexus://pair?v=1&port=51820&code=ABCD-2345'), isNull); // no id
      expect(PairPayload.parse('nexus://pair?v=1&id=d1&port=0&code=ABCD-2345'), isNull); // bad port
      expect(PairPayload.parse('nexus://pair?v=1&id=d1&port=51820&code=BADCODE'), isNull); // bad code shape
      expect(PairPayload.parse('nexus://pair?v=1&id=d1&port=999999&code=ABCD-2345'), isNull);
    });
  });
}
