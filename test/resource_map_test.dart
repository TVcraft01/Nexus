// The capability / resource seam, tested as data: what it reports about who
// can do what, that it never claims more evidence than it has, and that the
// selection interface recommends a device without anything being routed
// through it.
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent_contract.dart';
import 'package:nexus/core/capability.dart';
import 'package:nexus/core/resource_map.dart';

AgentDeviceSnapshot _device({
  String id = 'p1',
  String name = 'Pixel 8',
  String platform = 'android',
  bool online = true,
}) => AgentDeviceSnapshot(
  id: id,
  name: name,
  online: online,
  capabilities: defaultCapabilitiesFor(platform),
  platform: platform,
);

AgentDeviceSnapshot _desk({bool online = true}) => AgentDeviceSnapshot(
  id: 'd1',
  name: 'Test Desk',
  online: online,
  capabilities: defaultCapabilitiesFor('linux'),
  platform: 'linux',
);

ResourceMap _map({
  AgentDeviceSnapshot? local,
  List<AgentDeviceSnapshot> paired = const [],
  Set<String> verifiedLocally = const {},
}) => ResourceMap.of(
  local: local,
  paired: paired,
  verifiedLocally: verifiedLocally,
);

void main() {
  group('the seam reads devices, it does not invent them', () {
    test('this device comes first and peers follow it', () {
      final map = _map(local: _desk(), paired: [_device()]);
      expect(map.devices.map((d) => d.name), ['Test Desk', 'Pixel 8']);
      expect(map.here!.isThisDevice, isTrue);
      expect(map.peers.length, 1);
      expect(map.peers.single.isThisDevice, isFalse);
    });

    test('an offline peer sorts after a reachable one', () {
      final map = _map(
        local: _desk(),
        paired: [
          _device(id: 'p2', name: 'Old Phone', online: false),
          _device(id: 'p3', name: 'New Phone'),
        ],
      );
      expect(map.devices.map((d) => d.name), [
        'Test Desk',
        'New Phone',
        'Old Phone',
      ]);
    });

    test('a device with no platform has no kind, and is never guessed at', () {
      final unknown = AgentDeviceSnapshot(
        id: 'x',
        name: 'Mystery',
        online: true,
        capabilities: const [DeviceCapability('greet.get')],
      );
      final map = _map(paired: [unknown]);
      expect(map.peers.single.kind, DeviceKind.other);
      expect(deviceKindWords(DeviceKind.other), isEmpty);
      expect(deviceKindOf('plan9'), DeviceKind.other);
    });

    test('the platform decides the kind, for every platform it names', () {
      expect(deviceKindOf('android'), DeviceKind.phone);
      expect(deviceKindOf('linux'), DeviceKind.computer);
      expect(deviceKindOf('windows'), DeviceKind.computer);
      expect(deviceKindOf('macos'), DeviceKind.computer);
      expect(deviceKindOf(''), DeviceKind.other);
    });
  });

  group('evidence is never flattened', () {
    test('only actions this device really runs count as verified', () {
      final map = _map(
        local: _desk(),
        verifiedLocally: const {AgentActions.webSearch},
      );
      final here = map.here!;
      expect(
        here.evidenceFor(AgentActions.webSearch),
        CapabilityEvidence.verified,
      );
      // Listed by the platform, but nothing has proven this device runs it.
      expect(
        here.evidenceFor(AgentActions.ledBlink),
        CapabilityEvidence.assumed,
      );
      expect(here.evidenceFor('nothing.at.all'), isNull);
      expect(here.can('nothing.at.all'), isFalse);
    });

    test('a peer is only ever assumed, because nothing announces yet', () {
      final map = _map(local: _desk(), paired: [_device()]);
      final peer = map.peers.single;
      expect(peer.can(AgentActions.callPlace), isTrue);
      expect(
        peer.evidenceFor(AgentActions.callPlace),
        CapabilityEvidence.assumed,
        reason: 'no peer sends a capability advertisement in this release',
      );
    });

    test('a verified action anywhere is reported as verified', () {
      final unproven = _map(local: _desk(), paired: [_device()]);
      expect(unproven.reach(AgentActions.webSearch).verifiedSomewhere, isFalse);
      final proven = _map(
        local: _desk(),
        paired: [_device()],
        verifiedLocally: const {AgentActions.webSearch},
      );
      expect(proven.reach(AgentActions.webSearch).verifiedSomewhere, isTrue);
    });
  });

  group('reach answers who, where, and whether anyone holds it', () {
    test('an undeclared capability is not reachable and not declared', () {
      final map = _map(local: _desk(), paired: [_device()]);
      final reach = map.reach('telepathy.read');
      expect(reach.declared, isFalse);
      expect(reach.hasAnyDevice, isFalse);
      expect(reach.hasExecutor, isFalse);
      expect(reach.declaredOn, isNull);
      expect(map.choose('telepathy.read'), isNull);
    });

    test('nobody holding it is different from nobody reachable', () {
      // A desktop-only world cannot make a call, and the answer can say so
      // from the registry instead of guessing.
      final noPhone = _map(local: _desk());
      final call = noPhone.reach(AgentActions.callPlace);
      expect(call.declared, isTrue);
      expect(call.hasAnyDevice, isFalse);
      expect(call.declaredOn, 'a phone');

      // A phone that is paired but offline holds it, and is not in reach.
      final offlinePhone = _map(
        local: _desk(),
        paired: [_device(online: false)],
      );
      final held = offlinePhone.reach(AgentActions.callPlace);
      expect(held.hasAnyDevice, isTrue);
      expect(held.hasExecutor, isFalse);
      expect(held.reachable, isEmpty);
    });

    test('declaredOn reports the registry platforms in the user terms', () {
      final map = _map(local: _desk(), paired: [_device()]);
      expect(map.reach(AgentActions.callPlace).declaredOn, 'a phone');
      expect(
        map.reach(AgentActions.webSearch).declaredOn,
        'a phone or a computer',
      );
      // Answered locally with no device backend: where it "works" is nowhere
      // specific, and the seam says nothing rather than inventing a form.
      expect(map.reach(AgentActions.mathCalc).declaredOn, isNull);
      expect(map.reach(AgentActions.deviceList).declaredOn, isNull);
    });
  });

  group('selection recommends, and routes nothing', () {
    test('this device wins when it can, so nothing has to be transferred', () {
      final map = _map(
        local: _desk(),
        paired: [_device()],
        verifiedLocally: const {AgentActions.webSearch},
      );
      expect(map.choose(AgentActions.webSearch)!.isThisDevice, isTrue);
    });

    test('an offline device is never chosen', () {
      final map = _map(local: _desk(), paired: [_device(online: false)]);
      // This device cannot call, so the only holder is out of reach.
      final reach = map.reach(AgentActions.callPlace);
      expect(reach.hasAnyDevice, isTrue);
      expect(map.choose(AgentActions.callPlace), isNull);
    });

    test('a reachable peer is chosen when nothing here can', () {
      final map = _map(local: _desk(), paired: [_device()]);
      final chosen = map.choose(AgentActions.callPlace);
      expect(chosen!.id, 'p1');
      expect(chosen.isThisDevice, isFalse);
    });

    test('the recommendation is used for no action — it is data only', () {
      final map = _map(local: _desk(), paired: [_device()]);
      // Whatever it recommends, the recommendation is a device, not a result:
      // there is no task id, no transport and no completion to await, which is
      // what keeps this a seam rather than a routing implementation.
      final chosen = map.choose(AgentActions.callPlace);
      expect(chosen, isA<DeviceResource>());
      expect(map.reachablePeersOf(AgentActions.callPlace).single.id, 'p1');
    });
  });
}
