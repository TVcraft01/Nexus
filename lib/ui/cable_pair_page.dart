import 'dart:async';

import 'package:flutter/material.dart';

import '../core/cable_pairing.dart';
import '../mesh/mesh_service.dart';
import '../mesh/serial_bridge.dart';
import 'theme.dart';

/// USB provisioning flow. Android authorization is handled by Android/ADB;
/// once authorized, Nexus installs itself, opens the tunnel and sends a
/// one-time pairing URI to the phone so no manual code entry is needed.
class CablePairPage extends StatefulWidget {
  final MeshService mesh;
  const CablePairPage({super.key, required this.mesh});

  @override
  State<CablePairPage> createState() => _CablePairPageState();
}

class _CablePairPageState extends State<CablePairPage> {
  bool _checking = true;
  List<String> _devices = const [];
  bool _awaitingAuthorization = false;
  String? _device;
  bool _installing = false;
  String? _installError;
  String? _installedVersion;
  bool _tunnelOk = false;
  int? _cablePort;
  String? _provisionError;
  Timer? _poll;
  int _pairedAtStart = 0;
  Timer? _refresh;
  String? _tetherHint;

  String get _code => _session?.code ?? '';
  PairingSession? _session;

  @override
  void initState() {
    super.initState();
    unawaited(_detect());
    _refresh = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!mounted) return;
      unawaited(_detect());
      setState(() {});
    });
    unawaited(widget.mesh.ensureSerialBridge());
    unawaited(_checkTether());
  }

  Future<void> _checkTether() async {
    final hint = await CablePairing.detectUsbTether();
    if (mounted) setState(() => _tetherHint = hint);
  }

  Future<void> _detect() async {
    if (!mounted) return;
    final states = await CablePairing.deviceStates();
    if (!mounted) return;
    final authorized = states.entries
        .where((entry) => entry.value == 'device')
        .map((entry) => entry.key)
        .toList();
    final awaiting = states.values.any((state) => state == 'unauthorized');
    setState(() {
      _checking = false;
      _devices = authorized;
      _awaitingAuthorization = awaiting && authorized.isEmpty;
    });
    if (_device == null && authorized.isNotEmpty) {
      await _select(authorized.first);
    }
  }

  Future<void> _select(String serial) async {
    setState(() {
      _device = serial;
      _installedVersion = null;
      _installError = null;
      _provisionError = null;
    });
    final hasApp = await CablePairing.hasNexusInstalled(serial);
    if (!mounted) return;
    if (hasApp) {
      setState(() => _installedVersion = 'already installed');
    } else {
      await _install();
    }
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
        _installError = 'Nexus could not be installed on this device.';
      }
    });
  }

  Future<void> _openTunnelAndProvision() async {
    final serial = _device;
    if (serial == null) return;
    setState(() {
      _tunnelOk = false;
      _cablePort = null;
      _provisionError = null;
    });

    final cablePort = await CablePairing.openTunnel(serial, widget.mesh.port);
    if (!mounted) return;
    if (cablePort == null) {
      setState(() => _provisionError =
          'Nexus could not create the secure cable tunnel. The phone is authorized, but ADB reverse-port forwarding failed.');
      return;
    }

    setState(() {
      _tunnelOk = true;
      _cablePort = cablePort;
      _session = widget.mesh.beginPairing();
      _pairedAtStart = widget.mesh.pairedDevices.length;
    });

    final error = await CablePairing.launchProvisioning(
      serial: serial,
      address: '127.0.0.1',
      port: cablePort,
      code: _code,
    );
    if (!mounted) return;
    if (error != null) {
      setState(() => _provisionError = error);
    }

    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 1), (_) {
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
    _refresh?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NexusColors.surface,
      appBar: AppBar(
        backgroundColor: NexusColors.surface,
        title: const Text('Connect device'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (_checking)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else if (_devices.isEmpty && !_awaitingAuthorization)
            _buildNoDevice(context)
          else if (_awaitingAuthorization)
            _buildAuthorization(context)
          else ...[
            _buildDevicePicker(context),
            const SizedBox(height: 14),
            if (_installing)
              const _Row(
                icon: Icons.download_rounded,
                text: 'Installing Nexus on the device…',
              )
            else if (_installError != null)
              _ExpandableError(
                title: 'Unable to connect',
                summary: _installError!,
                details:
                    'Nexus could not use ADB to install the current Android build. Check that the phone is unlocked, USB debugging is enabled, the computer is authorized, and the PC can download the latest Nexus release.',
              )
            else if (_installedVersion != null && !_tunnelOk)
              _Row(
                icon: Icons.check_circle_rounded,
                text: _installedVersion == 'already installed'
                    ? 'Nexus is already installed.'
                    : 'Nexus installed successfully.',
              ),
            if (_device != null && _installError == null && !_installing) ...[
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: _tunnelOk ? null : _openTunnelAndProvision,
                icon: const Icon(Icons.usb_rounded, size: 18),
                label: Text(_tunnelOk ? 'Connecting…' : 'Connect device'),
              ),
            ],
            if (_tunnelOk) ...[
              const SizedBox(height: 18),
              _buildProvisioningCard(context),
            ],
            if (_provisionError != null) ...[
              const SizedBox(height: 12),
              _ExpandableError(
                title: 'Unable to connect',
                summary: _provisionError!,
                details:
                    'The phone is installed and the cable tunnel is open, but Nexus could not finish the automatic pairing handshake. You can retry the connection or use the temporary pairing code below as a fallback.',
              ),
            ],
          ],
          const SizedBox(height: 26),
          _buildSerialSection(context),
          if (_tetherHint != null) ...[
            const SizedBox(height: 14),
            _Row(icon: Icons.link_rounded, text: _tetherHint!),
          ],
        ],
      ),
    );
  }

  Widget _buildAuthorization(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: NexusColors.accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: NexusColors.accent.withValues(alpha: 0.35)),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.verified_user_rounded, color: NexusColors.accent),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Authorize this computer on the device',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          SizedBox(height: 10),
          Text(
            'Unlock the Android device and accept the USB debugging request. Nexus will continue automatically once Android authorizes this computer.',
            style: TextStyle(fontSize: 13, color: NexusColors.muted),
          ),
        ],
      ),
    );
  }

  Widget _buildSerialSection(BuildContext context) {
    final devices = widget.mesh.serialDevices;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Microcontrollers on the cable',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'ESP32 and compatible boards can appear here when connected over USB.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 10),
        if (devices.isEmpty)
          const _Row(
            icon: Icons.memory_rounded,
            text: 'No microcontroller detected.',
          )
        else
          for (final d in devices)
            _SerialDeviceTile(mesh: widget.mesh, device: d),
      ],
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
    return const _Row(
      icon: Icons.usb_off_rounded,
      text: 'No supported device is connected. Plug in a phone or PC and Nexus will detect it.',
    );
  }

  Widget _buildProvisioningCard(BuildContext context) {
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
          const Row(
            children: [
              Icon(Icons.sync_rounded, color: NexusColors.accent),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Finishing connection…',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Nexus is opening on the device and completing the secure pairing automatically.',
            style: TextStyle(fontSize: 12, color: NexusColors.muted),
          ),
          if (_provisionError != null) ...[
            const SizedBox(height: 12),
            Text(
              'Fallback code: $_code · port ${_cablePort ?? widget.mesh.port}',
              style: const TextStyle(fontSize: 12, color: NexusColors.muted),
            ),
          ],
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

class _ExpandableError extends StatelessWidget {
  final String title;
  final String summary;
  final String details;
  const _ExpandableError({
    required this.title,
    required this.summary,
    required this.details,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: NexusColors.danger.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: NexusColors.danger.withValues(alpha: 0.35)),
      ),
      child: ExpansionTile(
        leading: const Icon(Icons.error_outline_rounded, color: NexusColors.danger),
        title: Text(title, style: const TextStyle(color: NexusColors.danger)),
        subtitle: Text(summary, style: const TextStyle(fontSize: 12)),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text(details, style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

class _SerialDeviceTile extends StatelessWidget {
  final MeshService mesh;
  final SerialDevice device;
  const _SerialDeviceTile({required this.mesh, required this.device});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: NexusColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: device.online ? NexusColors.accent : NexusColors.border,
        ),
      ),
      child: Row(
        children: [
          Icon(
            device.online ? Icons.memory_rounded : Icons.memory_outlined,
            size: 22,
            color: device.online ? NexusColors.accent : NexusColors.muted,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(device.name,
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                const SizedBox(height: 2),
                Text('${device.id} · ${device.port}',
                    style: const TextStyle(fontSize: 11, color: NexusColors.muted)),
              ],
            ),
          ),
          if (device.paired)
            const Text('Paired ✓',
                style: TextStyle(fontSize: 12, color: NexusColors.accent))
          else
            FilledButton.tonal(
              onPressed: () async {
                await mesh.pairSerialDevice(device.id);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('${device.name} paired over cable.')),
                  );
                }
              },
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 14),
              ),
              child: const Text('Pair', style: TextStyle(fontSize: 12)),
            ),
          const SizedBox(width: 6),
          IconButton(
            tooltip: 'Send a test blink',
            icon: const Icon(Icons.bolt_rounded, size: 18),
            color: NexusColors.accent,
            onPressed: () async {
              final ok = await mesh.sendSerialMessage(device.id, {'blink': true});
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(ok
                        ? 'Sent to ${device.name}.'
                        : 'Could not reach ${device.name}.'),
                  ),
                );
              }
            },
          ),
        ],
      ),
    );
  }
}
