import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:qr_flutter/qr_flutter.dart';

import '../mesh/discovery.dart';
import '../mesh/mesh_service.dart';
import 'theme.dart';

/// Opens the pairing sheet. If [nearby] is given, the "Enter code" tab is
/// pre-filled with that device's address and port.
Future<void> showPairSheet(
  BuildContext context, {
  required MeshService mesh,
  DiscoveredDevice? nearby,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: NexusColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      side: BorderSide(color: NexusColors.border),
    ),
    builder: (context) => _PairSheet(mesh: mesh, nearby: nearby),
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
  int _tab = 0; // 0 = show my code, 1 = enter a code
  late final PairingSession _session;
  late final TextEditingController _codeController;
  late final TextEditingController _addressController;
  late final TextEditingController _portController;
  bool _pairing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _session = widget.mesh.beginPairing();
    _codeController = TextEditingController();
    _addressController = TextEditingController(text: widget.nearby?.address ?? '');
    _portController = TextEditingController(text: '${widget.nearby?.port ?? widget.mesh.port}');
    if (widget.nearby != null) _tab = 1;
  }

  @override
  void dispose() {
    _codeController.dispose();
    _addressController.dispose();
    _portController.dispose();
    super.dispose();
  }

  Future<void> _pair() async {
    final code = _codeController.text.trim();
    final address = _addressController.text.trim();
    final port = int.tryParse(_portController.text.trim());

    if (code.isEmpty) {
      setState(() => _error = 'Enter the code shown on the other device.');
      return;
    }
    if (address.isEmpty || port == null || port <= 0 || port > 65535) {
      setState(() => _error = 'Enter the address and port of the other device.');
      return;
    }

    setState(() {
      _pairing = true;
      _error = null;
    });
    final result = await widget.mesh.pairWith(address: address, port: port, code: code);
    if (!mounted) return;
    setState(() => _pairing = false);
    if (result.ok) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Paired with ${result.peerName ?? 'device'}. 🎉'),
      ));
    } else {
      setState(() => _error = result.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height;
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 14,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: SingleChildScrollView(
        child: SizedBox(
          height: height * 0.72,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(color: NexusColors.border, borderRadius: BorderRadius.circular(2)),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Text('Pair a device', style: Theme.of(context).textTheme.titleLarge),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded, color: NexusColors.muted),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 0, label: Text('Show my code'), icon: Icon(Icons.qr_code_2_rounded, size: 16)),
                  ButtonSegment(value: 1, label: Text('Enter a code'), icon: Icon(Icons.keyboard_rounded, size: 16)),
                ],
                selected: {_tab},
                onSelectionChanged: (s) => setState(() => _tab = s.first),
                style: SegmentedButton.styleFrom(
                  backgroundColor: NexusColors.surface,
                  foregroundColor: NexusColors.muted,
                  selectedForegroundColor: NexusColors.accent,
                  selectedBackgroundColor: NexusColors.accent.withValues(alpha: 0.12),
                  side: const BorderSide(color: NexusColors.border),
                ),
              ),
              const SizedBox(height: 16),
              Expanded(child: _tab == 0 ? _buildShowTab(context) : _buildEnterTab(context)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildShowTab(BuildContext context) {
    final valid = widget.mesh.pendingCodeActive;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Center(
              child: QrImageView(
                data: _session.qrPayload,
                size: 200,
                backgroundColor: Colors.white,
                eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Color(0xFF0B0F14)),
                dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: Color(0xFF0B0F14)),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: Text(
              valid ? _session.code : 'Expired — reopen to get a fresh code.',
              style: const TextStyle(
                fontSize: 34,
                fontWeight: FontWeight.w800,
                letterSpacing: 6,
                color: NexusColors.text,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'On the other device: add this one, enter the code above, and the two '
            'devices pair directly — no cloud, no account.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Text(
            'Code expires in 5 minutes. It is the only secret needed to pair — '
            'don’t share it with strangers.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: NexusColors.muted),
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: () => Clipboard.setData(ClipboardData(text: _session.code)),
            icon: const Icon(Icons.copy_rounded, size: 16),
            label: const Text('Copy code'),
          ),
        ],
      ),
    );
  }

  Widget _buildEnterTab(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.nearby != null)
            Container(
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: NexusColors.accent.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: NexusColors.accent.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.wifi_rounded, size: 18, color: NexusColors.accent),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Pairing with ${widget.nearby!.name} — enter the code it is showing.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          TextField(
            controller: _codeController,
            textCapitalization: TextCapitalization.characters,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, letterSpacing: 4, color: NexusColors.text),
            decoration: const InputDecoration(labelText: 'Code', hintText: 'XXXX-XXXX'),
            onSubmitted: (_) => _pair(),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _addressController,
                  decoration: const InputDecoration(labelText: 'Address', hintText: '192.168.1.23'),
                  onSubmitted: (_) => _pair(),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 1,
                child: TextField(
                  controller: _portController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Port'),
                  onSubmitted: (_) => _pair(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Address and port are usually filled in for you when the device was '
            'found on your network.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: NexusColors.danger.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: NexusColors.danger.withValues(alpha: 0.4)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.error_outline_rounded, size: 18, color: NexusColors.danger),
                  const SizedBox(width: 10),
                  Expanded(child: Text(_error!, style: const TextStyle(color: NexusColors.danger, fontSize: 13))),
                ],
              ),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _pairing ? null : _pair,
            icon: _pairing
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF06251F)))
                : const Icon(Icons.link_rounded, size: 18),
            label: Text(_pairing ? 'Pairing…' : 'Pair'),
          ),
        ],
      ),
    );
  }
}
