import 'dart:async';

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/network_info.dart';
import '../../core/pair_payload.dart';
import '../../mesh/discovery.dart';
import '../../mesh/mesh_service.dart';
import '../cable_pair_page.dart';
import 'design_system.dart';

Future<void> showNexusV2PairSheet(
  BuildContext context, {
  required MeshService mesh,
  DiscoveredDevice? nearby,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _PairSheet(mesh: mesh, nearby: nearby),
  );
}

class _PairSheet extends StatefulWidget {
  final MeshService mesh;
  final DiscoveredDevice? nearby;
  const _PairSheet({required this.mesh, this.nearby});

  @override
  State<_PairSheet> createState() => _PairSheetState();
}

class _PairSheetState extends State<_PairSheet> {
  late PairingSession _session;
  late final TextEditingController _address;
  late final TextEditingController _port;
  late final TextEditingController _code;
  bool _manual = false;
  bool _pairing = false;
  String? _error;

  bool get _canCable => defaultTargetPlatform == TargetPlatform.linux || defaultTargetPlatform == TargetPlatform.windows || defaultTargetPlatform == TargetPlatform.macOS;
  bool get _canScan => defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS;

  @override
  void initState() {
    super.initState();
    _session = widget.mesh.beginPairing();
    _address = TextEditingController(text: widget.nearby?.address ?? '');
    _port = TextEditingController(text: '${widget.nearby?.port ?? widget.mesh.port}');
    _code = TextEditingController();
    _manual = widget.nearby != null;
    unawaited(_refreshQr());
  }

  Future<void> _refreshQr() async {
    final ips = await detectAllIpv4s();
    if (!mounted) return;
    setState(() {
      _session = PairingSession(
        code: _session.code,
        qrPayload: PairPayload.build(
          id: widget.mesh.identity.id,
          name: widget.mesh.identity.name,
          port: widget.mesh.port,
          code: _session.code,
          ip: ips.isEmpty ? null : ips.first,
          ips: ips,
        ),
        expiresAt: _session.expiresAt,
      );
    });
  }

  @override
  void dispose() {
    _address.dispose();
    _port.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _pair() async {
    final address = _address.text.trim();
    final port = int.tryParse(_port.text.trim());
    final code = _code.text.trim();
    if (address.isEmpty || port == null || port <= 0 || port > 65535 || code.isEmpty) {
      setState(() => _error = 'Enter the address, port and code shown on the other device.');
      return;
    }
    setState(() { _pairing = true; _error = null; });
    final result = await widget.mesh.pairWith(address: address, port: port, code: code);
    if (!mounted) return;
    if (result.ok) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      _pairing = false;
      _error = result.error ?? 'Nexus could not connect to that device.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Add a device', style: theme.textTheme.headlineMedium),
            const SizedBox(height: 5),
            Text('Pair once. Nexus remembers the device after that.', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 18),
            if (_canCable)
              _MethodRow(
                icon: Icons.usb_rounded,
                title: 'Connect with a cable',
                subtitle: 'Plug in an Android device and follow the one-time authorization prompt.',
                onTap: () async {
                  Navigator.pop(context);
                  await Navigator.push(context, MaterialPageRoute(builder: (_) => CablePairPage(mesh: widget.mesh)));
                },
              ),
            if (_canScan)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: _MethodRow(
                  icon: Icons.qr_code_scanner_rounded,
                  title: 'Scan a QR code',
                  subtitle: 'Fastest when both devices can see each other.',
                  onTap: () => setState(() { _manual = false; }),
                ),
              ),
            const SizedBox(height: 8),
            _MethodRow(
              icon: Icons.password_rounded,
              title: 'Use a pairing code',
              subtitle: 'Enter the code shown on the other device.',
              onTap: () => setState(() { _manual = true; }),
            ),
            const SizedBox(height: 18),
            if (!_manual) _showCode(context) else _enterCode(context),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: theme.colorScheme.error.withValues(alpha: .10), borderRadius: BorderRadius.circular(12)),
                child: Row(children: [
                  Icon(Icons.error_outline_rounded, size: 18, color: theme.colorScheme.error),
                  const SizedBox(width: 10),
                  Expanded(child: Text(_error!, style: TextStyle(color: theme.colorScheme.error))),
                ]),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _showCode(BuildContext context) {
    final remaining = _session.expiresAt.difference(DateTime.now());
    final code = _session.code;
    return Center(
      child: Column(children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18)),
          child: QrImageView(data: _session.qrPayload, size: 220, backgroundColor: Colors.white),
        ),
        const SizedBox(height: 16),
        Text('Scan this with the other device', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        GestureDetector(
          onTap: () => Clipboard.setData(ClipboardData(text: code)),
          child: Text(code, style: const TextStyle(fontSize: 28, letterSpacing: 7, fontWeight: FontWeight.w700)),
        ),
        const SizedBox(height: 6),
        Text(remaining.isNegative ? 'Code expired — close and try again.' : 'Tap the code to copy it. Expires in ${remaining.inMinutes}m.', style: Theme.of(context).textTheme.bodySmall),
      ]),
    );
  }

  Widget _enterCode(BuildContext context) {
    return Column(children: [
      TextField(controller: _address, decoration: const InputDecoration(labelText: 'Device address', hintText: '192.168.1.20')),
      const SizedBox(height: 10),
      TextField(controller: _port, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Port')),
      const SizedBox(height: 10),
      TextField(controller: _code, autofocus: widget.nearby != null, textInputAction: TextInputAction.done, onSubmitted: (_) => unawaited(_pair()), decoration: const InputDecoration(labelText: 'Pairing code')),
      const SizedBox(height: 14),
      SizedBox(width: double.infinity, child: FilledButton(onPressed: _pairing ? null : () => unawaited(_pair()), child: Text(_pairing ? 'Connecting…' : 'Connect'))),
    ]);
  }
}

class _MethodRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const _MethodRow({required this.icon, required this.title, required this.subtitle, required this.onTap});

  @override
  Widget build(BuildContext context) => Card(
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          minVerticalPadding: 10,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
          leading: Icon(icon, size: 24),
          title: Text(title),
          subtitle: Text(subtitle),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: onTap,
        ),
      );
}
