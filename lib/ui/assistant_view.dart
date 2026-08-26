import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart'
    show getApplicationDocumentsDirectory;

import '../core/agent_contract.dart';
import '../core/command_interpreter.dart';
import '../core/command_service.dart';
import '../core/device_actions.dart';
import '../core/phone_actions.dart';
import '../core/query_log.dart';
import '../mesh/mesh_service.dart';
import 'nexus_header.dart';
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
  /// The conversation: user bubbles and assistant cards, in order.
  final List<_ThreadEntry> _thread = [];
  late final CommandService _service;
  String? _pendingKey; // a clarification is open; the next input answers it
  String? _reply; // outcome shown on whichever plan card is open
  bool _sending = false;

  /// An open "who did you mean?" question after an unresolved contact.
  ({String phrase, List<String> candidates})? _pendingContactAsk;

  /// Runs real phone actions (dialing) on Android; elsewhere answers honestly.
  final PhoneActionBackend _phoneBackend = RealPhoneActionBackend();

  /// Runs the small device-local actions (alarms, timers, torch…).
  final DeviceActionBackend _deviceBackend = RealDeviceActionBackend();

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
      // On Android these run natively on THIS device from typed input alone.
      locallyExecutable: defaultTargetPlatform == TargetPlatform.android
          ? const {
              AgentActions.callPlace,
              AgentActions.alarmSet,
              AgentActions.timerSet,
              AgentActions.webSearch,
              AgentActions.navigationRoute,
              AgentActions.noteCreate,
              AgentActions.batteryGet,
              AgentActions.torchToggle,
              AgentActions.volumeSet,
            }
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
      // Teach once here, know it on every paired device: any locally taught
      // phrase is broadcast over the mesh so the other phones learn it too.
      onPhraseLearned: (phrase, meaning) {
        unawaited(widget.mesh.broadcastLearnedPhrase(phrase, meaning));
      },
    );
    // And the other direction — adopt phrases taught on paired devices, live
    // (not only after a restart).
    widget.mesh.onLearnedPhraseReceived = (phrase, meaning) {
      _service.adoptLearned(phrase, meaning);
    };
  }

  @override
  void dispose() {
    widget.mesh.onLearnedPhraseReceived = null;
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
    // Approval re-runs (Approve/Deny) update the card they belong to instead
    // of appending a new one — the exchange stays one bubble pair.
    bool replaceLast = false,
  }) {
    final result = _service.execute(
      input,
      approval: approval,
      // Unique per execution: the mesh matches the remote reply to this id.
      requestId: 'ui-${DateTime.now().microsecondsSinceEpoch}',
      answerTo: answerTo,
    );
    _logAsk(input, result);
    _consume(
      result,
      asUser: input.trim(),
      typedPhrase: input.trim().toLowerCase(),
      replaceLast: replaceLast,
    );
  }

  /// Every ask and its outcome lands in the query log — raw material for
  /// improving matching and catching bugs.
  void _logAsk(String input, AgentDispatchResult result) {
    final route = switch (result.dispatch) {
      final AgentActionPlan plan => plan.request.action,
      final AgentClarification ask => ask.key,
      final AgentMessage _ => 'message',
      _ => '',
    };
    QueryLog.i.ask(input.trim(), result.status.name, route, result.message);
  }

  /// Actions this device executes itself, straight after planning — typing
  /// "wake me at 7" sets a real alarm with zero extra taps.
  static const _selfRunActions = {
    AgentActions.callPlace,
    AgentActions.alarmSet,
    AgentActions.timerSet,
    AgentActions.webSearch,
    AgentActions.navigationRoute,
    AgentActions.noteCreate,
    AgentActions.batteryGet,
    AgentActions.torchToggle,
    AgentActions.volumeSet,
  };

  /// Appends to (or, for re-runs, updates the end of) the thread. No
  /// setState — callers own the rebuild.
  void _appendResult(AgentDispatchResult result, {String? asUser, bool replaceLast = false}) {
    if (replaceLast && _thread.isNotEmpty) {
      _thread[_thread.length - 1] = _ThreadEntry.result(result);
    } else {
      if (asUser != null && asUser.isNotEmpty) _thread.add(_ThreadEntry.user(asUser));
      _thread.add(_ThreadEntry.result(result));
    }
    _pendingKey = switch (result.dispatch) {
      final AgentClarification clarification => clarification.key,
      _ => null,
    };
  }

  /// Shows a dispatch result — and starts self-run actions right away.
  void _consume(AgentDispatchResult result, {String? asUser, String? typedPhrase, bool replaceLast = false}) {
    setState(() => _appendResult(result, asUser: asUser, replaceLast: replaceLast));
    if (result.dispatch case final AgentActionPlan plan
        when plan.request.target == widget.mesh.identity.id &&
            _selfRunActions.contains(plan.request.action)) {
      plan.request.action == AgentActions.callPlace
          ? unawaited(_placeLocalCall(plan.request, typedPhrase ?? ''))
          : unawaited(_runSelfAction(plan.request));
    }
  }

  Future<void> _runSelfAction(AgentRequest request) async {
    setState(() {
      _sending = true;
      _reply = null;
    });
    // Follow-up answers arrive as plain strings ('time': '7am') — parse them
    // into what the native side expects.
    final prepared = Map<String, dynamic>.of(request.arguments);
    if (request.action == AgentActions.alarmSet && prepared['hour'] == null) {
      final parsed =
          CommandInterpreter.parseClockTime(prepared['time']?.toString() ?? '');
      if (parsed == null) {
        _showSelfOutcome(false, 'I still need a time — like 7am or 18:30.');
        return;
      }
      prepared
        ..remove('time')
        ..['hour'] = parsed.$1
        ..['minute'] = parsed.$2;
    }
    if (request.action == AgentActions.timerSet && prepared['seconds'] is! int) {
      final seconds =
          CommandInterpreter.parseDurationSeconds(prepared['seconds']?.toString() ?? '');
      if (seconds == null) {
        _showSelfOutcome(false, 'How long should it run? Try "5 minutes".');
        return;
      }
      prepared['seconds'] = seconds;
    }
    final ActionResult outcome;
    if (request.action == AgentActions.noteCreate) {
      outcome = await _appendNote(prepared['text']?.toString() ?? '');
    } else {
      outcome = await _deviceBackend.run(request.action, prepared);
    }
    if (!mounted) return;
    _showSelfOutcome(outcome.ok, outcome.message);
  }

  void _showSelfOutcome(bool ok, String message) {
    setState(() {
      _sending = false;
      _appendResult(
        AgentDispatchResult(
          status: ok ? AgentResultStatus.succeeded : AgentResultStatus.unavailable,
          message: ok ? '' : message,
          dispatch: ok ? AgentMessage(message) : null,
        ),
        replaceLast: true,
      );
    });
  }

  Future<ActionResult> _appendNote(String text) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}${Platform.pathSeparator}nexus_notes.txt');
      await f.writeAsString(
        '${DateTime.now().toIso8601String()}  $text\n',
        mode: FileMode.append,
      );
      return const ActionResult(true, 'Noted.');
    } catch (_) {
      return const ActionResult(false, 'Could not save the note on this device.');
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
      QueryLog.i.call(contact, 'asked', candidates: outcome.candidates);
      final askPhrase = phrase.isNotEmpty ? phrase : 'call ${contact.toLowerCase()}';
      setState(() {
        _sending = false;
        _pendingContactAsk = (phrase: askPhrase, candidates: outcome.candidates);
        _appendResult(
          AgentDispatchResult(
            status: AgentResultStatus.needsInfo,
            dispatch: AgentClarification(
              question:
                  'I don\'t know "$contact" on this phone. Did you mean: ${outcome.candidates.join("  ·  ")}?',
              key: 'contact:$askPhrase',
              hint: 'Name one — I\'ll call them and remember this wording.',
            ),
          ),
          replaceLast: true,
        );
      });
      return;
    }
    QueryLog.i.call(
      contact,
      outcome.placed ? 'placed' : (outcome.launched ? 'dialer' : 'failed'),
    );
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
        _appendResult(
          AgentDispatchResult(
            status: AgentResultStatus.needsInfo,
            dispatch: AgentClarification(
              question:
                  'I don\'t see "${text.trim()}" here. Did you mean: ${ask.candidates.join("  ·  ")}?',
              key: 'contact:${ask.phrase}',
              hint: 'Name one of those, and I\'ll remember it.',
            ),
          ),
          replaceLast: true,
        );
      });
      return;
    }
    QueryLog.i.learned(ask.phrase, 'call $match');
    _consume(
      _service.learnAndRun(ask.phrase, 'call $match'),
      asUser: text,
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
    _execute(_lastInput, approval: AgentApproval.approved, replaceLast: true);
  }

  void _deny() {
    _execute(_lastInput, approval: AgentApproval.denied, replaceLast: true);
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
    QueryLog.i.remote(from, request.action, approve ? 'approved' : 'denied', request.arguments.toString());
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

  /// One-tap examples — for anyone who doesn't know what to type yet.
  Widget _suggestionChips() {
    const suggestions = [
      'what can you do',
      'what time is it',
      'how much battery',
      'set an alarm for 7am',
      'timer for 5 minutes',
      'flashlight on',
    ];
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          for (final s in suggestions)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ActionChip(
                label: Text(s, style: const TextStyle(fontSize: 12)),
                onPressed: () {
                  _controller.text = s;
                  _onSubmit();
                },
              ),
            ),
          // Room to scroll the last chip clear of the edge.
          const SizedBox(width: 16),
        ],
      ),
    );
  }

  /// First-run guidance: three steps, one screen, no jargon.
  Widget _welcomeView() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: NexusColors.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: NexusColors.accent.withValues(alpha: 0.35)),
          ),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Hello! I am Nexus.',
                style: TextStyle(color: NexusColors.text, fontWeight: FontWeight.w700, fontSize: 16),
              ),
              SizedBox(height: 10),
              Text(
                'Just type what you want, like you would say it:\n'
                '1. Try a blue word below — tap one and watch.\n'
                '2. "call …" dials right away; if I am not sure who,\n'
                '    I ask once and remember forever.\n'
                '3. Pair your other devices from the Devices tab — then\n'
                '    I can also do things on them for you.\n',
                style: TextStyle(color: NexusColors.muted, fontSize: 13, height: 1.45),
              ),
              Text(
                'If I ever misunderstand, tell me what you meant — I learn.',
                style: TextStyle(color: NexusColors.muted, fontSize: 13),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // One header for every tab.
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 24, 20, 0),
          child: NexusHeader(
            icon: Icons.forum_rounded,
            title: 'Assistant',
            subtitle: 'Type it like you\'d say it — I\'ll take care of it.',
          ),
        ),
        const SizedBox(height: 16),
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

        // One-tap examples under the input bar.
        _suggestionChips(),

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
    if (_thread.isEmpty && _incoming() == null) {
      return widget.mesh.pairedDevices.isEmpty ? _welcomeView() : _emptyChat();
    }

    final incoming = _incoming();
    // reverse:true is the chat pattern — the newest exchange pins to the
    // bottom automatically, and the incoming-request card (last child) stays
    // pinned at the top.
    final entries = _thread.reversed.toList();
    return ListView(
      reverse: true,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      children: [
        for (final (i, entry) in entries.indexed) ...[_entryView(entry, isLast: i == 0), const SizedBox(height: 12)],
        if (incoming != null) ...[_incomingRequestView(incoming), const SizedBox(height: 12)],
      ],
    );
  }

  /// One exchange in the thread: a user bubble, or an assistant card with its
  /// status chip (only on the newest exchange, so history stays calm).
  Widget _entryView(_ThreadEntry entry, {required bool isLast}) {
    if (entry.userText case final String user) {
      return Align(
        alignment: Alignment.centerRight,
        child: Semantics(
          container: true,
          label: 'You: $user',
          child: Container(
            constraints: const BoxConstraints(maxWidth: 320),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: NexusColors.accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: NexusColors.accent.withValues(alpha: 0.3)),
            ),
            child: Text(
              user,
              style: const TextStyle(color: NexusColors.text, fontSize: 13.5, height: 1.35),
            ),
          ),
        ),
      );
    }
    final result = entry.result!;
    return Semantics(
      container: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isLast) ...[_statusChip(result.status, result.message), const SizedBox(height: 12)],
          if (result.dispatch case final AgentDeviceList list) _deviceListView(list.devices),
          if (result.dispatch case final AgentActionPlan plan) _planView(plan),
          if (result.dispatch case final AgentMessage message)
            isLast && message.live ? _liveClockView() : _messageView(message),
          if (result.dispatch case final AgentClarification ask) _questionView(ask),
          if (isLast && result.status == AgentResultStatus.required) ...[
            const SizedBox(height: 12),
            _approvalBar(),
          ],
        ],
      ),
    );
  }

  /// A friendly prompt when devices are paired but nothing has been asked yet.
  Widget _emptyChat() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.forum_outlined, size: 44, color: NexusColors.muted),
            const SizedBox(height: 12),
            const Text(
              'Ask me anything — I listen and do.',
              textAlign: TextAlign.center,
              style: TextStyle(color: NexusColors.text, fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            const Text(
              'Type below, or tap a suggestion to try one.',
              textAlign: TextAlign.center,
              style: TextStyle(color: NexusColors.muted, fontSize: 13),
            ),
          ],
        ),
      ),
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
  }  @override
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

/// One exchange in the assistant conversation: either a user bubble or an
/// assistant card. Approval re-runs and self-run outcomes replace the last
/// entry instead of appending, so each exchange stays one bubble pair.
class _ThreadEntry {
  final String? userText;
  final AgentDispatchResult? result;

  _ThreadEntry.user(this.userText) : result = null;
  _ThreadEntry.result(this.result) : userText = null;
}
