import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/qr_pairing.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/mesh/mesh_service.dart';

import 'mesh_test.dart' show FakeClipboard;

Future<int> _freePort() async {
  final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = probe.port;
  await probe.close();
  return port;
}

MeshService _mesh({
  required String id,
  required String name,
  required NexusStore store,
}) => MeshService(
  identity: DeviceInfo(id: id, name: name, platform: 'linux'),
  store: store,
  clipboard: FakeClipboard(),
  heartbeatInterval: const Duration(seconds: 30),
  connectTimeout: const Duration(seconds: 3),
);

void main() {
  group('QrPairingToken', () {
    test('generation/parsing roundtrip, minimal payload', () {
      final token = QrPairingToken.generate(address: '192.168.1.10', port: 51820);
      final encoded = token.encode();
      expect(encoded, startsWith('nexus://pair?'));
      expect(encoded, contains('v=2'));
      // Minimal: no contacts, files, clipboard, location, history, names.
      for (final banned in ['name=', 'contact', 'clip', 'file', 'loc', 'history', 'device']) {
        expect(encoded.contains(banned), isFalse, reason: 'banned: $banned');
      }
      final parsed = QrPairingToken.parse(encoded);
      expect(parsed, isNotNull);
      expect(parsed!.pairingId, token.pairingId);
      expect(parsed.publicKey, token.publicKey);
      expect(parsed.nonce, token.nonce);
      expect(parsed.code, token.code);
      expect(parsed.port, 51820);
    });

    test('expired QR rejected', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final token = QrPairingToken.generate(
        address: '192.168.1.10',
        port: 51820,
        nowMs: now - QrPairingToken.validity.inMilliseconds - 1000,
      );
      expect(QrPairingToken.parse(token.encode(), nowMs: now), isNull);
    });

    test('wrong version rejected', () {
      final token = QrPairingToken.generate(address: '127.0.0.1', port: 51820);
      final v1 = token.encode().replaceFirst('v=2', 'v=1');
      final v9 = token.encode().replaceFirst('v=2', 'v=9');
      expect(QrPairingToken.parse(v1), isNull);
      expect(QrPairingToken.parse(v9), isNull);
      expect(QrPairingToken.parse('https://example.com'), isNull);
    });

    test('tampered payload rejected', () {
      final token = QrPairingToken.generate(address: '127.0.0.1', port: 51820);
      final encoded = token.encode();
      String tamper(String key) {
        final uri = Uri.parse(encoded);
        final params = Map<String, String>.from(uri.queryParameters);
        final v = params[key]!;
        params[key] = v.substring(0, v.length - 1) + (v.endsWith('A') ? 'B' : 'A');
        return 'nexus://pair?${Uri(queryParameters: params).query}';
      }
      for (final key in ['pid', 'pub', 'nonce', 'code', 'exp']) {
        expect(QrPairingToken.parse(tamper(key)), isNull, reason: key);
      }
    });

    test('fresh install: pairing and capabilities default OFF', () async {
      final tmp = await Directory.systemTemp.createTemp('nexus_qr_defaults');
      addTearDown(() => tmp.delete(recursive: true));
      final store = NexusStore(explicitPath: '${tmp.path}/fresh.json');
      await store.load();
      expect(store.pairingEnabled, isFalse);
      expect(store.clipboardSync, isFalse);
      expect(store.fileShare, isFalse);
      expect(store.notificationShare, isFalse);
      expect(store.locationShare, isFalse);
      expect(store.locationReminders, isFalse);
    });
  });

  group('QR pairing state machine (two fresh installs)', () {
    late Directory tmp;
    late NexusStore storeA;
    late NexusStore storeB;
    late MeshService meshA;
    late MeshService meshB;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('nexus_qr_mesh');
      storeA = NexusStore(explicitPath: '${tmp.path}/a.json')
        ..port = await _freePort()
        ..pairingEnabled = true;
      storeB = NexusStore(explicitPath: '${tmp.path}/b.json')
        ..port = await _freePort()
        ..pairingEnabled = true;
      await storeA.save();
      await storeB.save();
      meshA = _mesh(id: 'qr-device-a', name: 'Device A', store: storeA);
      meshB = _mesh(id: 'qr-device-b', name: 'Device B', store: storeB);
      await meshA.start();
      await meshB.start();
    });

    tearDown(() async {
      await meshA.stop();
      await meshB.stop();
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    test('scan alone pairs nothing and leaks no data', () async {
      final session = meshA.beginQrPairing();
      final token = QrPairingToken.parse(session.qrPayload);
      expect(token, isNotNull);
      // A scan is a parse: no session, no secret stored, no pairing.
      expect(meshA.isPaired('qr-device-b'), isFalse);
      expect(meshB.isPaired('qr-device-a'), isFalse);
      expect(meshB.pairedDevices, isEmpty);
      expect(meshA.pendingQrRequests, isEmpty);
      expect(token!.code, hasLength(4));
    });

    test('mutual confirmation required, single-use, revoke works', () async {
      final session = meshA.beginQrPairing();
      final token = QrPairingToken.parse(session.qrPayload)!;

      // B sends the request; A has not confirmed yet -> nobody paired.
      final requestFuture = meshB.pairWithQr(
        token: token,
        address: '127.0.0.1',
      );
      // Wait until A staged the inbound request.
      QrInboundRequest? staged;
      for (var i = 0; i < 100 && staged == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        final reqs = meshA.pendingQrRequests;
        if (reqs.isNotEmpty) staged = reqs.first;
      }
      expect(staged, isNotNull, reason: 'A must stage the request, not pair');
      expect(staged!.code, token.code);
      expect(meshA.isPaired('qr-device-b'), isFalse,
          reason: 'scan + request without Allow must not pair');
      expect(meshB.isPaired('qr-device-a'), isFalse);

      // A explicitly allows -> both pair.
      expect(await meshA.acceptQrPairing(token.pairingId), isTrue);
      final result = await requestFuture;
      expect(result.ok, isTrue, reason: result.error);
      expect(meshA.isPaired('qr-device-b'), isTrue);
      expect(meshB.isPaired('qr-device-a'), isTrue);

      // Single-use: the same QR can never pair again.
      expect(await meshA.acceptQrPairing(token.pairingId), isFalse);
      expect(meshA.qrPidUsable(token.pairingId, token.expiryMs), isFalse);
      final replay = await meshB.pairWithQr(
        token: token,
        address: '127.0.0.1',
      );
      expect(replay.ok, isFalse);

      // Audit trail exists on both sides.
      expect(
        storeA.pairingAudit.map((e) => e['event']),
        containsAll(['qr-shown', 'qr-request-got', 'paired']),
      );
      expect(
        storeB.pairingAudit.map((e) => e['event']),
        contains('paired'),
      );

      // Either side can revoke.
      await meshA.revokePairing('qr-device-b');
      expect(meshA.isPaired('qr-device-b'), isFalse);
      expect(
        storeA.pairingAudit.map((e) => e['event']),
        contains('revoked'),
      );
    });

    test('pairing refused while the toggle is off', () async {
      storeB.pairingEnabled = false;
      await storeB.save();
      final session = meshA.beginQrPairing();
      final token = QrPairingToken.parse(session.qrPayload)!;
      final result = await meshB.pairWithQr(
        token: token,
        address: '127.0.0.1',
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('Pairing is off'));
    });
  });
}
