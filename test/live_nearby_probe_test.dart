// Live probe: a second Nexus device on this network, so the phone's Devices tab
// has something real to hear while it is being tested over adb.
//
// It is the project's own `DiscoveryService` — the same class the app runs, the
// same announce payload, the same unicast reply path — announcing as a Linux
// desktop called "Study PC". It is not a second Nexus install: it announces and
// hears, and it has no mesh sockets, so it can be discovered and paired but not
// sent files. That is exactly the shape the discovery test needs.
//
// Not part of the normal suite (the run needs a phone on the same Wi-Fi). Run it
// while driving the phone:
//
//   flutter test test/live_nearby_probe_test.dart \
//     --dart-define=NEARBY_PHONE_IP=192.168.1.8 --dart-define=NEARBY_SECONDS=180
//
// The phone address is announced to directly as well as by multicast: the
// phone's Wi-Fi firmware filters multicast frames unless an app holds the
// multicast lock, and unicast is how the real mesh gets through the same
// filter.
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/identity.dart' show DeviceInfo;
import 'package:nexus/mesh/discovery.dart'
    show DiscoveredDevice, DiscoveryService;

void main() {
  test('announces as a nearby Nexus device', () async {
    const String phone = String.fromEnvironment('NEARBY_PHONE_IP');
    const int seconds = int.fromEnvironment('NEARBY_SECONDS', defaultValue: 120);
    if (phone.isEmpty) {
      markTestSkipped('NEARBY_PHONE_IP not provided');
      return;
    }

    final DiscoveryService service = DiscoveryService(
      identity: DeviceInfo(
        id: 'studypc000000000000000000000000001',
        name: 'Study PC',
        platform: 'linux',
      ),
      onDiscovered: (DiscoveredDevice device) => debugPrint(
        'NEARBY PROBE: heard ${device.name} at ${device.address}:${device.port}',
      ),
    )..knownAddresses.add((address: phone, port: 51822));

    await service.start();
    debugPrint('NEARBY PROBE: announcing to $phone — ${service.status.describe()}');
    // The announce loop is the service's own (every three seconds); this only
    // keeps the test alive while the phone is being driven.
    await Future<void>.delayed(Duration(seconds: seconds));
    // Read before the socket closes: after `stop()` the bound port is null by
    // design, and the summary would read "discovery is off" — true, and not
    // what this line is for.
    final String summary = service.status.describe();
    await service.stop();
    debugPrint('NEARBY PROBE: stopped ($summary)');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
