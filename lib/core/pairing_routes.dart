import 'package:nexus/mesh/mesh_service.dart';

/// Attempts a pairing connection through each candidate route in order.
///
/// QR payloads can contain several addresses (LAN, VPN, Tailscale). A single
/// address may be unreachable even when another route is healthy, so pairing
/// must not fail after the first socket timeout.
Future<PairResult> pairThroughRoutes({
  required MeshService mesh,
  required List<String> addresses,
  required int port,
  required String code,
}) async {
  final seen = <String>{};
  PairResult? last;
  for (final raw in addresses) {
    final address = raw.trim();
    if (address.isEmpty || !seen.add(address)) continue;
    last = await mesh.pairWith(
      address: address,
      port: port,
      code: code,
    );
    if (last.ok) return last;
  }
  return last ??
      const PairResult.failure('Nexus could not find a usable route to that device.');
}
