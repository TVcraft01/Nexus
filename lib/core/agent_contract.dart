/// Versioned contracts for future device actions.
///
/// This layer deliberately does not execute actions or choose an AI model.
/// MeshService can later transport an [AgentRequest] after pairing and apply
/// the target device's [DeviceCapabilities] before dispatch.
abstract final class AgentActions {
  static const deviceList = 'device.list';
  static const clipboardWrite = 'clipboard.write';
  static const ledBlink = 'led.blink';
}

class ParsedCommand {
  final String action;
  final String target;
  final Map<String, dynamic> arguments;

  const ParsedCommand({
    required this.action,
    required this.target,
    this.arguments = const {},
  });

  AgentRequest toRequest({
    required String requestId,
    AgentApproval approval = AgentApproval.required,
  }) => AgentRequest(
    requestId: requestId,
    target: target,
    action: action,
    arguments: arguments,
    approval: approval,
  );
}

/// Parses only deterministic commands whose target and arguments are explicit.
/// A future model can produce the same [ParsedCommand] shape without changing
/// execution or authorization.
ParsedCommand? parseCommand(String input) {
  final text = input.trim().toLowerCase();
  if (text == 'show my devices' || text == 'list devices') {
    return const ParsedCommand(action: AgentActions.deviceList, target: 'local');
  }
  final blink = RegExp(r'^(?:blink|flash) (.+)$').firstMatch(text);
  if (blink != null) {
    final target = blink.group(1)!.replaceFirst(RegExp(r'^the '), '').trim();
    return ParsedCommand(
      action: AgentActions.ledBlink,
      target: target,
    );
  }
  return null;
}

class AgentDeviceSnapshot {
  final String id;
  final String name;
  final bool online;
  final List<DeviceCapability> capabilities;

  const AgentDeviceSnapshot({
    required this.id,
    required this.name,
    required this.online,
    this.capabilities = const [],
  });

  @override
  bool operator ==(Object other) =>
      other is AgentDeviceSnapshot &&
      other.id == id &&
      other.name == name &&
      other.online == online &&
      _sameCapabilities(other.capabilities, capabilities);

  @override
  int get hashCode => Object.hash(id, name, online, capabilities.length);

  static bool _sameCapabilities(List<DeviceCapability> a, List<DeviceCapability> b) =>
      a.length == b.length &&
      a.indexed.every((entry) =>
          entry.$2.id == b[entry.$1].id && entry.$2.version == b[entry.$1].version);
}

sealed class AgentDispatch {
  const AgentDispatch();
}

class AgentDeviceList extends AgentDispatch {
  final List<AgentDeviceSnapshot> devices;

  const AgentDeviceList(this.devices);
}

class AgentActionPlan extends AgentDispatch {
  final AgentRequest request;

  const AgentActionPlan(this.request);
}

class AgentDispatchResult {
  final AgentResultStatus status;
  final String message;
  final AgentDispatch? dispatch;

  const AgentDispatchResult({
    required this.status,
    this.message = '',
    this.dispatch,
  });
}

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

enum AgentResultStatus { succeeded, required, denied, unavailable }

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
      approval == AgentApproval.approved &&
      target.toLowerCase() == device.deviceId.toLowerCase() &&
      device.supports(action);
}

/// Converts one parsed command into a local result or a checked request.
AgentDispatchResult dispatchCommand({
  required ParsedCommand command,
  required DeviceCapabilities localDevice,
  List<AgentDeviceSnapshot> devices = const [],
  DeviceCapabilities? targetDevice,
  AgentApproval approval = AgentApproval.required,
  String requestId = 'local-command',
}) {
  if (command.action == AgentActions.deviceList && command.target == 'local') {
    return AgentDispatchResult(
      status: AgentResultStatus.succeeded,
      dispatch: AgentDeviceList(List.unmodifiable(devices)),
    );
  }
  if (command.action != AgentActions.ledBlink) {
    return const AgentDispatchResult(status: AgentResultStatus.unavailable);
  }
  if (command.target.trim().isEmpty) {
    return const AgentDispatchResult(
      status: AgentResultStatus.unavailable,
      message: 'A target device is required.',
    );
  }
  if (approval == AgentApproval.required) {
    return const AgentDispatchResult(
      status: AgentResultStatus.required,
      message: 'Local approval is required.',
    );
  }
  if (approval == AgentApproval.denied) {
    return const AgentDispatchResult(
      status: AgentResultStatus.denied,
      message: 'The action was denied locally.',
    );
  }
  final target = targetDevice;
  if (target == null ||
      target.deviceId.toLowerCase() != command.target.toLowerCase() ||
      !target.supports(AgentActions.ledBlink)) {
    return const AgentDispatchResult(
      status: AgentResultStatus.unavailable,
      message: 'The target does not support led.blink.',
    );
  }
  final request = command.toRequest(
    requestId: requestId,
    approval: AgentApproval.approved,
  );
  return AgentDispatchResult(
    status: AgentResultStatus.succeeded,
    dispatch: AgentActionPlan(request),
  );
}
