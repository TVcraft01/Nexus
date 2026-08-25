import 'dart:async';

import 'package:flutter/material.dart';

import '../core/agent_contract.dart';
import '../core/command_service.dart';
import '../mesh/mesh_service.dart';
import 'theme.dart';

/// The assistant is a translator from human to machine: it asks when it
/// doesn't understand, and remembers what you taught it. This service is kept
/// alive for the whole view so questions and answers share one memory.

class AssistantView extends StatefulWidget {
  final MeshService mesh;

  const AssistantView({super.key, required this.mesh});

  @override
  State<AssistantView> createState() => _AssistantViewState();
}

class _AssistantViewState extends State<AssistantView> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  String _lastInput = '';
  AgentDispatchResult? _result;
  late final CommandService _service;
  String? _pendingKey; // a clarification is open; the next input answers it

  @override
  void initState() {
    super.initState();
    _service = CommandService(
      devices: _buildSnapshots,
      memory: AgentMemory(
        learned: widget.mesh.store.agentLearned,
        defaults: widget.mesh.store.agentDefaults,
      ),
      onMemoryChanged: () {
        widget.mesh.store.agentLearned = _service.learnedSnapshot;
        widget.mesh.store.agentDefaults = _service.defaultsSnapshot;
        // Best-effort persist — never a boot requirement.
        unawaited(widget.mesh.store.save());
      },
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  List<AgentDeviceSnapshot> _buildSnapshots() {
    final mesh = widget.mesh;
    final out = <AgentDeviceSnapshot>[];

    for (final d in mesh.pairedDevices) {
      out.add(AgentDeviceSnapshot(
        id: d.id,
        name: d.name,
        online: mesh.isOnline(d.id),
        capabilities: const [DeviceCapability(AgentActions.deviceList)],
      ));
    }

    for (final d in mesh.serialDevices) {
      out.add(AgentDeviceSnapshot(
        id: d.id,
        name: d.name,
        online: d.online,
        capabilities: d.caps
            .where((c) => c == 'msg')
            .map((_) => const DeviceCapability(AgentActions.ledBlink))
            .toList(),
      ));
    }

    for (final d in mesh.remoteSerialDevices) {
      out.add(AgentDeviceSnapshot(
        id: d.id,
        name: d.name,
        online: d.online,
        capabilities: d.caps
            .where((c) => c == 'msg')
            .map((_) => const DeviceCapability(AgentActions.ledBlink))
            .toList(),
      ));
    }

    return out;
  }

  void _execute(
    String input, {
    AgentApproval approval = AgentApproval.required,
    String? answerTo,
  }) {
    final result = _service.execute(
      input,
      approval: approval,
      requestId: 'ui-1',
      answerTo: answerTo,
    );
    setState(() {
      _result = result;
      // A clarification asks a question: the next submission is the answer.
      if (result.dispatch case final AgentClarification clarification) {
        _pendingKey = clarification.key;
      } else {
        _pendingKey = null;
      }
    });
  }

  void _onSubmit() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    _lastInput = text;
    _controller.clear();
    final pending = _pendingKey;
    if (pending != null) {
      _execute(text, answerTo: pending);
    } else {
      _execute(text);
    }
  }

  void _approve() {
    _execute(_lastInput, approval: AgentApproval.approved);
  }

  void _deny() {
    _execute(_lastInput, approval: AgentApproval.denied);
  }

  /// Sends the actual blink payload to a serial device.
  Future<void> _sendBlink(String deviceId, String deviceName) async {
    final ok = await widget.mesh.sendSerialMessage(deviceId, {'blink': true});
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok ? 'Sent to $deviceName.' : 'Could not reach $deviceName.',
        ),
      ),
    );
  }

  /// Pushes approved text to the other devices through the mesh clipboard.
  Future<void> _sendClipboard(String text) async {
    final sent = await widget.mesh.broadcastClipboard(text);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          sent > 0
              ? 'Copied to $sent device${sent == 1 ? '' : 's'}.'
              : 'No other device received it.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Input bar
        Container(
          margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          decoration: BoxDecoration(
            color: NexusColors.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: NexusColors.border),
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  focusNode: _focus,
                  onSubmitted: (_) => _onSubmit(),
                  decoration: InputDecoration(
                    hintText: _pendingKey == null
                        ? 'Ask anything — "play my playlist", "bring me home"…'
                        : 'Type your answer…',
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  ),
                  style: const TextStyle(color: NexusColors.text, fontSize: 14),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.send_rounded, size: 20),
                color: NexusColors.accent,
                onPressed: _onSubmit,
              ),
            ],
          ),
        ),

        // Result area
        Expanded(
          child: _buildResult(),
        ),
      ],
    );
  }

  Widget _buildResult() {
    final result = _result;
    if (result == null) {
      return const Center(
        child: Icon(Icons.mic_none_rounded, size: 48, color: NexusColors.muted),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        _statusChip(result.status, result.message),
        const SizedBox(height: 12),
        if (result.dispatch case final AgentDeviceList list) _deviceListView(list.devices),
        if (result.dispatch case final AgentActionPlan plan) _planView(plan),
        if (result.dispatch case final AgentMessage message) _messageView(message),
        if (result.dispatch case final AgentClarification ask) _questionView(ask),
        if (result.status == AgentResultStatus.required) ...[
          const SizedBox(height: 12),
          _approvalBar(),
        ],
      ],
    );
  }

  Widget _statusChip(AgentResultStatus status, String message) {
    final Color color;
    final String label;
    switch (status) {
      case AgentResultStatus.succeeded:
        color = NexusColors.ok;
        label = 'Done';
      case AgentResultStatus.required:
        color = NexusColors.warn;
        label = 'Approval needed';
      case AgentResultStatus.denied:
        color = NexusColors.danger;
        label = 'Denied';
      case AgentResultStatus.unavailable:
        color = NexusColors.muted;
        label = 'Unavailable';
      case AgentResultStatus.needsInfo:
        color = NexusColors.warn;
        label = 'Question';
    }
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
        ),
        if (message.isNotEmpty) ...[
          const SizedBox(width: 8),
          Expanded(
            child: Text(message, style: const TextStyle(color: NexusColors.muted, fontSize: 12)),
          ),
        ],
      ],
    );
  }

  Widget _questionView(AgentClarification ask) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: NexusColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: NexusColors.warn.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.help_outline_rounded, size: 18, color: NexusColors.warn),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  ask.question,
                  style: const TextStyle(
                    color: NexusColors.text,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
              ),
            ],
          ),
          if (ask.hint != null) ...[const SizedBox(height: 6), Text(ask.hint!, style: const TextStyle(color: NexusColors.muted, fontSize: 12))],
        ],
      ),
    );
  }

  Widget _deviceListView(List<AgentDeviceSnapshot> devices) {
    if (devices.isEmpty) {
      return const Text('No devices found.', style: TextStyle(color: NexusColors.muted));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: devices.map((d) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: NexusColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: NexusColors.border),
          ),
          child: Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: d.online ? NexusColors.ok : NexusColors.muted,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  d.name,
                  style: const TextStyle(color: NexusColors.text, fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                d.id,
                style: const TextStyle(color: NexusColors.muted, fontSize: 11),
              ),
              const SizedBox(width: 8),
              Text(
                d.online ? 'Online' : 'Offline',
                style: TextStyle(
                  color: d.online ? NexusColors.ok : NexusColors.muted,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
      )).toList(),
    );
  }

  Widget _planView(AgentActionPlan plan) {
    final request = plan.request;
    if (request.action == AgentActions.clipboardWrite) {
      final text = (request.arguments['text'] as String?) ?? '';
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: NexusColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: NexusColors.accent.withValues(alpha: 0.35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.content_copy_rounded, size: 18, color: NexusColors.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Copy to my devices',
                    style: const TextStyle(color: NexusColors.text, fontWeight: FontWeight.w600, fontSize: 14),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '\u201c$text\u201d',
              style: const TextStyle(color: NexusColors.muted, fontSize: 12),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: () => _sendClipboard(text),
              icon: const Icon(Icons.send_rounded, size: 16),
              label: const Text('Copy now'),
            ),
          ],
        ),
      );
    }
    final snapshot = _buildSnapshots();
    final target = snapshot.where((d) => d.id == request.target).firstOrNull;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: NexusColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: NexusColors.accent.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.bolt_rounded, size: 18, color: NexusColors.accent),
              const SizedBox(width: 8),
              Text(
                'Blink ${target?.name ?? request.target}',
                style: const TextStyle(color: NexusColors.text, fontWeight: FontWeight.w600, fontSize: 14),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Target: ${request.target} · Action: ${request.action}',
            style: const TextStyle(color: NexusColors.muted, fontSize: 11),
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: () => _sendBlink(request.target, target?.name ?? request.target),
            icon: const Icon(Icons.bolt_rounded, size: 16),
            label: const Text('Send blink now'),
          ),
        ],
      ),
    );
  }

  Widget _messageView(AgentMessage message) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: NexusColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: NexusColors.accent.withValues(alpha: 0.35)),
      ),
      child: Text(
        message.text,
        style: const TextStyle(color: NexusColors.text, fontSize: 13, height: 1.4),
      ),
    );
  }

  Widget _approvalBar() {
    return Row(
      children: [
        Expanded(
          child: FilledButton(
            onPressed: _approve,
            child: const Text('Approve'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: OutlinedButton(
            onPressed: _deny,
            style: OutlinedButton.styleFrom(
              foregroundColor: NexusColors.danger,
              side: const BorderSide(color: NexusColors.danger),
            ),
            child: const Text('Deny'),
          ),
        ),
      ],
    );
  }
}