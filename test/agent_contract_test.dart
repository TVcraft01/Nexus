import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent_contract.dart';

void main() {
  const phone = DeviceCapabilities(deviceId: 'phone');
  const esp = DeviceCapabilities(
    deviceId: 'esp32',
    capabilities: [DeviceCapability(AgentActions.ledBlink)],
  );

  test('contracts round-trip', () {
    const caps = DeviceCapabilities(
      deviceId: 'phone',
      capabilities: [DeviceCapability(AgentActions.clipboardWrite, version: 2)],
    );
    expect(DeviceCapabilities.fromJson(caps.toJson()).toJson(), caps.toJson());
    const request = AgentRequest(
      requestId: 'r1', target: 'phone', action: AgentActions.clipboardWrite,
      arguments: {'text': 'hello'}, approval: AgentApproval.approved,
    );
    expect(AgentRequest.fromJson(request.toJson()).toJson(), request.toJson());
  });

  test('parse supported commands only', () {
    final cases = <String, ParsedCommand?>{
      'show my devices': const ParsedCommand(action: AgentActions.deviceList, target: 'local'),
      ' BLINK THE ESP32 ': const ParsedCommand(action: AgentActions.ledBlink, target: 'esp32'),
      'unsupported command': null,
    };
    for (final entry in cases.entries) {
      expect(parseCommand(entry.key)?.action, entry.value?.action, reason: entry.key);
      expect(parseCommand(entry.key)?.target, entry.value?.target, reason: entry.key);
    }
  });

  test('dispatch returns snapshots or a validated dry-run plan', () {
    const snapshots = [
      AgentDeviceSnapshot(id: 'phone', name: 'My phone', online: true),
      AgentDeviceSnapshot(id: 'esp32', name: 'Desk ESP32', online: false),
    ];
    final list = dispatchCommand(
      command: const ParsedCommand(action: AgentActions.deviceList, target: 'local'),
      localDevice: phone,
      devices: snapshots,
    );
    expect(list.status, AgentResultStatus.succeeded);
    expect((list.dispatch! as AgentDeviceList).devices, orderedEquals(snapshots));

    final cases = <String, ({AgentApproval approval, DeviceCapabilities? target, AgentResultStatus status})>{
      'required': (approval: AgentApproval.required, target: esp, status: AgentResultStatus.required),
      'denied': (approval: AgentApproval.denied, target: esp, status: AgentResultStatus.denied),
      'missing target': (approval: AgentApproval.approved, target: null, status: AgentResultStatus.unavailable),
      'missing capability': (approval: AgentApproval.approved, target: phone, status: AgentResultStatus.unavailable),
      'old capability': (approval: AgentApproval.approved, target: const DeviceCapabilities(deviceId: 'esp32', capabilities: [DeviceCapability(AgentActions.ledBlink, version: 0)]), status: AgentResultStatus.unavailable),
    };
    for (final entry in cases.entries) {
      final result = dispatchCommand(
        command: const ParsedCommand(action: AgentActions.ledBlink, target: 'esp32'),
        localDevice: phone,
        targetDevice: entry.value.target,
        approval: entry.value.approval,
        requestId: entry.key,
      );
      expect(result.status, entry.value.status, reason: entry.key);
      expect(result.dispatch, isNull, reason: entry.key);
    }

    final success = dispatchCommand(
      command: const ParsedCommand(action: AgentActions.ledBlink, target: 'esp32'),
      localDevice: phone,
      targetDevice: esp,
      approval: AgentApproval.approved,
      requestId: 'blink-1',
    );
    final plan = (success.dispatch! as AgentActionPlan).request;
    expect(success.status, AgentResultStatus.succeeded);
    expect(plan.requestId, 'blink-1');
    expect(plan.target, 'esp32');
    expect(plan.approval, AgentApproval.approved);
    expect(plan.isAuthorized(esp), isTrue);
    expect(plan.isAuthorized(const DeviceCapabilities(deviceId: 'esp32')), isFalse);
  });
}
