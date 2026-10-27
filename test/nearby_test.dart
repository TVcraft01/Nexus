// Discovery, without a network.
//
// The transport is faked at the one seam that matters — `DiscoveryService`,
// whose own socket behaviour is already pinned in test/discovery_test.dart —
// so what is exercised here is this object's promises: it says what it heard,
// it says when it heard nothing, a device that goes quiet leaves the list, a
// socket that will not open is a sentence rather than a crash, and stopping it
// really closes the transport.
import 'package:flutter/foundation.dart' show ChangeNotifier, VoidCallback;
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/identity.dart' show DeviceInfo;
import 'package:nexus/mesh/discovery.dart'
    show MeshNearbySource, DiscoveredDevice, DiscoveryService, DiscoveryStatus;
import 'package:nexus/mesh/nearby.dart' show NearbyDevices;

final DiscoveredDevice _tablet = DiscoveredDevice(
  id: 'tablet000000000000000000000000001',
  name: 'Kitchen tablet',
  platform: 'android',
  address: '192.168.1.44',
  port: 51820,
  lastSeen: DateTime(2026, 10, 18, 12),
);

/// What a transport does with a device it hears. A named function rather than a
/// lambda, because half these tests count calls and the lint that says so is
/// right: a closure with an empty body is a tear-off waiting to happen.
void _ignoreDevice(DiscoveredDevice device) {}

/// A discovery service that answers with whatever the test says, the moment it
/// is started. Subclassed rather than reimplemented because the object under
/// test only ever calls `start`, `stop` and `status` on it.
class _FakeTransport extends DiscoveryService {
  _FakeTransport(
    void Function(DiscoveredDevice) onHeard, {
    this.heard = const <DiscoveredDevice>[],
    this.fails = false,
    this.boundPort = 51822,
  }) :
       super(
         identity: DeviceInfo(
           id: 'me0000000000000000000000000000001',
           name: 'This Phone',
           platform: 'android',
         ),
         onDiscovered: onHeard,
       );

  final List<DiscoveredDevice> heard;
  final bool fails;
  final int boundPort;

  bool stopped = false;

  @override
  Future<void> start() async {
    if (fails) throw StateError('no socket for you');
    heard.forEach(onDiscovered);
  }

  @override
  Future<void> stop() async => stopped = true;

  @override
  DiscoveryStatus get status => DiscoveryStatus(
    boundPort: boundPort,
    announced: 3,
    failedSends: 0,
    received: heard.length,
  );
}

/// A mesh standing in for the real one: the peers it heard, and a change
/// notification. Exactly what `NearbyDevices.bindTo` needs.
class _FakeMesh extends ChangeNotifier implements MeshNearbySource {
  _FakeMesh(this._peers);

  List<DiscoveredDevice> _peers;

  /// How many listeners are attached. `hasListeners` is protected, so a test
  /// counts through the calls it is allowed to make.
  int attached = 0;

  @override
  List<DiscoveredDevice> get nearbyDevices => _peers;

  @override
  void addListener(VoidCallback listener) {
    attached++;
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    attached--;
    super.removeListener(listener);
  }

  void hear(List<DiscoveredDevice> peers) {
    _peers = peers;
    notifyListeners();
  }
}

void main() {
  test('hears a device and puts it on the list', () async {
    final NearbyDevices nearby = NearbyDevices(
      discovery: (void Function(DiscoveredDevice) onHeard) =>
          _FakeTransport(onHeard, heard: <DiscoveredDevice>[_tablet]),
    );

    await nearby.start();

    expect(nearby.running, isTrue);
    expect(nearby.hasHeard(_tablet.id), isTrue);
    expect(nearby.devices.map((DiscoveredDevice d) => d.name), <String>[
      'Kitchen tablet',
    ]);
    expect(nearby.device(_tablet.id)?.address, '192.168.1.44');
    expect(nearby.status, 'Heard 1 Nexus device on this network.');
    await nearby.stop();
  });

  test('with nothing heard it says what discovery is doing', () async {
    final NearbyDevices nearby = NearbyDevices(
      discovery: _FakeTransport.new,
    );

    await nearby.start();

    // The transport's own honest summary, not a cheerful "looking…" that never
    // ends and never explains an empty screen.
    expect(nearby.devices, isEmpty);
    expect(
      nearby.status,
      'Discovery is listening; no other Nexus device has been heard yet.',
    );
    await nearby.stop();
  });

  test('a device that goes quiet leaves the list', () async {
    final NearbyDevices nearby = NearbyDevices(
      window: Duration.zero,
      discovery: (void Function(DiscoveredDevice) onHeard) =>
          _FakeTransport(onHeard, heard: <DiscoveredDevice>[_tablet]),
    );

    await nearby.start();
    expect(nearby.devices, hasLength(1));

    // A zero window means "anything not heard in this instant is gone" — the
    // same rule the real minute runs, without a minute of waiting.
    await Future<void>.delayed(const Duration(milliseconds: 5));
    nearby.debugSweep();

    expect(nearby.devices, isEmpty);
    expect(nearby.hasHeard(_tablet.id), isFalse);
    await nearby.stop();
  });

  test('stopping closes the transport and says so', () async {
    final _FakeTransport transport = _FakeTransport(_ignoreDevice);
    final NearbyDevices nearby = NearbyDevices(
      discovery: (void Function(DiscoveredDevice) _) => transport,
    );

    await nearby.start();
    await nearby.stop();

    expect(transport.stopped, isTrue);
    expect(nearby.running, isFalse);
    expect(nearby.status, 'Not looking for devices.');
  });

  test('a socket that will not open is a sentence, not a crash', () async {
    final NearbyDevices nearby = NearbyDevices(
      discovery: (void Function(DiscoveredDevice) onHeard) =>
          _FakeTransport(onHeard, fails: true),
    );

    await nearby.start();

    expect(nearby.status, contains('could not open a network socket'));
    await nearby.stop();
  });

  test('a transport stuck on the wrong port says which way it is broken',
      () async {
    final NearbyDevices nearby = NearbyDevices(
      discovery: (void Function(DiscoveredDevice) onHeard) =>
          _FakeTransport(onHeard, boundPort: 40404),
    );

    await nearby.start();

    // Deaf, and it knows why: on another port the announces never arrive.
    expect(nearby.status, contains('cannot hear other devices'));
    await nearby.stop();
  });

  group('bound to the mesh', () {
    test('reads the mesh\'s discovery instead of opening a socket', () async {
      final _FakeMesh mesh = _FakeMesh(<DiscoveredDevice>[_tablet]);
      // A factory that throws is the assertion: a bound list must not try.
      final NearbyDevices nearby = NearbyDevices(
        discovery: (void Function(DiscoveredDevice) _) =>
            throw StateError('a bound list must not open a socket'),
      );
      // Disposed inside the test, not in a tearDown: the last assertion is
      // about what dispose() does, and ChangeNotifier refuses a second one.

      nearby.bindTo(mesh);
      await nearby.start();

      expect(nearby.boundToMesh, isTrue);
      expect(nearby.running, isTrue);
      expect(nearby.devices.single.id, _tablet.id);
      // No socket of its own means no discovery status to report.
      expect(nearby.discoveryStatus, isNull);
      expect(nearby.status, contains('Heard 1 Nexus device'));

      // The Devices tab stops the list when it goes away; the mesh is the
      // app's, so that must not stop the mesh.
      await nearby.stop();
      expect(nearby.running, isFalse);
      expect(mesh.attached, 1);

      nearby.dispose();
      expect(mesh.attached, 0);
      expect(nearby.boundToMesh, isFalse);
    });

    test('follows the mesh, and keeps a forgotten device out', () async {
      final DiscoveredDevice laptop = DiscoveredDevice(
        id: 'laptop000000000000000000000000001',
        name: 'Study laptop',
        platform: 'linux',
        address: '192.168.1.9',
        port: 51820,
        lastSeen: DateTime(2026, 10, 18, 12),
      );
      final _FakeMesh mesh = _FakeMesh(<DiscoveredDevice>[_tablet]);
      final NearbyDevices nearby = NearbyDevices(
        discovery: (void Function(DiscoveredDevice) _) =>
            throw StateError('a bound list must not open a socket'),
      );
      addTearDown(nearby.dispose);

      nearby.bindTo(mesh);
      await nearby.start();

      mesh.hear(<DiscoveredDevice>[laptop]);
      expect(nearby.devices.single.name, 'Study laptop');

      // Forget is about the list the user is reading, and the mesh's next
      // change must not put the device back under Nearby.
      nearby.forget(laptop.id);
      mesh.hear(<DiscoveredDevice>[laptop, _tablet]);
      expect(nearby.devices.map((DiscoveredDevice d) => d.id), <String>[
        _tablet.id,
      ]);
    });
  });
}
