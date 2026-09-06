import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../core/agent_contract.dart';
import '../core/command_service.dart';
import '../core/dream.dart';
import '../core/predictions.dart';
import '../core/query_log.dart';
import '../core/reminders.dart';
import '../core/speech.dart';
import '../mesh/mesh_service.dart';
import 'device_executor.dart';
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
  // — unless that input is itself a command (then the command wins and the
  // question is dropped, see _onSubmit).
  String? _reply; // outcome shown on whichever plan card is open
  bool _sending = false;

  /// Phrases from the dream log the assistant still fails on, loaded once
  /// after the first frame. When non-empty (and not dismissed) the assistant
  /// says so itself — its first proactive behavior, before being asked.
  List<DreamInsight>? _dreamGaps;
  List<DreamLearn>? _dreamLearns;
  bool _dreamDismissed = false;

  /// The phrases this user asks most (their habits), mined from the same
  /// log pass. When a real routine exists (asked twice or more) the static
  /// suggestion chips make way for these — the assistant predicting.
  List<Habit>? _habits;

  /// Promises to say something back later: this device's copy, mirrored
  /// into the store (a reminder set before a restart still fires) and fed
  /// by peers' reminders over the mesh. The engine owns the list, the
  /// ticking due-check and the one-shot fire; the view only renders.
  final ReminderEngine _reminderEngine = ReminderEngine();

  /// Whether the mic is listening right now (button becomes the live mic).
  bool _listening = false;

  /// An open "who did you mean?" question after an unresolved contact.

  /// Runs actions on this platform (apps, calls, texts, media…); the view
  /// only decides when to run them.
  final DeviceExecutor _executor = DeviceExecutor();

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
      // The set of actions this device can truly execute end to end: they
      // run immediately from typed input — no Approve/Deny prompt. One
      // definition ([_selfRunActions]) feeds both the service's gate and
      // this view's self-run routing.
      locallyExecutable: _selfRunActions,
      memory: AgentMemory(
        learned: widget.mesh.store.agentLearned,
        defaults: widget.mesh.store.agentDefaults,
        facts: widget.mesh.store.agentFacts,
      ),
      onMemoryChanged: () {
        widget.mesh.store.agentLearned = _service.learnedSnapshot;
        widget.mesh.store.agentDefaults = _service.defaultsSnapshot;
        widget.mesh.store.agentFacts = _service.factsSnapshot;
        // Best-effort persist — never a boot requirement.
        unawaited(widget.mesh.store.save());
      },
      // Teach once here, know it on every paired device: any locally taught
      // phrase is broadcast over the mesh so the other phones learn it too.
      onPhraseLearned: (phrase, meaning) {
        unawaited(widget.mesh.broadcastLearnedPhrase(phrase, meaning));
      },
      // Remember once here, known on every paired device: a fact told to
      // this assistant is broadcast over the mesh like a taught phrase.
      onFactLearned: (fact) {
        unawaited(widget.mesh.broadcastFact(fact));
      },
    );
    // And the other direction — adopt phrases taught on paired devices, live
    // (not only after a restart).
    widget.mesh.onLearnedPhraseReceived = (phrase, meaning) {
      _service.adoptLearned(phrase, meaning);
    };
    // And the other direction — adopt facts told to paired devices, live.
    widget.mesh.onFactReceived = (fact) {
      _service.adoptFact(fact);
    };

    // Reminders: this device's copy comes back from the store (a promise
    // made before a restart still fires), and peers' reminders arrive live.
    // The engine owns the state; the view wires the edges — persistence,
    // mesh broadcast, and the fired message in the thread.
    _reminderEngine
      ..onPersist = (list) {
        widget.mesh.store.agentReminders = [
          for (final r in list) jsonEncode(r.toJson()),
        ];
        unawaited(widget.mesh.store.save());
      }
      ..onBroadcast = (reminder) {
        unawaited(widget.mesh.broadcastReminder(jsonEncode(reminder.toJson())));
      }
      ..onFired = (reminder) {
        setState(() {
          _appendResult(
            AgentDispatchResult(
              status: AgentResultStatus.succeeded,
              dispatch: AgentMessage('Reminder: ${reminder.text}.'),
            ),
          );
        });
      }
      ..seed(widget.mesh.store.agentReminders);
    // Listen after seeding, so the engine's first notify can't setState
    // mid-initState.
    _reminderEngine.addListener(_onRemindersChanged);
    widget.mesh.onReminderReceived = _reminderEngine.adopt;
    // The assistant keeps its own promises: check every so often and fire
    // whatever's due — without anyone asking. The first check is deferred
    // a microtask (like the original async call) so a reminder that came
    // due while the app was closed fires on startup, after the frame.
    // Guarded: if the view is unmounted in the same frame, the engine is
    // already disposed by the time the microtask runs.
    _reminderEngine.start();
    unawaited(
      Future<void>.microtask(() {
        if (!mounted) return;
        _reminderEngine.check();
      }),
    );

    // The assistant's proactive behaviors: once the first frame is drawn,
    // read its own log — to know what it still fails on (the dream nudge)
    // and what you keep asking (personal predictions). Both before being
    // asked.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_refreshFromLog());
    });
  }

  @override
  void dispose() {
    widget.mesh.onLearnedPhraseReceived = null;
    widget.mesh.onFactReceived = null;
    widget.mesh.onReminderReceived = null;
    _reminderEngine.removeListener(_onRemindersChanged);
    _reminderEngine.dispose();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onRemindersChanged() => setState(() {});

  List<AgentDeviceSnapshot> _buildSnapshots() {
    final mesh = widget.mesh;
    final out = <AgentDeviceSnapshot>[];

    for (final d in mesh.pairedDevices) {
      out.add(
        AgentDeviceSnapshot(
          id: d.id,
          name: d.name,
          online: mesh.isOnline(d.id),
          capabilities: defaultCapabilitiesFor(d.platform),
        ),
      );
    }

    for (final d in mesh.serialDevices) {
      out.add(
        AgentDeviceSnapshot(
          id: d.id,
          name: d.name,
          online: d.online,
          capabilities: d.caps
              .where((c) => c == 'msg')
              .map((_) => const DeviceCapability(AgentActions.ledBlink))
              .toList(),
        ),
      );
    }

    for (final d in mesh.remoteSerialDevices) {
      out.add(
        AgentDeviceSnapshot(
          id: d.id,
          name: d.name,
          online: d.online,
          capabilities: d.caps
              .where((c) => c == 'msg')
              .map((_) => const DeviceCapability(AgentActions.ledBlink))
              .toList(),
        ),
      );
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
    // Every ask refines what the assistant predicts you'll ask next.
    unawaited(_refreshFromLog());
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
  /// "wake me at 7" sets a real alarm with zero extra taps. The ONE
  /// definition of "what this device can do end to end": passed to
  /// [CommandService] as `locallyExecutable` and used here to decide which
  /// plans/messages self-run. Android runs the catalog natively; the
  /// desktop runs what a Linux box can do.
  static const _selfRunActions = {
    AgentActions.webSearch,
    AgentActions.noteCreate,
    AgentActions.timerSet,
    AgentActions.openUrl,
    AgentActions.weatherGet,
    AgentActions.navOpen,
    AgentActions.locationGet,
    AgentActions.musicSearch,
    AgentActions.currencyGet,
    AgentActions.timezoneGet,
    AgentActions.calendarAdd,
    AgentActions.shoppingListAdd,
    AgentActions.shoppingListGet,
    AgentActions.emailSend,
    AgentActions.systemInfo,
    AgentActions.volumeSet,
    AgentActions.appOpen,
    AgentActions.appClose,
    AgentActions.screenshot,
    AgentActions.batteryGet,
    AgentActions.brightnessSet,
    AgentActions.flashlightToggle,
    AgentActions.wifiToggle,
    AgentActions.bluetoothToggle,
    AgentActions.lockScreen,
    AgentActions.callPlace,
    AgentActions.messageSend,
    AgentActions.mediaPlay,
    AgentActions.mediaPause,
    AgentActions.mediaNext,
    AgentActions.mediaPrev,
    AgentActions.mediaShuffle,
    AgentActions.mediaRepeat,
    AgentActions.alarmSet,
    AgentActions.defineWord,
  };

  /// Appends to (or, for re-runs, updates the end of) the thread. No
  /// setState — callers own the rebuild.
  void _appendResult(
    AgentDispatchResult result, {
    String? asUser,
    bool replaceLast = false,
  }) {
    if (replaceLast && _thread.isNotEmpty) {
      _thread[_thread.length - 1] = _ThreadEntry.result(result);
    } else {
      if (asUser != null && asUser.isNotEmpty)
        _thread.add(_ThreadEntry.user(asUser));
      _thread.add(_ThreadEntry.result(result));
    }
    _pendingKey = switch (result.dispatch) {
      final AgentClarification clarification => clarification.key,
      _ => null,
    };
  }

  /// Shows a dispatch result — and starts self-run actions right away.
  void _consume(
    AgentDispatchResult result, {
    String? asUser,
    String? typedPhrase,
    bool replaceLast = false,
  }) {
    setState(
      () => _appendResult(result, asUser: asUser, replaceLast: replaceLast),
    );
    // Path 1: A routed action plan targeting this device — e.g. ledBlink
    // resolved to a local serial device, or clipboardWrite.
    if (result.dispatch case final AgentActionPlan plan
        when plan.request.target == widget.mesh.identity.id &&
            _selfRunActions.contains(plan.request.action)) {
      unawaited(_runSelfAction(plan.request));
    }
    // Path 3: An approved plan aimed at a PAIRED device (a call or text
    // this device can't run, offered to the phone that can). The device
    // question already got the user's consent, so it sends itself and shows
    // the remote's outcome in the plan card; the paired device re-gates the
    // request on its own side. Blink and clipboard keep their dedicated
    // paths (they target serial nodes, not mesh devices).
    if (result.dispatch case final AgentActionPlan plan
        when plan.request.target.isNotEmpty &&
            plan.request.target != widget.mesh.identity.id &&
            plan.request.approval == AgentApproval.approved &&
            plan.request.action != AgentActions.ledBlink &&
            plan.request.action != AgentActions.clipboardWrite) {
      unawaited(_sendAgentRequest(plan.request));
    }
    // Path 2: A message with an attached action — these come from
    // _localAnswer() for webSearch, noteCreate, timerSet, openUrl,
    // systemInfo, volumeSet. The message is shown immediately and the
    // side-effect (open browser, save note, etc.) runs in the background.
    // A reminder card is different: it registers the promise with this
    // device's reminder engine (which fires later, on its own) instead of
    // running an executor stub.
    if (result.dispatch case final AgentMessage message
        when message.action == AgentActions.reminderSet) {
      final dueAt = DateTime.tryParse(
        message.arguments?['dueAt']?.toString() ?? '',
      );
      final text = message.arguments?['text']?.toString() ?? '';
      if (dueAt != null && text.isNotEmpty) {
        _reminderEngine.register(text, dueAt);
      }
    }
    if (result.dispatch case final AgentMessage message
        when message.action != null &&
            _selfRunActions.contains(message.action)) {
      unawaited(
        _runSelfAction(
          AgentRequest(
            requestId: 'ui-${DateTime.now().microsecondsSinceEpoch}',
            target: widget.mesh.identity.id,
            action: message.action!,
            arguments: message.arguments ?? const {},
          ),
        ),
      );
    }
  }

  Future<void> _runSelfAction(AgentRequest request) async {
    setState(() {
      _sending = true;
      _reply = null;
    });
    final outcome = await _executor.run(request);
    if (!mounted) return;
    _showSelfOutcome(outcome.ok, outcome.message);
  }

  /// One utterance, then the recognized words run through the same pipeline
  /// as typing them — the "command based" assistant, spoken. Devices without
  /// a speech service answer honestly instead of pretending to listen.
  Future<void> _listen() async {
    final speech = SpeechInput.current;
    if (!speech.available) {
      setState(
        () => _appendResult(
          AgentDispatchResult(
            status: AgentResultStatus.succeeded,
            dispatch: const AgentMessage(
              'Voice input isn\'t set up on this device yet — type it, or '
              'tap one of the example chips below.',
            ),
          ),
        ),
      );
      return;
    }
    setState(() => _listening = true);
    final heard = await speech.listen();
    if (!mounted) return;
    setState(() => _listening = false);
    final text = heard?.trim() ?? '';
    if (text.isEmpty) {
      setState(
        () => _appendResult(
          const AgentDispatchResult(
            status: AgentResultStatus.succeeded,
            dispatch: AgentMessage(
              'I didn\'t catch that — could you say it again?',
            ),
          ),
        ),
      );
      return;
    }
    _controller.text = text;
    _onSubmit();
  }

  void _showSelfOutcome(bool ok, String message) {
    setState(() {
      _sending = false;
      _appendResult(
        AgentDispatchResult(
          status: ok
              ? AgentResultStatus.succeeded
              : AgentResultStatus.unavailable,
          message: ok ? '' : message,
          dispatch: ok ? AgentMessage(message) : null,
        ),
        replaceLast: true,
      );
    });
  }

  void _onSubmit() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    HapticFeedback.selectionClick();
    _lastInput = text;
    _controller.clear();
    final pending = _pendingKey;
    // A clarification is open. The next input answers it — UNLESS it is
    // itself a command: the user moved on, so the new request runs and the
    // stale question is dropped instead of silently swallowing the command
    // ("call mom" must never be learned as the meaning of "open deezer").
    if (pending != null && !_service.parsesAsCommand(text)) {
      _execute(text, answerTo: pending);
    } else {
      if (pending != null) _service.cancelPending(pending);
      _execute(text);
    }
  }

  void _approve() {
    HapticFeedback.lightImpact();
    _execute(_lastInput, approval: AgentApproval.approved, replaceLast: true);
  }

  void _deny() {
    HapticFeedback.selectionClick();
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
    final deviceName =
        _buildSnapshots()
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
  Future<void> _handleIncoming(
    AgentRequest request,
    String from,
    bool approve,
  ) async {
    QueryLog.i.remote(
      from,
      request.action,
      approve ? 'approved' : 'denied',
      request.arguments.toString(),
    );
    final AgentDispatchResult result;
    if (!approve) {
      result = _service.handleRemoteRequest(
        request,
        approval: AgentApproval.denied,
      );
    } else if (_selfRunActions.contains(request.action)) {
      // Actions this device can genuinely run get executed here; everything
      // else answers honestly via the service's catalog.
      final outcome = await _executor.run(request);
      result = AgentDispatchResult(
        status: outcome.ok
            ? AgentResultStatus.succeeded
            : AgentResultStatus.unavailable,
        message: outcome.message,
        dispatch: outcome.ok ? AgentMessage(outcome.message) : null,
      );
    } else {
      result = _service.handleRemoteRequest(
        request,
        approval: AgentApproval.approved,
      );
    }
    final delivered = await widget.mesh.sendAgentResult(
      from,
      request.requestId,
      result,
    );
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
    // Personal prediction: when this user keeps asking the same phrases,
    // the generic suggestions make way for their own habits. A real habit
    // means asked more than once — a single ask is not a routine yet.
    final habits = _habits;
    final personal = habits == null || habits.every((h) => h.count < 2)
        ? null
        : habits.where((h) => h.count >= 2).take(4).toList();
    final suggestions =
        personal?.map((h) => h.phrase).toList() ??
        const [
          'what can you do',
          'what time is it',
          'what do you know about me',
          'what is the weather in paris',
          'take me home',
          'play my playlist',
          'open youtube',
          'call mom',
          'email mom',
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
            border: Border.all(
              color: NexusColors.accent.withValues(alpha: 0.35),
            ),
          ),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Hello! I am Nexus.',
                style: TextStyle(
                  color: NexusColors.text,
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
              SizedBox(height: 10),
              Text(
                'Just type what you want, like you would say it:\n'
                '1. Try a blue word below — tap one and watch.\n'
                '2. "call …" dials right away; if I am not sure who,\n'
                '    I ask once and remember forever.\n'
                '3. "remember that …" saves a fact I keep for you:\n'
                '    ask "what do you know about me" anytime.\n'
                '4. Pair your other devices from the Devices tab — then\n'
                '    I can also do things on them for you.\n',
                style: TextStyle(
                  color: NexusColors.muted,
                  fontSize: 13,
                  height: 1.45,
                ),
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

  /// Opens the dream review: phrases the assistant had to give up on,
  /// straight from its own log. Teaching one closes that gap forever.
  Future<void> _showDreamReview(BuildContext context) async {
    final lines = await QueryLog.i.readAll();
    if (!context.mounted) return;
    final insights = const DreamPass().unknownPhrases(
      lines,
      exclude: {..._service.learnedSnapshot.keys},
    );
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: NexusColors.bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetContext) =>
          _DreamSheet(service: _service, insights: insights),
    );
    // Teaching inside the sheet closes gaps — refresh so the nudge
    // disappears without a restart when everything is understood.
    await _refreshFromLog();
  }

  /// Reads the ask log once and updates both proactive surfaces from it:
  /// the phrases the assistant still fails on (the dream nudge) and the
  /// phrases this user asks most (personal predictions). Called after the
  /// first frame, when the dream review closes, and after every ask;
  /// [setState] only when the picture changed, so idle starts cost one
  /// rebuild at most.
  Future<void> _refreshFromLog() async {
    final lines = await QueryLog.i.readAll();
    if (!mounted) return;
    final gaps = const DreamPass().unknownPhrases(
      lines,
      exclude: {..._service.learnedSnapshot.keys},
    );
    // The dream also finds fixes on its own: a phrase the user kept
    // re-asking that maps onto a phrase they have since taught.
    final learns = const DreamPass().learnable(
      lines,
      learned: _service.learnedSnapshot,
    );
    final habits = const Predictions().habits(lines);
    final changed =
        gaps.length != (_dreamGaps?.length ?? 0) ||
        learns.length != (_dreamLearns?.length ?? 0) ||
        habits.length != (_habits?.length ?? 0) ||
        gaps.any(
          (g) => !(_dreamGaps ?? const []).any((o) => o.phrase == g.phrase),
        ) ||
        learns.any(
          (l) => !(_dreamLearns ?? const []).any((o) => o.phrase == l.phrase),
        ) ||
        habits.any(
          (h) => !(_habits ?? const []).any((o) => o.phrase == h.phrase),
        );
    if (!changed) return;
    setState(() {
      _dreamGaps = gaps;
      _dreamLearns = learns;
      _habits = habits;
    });
  }

  /// Saves the promise locally (persisted), tells every paired device so it
  /// fires wherever the user is, and starts watching for its time. The
  /// catalog already said "Reminder set for …" — this is the doing part.
  /// The reminder that fired, waiting for a "Done" — sits above the
  /// composer like the nudge, never hiding a reply.
  Widget _reminderBanner() {
    final reminder = _reminderEngine.fired;
    if (reminder == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      child: Container(
        key: const ValueKey('reminder-banner'),
        padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
        decoration: BoxDecoration(
          color: NexusColors.accent.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: NexusColors.accent.withValues(alpha: 0.4),
          ),
        ),
        child: Row(
          children: [
            const Icon(Icons.alarm_rounded, size: 18, color: NexusColors.accent),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Reminder: ${reminder.text}',
                style: const TextStyle(
                  color: NexusColors.text,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Done',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.check_rounded, size: 18),
              color: NexusColors.ok,
              onPressed: _reminderEngine.acknowledge,
            ),
          ],
        ),
      ),
    );
  }

  /// A once-per-session nudge above the composer: the assistant noticed it
  /// still fails on something you asked (its dream log) and offers to be
  /// taught. Tapping opens the same review as the header button; the X
  /// silences it for this session.
  /// The dream's self-improvement in one tap: the user's own teaching,
  /// applied to the variant they keep typing — validated, persisted, and
  /// broadcast to every paired device by the service's normal teach funnel.
  void _dreamLearn(DreamLearn learn) {
    setState(() => _dreamDismissed = true);
    _consume(_service.learn(learn.phrase, learn.meaning));
    unawaited(_refreshFromLog());
  }

  /// The specific beats the generic: when the dream found a fix, offer it
  /// instead of the plain "teach me?" nudge.
  Widget _dreamLearnCard(DreamLearn learn) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 12, 0),
      child: Material(
        color: Colors.transparent,
        child: Container(
          key: const ValueKey('dream-learn-card'),
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          decoration: BoxDecoration(
            color: NexusColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: NexusColors.border),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.auto_awesome_rounded,
                size: 16,
                color: NexusColors.accent,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'You tried "${learn.phrase}" a few times — I think you '
                  'meant "${learn.source}". Want me to remember that?',
                  style: const TextStyle(
                    color: NexusColors.text,
                    fontSize: 13,
                  ),
                ),
              ),
              TextButton(
                key: const ValueKey('dream-learn-button'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () => _dreamLearn(learn),
                child: const Text('Learn it'),
              ),
              IconButton(
                tooltip: 'Not now',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close_rounded, size: 16),
                color: NexusColors.muted,
                onPressed: () => setState(() => _dreamDismissed = true),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dreamNudge() {
    if (_dreamDismissed) return const SizedBox.shrink();
    final learns = _dreamLearns;
    if (learns != null && learns.isNotEmpty) {
      return _dreamLearnCard(learns.first);
    }
    final gaps = _dreamGaps;
    if (gaps == null || gaps.isEmpty) {
      return const SizedBox.shrink();
    }
    final message = gaps.length == 1
        ? 'I still don\'t understand "${gaps.first.phrase}" — teach me?'
        : 'I still don\'t get ${gaps.length} things you asked — teach me?';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 12, 0),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: const ValueKey('dream-nudge'),
          borderRadius: BorderRadius.circular(12),
          onTap: () => unawaited(_showDreamReview(context)),
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            decoration: BoxDecoration(
              color: NexusColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: NexusColors.border),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.auto_awesome_rounded,
                  size: 16,
                  color: NexusColors.accent,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    message,
                    style: const TextStyle(
                      color: NexusColors.text,
                      fontSize: 13,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Not now',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close_rounded, size: 16),
                  color: NexusColors.muted,
                  onPressed: () => setState(() => _dreamDismissed = true),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // One header for every tab — plus the assistant's own dream review:
        // what it failed to understand, mined from its log, fixable in place.
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 12, 0),
          child: Row(
            children: [
              const Expanded(
                child: NexusHeader(
                  icon: Icons.forum_rounded,
                  title: 'Assistant',
                  subtitle:
                      'Type it like you\'d say it — I\'ll take care of it.',
                ),
              ),
              IconButton(
                tooltip: 'What I still misunderstand',
                icon: const Icon(Icons.psychology_alt_outlined),
                color: NexusColors.muted,
                onPressed: () => unawaited(_showDreamReview(context)),
              ),
            ],
          ),
        ),
        // Proactive nudge: gaps the dream log found, surfaced without being
        // asked. Sits above the composer so it never hides a reply.
        _dreamNudge(),
        // A reminder that fired, waiting for a "Done".
        _reminderBanner(),
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
                        ? 'Ask anything — "what is the weather", "take me home"…'
                        : 'Answer the question — or type a new command',
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                  ),
                  style: const TextStyle(color: NexusColors.text, fontSize: 14),
                ),
              ),
              IconButton(
                tooltip: _listening ? 'Listening…' : 'Speak your question',
                icon: Icon(
                  _listening ? Icons.mic_rounded : Icons.mic_none_rounded,
                  size: 20,
                  color: _listening ? NexusColors.accent : NexusColors.muted,
                ),
                onPressed: _listening ? null : () => unawaited(_listen()),
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
        for (final (i, entry) in entries.indexed) ...[
          _entryView(entry, isLast: i == 0),
          const SizedBox(height: 12),
        ],
        if (incoming != null) ...[
          _incomingRequestView(incoming),
          const SizedBox(height: 12),
        ],
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
              border: Border.all(
                color: NexusColors.accent.withValues(alpha: 0.3),
              ),
            ),
            child: Text(
              user,
              style: const TextStyle(
                color: NexusColors.text,
                fontSize: 13.5,
                height: 1.35,
              ),
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
          if (isLast) ...[
            _statusChip(result.status, result.message),
            const SizedBox(height: 12),
          ],
          if (result.dispatch case final AgentDeviceList list)
            _deviceListView(list.devices),
          if (result.dispatch case final AgentActionPlan plan) _planView(plan),
          if (result.dispatch case final AgentMessage message)
            isLast && message.live ? _liveClockView() : _messageView(message),
          if (result.dispatch case final AgentClarification ask)
            _questionView(ask),
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
            const Icon(
              Icons.forum_outlined,
              size: 44,
              color: NexusColors.muted,
            ),
            const SizedBox(height: 12),
            const Text(
              'Ask me anything — I listen and do.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: NexusColors.text,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
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
    final fromName =
        widget.mesh.pairedDevices
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
              const Icon(
                Icons.notification_important_rounded,
                size: 18,
                color: NexusColors.warn,
              ),
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
                  onPressed: () =>
                      _handleIncoming(request, incoming.from, true),
                  child: const Text('Approve'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton(
                  onPressed: () =>
                      _handleIncoming(request, incoming.from, false),
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
                  style: const TextStyle(
                    color: NexusColors.text,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
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
          child: Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (message.isNotEmpty) ...[
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: NexusColors.muted, fontSize: 12),
            ),
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
              const Icon(
                Icons.help_outline_rounded,
                size: 18,
                color: NexusColors.warn,
              ),
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
          if (ask.hint != null) ...[
            const SizedBox(height: 6),
            Text(
              ask.hint!,
              style: const TextStyle(color: NexusColors.muted, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }

  Widget _deviceListView(List<AgentDeviceSnapshot> devices) {
    if (devices.isEmpty) {
      return const Text(
        'No devices found.',
        style: TextStyle(color: NexusColors.muted),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: devices
          .map(
            (d) => Padding(
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
                        style: const TextStyle(
                          color: NexusColors.text,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      d.id,
                      style: const TextStyle(
                        color: NexusColors.muted,
                        fontSize: 11,
                      ),
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
            ),
          )
          .toList(),
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
    if (request.action != AgentActions.ledBlink) {
      return _remotePlanView(request);
    }
    final snapshot = _buildSnapshots();
    final target = snapshot.where((d) => d.id == request.target).firstOrNull;

    return _planCard(
      Icons.bolt_rounded,
      'Blink ${target?.name ?? request.target}',
      [
        const SizedBox(height: 6),
        Text(
          'Target: ${request.target} · Action: ${request.action}',
          style: const TextStyle(color: NexusColors.muted, fontSize: 11),
        ),
        const SizedBox(height: 10),
        FilledButton.icon(
          onPressed: () =>
              _sendBlink(request.target, target?.name ?? request.target),
          icon: const Icon(Icons.bolt_rounded, size: 16),
          label: const Text('Send blink now'),
        ),
      ],
    );
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
      if (_reply != null) ...[
        const SizedBox(height: 10),
        _remoteReplyView(_reply!),
      ],
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
        color: (failed ? NexusColors.danger : NexusColors.ok).withValues(
          alpha: 0.1,
        ),
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
      case AgentActions.timerSet:
        return 'Set a timer';
      case AgentActions.webSearch:
        return 'Search for ${a['query']}';
      case AgentActions.noteCreate:
        return 'Make a note';
      case AgentActions.openUrl:
        return 'Open ${a['url']}';
      case AgentActions.systemInfo:
        return 'Show system info';
      case AgentActions.volumeSet:
        return 'Volume ${a['mode']}';
      case AgentActions.ledBlink:
        final target = a['target']?.toString() ?? request.target;
        return 'Blink $target';
      case AgentActions.clipboardWrite:
        final text = (a['text']?.toString() ?? '').replaceAll('\n', ' ');
        final preview = text.length > 40 ? '${text.substring(0, 40)}…' : text;
        return 'Copy "$preview"';
      case AgentActions.greet:
        return 'Say hello';
      case AgentActions.timeGet:
        return 'What time is it?';
      case AgentActions.mathCalc:
        return 'Calculate ${a['expr']}';
      case AgentActions.helpGet:
        return 'What can you do?';
      case AgentActions.deviceList:
        return 'List devices';
      case AgentActions.appOpen:
        return 'Open ${a['query']}';
      case AgentActions.appClose:
        return 'Close ${a['query']}';
      case AgentActions.screenshot:
        return 'Take a screenshot';
      case AgentActions.batteryGet:
        return 'Check battery';
      case AgentActions.brightnessSet:
        return 'Adjust brightness';
      case AgentActions.flashlightToggle:
        return 'Toggle flashlight';
      case AgentActions.wifiToggle:
        return 'Toggle WiFi';
      case AgentActions.bluetoothToggle:
        return 'Toggle Bluetooth';
      case AgentActions.lockScreen:
        return 'Lock screen';
      case AgentActions.callPlace:
        if (a['mode'] == 'video') {
          final app = a['app']?.toString();
          return app == null
              ? 'Video call ${a['contact']}'
              : 'Video call ${a['contact']} on $app';
        }
        return 'Call ${a['contact']}';
      case AgentActions.messageSend:
        return 'Text ${a['contact']}';
      case AgentActions.mediaPlay:
        return 'Play music';
      case AgentActions.mediaPause:
        return 'Pause music';
      case AgentActions.mediaNext:
        return 'Next track';
      case AgentActions.mediaPrev:
        return 'Previous track';
      case AgentActions.mediaShuffle:
        return 'Toggle shuffle';
      case AgentActions.mediaRepeat:
        return 'Toggle repeat';
      case AgentActions.alarmSet:
        return 'Set an alarm';
      case AgentActions.defineWord:
        return 'Define ${a['word']}';
      case AgentActions.translateText:
        return 'Translate';
      case AgentActions.unitConvert:
        return 'Convert units';
      case AgentActions.randomDice:
        return 'Roll a dice';
      case AgentActions.randomCoin:
        return 'Flip a coin';
      case AgentActions.randomNumber:
        return 'Pick a random number';
      case AgentActions.tellJoke:
        return 'Tell a joke';
      case AgentActions.findDevice:
        return 'Find ${request.target}';
      case AgentActions.ringDevice:
        return 'Ring ${request.target}';
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
        style: const TextStyle(
          color: NexusColors.text,
          fontSize: 13,
          height: 1.4,
        ),
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
      style: const TextStyle(
        color: NexusColors.text,
        fontSize: 16,
        fontWeight: FontWeight.w600,
      ),
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

/// The dream review: phrases the assistant gave up on, mined from its own
/// log, each teachable in place. One taught phrase closes that gap forever.
class _DreamSheet extends StatefulWidget {
  final CommandService service;
  final List<DreamInsight> insights;

  const _DreamSheet({required this.service, required this.insights});

  @override
  State<_DreamSheet> createState() => _DreamSheetState();
}

class _DreamSheetState extends State<_DreamSheet> {
  // phrase -> the command it was just taught to mean, so the row can show
  // the outcome instead of waiting for a rebuild from the parent.
  final _taught = <String, String>{};

  @override
  Widget build(BuildContext context) {
    final open = widget.insights
        .where((i) => !_taught.containsKey(i.phrase))
        .toList(growable: false);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.psychology_alt_outlined,
                  color: NexusColors.accent,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'What I still misunderstand',
                    style: const TextStyle(
                      color: NexusColors.text,
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              widget.insights.isEmpty
                  ? 'Nothing yet — I understood everything you asked.'
                  : 'Things you asked that I had to give up on. Teach one and I never fail it again.',
              style: const TextStyle(color: NexusColors.muted, fontSize: 12.5),
            ),
            const SizedBox(height: 14),
            if (widget.insights.isEmpty)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  'Sweet dreams.',
                  style: TextStyle(color: NexusColors.muted, fontSize: 13),
                ),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: open.length,
                  itemBuilder: (context, index) => _DreamRow(
                    service: widget.service,
                    phrase: open[index].phrase,
                    count: open[index].count,
                    onTaught: (cmd) {
                      setState(() => _taught[open[index].phrase] = cmd);
                    },
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

typedef _DreamRowCallback = void Function(String meaning);

class _DreamRow extends StatefulWidget {
  final CommandService service;
  final String phrase;
  final int count;
  final _DreamRowCallback onTaught;

  const _DreamRow({
    required this.service,
    required this.phrase,
    required this.count,
    required this.onTaught,
  });

  @override
  State<_DreamRow> createState() => _DreamRowState();
}

class _DreamRowState extends State<_DreamRow> {
  final _controller = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _teach() async {
    final meaning = _controller.text.trim();
    if (meaning.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    // Answering UI only: the service validates the meaning and persists via
    // its own callbacks. Nothing executes from a review sheet.
    final result = widget.service.learn(widget.phrase, meaning);
    if (!mounted) return;
    if (result.status == AgentResultStatus.needsInfo) {
      setState(() {
        _busy = false;
        _error = result.message;
      });
      return;
    }
    // The sheet rebuilds without this row — that is the outcome.
    widget.onTaught(meaning.toLowerCase().trim());
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '"${widget.phrase}"  ·  asked ${widget.count} '
            '${widget.count == 1 ? 'time' : 'times'}',
            style: const TextStyle(color: NexusColors.text, fontSize: 13.5),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('dream-meaning'),
                  controller: _controller,
                  onSubmitted: (_) => _teach(),
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'means… e.g. "show my devices"',
                    border: OutlineInputBorder(),
                  ),
                  style: const TextStyle(color: NexusColors.text, fontSize: 13),
                ),
              ),
              IconButton(
                tooltip: 'Teach',
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check_rounded),
                color: NexusColors.accent,
                onPressed: _teach,
              ),
            ],
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _error!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}
