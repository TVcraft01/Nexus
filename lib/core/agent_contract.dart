/// Versioned contracts for future device actions.
///
/// This layer deliberately does not execute actions or choose an AI model.
/// MeshService can later transport an [AgentRequest] after pairing and apply
/// the target device's [DeviceCapabilities] before dispatch.
class DeviceCapability {
  final String id;
  final int version;

  const DeviceCapability(this.id, {this.version = 1});

  Map<String, dynamic> toJson() => {'id': id, 'version': version};

  factory DeviceCapability.fromJson(Map<String, dynamic> json) =>
      DeviceCapability(json['id'] as String, version: (json['version'] as num?)?.toInt() ?? 1);
}

class DeviceCapabilities {
  final String deviceId;
  final int version;
  final List<DeviceCapability> capabilities;

  const DeviceCapabilities({required this.deviceId, this.version = 1, this.capabilities = const []});

  bool supports(String id, {int version = 1}) => capabilities.any((c) => c.id == id && c.version >= version);

  Map<String, dynamic> toJson() => {
    'deviceId': deviceId,
    'version': version,
    'capabilities': capabilities.map((c) => c.toJson()).toList(),
  };

  factory DeviceCapabilities.fromJson(Map<String, dynamic> json) => DeviceCapabilities(
    deviceId: json['deviceId'] as String,
    version: (json['version'] as num?)?.toInt() ?? 1,
    capabilities: (json['capabilities'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => DeviceCapability.fromJson(Map<String, dynamic>.from(item)))
        .toList(),
  );
}

enum AgentApproval { automatic, required, approved, denied }

class AgentRequest {
  final int version;
  final String requestId;
  final String target;
  final String action;
  final Map<String, dynamic> arguments;
  final AgentApproval approval;

  const AgentRequest({
    required this.requestId,
    required this.target,
    required this.action,
    this.arguments = const {},
    this.approval = AgentApproval.required,
    this.version = 1,
  });

  Map<String, dynamic> toJson() => {
    'version': version,
    'requestId': requestId,
    'target': target,
    'action': action,
    'arguments': arguments,
    'approval': approval.name,
  };

  factory AgentRequest.fromJson(Map<String, dynamic> json) => AgentRequest(
    version: (json['version'] as num?)?.toInt() ?? 1,
    requestId: json['requestId'] as String,
    target: json['target'] as String,
    action: json['action'] as String,
    arguments: Map<String, dynamic>.from((json['arguments'] as Map?) ?? const {}),
    approval: AgentApproval.values.firstWhere(
      (value) => value.name == json['approval'],
      orElse: () => AgentApproval.required,
    ),
  );

  bool isAuthorized(DeviceCapabilities device) =>
      approval != AgentApproval.denied && device.supports(action);
}
