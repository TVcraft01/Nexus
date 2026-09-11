import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/cable_pairing.dart';
import '../../mesh/mesh_service.dart';

class NexusV2CablePairPage extends StatefulWidget {
  final MeshService mesh;
  const NexusV2CablePairPage({super.key, required this.mesh});

  @override
  State<NexusV2CablePairPage> createState() => _NexusV2CablePairPageState();
}

class _NexusV2CablePairPageState extends State<NexusV2CablePairPage> {
  bool _checking = true;
  bool _waitingForAuthorization = false;
  String? _device;
  bool _installing = false;
  bool _connecting = false;
  String? _error;
  String? _status;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => unawaited(_refresh()));
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final states = await CablePairing.deviceStates();
    if (!mounted) return;
    final authorized = states.entries.where((entry) => entry.value == 'device').map((entry) => entry.key).toList();
    final waiting = states.values.any((state) => state == 'unauthorized');
    setState(() {
      _checking = false;
      _waitingForAuthorization = waiting && authorized.isEmpty;
      if (_device == null && authorized.isNotEmpty) _device = authorized.first;
    });
    if (_device != null && authorized.contains(_device)) {
      await _ensureConnected();
    }
  }

  Future<void> _ensureConnected() async {
    if (_device == null || _installing || _connecting) return;
    final serial = _device!;
    final installed = await CablePairing.hasNexusInstalled(serial);
    if (!mounted) return;
    if (!installed) {
      setState(() {
        _installing = true;
        _status = 'Installing Nexus…';
        _error = null;
      });
      final version = await CablePairing.installAppOn(serial);
      if (!mounted) return;
      if (version == null) {
        setState(() {
          _installing = false;
          _status = null;
          _error = 'Nexus couldn’t be installed on this device.';
        });
        return;
      }
      setState(() => _installing = false);
    }
    if (!mounted || _connecting) return;
    setState(() {
      _connecting = true;
      _status = 'Connecting securely…';
      _error = null;
    });
    final port = await CablePairing.openTunnel(serial, widget.mesh.port);
    if (!mounted) return;
    if (port == null) {
      setState(() {
        _connecting = false;
        _status = null;
        _error = 'The cable connection couldn’t be created.';
      });
      return;
    }
    final session = widget.mesh.beginPairing();
    final error = await CablePairing.launchProvisioning(
      serial: serial,
      address: '127.0.0.1',
      port: port,
      code: session.code,
    );
    if (!mounted) return;
    if (error != null) {
      setState(() {
        _connecting = false;
        _status = null;
        _error = error;
      });
      return;
    }
    setState(() => _status = 'Finishing setup…');
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;
      if (widget.mesh.pairedDevices.any((d) => d.platform == 'android')) {
        Navigator.pop(context, true);
        return;
      }
    }
    if (mounted) {
      setState(() {
        _connecting = false;
        _status = null;
        _error = 'The phone was reached, but pairing did not finish.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Connect a device')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        children: [
          Text('Use a cable', style: theme.textTheme.displaySmall),
          const SizedBox(height: 6),
          Text('Plug in the Android device. Nexus will handle the setup for you.', style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 24),
          _Step(number: '1', title: 'Plug it in', body: 'Connect the phone to this computer with a USB cable.', active: !_waitingForAuthorization && _device == null),
          const SizedBox(height: 10),
          _Step(number: '2', title: 'Allow this computer', body: _waitingForAuthorization ? 'Unlock the phone and accept the USB debugging prompt. Nexus will continue automatically.' : 'Android may ask you to authorize this computer.', active: _waitingForAuthorization),
          const SizedBox(height: 10),
          _Step(number: '3', title: 'Done', body: _status ?? (_device != null ? 'Nexus will finish the connection automatically.' : 'Waiting for a device…'), active: _installing || _connecting),
          if (_checking) ...[
            const SizedBox(height: 20),
            const Center(child: CircularProgressIndicator(strokeWidth: 2)),
          ],
          if (_error != null) ...[
            const SizedBox(height: 18),
            _FailureCard(error: _error!, onRetry: () => unawaited(_refresh())),
          ],
          const SizedBox(height: 18),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('Need help?'),
            childrenPadding: const EdgeInsets.only(bottom: 8),
            children: const [
              Align(
                alignment: Alignment.centerLeft,
                child: Text('Keep the phone unlocked while approving USB debugging. If Android does not show a prompt, unplug and reconnect the cable, then try again.'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  final String number;
  final String title;
  final String body;
  final bool active;
  const _Step({required this.number, required this.title, required this.body, required this.active});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(children: [
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active ? theme.colorScheme.primary : theme.colorScheme.surfaceContainerHighest,
              shape: BoxShape.circle,
            ),
            child: Text(number, style: TextStyle(color: active ? theme.colorScheme.onPrimary : theme.colorScheme.onSurfaceVariant, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 3),
            Text(body, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ])),
        ]),
      ),
    );
  }
}

class _FailureCard extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;
  const _FailureCard({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Unable to connect', style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Theme.of(context).colorScheme.error)),
            const SizedBox(height: 6),
            Text(error),
            const SizedBox(height: 10),
            TextButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh_rounded), label: const Text('Try again')),
          ]),
        ),
      );
}
