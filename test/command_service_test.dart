import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent_contract.dart';
import 'package:nexus/core/command_service.dart';

void main() {
  const devices = [
    AgentDeviceSnapshot(
      id: 'esp32',
      name: 'Desk ESP32',
      online: true,
      capabilities: [DeviceCapability(AgentActions.ledBlink)],
    ),
    AgentDeviceSnapshot(id: 'phone', name: 'My Phone', online: true),
  ];
  final service = CommandService(devices: () => devices);

  test('lists the injected snapshots', () {
    final result = service.execute('show my devices');
    expect(result.status, AgentResultStatus.succeeded);
    expect((result.dispatch! as AgentDeviceList).devices, devices);
  });

  test('resolves exact ID and unique display name', () {
    for (final target in ['esp32', 'Desk ESP32']) {
      final result = service.execute(
        'blink the $target',
        approval: AgentApproval.approved,
        requestId: target,
      );
      expect(result.status, AgentResultStatus.succeeded, reason: target);
      final plan = (result.dispatch! as AgentActionPlan).request;
      expect(plan.target, 'esp32', reason: target);
      expect(plan.isAuthorized(DeviceCapabilities(
        deviceId: 'esp32',
        capabilities: [DeviceCapability(AgentActions.ledBlink)],
      )), isTrue, reason: target);
    }
  });

  test('rejects ambiguous and missing names', () {
    final ambiguous = CommandService(
      devices: () => const [
        AgentDeviceSnapshot(id: 'a', name: 'Board', online: true),
        AgentDeviceSnapshot(id: 'b', name: 'Board', online: true),
      ],
    ).execute('blink the board', approval: AgentApproval.approved);
    expect(ambiguous.status, AgentResultStatus.unavailable);

    // Missing target stays unavailable even before any approval decision —
    // there must never be an approval prompt for a device that does not exist.
    for (final approval in [AgentApproval.approved, AgentApproval.required]) {
      final missing = service.execute('blink the unknown', approval: approval);
      expect(missing.status, AgentResultStatus.unavailable, reason: approval.name);
      expect(missing.dispatch, isNull);
    }
  });

  test('requires and respects explicit local approval', () {
    for (final approval in [AgentApproval.required, AgentApproval.denied]) {
      final result = service.execute('blink the esp32', approval: approval);
      expect(
        result.status,
        approval == AgentApproval.required
            ? AgentResultStatus.required
            : AgentResultStatus.denied,
      );
      expect(result.dispatch, isNull);
    }
  });
}