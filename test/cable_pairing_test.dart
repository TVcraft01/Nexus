import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/cable_pairing.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/mesh/mesh_service.dart';

/// A clipboard that lives in memory — no platform channels needed in tests.
class FakeClipboard implements ClipboardBackend {
  String? value;
  @override
  Future<String?> readText() async => value;
  @override
  Future<void> writeText(String text) async => value = text;
}

/// Builds a `nexus://pair` provisioning link exactly like the PC does. Any
/// parameter can be omitted by passing null, for malformed-link tests.
String provisionUri({
  String? address = '127.0.0.1',
  String? port = '51824',
  String? code = 'ABCD-2345',
  String? expires,
}) {
  expires ??=
      '${DateTime.now().add(const Duration(minutes: 5)).millisecondsSinceEpoch}';
  final parts = <String>[
    if (address != null) 'address=$address',
    if (port != null) 'port=$port',
    if (code != null) 'code=$code',
    'expires=$expires',
  ];
  return 'nexus://pair?${parts.join('&')}';
}

String expiredProvisionUri() => provisionUri(
      expires:
          '${DateTime.now().subtract(const Duration(minutes: 1)).millisecondsSinceEpoch}',
    );

void main() {
  group('parseDevicesOutput', () {
    test('returns attached, authorized devices', () {
      final output = 'List of devices attached\n'
          'R5CX73XFGKW\tdevice usb:1-2 product:sm-s928b\n'
          'emulator-5554\tdevice product:sdk_gphone64\n';
      expect(CablePairing.parseDevicesOutput(output), ['R5CX73XFGKW', 'emulator-5554']);
    });

    test('ignores unauthorized and offline devices', () {
      final output = 'List of devices attached\n'
          'R5CX73XFGKW\tdevice\n'
          'DEADBEEF\tunauthorized\n'
          'EMULATOR1\toffline\n';
      expect(CablePairing.parseDevicesOutput(output), ['R5CX73XFGKW']);
    });

    test('returns empty for no devices or empty output', () {
      expect(CablePairing.parseDevicesOutput('List of devices attached\n\n'), isEmpty);
      expect(CablePairing.parseDevicesOutput(''), isEmpty);
    });
  });

  group('tunnelCandidates', () {
    test('tries the mesh port first, then consecutive free ports', () {
      expect(CablePairing.tunnelCandidates(51820), [51820, 51821, 51822, 51823]);
      expect(CablePairing.tunnelCandidates(9000), [9000, 9001, 9002, 9003]);
    });
  });

  group('linuxSetupScript', () {
    test('produces a runnable script mentioning install and pairing', () {
      final script = CablePairing.linuxSetupScript();
      expect(script, contains('#!/usr/bin/env bash'));
      expect(script, contains('nexus-linux-x64.tar.gz'));
      expect(script, contains('Enter a code'));
      // The script is for the *other* device; it must not contain our own
      // shell-expanded variables.
      expect(script, isNot(contains('Undefined name')));
    });
  });

  group('parseProvisioningUri', () {
    test('accepts a valid, unexpired provisioning link', () {
      final payload = CablePairing.parseProvisioningUri(provisionUri());
      expect(payload, isNotNull);
      expect(payload!['address'], '127.0.0.1');
      expect(payload['port'], '51824');
      expect(payload['code'], 'ABCD-2345');
    });

    test('rejects wrong scheme, wrong host, and non-root paths', () {
      expect(
        CablePairing.parseProvisioningUri(
          'https://pair?address=127.0.0.1&port=51824&code=ABCD-2345&expires=9999999999999',
        ),
        isNull,
      );
      expect(
        CablePairing.parseProvisioningUri(
          'nexus://other?address=127.0.0.1&port=51824&code=ABCD-2345&expires=9999999999999',
        ),
        isNull,
      );
      expect(
        CablePairing.parseProvisioningUri(
          'nexus://pair.evil?address=127.0.0.1&port=51824&code=ABCD-2345&expires=9999999999999',
        ),
        isNull,
      );
      expect(
        CablePairing.parseProvisioningUri(
          'nexus://pair/extra?address=127.0.0.1&port=51824&code=ABCD-2345&expires=9999999999999',
        ),
        isNull,
      );
      expect(CablePairing.parseProvisioningUri(null), isNull);
      expect(CablePairing.parseProvisioningUri('/'), isNull);
    });

    test('rejects missing or malformed fields', () {
      expect(CablePairing.parseProvisioningUri('nexus://pair'), isNull);
      expect(
        CablePairing.parseProvisioningUri(provisionUri(address: null)),
        isNull,
      );
      expect(
        CablePairing.parseProvisioningUri(provisionUri(port: null)),
        isNull,
      );
      expect(
        CablePairing.parseProvisioningUri(provisionUri(code: null)),
        isNull,
      );
      expect(
        CablePairing.parseProvisioningUri(
          'nexus://pair?address=127.0.0.1&port=51824&code=ABCD-2345',
        ),
        isNull,
      );
      expect(
        CablePairing.parseProvisioningUri(provisionUri(port: 'abc')),
        isNull,
      );
      expect(
        CablePairing.parseProvisioningUri(provisionUri(port: '0')),
        isNull,
      );
      expect(
        CablePairing.parseProvisioningUri(provisionUri(port: '999999')),
        isNull,
      );
      expect(
        CablePairing.parseProvisioningUri(provisionUri(code: 'ABC')),
        isNull,
      );
    });

    test('accepts port boundaries 1 and 65535', () {
      expect(
        CablePairing.parseProvisioningUri(provisionUri(port: '1')),
        isNotNull,
      );
      expect(
        CablePairing.parseProvisioningUri(provisionUri(port: '65535')),
        isNotNull,
      );
    });

    test('rejects expired links', () {
      expect(CablePairing.parseProvisioningUri(expiredProvisionUri()), isNull);
    });
  });

  group('attemptAutoPair', () {
    late Directory tmp;
    late MeshService pc;
    late MeshService phone;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('nexus_cable_test');
      final storePc = NexusStore(explicitPath: '${tmp.path}/pc.json')
        ..port = 53220;
      final storePhone = NexusStore(explicitPath: '${tmp.path}/phone.json')
        ..port = 53221;
      await storePc.save();
      await storePhone.save();

      pc = MeshService(
        identity: DeviceInfo(
          id: 'pc-a',
          name: 'Test PC',
          platform: 'linux',
        ),
        store: storePc,
        clipboard: FakeClipboard(),
      );
      phone = MeshService(
        identity: DeviceInfo(
          id: 'phone-1',
          name: 'Test Phone',
          platform: 'android',
        ),
        store: storePhone,
        clipboard: FakeClipboard(),
      );
    });

    tearDown(() async {
      await pc.stop();
      await phone.stop();
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    test('a valid unexpired link pairs automatically with the PC', () async {
      await pc.start();
      await phone.start();

      final session = pc.beginPairing();
      final link = provisionUri(port: '${pc.port}', code: session.code);
      final payload = CablePairing.parseProvisioningUri(link);
      expect(payload, isNotNull);

      // Exactly what the cold-start path and the warm-start channel handler
      // run with a delivered link.
      final result = await CablePairing.attemptAutoPair(phone, payload!);
      expect(result.ok, isTrue, reason: result.error);
      expect(pc.isPaired('phone-1'), isTrue);
      expect(phone.isPaired('pc-a'), isTrue);
    });

    test('invalid and expired links never trigger pairing', () async {
      await pc.start();
      await phone.start();
      pc.beginPairing(); // PC is showing a code and ready to accept

      // Exactly what the warm-start handler does with each delivered link:
      // parse strictly, and only attempt a handshake when non-null.
      final delivered = <String>[
        provisionUri(port: 'not-a-port'),
        provisionUri(port: '0'),
        provisionUri(code: 'ABC'),
        provisionUri(address: null),
        expiredProvisionUri(),
        'https://pair?address=127.0.0.1&port=53220&code=ABCD-2345&expires=9999999999999',
        'nexus://other?address=127.0.0.1&port=53220&code=ABCD-2345&expires=9999999999999',
        'garbage',
      ];
      for (final link in delivered) {
        final payload = CablePairing.parseProvisioningUri(link);
        if (payload != null) {
          await CablePairing.attemptAutoPair(phone, payload);
        }
      }

      expect(phone.pairedDevices, isEmpty);
      expect(pc.pairedDevices, isEmpty);
    });
  });
}
