import 'dart:convert';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/pair_invite.dart';
import 'package:nexus/core/qr_pairing.dart';

/// What a pairing QR carries, read back.
///
/// The scanner is pointed at the world, so most of these tests are about the
/// codes that are *not* ours: a website, a coupon, a vCard, half a JSON object,
/// a Nexus code from an older build. Each of them has to come back null, and
/// none of them may throw — a scanner that crashes on a bus ticket is a scanner
/// nobody points at anything twice.
void main() {
  const PairInvite invite = PairInvite(
    deviceName: 'My phone',
    deviceId: 'h3k2p9wq77m4n8x1v5z6b0cd3efg4hij',
    publicKey: 'Srpq1Yx0Ff3kQw7Zz9RtUvWxYzA2BcDeFgHiJkLmNoP',
  );

  group('the payload', () {
    test('is the JSON a person could read back', () {
      // Field names and order are the contract: another device's parser, a
      // person debugging with a camera app, and the tests below all read this
      // exact map.
      final Map<String, dynamic> json =
          jsonDecode(invite.encode()) as Map<String, dynamic>;
      expect(json, <String, dynamic>{
        'type': kNexusPairType,
        'device_name': 'My phone',
        'device_id': 'h3k2p9wq77m4n8x1v5z6b0cd3efg4hij',
        'public_key': 'Srpq1Yx0Ff3kQw7Zz9RtUvWxYzA2BcDeFgHiJkLmNoP',
      });
      expect(invite.encode(), startsWith('{"type":"nexus_pair"'));
    });

    test('comes back the same as it went in', () {
      final PairInvite? parsed = PairInvite.parse(invite.encode());
      expect(parsed, isNotNull);
      expect(parsed!.deviceName, invite.deviceName);
      expect(parsed.deviceId, invite.deviceId);
      expect(parsed.publicKey, invite.publicKey);

      // The desktop code is the same object under the names a PC can document:
      // `name` and `address`, with `port` as a number, and the Ollama
      // capability the phone stores for the hive route.
      const PairInvite desktop = PairInvite(
        deviceName: 'Studio PC',
        deviceId: 'pc-0123456789abcdef',
        publicKey: 'pc-public-key',
        addresses: <String>['192.168.1.100'],
        port: 51820,
        code: 'pc-transfer-token',
        platform: 'linux',
        ollama: true,
      );
      final Map<String, dynamic> pcJson =
          jsonDecode(desktop.encodeForDesktop()) as Map<String, dynamic>;
      expect(pcJson['name'], 'Studio PC');
      expect(pcJson['address'], '192.168.1.100');
      expect(pcJson['port'], 51820);
      expect(pcJson['code'], 'pc-transfer-token');
      expect(pcJson['ollama'], isTrue);
      final PairInvite? pc = PairInvite.parse(desktop.encodeForDesktop());
      expect(pc?.deviceName, 'Studio PC');
      expect(pc?.addresses.single, '192.168.1.100');
      expect(pc?.port, 51820);
      expect(pc?.code, 'pc-transfer-token');
      expect(pc?.platform, 'linux');
      expect(pc?.ollama, isTrue);
    });

    test('tolerates the whitespace a paste arrives with', () {
      final PairInvite? parsed = PairInvite.parse('  ${invite.encode()}\n');
      expect(parsed?.deviceName, 'My phone');
    });
  });

  group('codes that are not ours', () {
    test('a website link is refused, and does not throw', () {
      expect(PairInvite.parse('https://nexus.example.com/pair'), isNull);
      expect(PairInvite.parse('https://example.com'), isNull);
      expect(PairInvite.parse(''), isNull);
      expect(PairInvite.parse('   '), isNull);
    });

    test('JSON from somebody else is refused by its type', () {
      expect(
        PairInvite.parse('{"type":"vcard","device_name":"x","device_id":"y"}'),
        isNull,
      );
      expect(PairInvite.parse('{"name":"My phone","id":"abc"}'), isNull);
      // The type has to be the exact string: a near-miss is another app's code,
      // and pairing with it would be pairing with a stranger.
      expect(
        PairInvite.parse(
          '{"type":"nexus-pair","device_name":"My phone",'
          '"device_id":"h3k2p9wq77m4n8x1v5z6b0cd3efg4hij","public_key":"k"}',
        ),
        isNull,
      );
    });

    test('a payload missing a field, or half-pasted, is refused', () {
      expect(
        PairInvite.parse(
          '{"type":"nexus_pair","device_name":"My phone",'
          '"device_id":"h3k2p9wq77m4n8x1v5z6b0cd3efg4hij"}',
        ),
        isNull,
        reason: 'no public key',
      );
      expect(
        PairInvite.parse(
          '{"type":"nexus_pair","device_name":"","device_id":"'
          'h3k2p9wq77m4n8x1v5z6b0cd3efg4hij","public_key":"k"}',
        ),
        isNull,
        reason: 'a device with no name cannot be paired with',
      );
      expect(
        PairInvite.parse('{"type":"nexus_pair","device_name":"My phone"'),
        isNull,
        reason: 'truncated: the tail of a paste',
      );
    });

    test('a device id too short to be one is refused', () {
      // The seeded length is a real guard, not decoration: "paired with `a`" is
      // a row nobody can act on, and every real id is 32 characters.
      expect(
        PairInvite.parse(
          '{"type":"nexus_pair","device_name":"My phone","device_id":"abc",'
          '"public_key":"k"}',
        ),
        isNull,
      );
    });

    test("an older Nexus code is somebody else's format, not ours", () {
      // v2 (`qr_pairing.dart`) and v1 (`pair_payload.dart`) are the *mesh's*
      // handshake codes: they carry a one-time secret and a port, and this
      // shell cannot complete that exchange. They parse as "not this format",
      // which is what lets the scanner say the honest thing about them.
      final String v2 = QrPairingToken.generate(port: 51820, nowMs: 1).encode();
      expect(PairInvite.parse(v2), isNull);
      expect(
        PairInvite.parse(
          'nexus://pair?v=1&id=device-a&name=My+PC&port=51820&code=ABCD-2345',
        ),
        isNull,
      );
    });
  });

  group('who this device is', () {
    tearDown(PairIdentity.debugReset);

    test('is named from the platform, with an id and a key', () {
      final PairIdentity who = PairIdentity.current;
      // Named for what the platform can honestly say: the shell has no
      // device-name channel yet, so it does not invent a model number.
      expect(who.name, isNotEmpty);
      expect(who.id.length, 32);
      expect(who.publicKey, isNotEmpty);
      expect(PairInvite.parse(who.invite.encode())?.deviceId, who.id);
    });

    test('is the same device until the app restarts', () {
      // Showing the code twice in one session must show the same code: an id
      // that changed between the sheet and the page would make the other
      // device's scan fail for a reason nobody could see.
      final PairIdentity first = PairIdentity.current;
      final PairIdentity second = PairIdentity.current;
      expect(identical(first, second), isTrue);
      PairIdentity.debugReset();
      expect(PairIdentity.current.id, isNot(first.id));
    });

    test('says "My phone" on Android, and the hostname on a desktop', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(defaultPairDeviceName(), 'My phone');
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(defaultPairDeviceName(), 'My device');
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      expect(defaultPairDeviceName(), isNotEmpty);
      debugDefaultTargetPlatformOverride = null;
    });

    test('can be stated by a test instead of generated', () {
      PairIdentity.override = () => const PairIdentity(
        name: 'Test Phone',
        id: 'test-device-id-0001',
        publicKey: 'pk-test',
      );
      addTearDown(() => PairIdentity.override = null);
      expect(PairIdentity.current.name, 'Test Phone');
      expect(PairIdentity.current.invite.deviceId, 'test-device-id-0001');
    });

    test('the placeholder key is 32 random bytes, base64url', () {
      final String a = placeholderPublicKey();
      final String b = placeholderPublicKey();
      expect(a, isNot(b));
      expect(a.length, 43, reason: '32 bytes in base64url, unpadded');
      expect(a, matches(RegExp(r'^[A-Za-z0-9_-]+$')));
    });
  });
}
