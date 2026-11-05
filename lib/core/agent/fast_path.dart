// Known goals, planned without the model.
//
// Four things this app is about — the Wi-Fi status, the signal, the band, the
// DNS — have exactly one right answer, so asking a 2 GB model to rediscover it
// every time is how a wrong tool gets planned for "change my DNS". These
// patterns turn those asks into the same [ProposedPlan] a model would have to
// produce, and the validator still checks it afterwards: the fast path is
// cheaper, not more trusted.
//
// It answers with a question instead of a guess whenever an argument is
// genuinely missing (which connection, which DNS servers), because a guessed
// value in a network setting is the expensive kind of wrong.
//
// Anything it does not recognise returns null, and the model plans it.
import 'plan.dart';

/// Known Wi-Fi goals, with the current connection supplied by the caller.
///
/// [currentConnection] is how the fast path can plan "make my laptop use 5 GHz
/// only" without asking: on this PC that answer is the connection `nmcli` says
/// is in use. When it is null or throws, the fast path asks instead.
class PlanFastPath {
  const PlanFastPath({this.currentConnection}) : enabled = true;

  /// A fast path that never plans anything: for a test, or a call site, that
  /// wants every ask to go through the model.
  const PlanFastPath.off()
    : enabled = false,
      currentConnection = null;

  final String? Function()? currentConnection;

  /// False for [PlanFastPath.off].
  final bool enabled;

  static final RegExp _dns = RegExp(r'\bdns\b');
  static final RegExp _band = RegExp(r'\b(2\.4|5(?:\s?ghz|\s?g)\b|ghz|band)\b');
  static final RegExp _power = RegExp(r'power ?sav');
  static final RegExp _signal = RegExp(r'\bsignal\b');
  static final RegExp _speed = RegExp(
    r'\b(link rate|latency|how fast|speed test|throughput)\b',
  );
  static final RegExp _status = RegExp(
    r'\b(wifi|wi-fi|network|connection)\s+(status|state|settings|details)\b'
    r'|\bam i (connected|online)\b',
  );
  static final RegExp _changeVerb = RegExp(
    r'\b(set|change|switch|turn|make|use|force|lock|fix)\b',
  );
  static final RegExp _ip = RegExp(r'\b\d{1,3}(?:\.\d{1,3}){3}\b');

  /// The plan for [goal], or null when this is not one of the known goals.
  ProposedPlan? plan(String goal) {
    if (!enabled) return null;
    final lower = goal.toLowerCase();
    final changing = _changeVerb.hasMatch(lower);

    if (changing && _dns.hasMatch(lower)) return _dnsPlan(goal, lower);
    if (changing && _band.hasMatch(lower)) return _bandPlan(goal, lower);
    if (changing && _power.hasMatch(lower)) return _powerPlan(goal, goal);

    // Reading: "what's my signal", "wifi status", "how fast is the link".
    if (_status.hasMatch(lower)) return _readPlan(goal, 'wifi_status');
    if (_signal.hasMatch(lower)) return _readPlan(goal, 'wifi_signal');
    if (_speed.hasMatch(lower)) return _readPlan(goal, 'wifi_speed');
    return null;
  }

  ProposedPlan _readPlan(String goal, String tool) => ProposedPlan(
    goal: goal,
    steps: <ProposedStep>[
      ProposedStep(tool: tool, description: _readDescription(tool)),
    ],
    notes: const <String>['Planned without the model: a known Wi-Fi goal.'],
  );

  static String _readDescription(String tool) => switch (tool) {
    'wifi_signal' => 'Read the Wi-Fi signal strength',
    'wifi_speed' => 'Read the link rate and measure the gateway latency',
    _ => 'Read the Wi-Fi status',
  };

  ProposedPlan _dnsPlan(String goal, String lower) {
    final servers = <String>[
      for (final match in _ip.allMatches(lower)) match.group(0)!,
    ];
    if (servers.isEmpty) {
      return _question(
        goal,
        'Which DNS servers should I use? Say the addresses, for example '
        '1.1.1.1 and 1.0.0.1.',
      );
    }
    final connection = _connection();
    if (connection == null) {
      return _question(
        goal,
        'Which Wi-Fi connection should I set the DNS servers on?',
      );
    }
    return _changePlan(
      goal: goal,
      tool: 'wifi_dns_set',
      connection: connection,
      value: servers.join(','),
      description:
          'Set the DNS servers of “$connection” to ${servers.join(', ')}',
    );
  }

  ProposedPlan _bandPlan(String goal, String lower) {
    final String value;
    final String label;
    if (RegExp(r'\b(auto|automatic|best)\b').hasMatch(lower)) {
      value = '';
      label = 'automatic (best band)';
    } else if (_mentions5(lower)) {
      value = 'a';
      label = '5 GHz only';
    } else if (lower.contains('2.4')) {
      value = 'bg';
      label = '2.4 GHz only';
    } else {
      return _question(
        goal,
        'Which band should I use: 2.4 GHz only, 5 GHz only, or automatic?',
      );
    }
    final connection = _connection();
    if (connection == null) {
      return _question(goal, 'Which Wi-Fi connection should I change the band on?');
    }
    return _changePlan(
      goal: goal,
      tool: 'wifi_band_set',
      connection: connection,
      value: value,
      description: 'Switch the Wi-Fi band of “$connection” to $label',
    );
  }

  ProposedPlan _powerPlan(String goal, String original) {
    final lower = original.toLowerCase();
    final String value;
    final String label;
    if (RegExp(r'\b(off|disable|disabled|never)\b').hasMatch(lower)) {
      value = '1';
      label = 'off (fastest)';
    } else if (RegExp(r'\b(aggressive|maximum|max)\b').hasMatch(lower)) {
      value = '3';
      label = 'aggressive';
    } else if (RegExp(r'\b(on|enable|enabled)\b').hasMatch(lower)) {
      value = '2';
      label = 'on';
    } else {
      return _question(
        goal,
        'Should Wi-Fi power saving be off (fastest), on, or left at the '
        'default?',
      );
    }
    final connection = _connection();
    if (connection == null) {
      return _question(
        goal,
        'Which Wi-Fi connection should I change power saving on?',
      );
    }
    return _changePlan(
      goal: goal,
      tool: 'wifi_powersave_set',
      connection: connection,
      value: value,
      description: 'Set Wi-Fi power saving of “$connection” to $label',
    );
  }

  static bool _mentions5(String lower) =>
      RegExp(r'\b5(?:\s?ghz|\s?g\b)').hasMatch(lower);

  String? _connection() {
    try {
      final value = currentConnection?.call()?.trim();
      return value == null || value.isEmpty ? null : value;
    } catch (_) {
      return null;
    }
  }

  static ProposedPlan _changePlan({
    required String goal,
    required String tool,
    required String connection,
    required String value,
    required String description,
  }) => ProposedPlan(
    goal: goal,
    steps: <ProposedStep>[
      ProposedStep(
        tool: tool,
        args: <String, Object?>{'connection': connection, 'value': value},
        description: description,
      ),
    ],
    notes: const <String>['Planned without the model: a known Wi-Fi goal.'],
  );

  static ProposedPlan _question(String goal, String question) => ProposedPlan(
    goal: goal,
    questions: <String>[question],
    notes: const <String>['Planned without the model: a known Wi-Fi goal.'],
  );
}
