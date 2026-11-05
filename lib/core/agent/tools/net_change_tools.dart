// Changing Wi-Fi settings, with a way back that does not depend on this app.
//
// Every tool here is `change`, always reversible, and always armed with a
// [RevertGuard] *before* the setting is touched: the timer is what puts the old
// value back if the change takes the connection away or nobody says to keep it.
// If the timer cannot be armed, the change does not happen — a setting that
// could cut the network with no scheduled way back is not one this code makes.
//
// Refusals, all deliberate:
//   * a connection whose mode is `ap` is never modified: that is somebody's
//     hotspot, and this code only ever changes the profile on *this* PC;
//   * nothing changes while CI is running, and nothing changes mounting a
//     second change while the first is still inside its window;
//   * an empty connection name is refused rather than guessed.
//
// The tools work on any NetworkManager connection by name, which is what lets
// item 3 be measured on a throwaway profile: create one, measure, change it,
// measure again, put it back. The connection in use is not special-cased into
// "never" — with a working timer, a user may choose to change it — but the
// refusal for an access point stands, and the timer is never optional.
import 'dart:io' show Platform;

import '../risk.dart';
import '../rollback.dart';
import '../tool.dart';
import '../verification.dart';
import 'command_runner.dart';
import 'revert_guard.dart';

/// The base of the three setting tools: read, arm, apply, verify.
abstract class WifiSettingTool extends Tool implements PendingRevert {
  WifiSettingTool({
    required this.runner,
    required this.guard,
    bool Function()? ciRunning,
  }) : _ciRunning = ciRunning ?? _ciInEnvironment;

  final CommandRunner runner;
  final RevertGuard guard;

  /// Whether a CI run is in progress. Injected so the refusal can be tested;
  /// the default reads the environment this process was started in.
  final bool Function() _ciRunning;

  static bool _ciInEnvironment() =>
      Platform.environment['CI'] == 'true' ||
      (Platform.environment['GITHUB_ACTIONS'] ?? '').isNotEmpty;

  RevertTicket? _ticket;
  String? _before;

  /// The `nmcli` property this tool writes, e.g. `802-11-wireless.band`.
  String get property;

  /// What the setting is called in a sentence.
  String get setting;

  /// The value as `nmcli` expects it, or null when the argument is not one this
  /// tool accepts (refused, never coerced into something plausible).
  String? normalise(String raw);

  /// How a value reads in the reply: `bg` is "2.4 GHz only", not "bg".
  String describe(String value) => value.isEmpty ? 'automatic' : value;

  @override
  RiskTier get risk => RiskTier.change;

  @override
  bool get reversible => true;

  @override
  Map<String, ToolArg> get args => <String, ToolArg>{
    'connection': const ToolArg(ArgType.text, example: 'my-network'),
    'value': ToolArg(ArgType.text, example: normaliseExample),
  };

  /// An example value for the planner's prompt.
  String get normaliseExample;

  @override
  RevertTicket? get pendingRevert => _ticket;

  @override
  void keep() {
    final ticket = _ticket;
    if (ticket != null) guard.confirm(ticket);
    _ticket = null;
  }

  String _connection(Map<String, Object?> args) =>
      (args['connection'] ?? '').toString().trim();

  Future<String> _read(String connection) async {
    final result = await runner.run('nmcli', <String>[
      '-g',
      property,
      'connection',
      'show',
      connection,
    ]);
    if (!result.ok) {
      throw ToolRefused(
        'I cannot read the $setting of “$connection”: ${result.reason}',
      );
    }
    return result.stdout.trim();
  }

  /// Refuses what this code must never do, whatever the plan says.
  Future<void> _refuse(String connection) async {
    if (connection.isEmpty) {
      throw const ToolRefused('Which connection should I change?');
    }
    final mode = await runner.run('nmcli', <String>[
      '-g',
      '802-11-wireless.mode',
      'connection',
      'show',
      connection,
    ]);
    if (mode.ok && mode.stdout.trim() == 'ap') {
      throw ToolRefused(
        '“$connection” is a hotspot this PC is sharing. I only change this '
        'PC’s own settings, never the hotspot’s.',
      );
    }
    if (_ciRunning()) {
      throw const ToolRefused(
        'I will not change network settings while CI is running.',
      );
    }
  }

  @override
  Future<String> run(Map<String, Object?> args) async {
    final connection = _connection(args);
    await _refuse(connection);

    final raw = (args['value'] ?? '').toString().trim();
    final value = normalise(raw);
    if (value == null) {
      throw ToolRefused(
        '“$raw” is not a $setting this PC understands. '
        'Try ${describe(normaliseExample)}.',
      );
    }

    final before = await _read(connection);
    // The timer goes up first: if it cannot be armed, the setting is untouched.
    _ticket = await guard.arm(
      label: '$setting on $connection',
      revertScript:
          'nmcli connection modify ${_sh(connection)} $property ${_sh(before)}',
    );
    _before = before;

    final applied = await runner.run('nmcli', <String>[
      'connection',
      'modify',
      connection,
      property,
      value,
    ]);
    if (!applied.ok) {
      // Nothing was written; the timer is not needed and must not fire later.
      keep();
      throw ToolRefused(
        'nmcli would not change the $setting: ${applied.reason}',
      );
    }
    return 'changed the $setting of “$connection” from '
        '${describe(before)} to ${describe(value)}, and scheduled the old '
        'value to come back if it is not kept';
  }

  @override
  Future<VerificationResult> verify(Map<String, Object?> args) async {
    final connection = _connection(args);
    final value = normalise((args['value'] ?? '').toString().trim());
    if (value == null) {
      return const VerificationResult.failed('the new value is not valid');
    }
    final now = await _read(connection);
    if (now != value) {
      return VerificationResult.failed(
        '$connection reads “${describe(now)}”, not “${describe(value)}”',
      );
    }
    return VerificationResult.ok('$property=${now.isEmpty ? 'auto' : now}');
  }

  @override
  Future<RollbackResult> Function()? rollback(Map<String, Object?> args) {
    final connection = _connection(args);
    return () async {
      final before = _before;
      if (before == null) {
        return const RollbackResult.failed('there was no value to put back');
      }
      final restored = await runner.run('nmcli', <String>[
        'connection',
        'modify',
        connection,
        property,
        before,
      ]);
      if (!restored.ok) {
        return RollbackResult.failed(
          'nmcli would not put the $setting back: ${restored.reason}',
        );
      }
      // The change is gone, so the timer has nothing left to revert.
      keep();
      final readBack = await _read(connection);
      if (readBack != before) {
        return RollbackResult.failed(
          '$connection reads “${describe(readBack)}” after the rollback',
        );
      }
      return RollbackResult.ok(
        '$setting of “$connection” back to ${describe(before)}',
      );
    };
  }

  /// Single-quoted for `sh`, so a connection name cannot become a second
  /// command in the detached revert script.
  static String _sh(String value) => "'${value.replaceAll("'", "'\\''")}'";
}

class WifiBandTool extends WifiSettingTool {
  WifiBandTool({required super.runner, required super.guard, super.ciRunning});

  @override
  String get name => 'wifi_band_set';

  @override
  String get description =>
      'Set the Wi-Fi band a connection uses: auto, bg (2.4 GHz only) or a '
      '(5 GHz only). Arms a revert timer before changing anything.';

  @override
  String get property => '802-11-wireless.band';

  @override
  String get setting => 'Wi-Fi band';

  @override
  String get normaliseExample => 'auto';

  @override
  String? normalise(String raw) => switch (raw.trim().toLowerCase()) {
    'auto' || '' || 'automatic' => '',
    'bg' || '2.4' || '2.4ghz' || '2.4 ghz' => 'bg',
    'a' || '5' || '5ghz' || '5 ghz' => 'a',
    _ => null,
  };

  @override
  String describe(String value) => switch (value) {
    '' => 'automatic (best band)',
    'bg' => '2.4 GHz only',
    'a' => '5 GHz only',
    _ => value,
  };
}

class WifiPowerSaveTool extends WifiSettingTool {
  WifiPowerSaveTool({
    required super.runner,
    required super.guard,
    super.ciRunning,
  });

  @override
  String get name => 'wifi_powersave_set';

  @override
  String get description =>
      'Set Wi-Fi power saving on a connection: 0 default, 1 off (fastest), '
      '2 on, 3 aggressive. Arms a revert timer before changing anything.';

  @override
  String get property => '802-11-wireless.powersave';

  @override
  String get setting => 'power saving';

  @override
  String get normaliseExample => '1';

  @override
  String? normalise(String raw) => switch (raw.trim().toLowerCase()) {
    '0' || 'default' => '0',
    '1' || 'off' || 'disabled' => '1',
    '2' || 'on' || 'enabled' => '2',
    '3' || 'aggressive' => '3',
    _ => null,
  };

  @override
  String describe(String value) => switch (value) {
    '0' || '' => 'default',
    '1' => 'off (fastest)',
    '2' => 'on',
    '3' => 'aggressive',
    _ => value,
  };
}

class WifiDnsTool extends WifiSettingTool {
  WifiDnsTool({required super.runner, required super.guard, super.ciRunning});

  @override
  String get name => 'wifi_dns_set';

  @override
  String get description =>
      'Set the DNS servers on a connection, comma separated, or empty to go '
      'back to automatic. Arms a revert timer before changing anything.';

  @override
  String get property => 'ipv4.dns';

  @override
  String get setting => 'DNS servers';

  @override
  String get normaliseExample => '1.1.1.1,1.0.0.1';

  @override
  String? normalise(String raw) {
    final parts = <String>[
      for (final part in raw.split(RegExp(r'[,\s]+')))
        if (part.trim().isNotEmpty) part.trim(),
    ];
    if (parts.isEmpty) return '';
    for (final part in parts) {
      if (!RegExp(r'^[0-9]{1,3}(\.[0-9]{1,3}){3}$').hasMatch(part)) return null;
    }
    return parts.join(' ');
  }

  @override
  String describe(String value) =>
      value.isEmpty ? 'automatic' : value.replaceAll(' ', ', ');
}

/// The change tools, wired to [runner] and [guard].
List<Tool> networkChangeTools({
  required CommandRunner runner,
  required RevertGuard guard,
}) => <Tool>[
  WifiBandTool(runner: runner, guard: guard),
  WifiPowerSaveTool(runner: runner, guard: guard),
  WifiDnsTool(runner: runner, guard: guard),
];
