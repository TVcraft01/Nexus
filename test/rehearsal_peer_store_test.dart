// Guards the rehearsal peer's store bootstrap (test/rehearsal_peer.dart).
//
// The peer runs as its own `flutter test` process, and a device run restarts
// it — kill the peer, bring it back — to prove the phone reconnects on its
// own. A restart therefore has to keep what the previous run wrote, which
// means reading the store file before writing anything into it. Saving a
// never-loaded store first overwrote the pairing list, so the restarted peer
// came back paired with nobody and never dialled the phone; on the
// 2026-10-07 device run that looked like a product reconnect failure until
// the store file showed it was this ordering.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'rehearsal_peer.dart' show openPeerStore;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the rehearsal peer keeps its port and its pairings across a restart',
      () async {
    final tmp = await Directory.systemTemp.createTemp('nexus_peer_store');
    addTearDown(() => tmp.delete(recursive: true));
    final path = '${tmp.path}/peer_store.json';

    // First run: the peer opens its store, then pairs with the phone.
    final first = await openPeerStore(path);
    first.upsertPaired({
      'id': 'goou4tt557c220n1qbudc3xiq65c6hdf',
      'name': 'TVcraft01 phone',
      'platform': 'android',
      'localName': false,
      'address': '10.238.55.30',
      'addresses': <String>['10.238.55.30'],
      'port': 51820,
      'pairingSecret': 'shared-secret',
      'lastVerified': null,
    });
    await first.save();
    // On disk, not just in memory: the next run reads the file.
    expect(
      File(path).readAsStringSync(),
      contains('goou4tt557c220n1qbudc3xiq65c6hdf'),
    );

    // Restart: the harness builds the same store again, exactly as a second
    // `flutter test test/rehearsal_peer.dart` does.
    final restarted = await openPeerStore(path);
    expect(restarted.port, first.port);
    expect(
      restarted.pairedDevices.map((device) => device['id']),
      contains('goou4tt557c220n1qbudc3xiq65c6hdf'),
      reason: 'a restarted peer must still know the phone it dials back',
    );
  });
}
