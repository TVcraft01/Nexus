/// The content of a Nexus pairing QR code: a `nexus://pair` URI.
///
/// Example:
///   nexus://pair?v=1&id=abc…&name=My+PC&port=51820&code=ABCD-2345&ip=192.168.1.100
///
/// The `code` is the shared secret — it is what makes pairing secure. The rest
/// (id, name, port, ip) just tells the scanning device where to connect and
/// who it is pairing with. `ip` is optional because the scanning device may
/// already know the address from discovery.
class PairPayload {
  final int version;
  final String id;
  final String name;
  final int port;
  final String code;
  final String? ip;

  const PairPayload({
    required this.version,
    required this.id,
    required this.name,
    required this.port,
    required this.code,
    this.ip,
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
    final version = int.tryParse(params['v'] ?? '1') ?? 1;

    if (id == null || code == null || port == null || port <= 0 || port > 65535) {
      return null;
    }
    if (!RegExp(r'^[A-Z2-9]{4}-[A-Z2-9]{4}$').hasMatch(code)) {
      return null;
    }
    return PairPayload(version: version, id: id, name: name, port: port, code: code, ip: ip);
  }

  /// Builds the URI shown in a pairing QR.
  static String build({
    required String id,
    required String name,
    required int port,
    required String code,
    String? ip,
  }) {
    final params = <String, String>{
      'v': '1',
      'id': id,
      'name': name,
      'port': '$port',
      'code': code,
      'ip': ?ip,
    };
    return 'nexus://pair?${Uri(queryParameters: params).query}';
  }
}
