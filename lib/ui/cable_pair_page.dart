import 'dart:async';

import 'package:flutter/material.dart';

import '../core/cable_pairing.dart';
import '../mesh/mesh_service.dart';
import 'theme.dart';

/// The "Pair over cable" flow. Steps through identifying the connected
/// device, installing the Nexus app on it if needed, opening the cable
/// tunnel, and showing the pairing code for the other device to enter.
///
/// Pops with `true` once the mesh reports the device as paired.
class CablePairPage extends StatefulWidget {
  final MeshService mesh;
  const CablePairPage({super.key, required this.mesh});

  @override
  State<CablePairPage> createState() => _CablePairPageState();
}

class _CablePairPageState extends State<CablePairPage> {
  bool _checking = true;
  List<String> _devices = const [];
  String? _device; // selected serial
  bool _installing = false;
  String? _installError;
  String? _installedVersion;
  bool _tunnelOk = false;
  String? _guide; // fallback guide for non-Android devices
  Timer? _poll;
  int _pairedAtStart = 0;

  String get _code => _session?.code ?? '';
  PairingSession? _session;

  @override
  void initState() {
    super.initState();
    _detect();
  }

  Future<void> _detect() async {
    setState(() {
      _checking = true;
      _guide = null;
    });
    final devices = await CablePairing.connectedDevices();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _devices = devices;
    });
    if (devices.isNotEmpty) {
      _select(devices.first);
    }
  }

  Future<void> _select(String serial) async {
    setState(() {
      _device = serial;
      _installedVersion = null;
      _installError = null;
    });
    final hasApp = await CablePairing.hasNexusInstalled(serial);
    if (!mounted) return;
    setState(() {
      if (hasApp) {
        _installedVersion = 'already installed';
      } else {
        _install(); // fire-and-forget install for the newly selected device
      }
    });
  }

  Future<void> _install() async {
    final serial = _device;
    if (serial == null) return;
    setState(() {
      _installing = true;
      _installError = null;
    });
    final version = await CablePairing.installAppOn(serial);
    if (!mounted) return;
    setState(() {
      _installing = false;
      if (version != null) {
        _installedVersion = version;
      } else {
        _installError = 'Could not install the app over the cable. Is the '
            'phone set to allow USB debugging, and does this PC have internet '
            'to fetch the latest release?';
      }
    });
  }

  Future<void> _openTunnelAndShowCode() async {
    final serial = _device;
    if (serial == null) return;
    setState(() => _tunnelOk = false);
    final ok = await CablePairing.reverseTunnel(serial, widget.mesh.port);
    if (!mounted) return;
    setState(() => _tunnelOk = ok);
    if (!ok) return;

    setState(() {
      _session = widget.mesh.beginPairing();
      _pairedAtStart = widget.mesh.pairedDevices.length;
    });
    // Watch for a brand-new pair to appear; ignore devices that were
    // already paired before this flow started.
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!mounted) return;
      if (widget.mesh.pairedDevices.length > _pairedAtStart) {
        _poll?.cancel();
        Navigator.pop(context, true);
      }
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NexusColors.surface,
      appBar: AppBar(
        backgroundColor: NexusColors.surface,
        title: const Text('Pair over cable'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (_checking)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else if (_devices.isEmpty)
            _buildNoDevice(context)
          else ...[
            _buildDevicePicker(context),
            const SizedBox(height: 14),
            if (_installing)
              const _Row(
                icon: Icons.download_rounded,
                text: 'Installing the Nexus app on the device…',
              )
            else if (_installError != null)
              _ErrorRow(text: _installError!)
            else if (_installedVersion != null && !_tunnelOk)
              _Row(
                icon: Icons.check_circle_rounded,
                text: _installedVersion == 'already installed'
                    ? 'Nexus is already on this device.'
                    : 'Installed Nexus $_installedVersion on the device.',
              ),
            if (_device != null && _installError == null && !_installing) ...[
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: _tunnelOk ? null : _openTunnelAndShowCode,
                icon: const Icon(Icons.usb_rounded, size: 18),
                label: Text(_tunnelOk ? 'Tunnel open' : 'Open the cable tunnel'),
              ),
            ],
            if (_tunnelOk) ...[
              const SizedBox(height: 18),
              _buildCodeCard(context),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildDevicePicker(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Connected devices', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        for (final serial in _devices)
          RadioGroup<String>(
            groupValue: _device,
            onChanged: (s) {
              if (s != null) _select(s);
            },
            child: Column(
              children: [
                RadioListTile<String>(
                  value: serial,
                  title: Text(serial, style: const TextStyle(fontSize: 14)),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildNoDevice(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _Row(
          icon: Icons.usb_off_rounded,
          text: 'No Android device detected on the cable. Make sure USB '
              'debugging is enabled on the phone and it is unlocked.',
        ),
        const SizedBox(height: 16),
        Text('Pairing a Raspberry Pi or other Linux device?',
            style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        const Text(
          'This PC can generate a setup script that installs Nexus on that '
          'device. After it runs, both devices pair over the network with a code.',
          style: TextStyle(fontSize: 13),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () {
            setState(() => _guide = CablePairing.linuxSetupScript());
          },
          icon: const Icon(Icons.terminal_rounded, size: 18),
          label: const Text('Generate Linux setup script'),
        ),
        if (_guide != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: NexusColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: NexusColors.border),
            ),
            child: SelectableText(
              _guide!,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildCodeCard(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: NexusColors.accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: NexusColors.accent.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'On the device: open Nexus → Pair a device → Enter a code',
            style: TextStyle(fontSize: 13, color: NexusColors.text),
          ),
          const SizedBox(height: 8),
          const Text(
            'Address 127.0.0.1, port below, code:',
            style: TextStyle(fontSize: 12, color: NexusColors.muted),
          ),
          const SizedBox(height: 10),
          Center(
            child: Text(
              _code,
              style: const TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.w800,
                letterSpacing: 4,
                color: NexusColors.text,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Center(
            child: Text(
              'port ${widget.mesh.port} · expires in 5 minutes',
              style: const TextStyle(fontSize: 12, color: NexusColors.muted),
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'The cable is the connection — no Wi-Fi needed for this pairing. '
            'Once the code is accepted, this page closes automatically.',
            style: TextStyle(fontSize: 12, color: NexusColors.muted),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Row({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: NexusColors.accent),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
      ],
    );
  }
}

class _ErrorRow extends StatelessWidget {
  final String text;
  const _ErrorRow({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
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
          Expanded(
            child: Text(text, style: const TextStyle(color: NexusColors.danger, fontSize: 13)),
          ),
        ],
      ),
    );
  }
}
