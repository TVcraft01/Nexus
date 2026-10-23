// The token on the QR, and the fact that it survives a restart.
//
// A transfer is only as useful as the token being the same one the scanner
// stored, and a token that is regenerated at launch breaks every pairing made
// yesterday. The store is mocked, so what this pins is the shape and the reuse,
// not the plugin.
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/pair_invite.dart';
import 'package:nexus/core/pair_token.dart';
import 'package:nexus/core/paired_devices.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    PairToken.debugReset();
  });

  tearDown(PairToken.debugReset);

  test('is long, url-safe, and stays the same across reads', () async {
    final String first = await PairToken.current();
    expect(first.length, greaterThanOrEqualTo(40));
    expect(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(first), isTrue);

    // A new read in the same process is the same token.
    expect(await PairToken.current(), first);

    // And so is one after the memo is dropped: the store is the truth.
    PairToken.debugReset();
    expect(await PairToken.current(), first);
  });

  test('a fresh install gets a fresh token', () async {
    final String first = await PairToken.current();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    PairToken.debugReset();
    final String second = await PairToken.current();
    expect(second, isNot(first));
  });

  test('the pairing QR carries it, and the scanner stores it as the code',
      () async {
    const PairIdentity me = PairIdentity(
      name: 'This Phone',
      id: 'this-phone-000000000000000000001',
      publicKey: 'this-key',
    );
    final String token = await PairToken.current();
    final String payload = me
        .withToken(token)
        .withAddresses(<String>['192.168.1.7'])
        .invite
        .encode();

    final PairInvite? parsed = PairInvite.parse(payload);
    expect(parsed, isNotNull);
    expect(parsed!.code, token);

    // The same row the scanner writes is the one the sender reads: the token
    // lives in [PairedDevice.code].
    final PairedDevice row = PairedDevice.fromInvite(parsed);
    expect(row.code, token);
    expect(row.addresses, <String>['192.168.1.7']);
  });

  test('an old code with no token still pairs, with an empty secret', () {
    final PairInvite? parsed = PairInvite.parse(
      '{"type":"nexus_pair","device_name":"Old Phone",'
      '"device_id":"old-phone-00000000000000000001","public_key":"k"}',
    );
    expect(parsed, isNotNull);
    expect(parsed!.code, isEmpty);
  });
}
