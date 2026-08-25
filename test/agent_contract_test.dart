import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent_contract.dart';

void main() {
  test('capabilities round-trip and require a supported version', () {
    const caps = DeviceCapabilities(
      deviceId: 'pc',
      capabilities: [DeviceCapability('camera.capture', version: 2)],
    );
    final restored = DeviceCapabilities.fromJson(caps.toJson());
    expect(restored.supports('camera.capture', version: 2), isTrue);
    expect(restored.supports('camera.capture', version: 3), isFalse);
  });

  test('request round-trips its target, arguments, and approval', () {
    const request = AgentRequest(
      version: 1,
      requestId: 'r1',
      target: 'esp32',
      action: 'led.blink',
      arguments: {'count': 2},
      approval: AgentApproval.approved,
    );
    final restored = AgentRequest.fromJson(request.toJson());
    expect(restored.requestId, 'r1');
    expect(restored.target, 'esp32');
    expect(restored.arguments['count'], 2);
    expect(restored.approval, AgentApproval.approved);
  });

  test('authorization requires capability and rejects denied requests', () {
    const device = DeviceCapabilities(
      deviceId: 'phone',
      capabilities: [DeviceCapability('clipboard.write')],
    );
    const allowed = AgentRequest(
      requestId: '1', target: 'phone', action: 'clipboard.write', approval: AgentApproval.approved,
    );
    const denied = AgentRequest(
      requestId: '2', target: 'phone', action: 'clipboard.write', approval: AgentApproval.denied,
    );
    expect(allowed.isAuthorized(device), isTrue);
    expect(denied.isAuthorized(device), isFalse);
    expect(allowed.isAuthorized(const DeviceCapabilities(deviceId: 'phone')), isFalse);
  });
}
