import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, HapticFeedback;
import 'package:qr_flutter/qr_flutter.dart';

import '../core/network_info.dart';
import '../core/pair_payload.dart';
import '../mesh/discovery.dart';
import '../mesh/mesh_service.dart';
import 'cable_pair_page.dart';
import 'components/nexus_ui.dart';
import 'scan_qr_page.dart';
import 'theme.dart';

/// One device the sheet found on the network, ready to pair with.
class _NearbyPick extends StatelessWidget {
  const _NearbyPick({
    required this.name,
    required this.platform,
    required this.onPair,
  });

  final String name;
  final String platform;
  final VoidCallback onPair;

  @override
  Widget build(BuildContext context) {
    final palette = NexusPalette.of(context);
    return NexusGroup(
      children: [
        NexusRow(
          title: name,
          subtitle: '${platformLabel(platform)} · on your network',
          minHeight: NexusSize.row,
          leading: Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: palette.accentTint(0.10),
              borderRadius: NexusRadius.row,
            ),
            child: Icon(
              platformIcon(platform),
              size: 20,
              color: palette.accent,
            ),
          ),
          trailing: FilledButton(
            onPressed: onPair,
            child: const Text('Pair'),
          ),
        ),
      ],
    );
  }
}

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
  /// Which step of the sheet is showing.
  ///
  /// The sheet opens on a chooser, not on a wall of transports: there is one
  /// obvious way to pair (the device you can see, or a QR code) and the rest
  /// is one tap away. -1 = chooser, 0 = show my code, 1 = enter a code,
  /// 2 = pair over cable.
  int _tab = -1;

  /// Whether "More ways to connect" is open.
  bool _moreWays = false;

  late PairingSession _session;
  late final TextEditingController _codeController;
  late final TextEditingController _addressController;
  late final TextEditingController _portController;
  bool _pairing = false;
  String? _error;

  /// Camera scanning needs a real camera; the phone can scan, desktop types.
  bool get _canScan =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  /// Cable pairing is a desktop feature: the PC identifies the connected
  /// device and serves the matching app over the cable.
  bool get _canCable =>
      defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.macOS;

  @override
  void initState() {
    super.initState();
    // The code is spent by the first device that pairs with it. Rebuild when
    // that happens so the sheet stops offering a code that no longer works.
    widget.mesh.addListener(_onMeshChanged);
    _session = widget.mesh.beginPairing();
    _codeController = TextEditingController();
    _addressController = TextEditingController(
      text: widget.nearby?.address ?? '',
    );
    _portController = TextEditingController(
      text: '${widget.nearby?.port ?? widget.mesh.port}',
    );
    if (widget.nearby != null) _prefill(widget.nearby);
    // Add our LAN IP to the QR as soon as we know it, so the other device can
    // connect straight from a scan without typing an address.
    unawaited(_refreshQrWithIp());
  }

  /// Points the code step at a device the user picked from the nearby list,
  /// so the common path is one tap instead of an address to type.
  void _prefill(DiscoveredDevice? device) {
    if (device == null) return;
    _tab = 1;
    _addressController.text = device.address;
    _portController.text = '${device.port}';
  }

  Future<void> _refreshQrWithIp() async {
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
          ip: ips.isNotEmpty ? ips.first : null,
          ips: ips,
        ),
        expiresAt: _session.expiresAt,
      );
    });
  }

  /// Opens the camera, parses a scanned Nexus QR, and pairs immediately.
  Future<void> _scanQr() async {
    final payload = await Navigator.push<PairPayload>(
      context,
      MaterialPageRoute(builder: (_) => const ScanQrPage()),
    );
    if (payload == null || !mounted) return;
    if (payload.id == widget.mesh.identity.id) {
      setState(
        () =>
            _error = 'That is this device’s own code — scan the other device.',
      );
      return;
    }
    // Build the full candidate list: the primary IP first, then every
    // announced IP, then any address we already know for this device.
    final candidates = <String>[];
    void add(String a) {
      if (a.isNotEmpty && !candidates.contains(a)) candidates.add(a);
    }

    add(payload.ip ?? '');
    for (final a in payload.ips) add(a);
    for (final a
        in widget.mesh.pairedDevices
            .where((d) => d.id == payload.id)
            .expand((d) => [d.address, ...d.addresses])) {
      add(a);
    }
    setState(() {
      _codeController.text = payload.code;
      _portController.text = '${payload.port}';
      _addressController.text = candidates.isNotEmpty ? candidates.first : '';
      _error = null;
    });
    // Try every address the QR advertised, not just the first: a QR carries
    // them all precisely because any single one can be stale (the device
    // changed networks, a VPN is down, a Docker bridge looks like a LAN).
    await _pair(addresses: candidates);
  }

  void _onMeshChanged() {
    if (mounted) setState(() {});
  }

  /// Issues a new code so the next device has something that works.
  void _newCode() {
    setState(() {
      _session = widget.mesh.beginPairing();
      _error = null;
    });
    HapticFeedback.selectionClick();
  }

  @override
  void dispose() {
    widget.mesh.removeListener(_onMeshChanged);
    _codeController.dispose();
    _addressController.dispose();
    _portController.dispose();
    super.dispose();
  }

  /// Pairs with the code in the fields. When [addresses] is given (a scanned
  /// QR), every advertised address is tried before giving up; otherwise the
  /// single address the user typed is used.
  Future<void> _pair({List<String>? addresses}) async {
    final code = _codeController.text.trim();
    final address = _addressController.text.trim();
    final port = int.tryParse(_portController.text.trim());

    if (code.isEmpty) {
      setState(() => _error = 'Enter the code shown on the other device.');
      return;
    }
    if (address.isEmpty || port == null || port <= 0 || port > 65535) {
      setState(
        () => _error = 'Enter the address and port of the other device.',
      );
      return;
    }

    HapticFeedback.selectionClick();
    setState(() {
      _pairing = true;
      _error = null;
    });
    final result = addresses == null
        ? await widget.mesh.pairWith(
            address: address,
            port: port,
            code: code,
          )
        : await widget.mesh.pairWithCandidates(
            addresses: addresses,
            port: port,
            code: code,
          );
    if (!mounted) return;
    setState(() => _pairing = false);
    if (result.ok) {
      HapticFeedback.lightImpact();
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Paired with ${result.peerName ?? 'device'}. 🎉'),
        ),
      );
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
                  decoration: BoxDecoration(
                    color: NexusColors.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  if (_tab >= 0)
                    IconButton(
                      onPressed: () => setState(() => _tab = -1),
                      tooltip: 'Back',
                      icon: const Icon(Icons.arrow_back_rounded),
                    ),
                  Expanded(
                    child: Text(
                      _tab < 0 ? 'Add device' : 'Finish pairing',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    tooltip: 'Close',
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Expanded(
                child: switch (_tab) {
                  -1 => _buildChooseTab(context),
                  0 => _buildShowTab(context),
                  1 => _buildEnterTab(context),
                  _ => _buildCableTab(context),
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The chooser: the one obvious way in, the rest behind a tap.
  Widget _buildChooseTab(BuildContext context) {
    final palette = NexusPalette.of(context);
    final nearby = widget.mesh.nearbyDevices
        .where((d) => !widget.mesh.isPaired(d.id))
        .toList();

    return ListView(
      padding: const EdgeInsets.only(top: NexusSpace.sm, bottom: NexusSpace.lg),
      children: [
        Text(
          nearby.isEmpty
              ? 'No devices nearby yet. Turn Nexus on and open Devices → Add '
                  'device on the other one, or use a QR code below.'
              : 'Pick a device you can see. Pairing asks for a code on the '
                  'other side.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (nearby.isNotEmpty) ...[
          const SizedBox(height: NexusSpace.md),
          for (final device in nearby)
            Padding(
              padding: const EdgeInsets.only(bottom: NexusSpace.sm),
              child: _NearbyPick(
                name: device.name,
                platform: device.platform,
                onPair: () => setState(() {
                  _prefill(device);
                  _error = null;
                }),
              ),
            ),
        ],
        if (_canScan) ...[
          const SizedBox(height: NexusSpace.lg),
          FilledButton.tonalIcon(
            onPressed: () => unawaited(_scanQr()),
            icon: const Icon(Icons.qr_code_scanner_rounded, size: 20),
            label: const Text('Scan a QR code'),
          ),
        ],
        const SizedBox(height: NexusSpace.lg),
        Divider(color: palette.separator, height: 1),
        const SizedBox(height: NexusSpace.sm),
        // Progressive disclosure: every transport is here, none of them is in
        // the way of the two that matter.
        InkWell(
          onTap: () => setState(() => _moreWays = !_moreWays),
          borderRadius: NexusRadius.row,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: NexusSpace.md),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'More ways to connect',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Icon(
                  _moreWays
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  color: palette.textTertiary,
                ),
              ],
            ),
          ),
        ),
        if (_moreWays) ...[
          NexusGroup(
            children: [
              NexusRow(
                title: 'Enter a code from the other device',
                minHeight: NexusSize.rowCompact,
                leading: Icon(
                  Icons.keyboard_rounded,
                  size: 20,
                  color: palette.textSecondary,
                ),
                chevron: true,
                onTap: () => setState(() => _tab = 1),
              ),
              NexusRow(
                title: 'Show my code instead',
                minHeight: NexusSize.rowCompact,
                leading: Icon(
                  Icons.qr_code_2_rounded,
                  size: 20,
                  color: palette.textSecondary,
                ),
                chevron: true,
                onTap: () => setState(() => _tab = 0),
              ),
              if (_canCable)
                NexusRow(
                  title: 'Pair over a USB cable',
                  subtitle: 'Needs the device plugged into this computer.',
                  minHeight: NexusSize.rowCompact,
                  leading: Icon(
                    Icons.usb_rounded,
                    size: 20,
                    color: palette.textSecondary,
                  ),
                  chevron: true,
                  onTap: () => setState(() => _tab = 2),
                ),
            ],
          ),
          const SizedBox(height: NexusSpace.md),
        ],
      ],
    );
  }

  Widget _buildShowTab(BuildContext context) {
    final valid = widget.mesh.pendingCodeActive;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // A spent code's QR is dead — scanning it would fail. Only draw a
          // code that can still pair, so the picture never lies.
          if (valid)
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
                  eyeStyle: const QrEyeStyle(
                    eyeShape: QrEyeShape.square,
                    color: Color(0xFF0B0F14),
                  ),
                  dataModuleStyle: const QrDataModuleStyle(
                    dataModuleShape: QrDataModuleShape.square,
                    color: Color(0xFF0B0F14),
                  ),
                ),
              ),
            )
          else
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: NexusColors.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: NexusColors.border),
              ),
              child: const Center(
                child: Icon(
                  Icons.check_circle_outline_rounded,
                  size: 48,
                  color: NexusColors.ok,
                ),
              ),
            ),
          const SizedBox(height: 16),
          Center(
            child: Text(
              valid ? _session.code : 'Code no longer usable',
              style: TextStyle(
                fontSize: valid ? 34 : 20,
                fontWeight: FontWeight.w800,
                letterSpacing: valid ? 6 : 0,
                color: valid ? NexusColors.text : NexusColors.muted,
                fontFeatures: const [FontFeature.tabularFigures()],
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
            valid
                ? 'Code expires in 5 minutes. It is the only secret needed to '
                    'pair — don’t share it with strangers.'
                : 'Each code pairs one device. Show a new code for the next one.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: NexusColors.muted),
          ),
          const SizedBox(height: 10),
          _TailscaleBanner(),
          const SizedBox(height: 14),
          if (valid)
            OutlinedButton.icon(
              onPressed: () =>
                  Clipboard.setData(ClipboardData(text: _session.code)),
              icon: const Icon(Icons.copy_rounded, size: 16),
              label: const Text('Copy code'),
            )
          else
            FilledButton.icon(
              onPressed: _newCode,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Show a new code'),
            ),
        ],
      ),
    );
  }

  Widget _buildCableTab(BuildContext context) {
    // The PC is the one that drives cable pairing — it identifies the
    // connected device, installs the matching app over the cable, and opens
    // the tunnel. A phone is the device being set up, so it gets a guide
    // instead of a "start" button (a phone cannot install apps on a PC).
    if (!_canCable) {
      return SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: NexusColors.accent.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: NexusColors.accent.withValues(alpha: 0.3),
                ),
              ),
              child: const Row(
                children: [
                  Icon(Icons.usb_rounded, size: 20, color: NexusColors.accent),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Plug this phone into a PC running Nexus and the PC does '
                      'the work: it spots this phone over the cable, installs '
                      'or updates Nexus on it if needed, and opens a secure '
                      'tunnel — no Wi-Fi used for the pairing.',
                      style: TextStyle(color: NexusColors.text, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Phone to PC pairing',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            Text(
              '1. On this phone: enable USB debugging (Settings > Developer '
              'options > USB debugging).',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            Text(
              '2. Plug this phone into the PC, then on the PC open Nexus > '
              'Pair a device > Pair over cable.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            Text(
              '3. When the PC shows a code and a port: open \"Enter a code\" '
              'here and type Address 127.0.0.1, the port shown on the PC, and '
              'that code, then tap Pair.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            Text(
              'Two phones and one cable?',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            Text(
              'Android cannot bridge two phones over a single USB cable, so '
              'phone-to-phone pairing over USB is not possible on a normal '
              'phone. To pair two phones anywhere with no router and no '
              'internet: put one in hotspot mode and pair the other to it '
              'with a code or a QR scan — same direct, private pairing, over '
              'the hotspot link instead of a cable.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      );
    }

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: NexusColors.accent.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: NexusColors.accent.withValues(alpha: 0.3),
              ),
            ),
            child: const Row(
              children: [
                Icon(Icons.usb_rounded, size: 20, color: NexusColors.accent),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Plug the device into this PC with a cable. This PC identifies '
                    'what is connected and sends the matching Nexus app — a phone '
                    'gets the Android app over the cable, a Raspberry Pi or other '
                    'Linux device gets a setup script.',
                    style: TextStyle(color: NexusColors.text, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: () async {
              final paired = await Navigator.push<bool>(
                this.context,
                MaterialPageRoute(
                  builder: (_) => CablePairPage(mesh: widget.mesh),
                ),
              );
              if (paired == true && mounted) {
                Navigator.pop(this.context);
                ScaffoldMessenger.of(this.context).showSnackBar(
                  const SnackBar(
                    content: Text('Device paired over the cable. 🎉'),
                  ),
                );
              }
            },
            icon: const Icon(Icons.usb_rounded, size: 18),
            label: const Text('Start cable pairing'),
          ),
          const SizedBox(height: 10),
          Text(
            'Only runs when you start it — nothing is detected or installed '
            'until you tap the button.',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: NexusColors.muted),
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
                border: Border.all(
                  color: NexusColors.accent.withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.wifi_rounded,
                    size: 18,
                    color: NexusColors.accent,
                  ),
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
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              letterSpacing: 4,
              color: NexusColors.text,
            ),
            decoration: const InputDecoration(
              labelText: 'Code',
              hintText: 'XXXX-XXXX',
            ),
            onSubmitted: (_) => _pair(),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _addressController,
                  decoration: const InputDecoration(
                    labelText: 'Address',
                    hintText: '192.168.1.23',
                  ),
                  onSubmitted: (_) => _pair(),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
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
                border: Border.all(
                  color: NexusColors.danger.withValues(alpha: 0.4),
                ),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.error_outline_rounded,
                    size: 18,
                    color: NexusColors.danger,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _error!,
                      style: const TextStyle(
                        color: NexusColors.danger,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 16),
          if (_canScan)
            OutlinedButton.icon(
              onPressed: _pairing ? null : _scanQr,
              icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
              label: const Text('Scan a QR code instead'),
            ),
          if (_canScan) const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: _pairing ? null : _pair,
            icon: _pairing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Color(0xFF06251F),
                    ),
                  )
                : const Icon(Icons.link_rounded, size: 18),
            label: Text(_pairing ? 'Pairing…' : 'Pair'),
          ),
        ],
      ),
    );
  }
}

/// Shows Tailscale status in the pairing UI so users know their device
/// is reachable across the internet (not just on the same WiFi).
class _TailscaleBanner extends StatefulWidget {
  const _TailscaleBanner();

  @override
  State<_TailscaleBanner> createState() => _TailscaleBannerState();
}

class _TailscaleBannerState extends State<_TailscaleBanner> {
  bool _loading = true;
  TailscaleInfo? _info;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final info = await detectTailscaleInfo();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _info = info;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SizedBox.shrink();
    if (_info == null || !_info!.online) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: NexusColors.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: NexusColors.border),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.wifi_off_rounded,
              size: 14,
              color: NexusColors.muted,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'No Tailscale — devices must be on the same network.',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: NexusColors.muted),
              ),
            ),
          ],
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: NexusColors.ok.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: NexusColors.ok.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.check_circle_rounded,
            size: 14,
            color: NexusColors.ok,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Tailscale active — paired devices can connect from anywhere.',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: NexusColors.ok),
            ),
          ),
        ],
      ),
    );
  }
}
