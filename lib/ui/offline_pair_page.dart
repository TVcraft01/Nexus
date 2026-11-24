import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:qr_flutter/qr_flutter.dart';

import '../mesh/mesh_service.dart';
import '../mesh/offline_pairing.dart';
import 'scan_qr_page.dart';
import 'theme.dart';

/// Pairing with no network at all: two screens, two codes, one secret.
///
/// The important property is that neither code carries an address. The devices
/// exchange the handshake by camera or by copy/paste, derive the same key, and
/// then show the same six digits. Nothing is stored until both people tap
/// "they match"; walking away at any point leaves nothing behind.
///
/// The paste path is always here, not a fallback hidden behind a camera error:
/// desktop Linux has no scanner plugin in this app, and a pairing flow that can
/// dead-end because a camera is unavailable is not a flow.
class OfflinePairPage extends StatefulWidget {
  final MeshService mesh;

  const OfflinePairPage({super.key, required this.mesh});

  /// Opens the page and answers true when a pairing was confirmed.
  static Future<bool?> show(BuildContext context, MeshService mesh) =>
      Navigator.push<bool>(
        context,
        MaterialPageRoute(builder: (_) => OfflinePairPage(mesh: mesh)),
      );

  @override
  State<OfflinePairPage> createState() => _OfflinePairPageState();
}

class _OfflinePairPageState extends State<OfflinePairPage> {
  /// 0 = show my code, 1 = enter theirs.
  int _mode = 0;

  OfflineHostSession? _host;
  OfflineGuestSession? _guest;
  OfflinePairingOffer? _offer;

  final TextEditingController _answer = TextEditingController();
  final TextEditingController _code = TextEditingController();

  bool _busy = false;
  bool _paired = false;

  /// True once this device (the host) has taken the other side's answer and
  /// has nothing left to show. The guest keeps its screen — its QR2 and its
  /// six digits are exactly what the host needs — and only gets the match
  /// buttons underneath them.
  bool _awaitingConfirm = false;
  String? _error;

  /// Camera scanning exists on the platforms the scanner supports; everywhere
  /// else the paste field is the whole interface, which is why it is never
  /// conditional.
  bool get _canScan {
    final platform = Theme.of(context).platform;
    return platform == TargetPlatform.android ||
        platform == TargetPlatform.iOS;
  }

  @override
  void initState() {
    super.initState();
    // The submit buttons are enabled only once their field has a code in it,
    // and a TextField rebuilding itself does not rebuild this page. Without
    // these listeners the button is decided when the page is built (empty) and
    // stays disabled while you type — the flow could be followed but never
    // finished. The e2e test types into the field and taps the button, which
    // is how this was caught.
    _answer.addListener(_onFieldChanged);
    _code.addListener(_onFieldChanged);
    unawaited(_newHost());
  }

  void _onFieldChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _answer.removeListener(_onFieldChanged);
    _code.removeListener(_onFieldChanged);
    _answer.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _newHost() async {
    try {
      final host = await widget.mesh.beginOfflinePairing();
      if (!mounted) return;
      setState(() {
        _host = host;
        _error = null;
      });
    } on OfflinePairingException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    }
  }

  Future<void> _scanInto(TextEditingController target, VoidCallback after) async {
    final scanned = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const ScanQrPage(offline: true)),
    );
    if (scanned == null || !mounted) return;
    target.text = scanned;
    after();
  }

  Future<void> _checkAnswer() async {
    final host = _host;
    if (host == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final offer = await host.acceptAnswer(_answer.text);
      if (!mounted) return;
      setState(() {
        _offer = offer;
        _awaitingConfirm = true;
        _busy = false;
      });
    } on OfflinePairingException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _busy = false;
      });
    }
  }

  Future<void> _answerCode() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final guest = await widget.mesh.answerOfflinePairing(_code.text);
      if (!mounted) return;
      setState(() {
        _guest = guest;
        _offer = guest.offer;
        _busy = false;
      });
    } on OfflinePairingException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _busy = false;
      });
    }
  }

  Future<void> _confirm() async {
    final offer = _offer;
    if (offer == null) return;
    setState(() => _busy = true);
    await widget.mesh.confirmOfflinePairing(offer);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _paired = true;
    });
  }

  void _mismatch() {
    // Nothing was written, so "abort" is simply dropping what is in memory and
    // starting again with a fresh ephemeral key.
    setState(() {
      _offer = null;
      _guest = null;
      _awaitingConfirm = false;
      _answer.clear();
      _code.clear();
      _error = 'Nothing was paired. Show a fresh code when you are ready.';
    });
    unawaited(_newHost());
  }

  Future<void> _copy(String text, String what) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$what copied. Paste it on the other device.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pair without a network')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          NexusSpace.page,
          NexusSpace.md,
          NexusSpace.page,
          NexusSpace.huge,
        ),
        children: [
          Text(
            'Neither device needs Wi-Fi or a hotspot. One shows a code, the '
            'other reads it, and both screens end up with the same six digits. '
            'If the digits differ, nothing is paired.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: NexusSpace.lg),
          if (_paired)
            _doneCard()
          else if (_offer != null && _awaitingConfirm)
            _confirmCard()
          else ...[
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('Show my code')),
                ButtonSegment(value: 1, label: Text('Enter their code')),
              ],
              selected: {_mode},
              onSelectionChanged: (selection) {
                setState(() {
                  _mode = selection.first;
                  _error = null;
                });
              },
            ),
            const SizedBox(height: NexusSpace.lg),
            if (_mode == 0) _showSection() else _enterSection(),
          ],
          if (_error != null) ...[
            const SizedBox(height: NexusSpace.md),
            Text(
              _error!,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: NexusColors.danger),
            ),
          ],
        ],
      ),
    );
  }

  Widget _showSection() {
    final host = _host;
    if (host == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(NexusSpace.xl),
          child: CircularProgressIndicator(),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _qrCard(host.qr1),
        const SizedBox(height: NexusSpace.sm),
        Text(
          'Scan this on the other device, or copy it and paste it there. It '
          'expires when you leave this screen.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: NexusSpace.md),
        OutlinedButton.icon(
          onPressed: () => _copy(host.qr1, 'Code'),
          icon: const Icon(Icons.copy_rounded, size: 16),
          label: const Text('Copy code'),
        ),
        const SizedBox(height: NexusSpace.xl),
        TextField(
          controller: _answer,
          minLines: 2,
          maxLines: 4,
          style: NexusType.caption,
          decoration: const InputDecoration(
            labelText: 'Their answer',
            hintText: 'Paste the code the other device shows back to you',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: NexusSpace.sm),
        Row(
          children: [
            if (_canScan) ...[
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () =>
                      _scanInto(_answer, () => unawaited(_checkAnswer())),
                  icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
                  label: const Text('Scan answer'),
                ),
              ),
              const SizedBox(width: NexusSpace.sm),
            ],
            Expanded(
              child: FilledButton(
                onPressed: _busy || _answer.text.trim().isEmpty
                    ? null
                    : _checkAnswer,
                child: const Text('Check answer'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _enterSection() {
    final guest = _guest;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _code,
          minLines: 2,
          maxLines: 4,
          style: NexusType.caption,
          decoration: const InputDecoration(
            labelText: 'The code from the other device',
            hintText: 'Paste what their screen shows',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: NexusSpace.sm),
        Row(
          children: [
            if (_canScan) ...[
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () =>
                      _scanInto(_code, () => unawaited(_answerCode())),
                  icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
                  label: const Text('Scan code'),
                ),
              ),
              const SizedBox(width: NexusSpace.sm),
            ],
            Expanded(
              child: FilledButton(
                onPressed: _busy || _code.text.trim().isEmpty
                    ? null
                    : _answerCode,
                child: const Text('Use this code'),
              ),
            ),
          ],
        ),
        if (guest != null) ...[
          const SizedBox(height: NexusSpace.xl),
          _qrCard(guest.qr2),
          const SizedBox(height: NexusSpace.sm),
          Text(
            'Show this back to ${guest.hostName}. They check it on their '
            'device, and both of you compare the six digits next.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: NexusSpace.md),
          OutlinedButton.icon(
            onPressed: () => _copy(guest.qr2, 'Answer'),
            icon: const Icon(Icons.copy_rounded, size: 16),
            label: const Text('Copy answer'),
          ),
          const SizedBox(height: NexusSpace.xl),
          _codeBlock(
            guest.offer.confirmationCode,
            'Compare this with the other device. Only tap “they match” if the '
                'two screens agree.',
          ),
          const SizedBox(height: NexusSpace.lg),
          _matchButtons(),
        ],
      ],
    );
  }

  Widget _confirmCard() {
    final offer = _offer!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _codeBlock(
          offer.confirmationCode,
          'Both devices must show these six digits. They are only equal when '
              'the exchange was not interfered with.',
        ),
        const SizedBox(height: NexusSpace.md),
        Text(
          '${offer.peerName} · pairing without a network',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: NexusSpace.xl),
        _matchButtons(),
      ],
    );
  }

  /// The two buttons a person uses to accept or reject the pairing. Shared,
  /// because both sides of the handshake end on the same decision at different
  /// points in the flow.
  Widget _matchButtons() {
    final offer = _offer;
    if (offer == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton(
          onPressed: _busy ? null : _confirm,
          child: Text('They match — pair with ${offer.peerName}'),
        ),
        const SizedBox(height: NexusSpace.sm),
        OutlinedButton(
          onPressed: _busy ? null : _mismatch,
          child: const Text('They do not match'),
        ),
      ],
    );
  }

  Widget _doneCard() {
    final name = _offer?.peerName ?? 'the other device';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(
          Icons.check_circle_outline_rounded,
          size: 44,
          color: NexusColors.ok,
        ),
        const SizedBox(height: NexusSpace.md),
        Text(
          'Paired with $name.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: NexusSpace.sm),
        Text(
          'The two devices now share a key. They can find each other and send '
          'files the next time they are on the same network — no account, no '
          'server.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: NexusSpace.xl),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Done'),
        ),
      ],
    );
  }

  Widget _qrCard(String data) => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Center(
      child: QrImageView(
        data: data,
        size: 220,
        backgroundColor: Colors.white,
        errorCorrectionLevel: QrErrorCorrectLevel.Q,
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
  );

  Widget _codeBlock(String code, String caption) => Column(
    children: [
      Text(
        code,
        style: NexusType.display.copyWith(
          fontWeight: FontWeight.w800,
          letterSpacing: 8,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      const SizedBox(height: NexusSpace.sm),
      Text(
        caption,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ],
  );
}
