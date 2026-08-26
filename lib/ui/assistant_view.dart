import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';

import '../core/agent_contract.dart';
import '../core/command_service.dart';
import '../core/phone_actions.dart';
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
  String? _reply; // outcome shown on whichever plan card is open
  bool _sending = false;

  /// An open "who did you mean?" question after an unresolved contact.
  ({String phrase, List<String> candidates})? _pendingContactAsk;

  /// Runs real phone actions (dialing) on Android; elsewhere answers honestly.
  final PhoneActionBackend _phoneBackend = RealPhoneActionBackend();

  @override
  void initState() {
    super.initState();
    _service = CommandService(
      devices: _buildSnapshots,
      local: AgentDeviceSnapshot(
        id: widget.mesh.identity.id,
        name: widget.mesh.identity.name,
        online: true,
        capabilities: defaultCapabilitiesFor(widget.mesh.identity.platform),
      ),
      // On Android this device can really place calls, so "call …" plans here.
      locallyExecutable: defaultTargetPlatform == TargetPlatform.android
          ? const {AgentActions.callPlace}
          : const {},
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
        capabilities: defaultCapabilitiesFor(d.platform),
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
      // Unique per execution: the mesh matches the remote reply to this id.
      requestId: 'ui-${DateTime.now().microsecondsSinceEpoch}',
      answerTo: answerTo,
    );
    _consume(result, typedPhrase: input.trim().toLowerCase());
  }

  /// Shows a dispatch result — and starts locally-executed calls right away,
  /// so typing "call …" needs no Approve tap and no Call-now tap.
  void _consume(AgentDispatchResult result, {String? typedPhrase}) {
    setState(() {
      _result = result;
      _pendingKey = switch (result.dispatch) {
        final AgentClarification clarification => clarification.key,
        _ => null,
      };
    });
    if (result.dispatch case final AgentActionPlan plan
        when plan.request.target == widget.mesh.identity.id &&
            plan.request.action == AgentActions.callPlace) {
      unawaited(_placeLocalCall(plan.request, typedPhrase ?? ''));
    }
  }

  /// Places the call natively. When no contact matches closely enough, the
  /// closest names become a question whose answer is taught for that exact
  /// wording — asked once, remembered forever.
  Future<void> _placeLocalCall(AgentRequest request, String phrase) async {
    setState(() {
      _sending = true;
      _reply = null;
    });
    final contact = request.arguments['contact']?.toString() ?? '';
    final outcome = await _phoneBackend.callContact(contact);
    if (!mounted) return;
    if (!outcome.placed && !outcome.launched && outcome.candidates.isNotEmpty) {
      final askPhrase = phrase.isNotEmpty ? phrase : 'call ${contact.toLowerCase()}';
      setState(() {
        _sending = false;
        _pendingContactAsk = (phrase: askPhrase, candidates: outcome.candidates);
        _pendingKey = 'contact:$askPhrase';
        _result = AgentDispatchResult(
          status: AgentResultStatus.needsInfo,
          dispatch: AgentClarification(
            question:
                'I don\'t know "$contact" on this phone. Did you mean: ${outcome.candidates.join("  ·  ")}?',
            key: 'contact:$askPhrase',
            hint: 'Name one — I\'ll call them and remember this wording.',
          ),
        );
      });
      return;
    }
    setState(() {
      _sending = false;
      _reply = outcome.message;
    });
  }

  /// Resolves a "who did you mean?" answer against the offered candidates,
  /// teaches the wording, and places the call.
  void _answerContactAsk(String text) {
    final ask = _pendingContactAsk;
    if (ask == null) return;
    // Claim the pending ask immediately — a double-fired tap must not
    // submit the original wording as an "answer".
    _pendingContactAsk = null;
    final lower = text.trim().toLowerCase();
    final match = ask.candidates.firstWhere(
      (c) =>
          c.toLowerCase() == lower ||
          c.toLowerCase().contains(lower) ||
          lower.contains(c.toLowerCase()),
      orElse: () => '',
    );
    if (match.isEmpty) {
      setState(() {
        _pendingContactAsk = ask;
        _result = AgentDispatchResult(
          status: AgentResultStatus.needsInfo,
          dispatch: AgentClarification(
            question:
                'I don\'t see "${text.trim()}" here. Did you mean: ${ask.candidates.join("  ·  ")}?',
            key: _pendingKey!,
            hint: 'Name one of those, and I\'ll remember it.',
          ),
        );
      });
      return;
    }
    _consume(
      _service.learnAndRun(ask.phrase, 'call $match'),
      typedPhrase: ask.phrase,
    );
  }

  void _onSubmit() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    _lastInput = text;
    _controller.clear();
    final pending = _pendingKey;
    if (pending != null && pending.startsWith('contact:') && _pendingContactAsk != null) {
      _answerContactAsk(text);
      return;
    }
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

  /// Runs an action and shows its outcome on whichever plan card is open.
  Future<void> _runAction(Future<String> Function() action) async {
    setState(() {
      _sending = true;
      _reply = null;
    });
    final outcome = await action();
    if (!mounted) return;
    setState(() {
      _sending = false;
      _reply = outcome;
    });
  }

  /// Sends an approved action to the routed device and shows its answer.
  Future<void> _sendAgentRequest(AgentRequest request) async {
    final deviceName = _buildSnapshots()
            .where((d) => d.id == request.target)
            .firstOrNull
            ?.name ??
        request.target;
    await _runAction(() async {
      final reply = await widget.mesh.sendAgentRequest(request.target, request);
      return reply == null
          ? 'Could not reach $deviceName.'
          : 'Sent to $deviceName — ${_describeOutcome(reply)}';
    });
  }

  String _describeOutcome(AgentDispatchResult reply) {
    if (reply.dispatch case final AgentMessage message) {
      return message.text;
    }
    if (reply.message.isNotEmpty) return reply.message;
    return switch (reply.status) {
      AgentResultStatus.succeeded => 'done.',
      AgentResultStatus.denied => 'it was denied.',
      AgentResultStatus.unavailable => 'it could not do it.',
      AgentResultStatus.required => 'it needs approval.',
      AgentResultStatus.needsInfo => 'it needs more information.',
    };
  }

  /// The remote device asked us to run an action — approve or deny locally,
  /// execute here, and send the outcome back over the mesh.
  Future<void> _handleIncoming(AgentRequest request, String from, bool approve) async {
    final result = approve &&
            request.action == AgentActions.callPlace &&
            defaultTargetPlatform == TargetPlatform.android
        ? await executePhoneCall(_phoneBackend, request)
        : _service.handleRemoteRequest(
            request,
            approval: approve ? AgentApproval.approved : AgentApproval.denied,
          );
    final delivered = await widget.mesh.sendAgentResult(from, request.requestId, result);
    if (!mounted) return;
    widget.mesh.dismissIncomingAgentRequest();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          approve
              ? (delivered
                  ? 'Done — ${_describeOutcome(result)}'
                  : 'Executed locally, but the reply could not be sent back.')
              : 'Action denied.',
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

        // Result area — rebuilds when an action arrives from another device.
        Expanded(
          child: ListenableBuilder(
            listenable: widget.mesh,
            builder: (context, _) => _buildResult(),
          ),
        ),
      ],
    );
  }

  Widget _buildResult() {
    final result = _result;
    if (result == null && _incoming() == null) {
      return const Center(
        child: Icon(Icons.mic_none_rounded, size: 48, color: NexusColors.muted),
      );
    }

    final incoming = _incoming();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        if (incoming != null) ...[_incomingRequestView(incoming), const SizedBox(height: 12)],
        if (result != null) ...[_statusChip(result.status, result.message), const SizedBox(height: 12)],
        if (result?.dispatch case final AgentDeviceList list) _deviceListView(list.devices),
        if (result?.dispatch case final AgentActionPlan plan) _planView(plan),
        if (result?.dispatch case final AgentMessage message)
          message.live ? _liveClockView() : _messageView(message),
        if (result?.dispatch case final AgentClarification ask) _questionView(ask),
        if (result?.status == AgentResultStatus.required) ...[
          const SizedBox(height: 12),
          _approvalBar(),
        ],
      ],
    );
  }

  /// The pending incoming action from another device, if any.
  ({String from, AgentRequest request})? _incoming() {
    final raw = widget.mesh.lastIncomingAgentRequest;
    if (raw == null) return null;
    final request = raw['request'];
    if (request is! AgentRequest) return null;
    return (from: raw['from'] as String, request: request);
  }

  /// "My Phone wants to: Call mom" — the receiving device re-approves the
  /// action locally before it runs here.
  Widget _incomingRequestView(({String from, AgentRequest request}) incoming) {
    final fromName = widget.mesh.pairedDevices
            .where((d) => d.id == incoming.from)
            .firstOrNull
            ?.name ??
        incoming.from;
    final request = incoming.request;
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
              const Icon(Icons.notification_important_rounded, size: 18, color: NexusColors.warn),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '$fromName wants to: ${_describeAction(request)}',
                  style: const TextStyle(
                    color: NexusColors.text,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: () => _handleIncoming(request, incoming.from, true),
                  child: const Text('Approve'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _handleIncoming(request, incoming.from, false),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: NexusColors.danger,
                    side: const BorderSide(color: NexusColors.danger),
                  ),
                  child: const Text('Deny'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Shared scaffold for every rendered action-plan card.
  Widget _planCard(IconData icon, String title, List<Widget> children) {
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
              Icon(icon, size: 18, color: NexusColors.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(color: NexusColors.text, fontWeight: FontWeight.w600, fontSize: 14),
                ),
              ),
            ],
          ),
          ...children,
        ],
      ),
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
      return _planCard(Icons.content_copy_rounded, 'Copy to my devices', [
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
      ]);
    }
    // A plan aimed at this device runs right here — no mesh round-trip.
    if (request.target == widget.mesh.identity.id &&
        request.action == AgentActions.callPlace) {
      return _localCallPlanView(request);
    }
    if (request.action != AgentActions.ledBlink) {
      return _remotePlanView(request);
    }
    final snapshot = _buildSnapshots();
    final target = snapshot.where((d) => d.id == request.target).firstOrNull;

    return _planCard(Icons.bolt_rounded, 'Blink ${target?.name ?? request.target}', [
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
    ]);
  }

  /// An approved call aimed at THIS device — executes natively via the
  /// phone-action backend and shows the outcome inline.
  Widget _localCallPlanView(AgentRequest request) {
    return _planCard(Icons.call_rounded, _describeAction(request), [
      const SizedBox(height: 6),
      Text(
        'right here on ${widget.mesh.identity.name}',
        style: const TextStyle(color: NexusColors.muted, fontSize: 12),
      ),
      if (_reply != null) ...[const SizedBox(height: 10), _remoteReplyView(_reply!)],
      const SizedBox(height: 10),
      FilledButton.icon(
        onPressed: _sending
            ? null
            : () => _runAction(() async =>
                _describeOutcome(await executePhoneCall(_phoneBackend, request))),
        icon: const Icon(Icons.call_rounded, size: 16),
        label: Text(_sending ? 'Calling…' : 'Call now'),
      ),
    ]);
  }

  /// A plan aimed at another device ("Call mom on My Phone") — sends the
  /// approved action over the mesh and shows the remote's answer.
  Widget _remotePlanView(AgentRequest request) {
    final snapshot = _buildSnapshots();
    final target = snapshot.where((d) => d.id == request.target).firstOrNull;
    final deviceName = target?.name ?? request.target;
    return _planCard(Icons.devices_rounded, _describeAction(request), [
      const SizedBox(height: 6),
      Text(
        'on $deviceName',
        style: const TextStyle(color: NexusColors.muted, fontSize: 12),
      ),
      const SizedBox(height: 6),
      Text(
        'Target: ${request.target} · Action: ${request.action}',
        style: const TextStyle(color: NexusColors.muted, fontSize: 11),
      ),
      if (_reply != null) ...[const SizedBox(height: 10), _remoteReplyView(_reply!)],
      const SizedBox(height: 10),
      FilledButton.icon(
        onPressed: _sending ? null : () => _sendAgentRequest(request),
        icon: const Icon(Icons.send_rounded, size: 16),
        label: Text(_sending ? 'Sending…' : 'Send to $deviceName'),
      ),
    ]);
  }

  Widget _remoteReplyView(String reply) {
    final failed = reply.startsWith('Could not reach');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: (failed ? NexusColors.danger : NexusColors.ok).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        reply,
        style: TextStyle(
          color: failed ? NexusColors.danger : NexusColors.text,
          fontSize: 12,
        ),
      ),
    );
  }

  String _describeAction(AgentRequest request) {
    final a = request.arguments;
    switch (request.action) {
      case AgentActions.callPlace:
        return 'Call ${a['contact']}';
      case AgentActions.messageSend:
        return 'Message ${a['contact']}';
      case AgentActions.mediaPlay:
        return 'Play ${a['playlist'] ?? 'your music'}';
      case AgentActions.musicControl:
        return '${(a['mode'] as String? ?? 'Control')} the music';
      case AgentActions.alarmSet:
        return 'Set an alarm';
      case AgentActions.timerSet:
        return 'Set a timer';
      case AgentActions.reminderSet:
        return 'Set a reminder';
      case AgentActions.weatherGet:
        return 'Check the weather';
      case AgentActions.navigationRoute:
        return 'Navigate to ${a['place']}';
      case AgentActions.webSearch:
        return 'Search for ${a['query']}';
      case AgentActions.noteCreate:
        return 'Make a note';
      case AgentActions.translateText:
        return 'Translate';
      case AgentActions.calendarGet:
        return 'Check my calendar';
      case AgentActions.newsGet:
        return 'Get the news';
      default:
        return request.action;
    }
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

  /// The answer to "what time is it" keeps ticking instead of going stale.
  Widget _liveClockView() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: NexusColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: NexusColors.accent.withValues(alpha: 0.35)),
      ),
      child: const _LiveClock(),
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

/// A ticking clock: "It's HH:MM.", refreshed every second.
class _LiveClock extends StatefulWidget {
  const _LiveClock();

  @override
  State<_LiveClock> createState() => _LiveClockState();
}

class _LiveClockState extends State<_LiveClock> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final hh = now.hour.toString().padLeft(2, '0');
    final mm = now.minute.toString().padLeft(2, '0');
    return Text(
      'It\'s $hh:$mm.',
      style: const TextStyle(color: NexusColors.text, fontSize: 16, fontWeight: FontWeight.w600),
    );
  }
}