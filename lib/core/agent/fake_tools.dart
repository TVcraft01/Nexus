// The tools the acceptance conversations run, against a [FakeDevice].
//
// They are deliberately ordinary: each one changes (or reads) the fake device,
// each one verifies by reading the device back, and each change has a rollback
// that restores what was there before. The real Linux tools in item 3 will have
// this exact shape, with `nmcli` where this file has a field.
import 'agent_records.dart';
import 'fake_device.dart';
import 'risk.dart';
import 'rollback.dart';
import 'tool.dart';
import 'verification.dart';

/// Every fake tool, in one list a test can hand to a [ToolRegistry].
///
/// `mail_auto_send` is registered even though neither conversation plans it:
/// the point of "auto-send stays off" is that the tool exists and is still not
/// in the plan the model produced.
List<Tool> fakeTools(FakeDevice device) => <Tool>[
  WifiStatusTool(device),
  WifiSetupTool(device),
  AgentCreateTool(device),
  AgentScheduleTool(device),
  MailDraftTool(device),
  MailAutoSendTool(device),
];

String _bandLabel(String band) => band == 'auto' ? 'the best band' : band;

class WifiStatusTool extends Tool {
  WifiStatusTool(this.device);

  final FakeDevice device;

  @override
  String get name => 'wifi_status';

  @override
  String get description =>
      'Read the Wi-Fi band and whether guests have their own network. '
      'Changes nothing.';

  @override
  RiskTier get risk => RiskTier.read;

  @override
  Map<String, ToolArg> get args => const <String, ToolArg>{};

  @override
  Future<String> run(Map<String, Object?> args) async =>
      'Wi-Fi is on ${_bandLabel(device.band)} with '
      '${device.guestNetwork ? 'a guest network' : 'no guest network'}';

  @override
  Future<VerificationResult> verify(Map<String, Object?> args) async =>
      VerificationResult.ok(
        'band=${device.band}, guest=${device.guestNetwork}',
      );
}

class WifiSetupTool extends Tool {
  WifiSetupTool(this.device);

  final FakeDevice device;

  /// The state this tool found before it changed anything, so its rollback can
  /// put it back even though the closure was made before `run`.
  String? _beforeBand;
  bool? _beforeGuest;

  @override
  String get name => 'wifi_set';

  @override
  String get description =>
      'Set the Wi-Fi band (auto picks the best speed) and turn a separate '
      'guest network on or off.';

  @override
  RiskTier get risk => RiskTier.change;

  @override
  bool get reversible => true;

  @override
  Map<String, ToolArg> get args => const <String, ToolArg>{
    'band': ToolArg(ArgType.text, example: 'auto'),
    'guest': ToolArg(ArgType.flag, example: 'true'),
  };

  @override
  Future<String> run(Map<String, Object?> args) async {
    final band = (args['band']! as String).trim();
    final guest = args['guest']! as bool;
    _beforeBand = device.band;
    _beforeGuest = device.guestNetwork;
    device.band = band;
    device.guestNetwork = guest;
    final speed = band == 'auto' ? 'the best speed' : band;
    return 'set the Wi-Fi to $speed and '
        '${guest ? 'gave guests their own network' : 'left the guest network off'}';
  }

  @override
  Future<VerificationResult> verify(Map<String, Object?> args) async {
    final band = (args['band']! as String).trim();
    final guest = args['guest']! as bool;
    if (device.band != band) {
      return VerificationResult.failed('the band still reads ${device.band}');
    }
    if (device.guestNetwork != guest) {
      return VerificationResult.failed(
        'the guest network still reads '
        '${device.guestNetwork ? 'on' : 'off'}',
      );
    }
    return VerificationResult.ok(
      'band=${device.band}, guest=${device.guestNetwork}',
    );
  }

  @override
  Future<RollbackResult> Function()? rollback(Map<String, Object?> args) {
    // The fields are read when the closure runs, not when it is made: the
    // before-state only exists after `run`.
    return () async {
      final band = _beforeBand ?? device.band;
      final guest = _beforeGuest ?? device.guestNetwork;
      device.band = band;
      device.guestNetwork = guest;
      return RollbackResult.ok(
        'Wi-Fi back on ${_bandLabel(band)}'
        '${guest ? ' with the guest network on' : ' with no guest network'}',
      );
    };
  }
}

class AgentCreateTool extends Tool {
  AgentCreateTool(this.device);

  final FakeDevice device;

  @override
  String get name => 'agent_create';

  @override
  String get description =>
      'Save an agent on this device: what it does, and which tools it may use.';

  @override
  RiskTier get risk => RiskTier.change;

  @override
  bool get reversible => true;

  @override
  Map<String, ToolArg> get args => const <String, ToolArg>{
    'name': ToolArg(ArgType.text, example: 'Mail drafter'),
    'goal': ToolArg(ArgType.text, example: 'draft replies in my style'),
    'tools': ToolArg(ArgType.text, example: 'mail_drafts'),
  };

  @override
  Future<String> run(Map<String, Object?> args) async {
    final name = (args['name']! as String).trim();
    final goal = (args['goal']! as String).trim();
    final tools = <String>[
      for (final part in (args['tools']! as String).split(','))
        if (part.trim().isNotEmpty) part.trim(),
    ];
    device.agents[name] = AgentDefinition(name: name, goal: goal, tools: tools);
    return 'created the agent “$name”';
  }

  @override
  Future<VerificationResult> verify(Map<String, Object?> args) async {
    final name = (args['name']! as String).trim();
    final saved = device.agent(name);
    if (saved == null) {
      return VerificationResult.failed(
        'there is no agent called $name on this device',
      );
    }
    return VerificationResult.ok(
      'agent “$name” saved with '
      '${saved.tools.isEmpty ? 'no tools' : saved.tools.join(', ')}',
    );
  }

  @override
  Future<RollbackResult> Function()? rollback(Map<String, Object?> args) {
    final name = (args['name']! as String).trim();
    return () async {
      device.agents.remove(name);
      return RollbackResult.ok('removed the agent “$name”');
    };
  }
}

class AgentScheduleTool extends Tool {
  AgentScheduleTool(this.device);

  final FakeDevice device;

  String? _beforeSchedule;

  @override
  String get name => 'agent_schedule';

  @override
  String get description => 'Set the hours an agent runs on this device.';

  @override
  RiskTier get risk => RiskTier.change;

  @override
  bool get reversible => true;

  @override
  Map<String, ToolArg> get args => const <String, ToolArg>{
    'name': ToolArg(ArgType.text, example: 'Mail drafter'),
    'hours': ToolArg(ArgType.text, example: '9:00-18:00 on weekdays'),
  };

  @override
  Future<String> run(Map<String, Object?> args) async {
    final name = (args['name']! as String).trim();
    final hours = (args['hours']! as String).trim();
    final agent = device.agent(name);
    if (agent == null) return 'there is no agent called $name';
    _beforeSchedule = agent.schedule;
    agent.schedule = hours;
    return 'set $name to run $hours';
  }

  @override
  Future<VerificationResult> verify(Map<String, Object?> args) async {
    final name = (args['name']! as String).trim();
    final hours = (args['hours']! as String).trim();
    final agent = device.agent(name);
    if (agent == null) {
      return VerificationResult.failed('there is no agent called $name');
    }
    if (agent.schedule != hours) {
      return VerificationResult.failed(
        '$name reads “${agent.schedule ?? 'no hours'}”, not “$hours”',
      );
    }
    return VerificationResult.ok('$name runs ${agent.schedule}');
  }

  @override
  Future<RollbackResult> Function()? rollback(Map<String, Object?> args) {
    final name = (args['name']! as String).trim();
    return () async {
      final agent = device.agent(name);
      if (agent == null) {
        return const RollbackResult.failed('the agent is gone');
      }
      agent.schedule = _beforeSchedule;
      return RollbackResult.ok('$name is back to only when asked');
    };
  }
}

class MailDraftTool extends Tool {
  MailDraftTool(this.device);

  final FakeDevice device;

  int? _index;

  @override
  String get name => 'mail_drafts';

  @override
  String get description =>
      'Write a draft reply. Never sends it — the user decides.';

  @override
  RiskTier get risk => RiskTier.change;

  @override
  bool get reversible => true;

  @override
  Map<String, ToolArg> get args => const <String, ToolArg>{
    'text': ToolArg(ArgType.text, example: 'Sure, Thursday works.'),
  };

  @override
  Future<String> run(Map<String, Object?> args) async {
    _index = device.drafts.length;
    device.drafts.add((args['text']! as String).trim());
    return 'drafted a reply';
  }

  @override
  Future<VerificationResult> verify(Map<String, Object?> args) async {
    final index = _index;
    if (index == null || device.drafts.length <= index) {
      return const VerificationResult.failed('the draft is not there');
    }
    return VerificationResult.ok('draft ${index + 1} on this device');
  }

  @override
  Future<RollbackResult> Function()? rollback(Map<String, Object?> args) {
    final index = _index;
    return () async {
      if (index != null && device.drafts.length > index) {
        device.drafts.removeAt(index);
      }
      return const RollbackResult.ok('removed the draft');
    };
  }
}

class MailAutoSendTool extends Tool {
  MailAutoSendTool(this.device);

  final FakeDevice device;

  bool? _before;

  @override
  String get name => 'mail_auto_send';

  @override
  String get description => 'Turn sending replies without asking on or off.';

  @override
  RiskTier get risk => RiskTier.change;

  @override
  bool get reversible => true;

  @override
  Map<String, ToolArg> get args => const <String, ToolArg>{
    'enabled': ToolArg(ArgType.flag, example: 'true'),
  };

  @override
  Future<String> run(Map<String, Object?> args) async {
    final enabled = args['enabled']! as bool;
    _before = device.mailAutoSend;
    device.mailAutoSend = enabled;
    return enabled ? 'turned auto-send on' : 'left auto-send off';
  }

  @override
  Future<VerificationResult> verify(Map<String, Object?> args) async {
    final enabled = args['enabled']! as bool;
    if (device.mailAutoSend != enabled) {
      return VerificationResult.failed(
        'auto-send still reads ${device.mailAutoSend}',
      );
    }
    return VerificationResult.ok('auto-send=${device.mailAutoSend}');
  }

  @override
  Future<RollbackResult> Function()? rollback(Map<String, Object?> args) {
    return () async {
      device.mailAutoSend = _before ?? false;
      return RollbackResult.ok(
        'auto-send back to ${device.mailAutoSend ? 'on' : 'off'}',
      );
    };
  }
}
