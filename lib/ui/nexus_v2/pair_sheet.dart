import 'dart:async';

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/network_info.dart';
import '../../core/pair_payload.dart';
import '../../mesh/discovery.dart';
import '../../mesh/mesh_service.dart';
import 'cable_pair_page.dart';
import 'design_system.dart';
import '../scan_qr_page.dart';

Future<void> showNexusV2PairSheet(BuildContext context, {required MeshService mesh, DiscoveredDevice? nearby}) {
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
  bool _showMyCode = true;
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
    _showMyCode = widget.nearby == null;
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

  Future<void> _scan() async {
    final payload = await Navigator.push<PairPayload>(context, MaterialPageRoute(builder: (_) => const ScanQrPage()));
    if (payload == null || !mounted) return;
    if (payload.id == widget.mesh.identity.id) {
      setState(() => _error = 'That is this device. Scan the other device.');
      return;
    }
    final addresses = <String>[];
    void add(String value) { if (value.isNotEmpty && !addresses.contains(value)) addresses.add(value); }
    add(payload.ip ?? '');
    for (final value in payload.ips) add(value);
    setState(() {
      _manual = true;
      _showMyCode = false;
      _address.text = addresses.isEmpty ? '' : addresses.first;
      _port.text = '${payload.port}';
      _code.text = payload.code;
      _error = null;
    });
    await _pair();
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
    } else {
      setState(() { _pairing = false; _error = result.error ?? 'Nexus could not connect to that device.'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Add a device', style: theme.textTheme.headlineMedium),
          const SizedBox(height: 5),
          Text('Connect a phone or computer once. Nexus remembers it.', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 18),
          NexusV2Group(
            children: [
              if (_canCable)
                NexusV2Row(
                  leading: const Icon(Icons.usb_rounded),
                  title: 'Use a cable',
                  subtitle: 'Recommended for setting up an Android phone',
                  onTap: () async {
                    Navigator.pop(context);
                    await Navigator.push(context, MaterialPageRoute(builder: (_) => NexusV2CablePairPage(mesh: widget.mesh)));
                  },
                ),
              if (_canScan)
                NexusV2Row(
                  leading: const Icon(Icons.qr_code_scanner_rounded),
                  title: 'Scan a QR code',
                  subtitle: 'The quickest wireless setup',
                  onTap: () => unawaited(_scan()),
                ),
              NexusV2Row(
                leading: const Icon(Icons.password_rounded),
                title: 'Enter a pairing code',
                subtitle: 'Use this when the other device shows a code',
                onTap: () => setState(() { _manual = true; _showMyCode = false; }),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_showMyCode) _showCode(context) else if (_manual) _enterCode(context),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: theme.colorScheme.error.withValues(alpha: .10), borderRadius: BorderRadius.circular(12)),
              child: Row(children: [
                Icon(Icons.error_outline_rounded, color: theme.colorScheme.error),
                const SizedBox(width: 9),
                Expanded(child: Text(_error!, style: TextStyle(color: theme.colorScheme.error))),
              ]),
            ),
          ],
        ]),
      ),
    );
  }

  Widget _showCode(BuildContext context) {
    final remaining = _session.expiresAt.difference(DateTime.now());
    return Center(child: Column(children: [
      Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)), child: QrImageView(data: _session.qrPayload, size: 208, backgroundColor: Colors.white)),
      const SizedBox(height: 15),
      Text('Scan this code on the other device', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 9),
      Semantics(
        label: 'Pairing code ${_session.code}',
        button: true,
        child: InkWell(
          onTap: () => Clipboard.setData(ClipboardData(text: _session.code)),
          borderRadius: BorderRadius.circular(12),
          child: Padding(padding: const EdgeInsets.all(8), child: Text(_session.code, style: const TextStyle(fontSize: 27, letterSpacing: 7, fontWeight: FontWeight.w700))),
        ),
      ),
      const SizedBox(height: 4),
      Text(remaining.isNegative ? 'Code expired. Close this sheet and try again.' : 'Tap the code to copy it · expires in ${remaining.inMinutes} min', style: Theme.of(context).textTheme.bodySmall),
    ]));
  }

  Widget _enterCode(BuildContext context) => Column(children: [
        TextField(controller: _address, decoration: const InputDecoration(labelText: 'Device address', hintText: '192.168.1.20')),
        const SizedBox(height: 10),
        TextField(controller: _port, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Port')),
        const SizedBox(height: 10),
        TextField(controller: _code, textInputAction: TextInputAction.done, onSubmitted: (_) => unawaited(_pair()), decoration: const InputDecoration(labelText: 'Pairing code')),
        const SizedBox(height: 14),
        SizedBox(width: double.infinity, child: FilledButton(onPressed: _pairing ? null : () => unawaited(_pair()), child: Text(_pairing ? 'Connecting…' : 'Connect'))),
      ]);
}
