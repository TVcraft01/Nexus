// Reading what the network is doing, without touching it.
//
// Three read-only tools — status, signal, speed — and the parsers behind them.
// They are the first half of item 3 on purpose: a tool that can only read is one
// whose numbers you can check against `nmcli` by hand, and those numbers are
// what the change tools are measured against later.
//
// Every field comes from `nmcli` on this PC. Nothing here is inferred: when the
// PC is not on Wi-Fi, the tool says so instead of reporting a plausible zero.
import '../risk.dart';
import '../tool.dart';
import '../verification.dart';
import 'command_runner.dart';

/// What `nmcli` says about the Wi-Fi this PC is on right now.
class WifiReport {
  const WifiReport({
    required this.device,
    required this.connection,
    required this.state,
    this.ssid = '',
    this.signal = 0,
    this.rate = '',
    this.frequency = '',
    this.security = '',
  });

  final String device;

  /// The NetworkManager connection name (`Freebox-CA82DC`), empty when the
  /// device is not on a connection.
  final String connection;
  final String state;
  final String ssid;
  final int signal;
  final String rate;
  final String frequency;
  final String security;

  bool get connected => state.startsWith('connected');

  /// `5 GHz (5180 MHz)`, or `2.4 GHz (2437 MHz)`, or empty when unknown.
  String get band {
    final mhz = int.tryParse(
      RegExp(r'(\d+)').firstMatch(frequency)?.group(1) ?? '',
    );
    if (mhz == null || mhz == 0) {
      return '';
    }
    return mhz >= 4900 ? '5 GHz ($frequency)' : '2.4 GHz ($frequency)';
  }

  /// One sentence for the chat: the connection, the signal and the link rate.
  String get summary {
    if (!connected) {
      return 'Wi-Fi on $device is ${state.isEmpty ? 'not connected' : state}.';
    }
    final parts = <String>[
      if (ssid.isNotEmpty) ssid,
      if (band.isNotEmpty) band,
      if (signal > 0) 'signal $signal%',
      if (rate.isNotEmpty && rate != '0 Mbit/s') 'link $rate',
    ];
    return 'Wi-Fi is on ${parts.isEmpty ? connection : parts.join(', ')}'
        '${connection.isEmpty ? '' : ' ($connection)'}.';
  }
}

/// The fields `nmcli` prints, split on the separator it escapes with `\`.
List<String> splitNmcliLine(String line) {
  final fields = <String>[];
  final buffer = StringBuffer();
  for (var index = 0; index < line.length; index++) {
    final char = line[index];
    if (char == r'\' && index + 1 < line.length) {
      buffer.write(line[++index]);
      continue;
    }
    if (char == ':') {
      fields.add(buffer.toString());
      buffer.clear();
      continue;
    }
    buffer.write(char);
  }
  fields.add(buffer.toString());
  return fields;
}

/// The Wi-Fi device and connection `nmcli device status` reports as active.
({String device, String connection, String state})? _activeWifi(
  String deviceStatus,
) {
  for (final line in deviceStatus.split('\n')) {
    if (line.trim().isEmpty) continue;
    final fields = splitNmcliLine(line);
    if (fields.length < 4) continue;
    if (fields[1] != 'wifi') continue;
    if (!fields[2].startsWith('connected')) continue;
    return (device: fields[0], connection: fields[3], state: fields[2]);
  }
  return null;
}

/// The `*` row of `nmcli device wifi list`, which is the network in use.
List<String>? _activeScanRow(String wifiList) {
  for (final line in wifiList.split('\n')) {
    if (!line.trim().startsWith('*')) continue;
    // Strip the in-use marker and the separator after it, or every field
    // would be one to the left of where it belongs.
    final row = line.trim().substring(1);
    return splitNmcliLine(row.startsWith(':') ? row.substring(1) : row);
  }
  return null;
}

/// Reads the current Wi-Fi state on [runner]'s machine.
Future<WifiReport> readWifiReport(CommandRunner runner) async {
  final status = await runner.run('nmcli', <String>[
    '-t',
    '-f',
    'DEVICE,TYPE,STATE,CONNECTION',
    'device',
    'status',
  ]);
  final active = status.ok ? _activeWifi(status.stdout) : null;
  if (active == null) {
    return const WifiReport(device: '', connection: '', state: 'not connected');
  }

  final scan = await runner.run('nmcli', <String>[
    '-t',
    '-f',
    'IN-USE,SSID,SIGNAL,RATE,FREQ,SECURITY',
    'device',
    'wifi',
    'list',
    '--rescan',
    'no',
  ]);
  final row = scan.ok ? _activeScanRow(scan.stdout) : null;
  return WifiReport(
    device: active.device,
    connection: active.connection,
    state: active.state,
    ssid: row != null && row.isNotEmpty ? row[0] : '',
    signal: row != null && row.length > 1 ? int.tryParse(row[1]) ?? 0 : 0,
    rate: row != null && row.length > 2 ? row[2] : '',
    frequency: row != null && row.length > 3 ? row[3] : '',
    security: row != null && row.length > 4 ? row[4] : '',
  );
}

/// `wifi_status` — what this PC is on, measured.
class WifiStatusTool extends Tool {
  WifiStatusTool(this.runner);

  final CommandRunner runner;

  @override
  String get name => 'wifi_status';

  @override
  String get description =>
      'Read the Wi-Fi connection, band, signal and link rate. Changes nothing.';

  @override
  RiskTier get risk => RiskTier.read;

  @override
  Map<String, ToolArg> get args => const <String, ToolArg>{};

  @override
  Future<String> run(Map<String, Object?> args) async =>
      (await readWifiReport(runner)).summary;

  @override
  Future<VerificationResult> verify(Map<String, Object?> args) async {
    final report = await readWifiReport(runner);
    if (!report.connected) {
      return const VerificationResult.failed('Wi-Fi is not connected');
    }
    return VerificationResult.ok(
      'device=${report.device}, connection=${report.connection}, '
      'signal=${report.signal}, rate=${report.rate}, freq=${report.frequency}',
    );
  }
}

/// `wifi_signal` — the measured signal, in percent and bars.
class WifiSignalTool extends Tool {
  WifiSignalTool(this.runner);

  final CommandRunner runner;

  @override
  String get name => 'wifi_signal';

  @override
  String get description =>
      'Read the signal strength of the Wi-Fi this PC is on. Changes nothing.';

  @override
  RiskTier get risk => RiskTier.read;

  @override
  Map<String, ToolArg> get args => const <String, ToolArg>{};

  @override
  Future<String> run(Map<String, Object?> args) async {
    final report = await readWifiReport(runner);
    if (!report.connected) {
      return 'Wi-Fi is not connected, so there is no signal to read.';
    }
    return 'Signal is ${report.signal}% on '
        '${report.ssid.isEmpty ? report.connection : report.ssid}.';
  }

  @override
  Future<VerificationResult> verify(Map<String, Object?> args) async {
    final report = await readWifiReport(runner);
    if (report.signal <= 0) {
      return const VerificationResult.failed('no signal reading');
    }
    return VerificationResult.ok('signal=${report.signal}%');
  }
}

/// `wifi_speed` — the link rate `nmcli` reports plus the measured latency to
/// the gateway.
///
/// Two numbers, and both are labelled as what they are: the link rate is what
/// the driver negotiated (not what the internet does), and the latency is four
/// ICMP packets to the default gateway, on this LAN. No throughput test: filling
/// the link to measure it is a different promise, and a slower one to keep.
class WifiSpeedTool extends Tool {
  WifiSpeedTool(this.runner);

  final CommandRunner runner;

  @override
  String get name => 'wifi_speed';

  @override
  String get description =>
      'Read the Wi-Fi link rate and measure the latency to the gateway. '
      'Changes nothing.';

  @override
  RiskTier get risk => RiskTier.read;

  @override
  Map<String, ToolArg> get args => const <String, ToolArg>{};

  @override
  Future<String> run(Map<String, Object?> args) async {
    final report = await readWifiReport(runner);
    final latency = await measureGatewayLatency(runner);
    final parts = <String>[
      if (report.rate.isNotEmpty && report.rate != '0 Mbit/s')
        'link rate ${report.rate}',
      if (latency != null) 'gateway ${latency.label}',
    ];
    if (parts.isEmpty) return 'I could not measure the link.';
    return 'Measured ${parts.join(', ')}.';
  }

  @override
  Future<VerificationResult> verify(Map<String, Object?> args) async {
    final latency = await measureGatewayLatency(runner);
    if (latency == null) {
      return const VerificationResult.failed('the gateway did not answer');
    }
    return VerificationResult.ok('gateway=${latency.averageMs}ms');
  }
}

/// The average round-trip to the default gateway, measured with `ping`.
class GatewayLatency {
  const GatewayLatency({
    required this.gateway,
    required this.averageMs,
    required this.lossPercent,
  });

  final String gateway;
  final double averageMs;
  final int lossPercent;

  String get label => '${averageMs}ms avg to $gateway ($lossPercent% loss)';
}

/// The gateway from `ip route`, or null when this PC has no default route.
Future<String?> defaultGateway(CommandRunner runner) async {
  final route = await runner.run('ip', <String>['route']);
  if (!route.ok) return null;
  for (final line in route.stdout.split('\n')) {
    final match = RegExp(r'^default via (\S+)').firstMatch(line.trim());
    if (match != null) return match.group(1);
  }
  return null;
}

/// Four pings to the gateway; null when there is no gateway or no reply.
Future<GatewayLatency?> measureGatewayLatency(CommandRunner runner) async {
  final gateway = await defaultGateway(runner);
  if (gateway == null) return null;
  final ping = await runner.run('ping', <String>[
    '-c',
    '4',
    '-W',
    '2',
    gateway,
  ]);
  if (!ping.ok) return null;
  final match = RegExp(
    r'(\d+)% packet loss.*?= [\d.]+/([\d.]+)/',
    dotAll: true,
  ).firstMatch(ping.stdout);
  if (match == null) return null;
  return GatewayLatency(
    gateway: gateway,
    averageMs: double.tryParse(match.group(2) ?? '') ?? 0,
    lossPercent: int.tryParse(match.group(1) ?? '') ?? 0,
  );
}

/// The read-only tools, as one list.
List<Tool> networkReadTools(CommandRunner runner) => <Tool>[
  WifiStatusTool(runner),
  WifiSignalTool(runner),
  WifiSpeedTool(runner),
];
