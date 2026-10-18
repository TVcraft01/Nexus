import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/pair_invite.dart';
import 'package:nexus/core/paired_devices.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The list of paired devices, and the fact that it survives a restart.
///
/// Three operations and one promise: add, forget, read back. The rest of these
/// tests are the edges of those three — pairing the same device twice, a stored
/// list that lost this device, a preferences value written by another build,
/// and the one row that may never be forgotten.
void main() {
  const PairInvite invite = PairInvite(
    deviceName: 'Ocean Phone',
    deviceId: 'ocean-phone-0001-real-id',
    publicKey: 'pk-ocean',
  );

  group('the list', () {
    test('seeds with this device and two examples, in that order', () {
      final PairedDevices paired = PairedDevices();
      expect(paired.devices.map((PairedDevice d) => d.name), <String>[
        'This Phone',
        'My PC',
        'Studio Mac',
      ]);
      expect(paired.devices.first.isThisDevice, isTrue);
      expect(paired.devices.where((PairedDevice d) => d.online).length, 2);
    });

    test('adds a scanned device as online, because somebody is holding it', () {
      final PairedDevices paired = PairedDevices(
        store: MemoryPairedDevicesStore(),
      );
      expect(paired.add(invite), isTrue);
      final PairedDevice added = paired.devices.last;
      expect(added.name, 'Ocean Phone');
      expect(added.id, 'ocean-phone-0001-real-id');
      expect(added.publicKey, 'pk-ocean');
      expect(added.online, isTrue);
      expect(added.detail, 'Paired just now');
      expect(added.isThisDevice, isFalse);
    });

    test('the same device scanned twice is one row, and says so', () {
      final PairedDevices paired = PairedDevices(
        store: MemoryPairedDevicesStore(),
      );
      expect(paired.add(invite), isTrue);
      expect(paired.add(invite), isFalse);
      expect(
        paired.devices.where((PairedDevice d) => d.id == invite.deviceId).length,
        1,
      );
      expect(paired.contains(invite.deviceId), isTrue);
    });

    test('forgets a peer, and keeps its hands off this device', () {
      final PairedDevices paired = PairedDevices(
        store: MemoryPairedDevicesStore(),
      );
      expect(paired.forget('example-mac'), isTrue);
      expect(paired.devices.map((PairedDevice d) => d.name), <String>[
        'This Phone',
        'My PC',
      ]);
      // The row that says who is reading the list is not a pairing: a device
      // cannot unpair from itself, and the row would come back next start.
      expect(paired.forget('this-device'), isFalse);
      expect(paired.devices.first.name, 'This Phone');
      expect(paired.forget('never-paired'), isFalse);
    });

    test('tells its listeners, so the screen can follow', () {
      final PairedDevices paired = PairedDevices(
        store: MemoryPairedDevicesStore(),
      );
      int notified = 0;
      paired.addListener(() => notified++);
      paired.add(invite);
      expect(notified, 1);
      paired.add(invite);
      expect(notified, 1, reason: 'a refused add is not a change');
      paired.forget(invite.deviceId);
      expect(notified, 2);
    });
  });

  group('surviving a restart', () {
    test('reads back what the last session wrote', () async {
      final MemoryPairedDevicesStore store = MemoryPairedDevicesStore();
      final PairedDevices first = PairedDevices(store: store);
      first.add(invite);
      // The write is deliberately not awaited by the caller (the screen has
      // already changed); the memory store lands it in a microtask.
      await Future<void>.delayed(Duration.zero);

      final PairedDevices second = PairedDevices(store: store);
      await second.attach();
      // The seed rows are part of the list, so they come back too — and the
      // device this phone is stays first, because it is the list saying whose
      // list it is.
      expect(second.devices.map((PairedDevice d) => d.name), <String>[
        'This Phone',
        'My PC',
        'Studio Mac',
        'Ocean Phone',
      ]);
    });

    test('keeps the seed when there is nothing stored', () async {
      final PairedDevices paired = PairedDevices(
        store: MemoryPairedDevicesStore(),
      );
      await paired.attach();
      expect(paired.devices.length, 3);
    });

    test('puts this device back at the top of a stored list that lost it', () async {
      // A list written by an older build, or by a version that stored peers
      // only: the row that says who is reading it is not optional.
      final MemoryPairedDevicesStore store = MemoryPairedDevicesStore(
        <PairedDevice>[
          const PairedDevice(id: 'peer', name: 'Peer', publicKey: 'k'),
        ],
      );
      final PairedDevices paired = PairedDevices(store: store);
      await paired.attach();
      expect(paired.devices.first.isThisDevice, isTrue);
      expect(paired.devices.last.name, 'Peer');
    });

    test('attaches once: a second call cannot undo a pairing', () async {
      final MemoryPairedDevicesStore store = MemoryPairedDevicesStore();
      final PairedDevices paired = PairedDevices(store: store, seed: const []);
      await paired.attach();
      paired.add(invite);
      await paired.attach();
      expect(paired.contains(invite.deviceId), isTrue);
    });
  });

  group('the preferences store', () {
    test('round-trips a list', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final SharedPrefsPairedDevicesStore store =
          SharedPrefsPairedDevicesStore();
      const PairedDevice mac = PairedDevice(
        id: 'example-mac',
        name: 'Studio Mac',
        publicKey: 'pk',
        detail: 'Laptop · last seen Oct 9',
      );
      await store.write(<PairedDevice>[
        const PairedDevice(
          id: 'this-device',
          name: 'This Phone',
          publicKey: '',
          isThisDevice: true,
          online: true,
        ),
        mac,
      ]);
      final List<PairedDevice>? back = await store.read();
      expect(back, isNotNull);
      expect(back!.length, 2);
      expect(back.first.isThisDevice, isTrue);
      expect(back.last.name, 'Studio Mac');
      expect(back.last.detail, 'Laptop · last seen Oct 9');
      expect(back.last.online, isFalse);
    });

    test('reads nothing out of a value written by something else', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        SharedPrefsPairedDevicesStore.key: 'not json at all',
      });
      expect(await SharedPrefsPairedDevicesStore().read(), isNull);

      SharedPreferences.setMockInitialValues(<String, Object>{
        SharedPrefsPairedDevicesStore.key: '{"devices":[]}',
      });
      expect(await SharedPrefsPairedDevicesStore().read(), isNull);
    });

    test('drops a broken row instead of keeping a device called null', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        SharedPrefsPairedDevicesStore.key:
            '[{"id":"peer","name":"Peer"},{"name":"no id"},{"id":"","name":""}]',
      });
      final List<PairedDevice>? back =
          await SharedPrefsPairedDevicesStore().read();
      expect(back, isNotNull);
      expect(back!.length, 1);
      expect(back.single.name, 'Peer');
      // A row written before the public key existed still reads: an empty key
      // is not a reason to lose a device the user paired.
      expect(back.single.publicKey, '');
    });
  });
}
