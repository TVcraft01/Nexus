/// The content of a Nexus pairing QR code: a `nexus://pair` URI.
///
/// Example:
///   nexus://pair?v=1&id=abc…&name=My+PC&port=51820&code=ABCD-2345&ip=192.168.1.100&ips=192.168.1.100,100.64.0.1
///
/// The `code` is the shared secret — it is what makes pairing secure. The rest
/// (id, name, port, ip, ips) just tells the scanning device where to connect
/// and who it is pairing with. `ip` is the primary address (backward compat);
/// `ips` lists ALL known addresses (LAN, VPN, Tailscale) so paired devices
/// can reconnect even when they leave the original WiFi network.
class PairPayload {
  final int version;
  final String id;
  final String name;
  final int port;
  final String code;
  final String? ip;
  final List<String> ips;

  const PairPayload({
    required this.version,
    required this.id,
    required this.name,
    required this.port,
    required this.code,
    this.ip,
    this.ips = const [],
  });

  /// Parses a scanned/typed URI. Returns null if it is not a Nexus pairing QR.
  static PairPayload? parse(String raw) {
    final trimmed = raw.trim();
    if (!trimmed.startsWith('nexus://pair')) return null;

    final query = trimmed.contains('?') ? trimmed.substring(trimmed.indexOf('?') + 1) : '';
    Map<String, String> params;
    try {
      params = Uri.splitQueryString(query);
    } catch (_) {
      return null;
    }

    final id = params['id'];
    final code = params['code']?.toUpperCase();
    final port = int.tryParse(params['port'] ?? '');
    final name = params['name'] ?? 'Unknown device';
    final ip = params['ip'];
    final ipsRaw = params['ips'];
    final ips = ipsRaw != null && ipsRaw.isNotEmpty
        ? ipsRaw.split(',').where((a) => a.trim().isNotEmpty).toList()
        : <String>[];
    final version = int.tryParse(params['v'] ?? '1') ?? 1;

    if (id == null || code == null || port == null || port <= 0 || port > 65535) {
      return null;
    }
    if (!RegExp(r'^[A-Z2-9]{4}-[A-Z2-9]{4}$').hasMatch(code)) {
      return null;
    }
    return PairPayload(
      version: version, id: id, name: name, port: port, code: code,
      ip: ip, ips: ips,
    );
  }

  /// Builds the URI shown in a pairing QR.
  static String build({
    required String id,
    required String name,
    required int port,
    required String code,
    String? ip,
    List<String>? ips,
  }) {
    final allIps = <String>[];
    if (ip != null && ip.isNotEmpty) allIps.add(ip);
    if (ips != null) {
      for (final a in ips) {
        if (a.isNotEmpty && !allIps.contains(a)) allIps.add(a);
      }
    }
    final params = <String, String>{
      'v': '1',
      'id': id,
      'name': name,
      'port': '$port',
      'code': code,
    };
    if (allIps.isNotEmpty) {
      params['ip'] = allIps.first;
      if (allIps.length > 1) {
        params['ips'] = allIps.join(',');
      }
    }
    return 'nexus://pair?${Uri(queryParameters: params).query}';
  }
}
