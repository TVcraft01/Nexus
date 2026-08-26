/// Versioned contracts for future device actions.
///
/// This layer deliberately does not execute actions or choose an AI model.
/// MeshService can later transport an [AgentRequest] after pairing and apply
/// the target device's [DeviceCapabilities] before dispatch.
abstract final class AgentActions {
  static const deviceList = 'device.list';
  static const ledBlink = 'led.blink';
  static const mediaPlay = 'media.play';
  static const musicControl = 'music.control';
  static const homeControl = 'home.control';
  static const messageSend = 'communication.message';
  static const callPlace = 'communication.call';
  static const weatherGet = 'info.weather';
  static const reminderSet = 'reminder.set';
  static const alarmSet = 'alarm.set';
  static const timerSet = 'timer.set';
  static const navigationRoute = 'navigation.route';
  static const webSearch = 'search.web';
  static const noteCreate = 'note.create';
  static const translateText = 'translate.text';
  static const calendarGet = 'calendar.get';
  static const newsGet = 'info.news';
  static const greet = 'greet';
  static const timeGet = 'time.get';
  static const mathCalc = 'math.calc';
  static const clipboardWrite = 'clipboard.write';
  static const helpGet = 'help.get';
  static const batteryGet = 'device.battery';
  static const torchToggle = 'device.torch';
  static const volumeSet = 'device.volume';
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

/// A plain answer, rendered as text — e.g. the time, a math result, or a
/// greeting. No device action is involved.
class AgentMessage extends AgentDispatch {
  final String text;

  /// When true the UI keeps the answer fresh (e.g. a ticking clock) instead
  /// of freezing the value from the moment the command ran.
  final bool live;

  const AgentMessage(this.text, {this.live = false});
}

/// The capabilities a device of [platform] advertises by default — a phone
/// can make calls and send texts, a desktop usually cannot. Devices that
/// announce richer capabilities later simply replace this default; the ids
/// are the same [AgentActions] strings so one check serves both.
List<DeviceCapability> defaultCapabilitiesFor(String platform) {
  switch (platform) {
    case 'android':
    case 'ios':
      return const [
        DeviceCapability(AgentActions.callPlace),
        DeviceCapability(AgentActions.messageSend),
        DeviceCapability(AgentActions.alarmSet),
        DeviceCapability(AgentActions.timerSet),
        DeviceCapability(AgentActions.reminderSet),
        DeviceCapability(AgentActions.mediaPlay),
        DeviceCapability(AgentActions.musicControl),
        DeviceCapability(AgentActions.weatherGet),
        DeviceCapability(AgentActions.navigationRoute),
        DeviceCapability(AgentActions.webSearch),
        DeviceCapability(AgentActions.noteCreate),
        DeviceCapability(AgentActions.translateText),
        DeviceCapability(AgentActions.calendarGet),
        DeviceCapability(AgentActions.newsGet),
        DeviceCapability(AgentActions.homeControl),
        DeviceCapability(AgentActions.batteryGet),
        DeviceCapability(AgentActions.torchToggle),
        DeviceCapability(AgentActions.volumeSet),
      ];
    case 'linux':
    case 'windows':
    case 'macos':
      // Everything a desktop usually has — except calls and texts, the
      // canonical "only my phone can do this" actions.
      return const [
        DeviceCapability(AgentActions.alarmSet),
        DeviceCapability(AgentActions.timerSet),
        DeviceCapability(AgentActions.reminderSet),
        DeviceCapability(AgentActions.mediaPlay),
        DeviceCapability(AgentActions.musicControl),
        DeviceCapability(AgentActions.weatherGet),
        DeviceCapability(AgentActions.navigationRoute),
        DeviceCapability(AgentActions.webSearch),
        DeviceCapability(AgentActions.noteCreate),
        DeviceCapability(AgentActions.translateText),
        DeviceCapability(AgentActions.calendarGet),
        DeviceCapability(AgentActions.newsGet),
        DeviceCapability(AgentActions.homeControl),
        DeviceCapability(AgentActions.batteryGet),
        DeviceCapability(AgentActions.volumeSet),
      ];
    default:
      return const [];
  }
}

/// The assistant needs one more piece of information before it can act —
/// either a missing argument ("which playlist?") or a phrase it has never
/// heard before ("what should \"bring me home\" mean?"). The UI shows the
/// question and sends the answer back through the same input box.
class AgentClarification extends AgentDispatch {
  final String question;

  /// Identifies what is being asked. `arg:<key>` asks for an argument
  /// default (e.g. `arg:media.play.playlist`); `teach:<phrase>` asks the user
  /// to teach a new phrase by typing the command it should mean.
  final String key;

  /// Optional examples / expected shape, shown under the question.
  final String? hint;

  const AgentClarification({
    required this.question,
    required this.key,
    this.hint,
  });
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

enum AgentApproval { required, approved, denied }

enum AgentResultStatus { succeeded, required, denied, unavailable, needsInfo }

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
  // clipboard.write: an explicit, cross-device action — it pushes text to
  // every other device and needs the same local approval as a hardware action.
  if (command.action == AgentActions.clipboardWrite &&
      command.target == 'local') {
    final text = (command.arguments['text'] as String?)?.trim() ?? '';
    if (text.isEmpty) {
      return const AgentDispatchResult(
        status: AgentResultStatus.unavailable,
        message: 'Nothing to copy. Try "copy hello to my phone".',
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
    return AgentDispatchResult(
      status: AgentResultStatus.succeeded,
      dispatch: AgentActionPlan(
        command.toRequest(requestId: requestId, approval: AgentApproval.approved),
      ),
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
  // Validate the target and capability BEFORE asking for approval: an
  // approval prompt for a device that does not exist (or cannot blink) is
  // worse than an honest "unavailable".
  final target = targetDevice;
  if (target == null ||
      target.deviceId.toLowerCase() != command.target.toLowerCase() ||
      !target.supports(AgentActions.ledBlink)) {
    return const AgentDispatchResult(
      status: AgentResultStatus.unavailable,
      message: 'The target does not support led.blink.',
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
  final request = command.toRequest(
    requestId: requestId,
    approval: AgentApproval.approved,
  );
  return AgentDispatchResult(
    status: AgentResultStatus.succeeded,
    dispatch: AgentActionPlan(request),
  );
}
