import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart' show CupertinoActionSheetAction;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, HapticFeedback;

import '../core/agent_contract.dart';
import '../core/brain.dart';
import '../core/capability.dart';
import '../core/command_service.dart';
import '../core/conversation.dart';
import '../core/conversation_engine.dart';
import '../core/device_actions.dart';
import '../core/distributed_brain.dart';
import '../core/dream.dart';
import '../core/predictions.dart';
import '../core/profile.dart';
import '../core/query_log.dart';
import '../core/reminders.dart';
import '../core/skills.dart';
import '../core/speech.dart';
import '../mesh/mesh_service.dart';
import 'components/nexus_ui.dart';
import 'device_executor.dart';
import 'nexus_core.dart';
import 'theme.dart';

/// The assistant is a translator from human to machine: it asks when it
/// doesn't understand, and remembers what you taught it. This service is kept
/// alive for the whole view so questions and answers share one memory.

class AssistantView extends StatefulWidget {
  final MeshService mesh;

  /// The optional local language-model brain (Ollama). When present, phrases
  /// the command interpreter doesn't understand get a real conversational
  /// reply instead of the teach card; when absent (or offline) the classic
  /// teach flow stays. Null on platforms with no local model support yet.
  final LocalBrain? brain;

  /// The real device executor by default. Injectable for the same reason
  /// [brain] is: the one path a widget test cannot otherwise drive is an
  /// action that fails by throwing, and that path decides whether the core's
  /// "working" state can be stranded.
  final DeviceExecutor? executor;

  const AssistantView({
    super.key,
    required this.mesh,
    this.brain,
    this.executor,
  });

  @override
  State<AssistantView> createState() => AssistantViewState();
}

/// Public so the shell can hold a key to it: Settings' "What I still
/// misunderstand" row opens a sheet this screen owns, and handing the sheet a
/// second service is the one thing that would let the two disagree about what
/// this device learned.
class AssistantViewState extends State<AssistantView> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  String _lastInput = '';

  /// The system this device is, in the registry's own vocabulary — the string
  /// the mesh advertises and every platform set is written in. One fact, read
  /// from the device's own identity, that filters every word this screen shows
  /// a user: a chip or a hint may only name what this platform really runs.
  String get _platform => widget.mesh.identity.platform;

  /// The conversation engine: owns the thread (user bubbles and assistant
  /// cards), the brain-exchange state machine, and the brain's health. The
  /// view renders from it and never mutates the thread directly.
  final ConversationEngine _conversation = ConversationEngine();
  late final CommandService _service;
  String? _reply; // outcome shown on whichever plan card is open
  bool _sending = false;

  /// The phrases this user asks most (their habits), mined from the same
  /// log pass. When a real routine exists (asked twice or more) the static
  /// suggestion chips make way for these — the assistant predicting.
  List<Habit>? _habits;

  /// The skills this user genuinely uses (their loop), ranked from the same
  /// log pass. Drives the one-tap chips and the brain's context: Nexus gets
  /// visibly better at what matters to this person.
  List<SkillUse>? _skills;

  /// Promises to say something back later: this device's copy, mirrored
  /// into the store (a reminder set before a restart still fires) and fed
  /// by peers' reminders over the mesh. The engine owns the list, the
  /// ticking due-check and the one-shot fire; the view only renders.
  final ReminderEngine _reminderEngine = ReminderEngine();

  /// Whether the mic is listening right now (button becomes the live mic).
  bool _listening = false;

  /// Whether we are waiting on the brain's reply for a phrase the interpreter
  /// did not know. Set by the view around the exchange it started, so the core
  /// reports thinking from the only place that knows an exchange is in flight.
  bool _brainThinking = false;

  /// Whether this device has already held a conversation. The welcome card is
  /// first-run content, so an emptied thread means "ready for your next
  /// question" once a thread has existed — which is what makes the header's
  /// New-conversation control return to the neutral empty chat instead of the
  /// greeting the user has already read.
  bool _everConversed = false;

  /// Whether the input currently being processed came from the mic. Voice
  /// contact actions (call/text/email) are confirmed by a spoken yes/no;
  /// typed ones run directly.
  bool _lastInputWasVoice = false;

  /// Contact actions that get a voice confirmation before running.
  static const _voiceConfirmActions = {
    AgentActions.callPlace,
    AgentActions.messageSend,
    AgentActions.emailSend,
  };

  /// A voice-triggered contact action awaiting a spoken yes/no.
  ({AgentRequest request, String question})? _voiceConfirm;

  /// An unresolved contact with near matches — "who did you mean?" is open
  /// and a yes/no answer (plus learning) is pending.
  ({AgentRequest request, List<String> candidates})? _contactConfirm;

  /// An open "who did you mean?" question after an unresolved contact.

  /// Runs actions on this platform (apps, calls, texts, media…); the view
  /// only decides when to run them.
  late final DeviceExecutor _executor = _executorWithProgress();

  /// The executor plus this view as its live-progress reporter — attached to
  /// an injected executor too, so the wiring a widget test drives is exactly
  /// the wiring the app uses.
  DeviceExecutor _executorWithProgress() {
    final executor =
        widget.executor ??
        DeviceExecutor(
          fileMesh: widget.mesh,
          // Android only, and only while "All files access" is off: a fetch
          // stops to offer the toggle instead of silently saving somewhere the
          // Files app hides. Declining is fine — the fetch runs either way.
          fileAccessPrompt: _askForFileAccess,
        );
    executor.fileFetchProgress = _noteFetchProgress;
    return executor;
  }

  /// The live line for an in-flight fetch, or null when none is running. It
  /// replaces the generic "working" chip while a pull is actually moving
  /// bytes, so a big file shows it is arriving instead of looking stuck.
  String? _fetchProgress;

  /// The user's profile: names and first-run state, persisted per device.
  final ProfileStore _profile = SharedPrefsProfileStore();
  UserProfile? _profileState;
  bool _profileLoaded = false;

  /// First-run setup form state.
  final TextEditingController _onboardName = TextEditingController();
  final TextEditingController _onboardAssistant = TextEditingController();
  final Map<String, bool?> _onboardPerms = {}; // action -> granted/denied/null

  /// The in-flow "All files access" ask, shown when a fetch is about to save
  /// into Nexus's own folder on Android — the one the Files app hides. Either
  /// answer lets the fetch continue; "Open settings" just jumps to the toggle.
  Future<void> _askForFileAccess() async {
    if (!mounted) return;
    final openSettings = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save to Downloads?'),
        content: const Text(
          'Nexus needs file access to save downloads to your Downloads folder.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Open settings'),
          ),
        ],
      ),
    );
    if (openSettings == true) {
      await MeshService.openAllFilesAccessSettings();
    }
  }

  /// Records one progress report from a running fetch. The executor hands
  /// over a finished line (see [FileFetchWords.progress]) so the view stays a
  /// renderer: nothing here knows about chunks, bytes or the mesh.
  void _noteFetchProgress(String label) {
    if (!mounted || label == _fetchProgress) return;
    setState(() => _fetchProgress = label);
  }

  @override
  void initState() {
    super.initState();
    // The conversation engine notifies on every thread/brain change; the
    // view rebuilds from it, exactly as its own setState used to.
    _conversation.addListener(_onConversationChanged);
    _service = CommandService(
      devices: _buildSnapshots,
      local: AgentDeviceSnapshot(
        id: widget.mesh.identity.id,
        name: widget.mesh.identity.name,
        online: true,
        capabilities: defaultCapabilitiesFor(widget.mesh.identity.platform),
        platform: widget.mesh.identity.platform,
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
        // Where the taught phrases and remembered preferences came from, with
        // a legacy stamp filled in for anything stored before this existed.
        ledger: widget.mesh.store.agentLedger,
      ),
      onMemoryChanged: () {
        widget.mesh.store.agentLearned = _service.learnedSnapshot;
        widget.mesh.store.agentDefaults = _service.defaultsSnapshot;
        widget.mesh.store.agentFacts = _service.memoryFacts;
        widget.mesh.store.agentLedger = _service.ledgerSnapshot;
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
      // Answer a "which …?" question here, remembered on every paired
      // device: one pick is one pick everywhere.
      onDefaultLearned: (key, value) {
        unawaited(widget.mesh.broadcastDefault(key, value));
      },
    );
    // And the other direction — adopt phrases taught on paired devices, live
    // (not only after a restart). The peer that sent it is recorded as the
    // source, so the memory says where it came from rather than "a device".
    widget.mesh.onLearnedPhraseReceived = (phrase, meaning, [from = '']) {
      _service.adoptLearned(phrase, meaning, from: from);
    };
    // And the other direction — adopt facts told to paired devices, live.
    widget.mesh.onFactReceived = (fact, [from = '']) {
      _service.adoptFact(fact, from: from);
    };
    // And the other direction — adopt "which …?" answers from paired
    // devices, live (a local answer wins).
    widget.mesh.onDefaultReceived = (key, value, [from = '']) {
      _service.adoptDefault(key, value, from: from);
    };
    // And a rename on any device is a rename everywhere: the profile names
    // travel the mesh like taught phrases do.
    widget.mesh.onProfileReceived = (userName, assistantName) {
      unawaited(_adoptRemoteProfile(userName, assistantName));
    };

    // First-run profile: names + onboarded flag, loaded after the first
    // frame so the welcome card can become a real setup flow.
    unawaited(_loadProfile());

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
        _conversation.appendResult(
          AgentDispatchResult(
            status: AgentResultStatus.succeeded,
            dispatch: AgentMessage('Reminder: ${reminder.text}.'),
          ),
        );
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

    // The assistant's one proactive behavior: once the first frame is
    // drawn, read its own log to know what you keep asking (personal
    // predictions), before being asked.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_refreshFromLog());
    });

    // The local brain: find out once, on start, whether a model is installed
    // — the status line tells the user how to enable real conversations.
    final brain = widget.brain;
    if (brain != null) {
      unawaited(_conversation.probe(brain));
    }
  }

  @override
  void dispose() {
    widget.mesh.onLearnedPhraseReceived = null;
    widget.mesh.onFactReceived = null;
    widget.mesh.onDefaultReceived = null;
    widget.mesh.onProfileReceived = null;
    widget.mesh.onReminderReceived = null;
    _reminderEngine.removeListener(_onRemindersChanged);
    _reminderEngine.dispose();
    _conversation.removeListener(_onConversationChanged);
    _conversation.dispose();
    _controller.dispose();
    _onboardName.dispose();
    _onboardAssistant.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onRemindersChanged() => setState(() {});

  /// Every thread entry this listener has seen, by identity. A card that
  /// is not in the set is genuinely new — an append, or a replacement
  /// (Thinking → answer, action card → outcome) wherever it sits in the
  /// thread — and gets read out loud exactly once. Probe flips and status
  /// changes never create entries and never re-speak.
  final Set<ConversationEntry> _seenEntries = {};

  void _onConversationChanged() {
    setState(() {});
    // Voice mode: read genuinely new reply cards out loud, exactly once,
    // wherever they landed — an out-of-order brain answer replaces its own
    // mid-thread card and still speaks, because each card carries its own
    // spoken-ask attribution. Typed exchanges stay quiet: a card speaks
    // only when the ask that produced it came from the microphone.
    for (final entry in _conversation.entries) {
      if (!_seenEntries.add(entry)) continue;
      if (!entry.spokenAsk) continue;
      final text = ConversationEngine.speakableText(entry);
      if (text != null) unawaited(SpeechOutput.current.speak(text));
    }
  }

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
          // The platform the peer reported at pairing, so a question about
          // "my phone" can resolve against the real registry instead of
          // hoping the device's name contains the word.
          platform: d.platform,
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
    // The ask came from the microphone — replies to it are read out loud.
    bool spoken = false,
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
      replaceLast: replaceLast,
      spoken: spoken,
    );
    // Every ask refines what the assistant predicts you'll ask next.
    unawaited(_refreshFromLog());
    // A phrase the interpreter doesn't know → hand it to the local brain for
    // a real conversational reply. Commands, answers to open questions, and
    // approval re-runs keep their fast path.
    final dispatch = result.dispatch;
    if (answerTo == null &&
        !replaceLast &&
        widget.brain != null &&
        dispatch is AgentClarification &&
        dispatch.key.startsWith('teach:')) {
      _startConversation(input.trim(), result);
    }
  }

  /// The memory context for a conversation, assembled at call time from the
  /// profile, the live service's memory, and the proactive readings — the
  /// engine asks for it fresh on every exchange.
  ConversationContext _memoryContext() => ConversationContext(
    userName: _profileState?.userName,
    assistantName: _profileState?.assistantName ?? 'Nexus',
    // The brain prompt only needs the text of what Nexus knows; provenance
    // is for the user's questions, not the model's context.
    facts: _service.factsSnapshot,
    learned: _service.learnedSnapshot,
    defaults: _service.defaultsSnapshot,
    habits: [
      for (final habit in _habits ?? const <Habit>[]) habit.phrase,
    ].take(5).toList(),
    skills: [
      for (final skill in _skills ?? const <SkillUse>[]) skill.label,
    ].take(5).toList(),
  );

  /// Hands a phrase the interpreter doesn't know to the conversation engine
  /// for a conversational reply. The engine owns the whole exchange — the
  /// Thinking swap, the ticket, the teach restore — and reports back which
  /// stale teach question (if any) it superseded.
  void _startConversation(String input, AgentDispatchResult original) {
    final brain = widget.brain;
    if (brain == null) return;
    // The engine stays classic when the last probe proved the brain offline —
    // it returns without the Thinking card, so the core must not flash
    // "thinking" for an exchange that will never be made.
    final willAsk = _conversation.brainHealth != BrainHealth.offline;
    if (willAsk) setState(() => _brainThinking = true);
    unawaited(() async {
      try {
        await _conversation.converse(
          brain: brain,
          input: input,
          original: original,
          context: _memoryContext,
          onBrainAnswered: (stale) {
            // The brain owns this phrase now — drop the service's stale teach
            // question so it can never swallow a later input.
            if (stale != null) _service.cancelPending(stale);
          },
        );
      } finally {
        if (mounted && willAsk) setState(() => _brainThinking = false);
      }
    }());
  }

  /// Every ask and its outcome lands in the query log — raw material for
  /// improving matching and catching bugs, and for the skill loop (an ask
  /// whose dispatch names a real action counts as genuine use of that
  /// skill; a plain answer like the time logs as "message").
  void _logAsk(String input, AgentDispatchResult result) {
    final route = switch (result.dispatch) {
      final AgentActionPlan plan => plan.request.action,
      final AgentClarification ask => ask.key,
      final AgentMessage message => message.action ?? 'message',
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
    AgentActions.calendarRead,
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
    AgentActions.appDefault,
    AgentActions.profileSet,
    AgentActions.profileGet,
    // The fetch runs here — this device pulls the file over the mesh — so it
    // is one of the actions this device executes end to end.
    AgentActions.fileFetch,
  };

  /// Shows a dispatch result — and starts self-run actions right away.
  ///
  /// The decision to act is taken *before* the card goes up: a card that is
  /// about to run something is [pending], which is what stops it wearing a
  /// finished status while the work is still out. A plan is a promise to act;
  /// the executor's own result is what replaces it.
  void _consume(
    AgentDispatchResult result, {
    String? asUser,
    bool replaceLast = false,
    bool spoken = false,
  }) {
    final plan = switch (result.dispatch) {
      final AgentActionPlan p => p,
      _ => null,
    };
    final message = switch (result.dispatch) {
      final AgentMessage m => m,
      _ => null,
    };
    // Path 1: A routed action plan targeting this device — e.g. ledBlink
    // resolved to a local serial device, or clipboardWrite.
    final runsHere =
        plan != null &&
        plan.request.target == widget.mesh.identity.id &&
        _selfRunActions.contains(plan.request.action);
    // Path 3: An approved plan aimed at a PAIRED device (a call or text
    // this device can't run, offered to the phone that can). The device
    // question already got the user's consent, so it sends itself and shows
    // the remote's outcome in the plan card; the paired device re-gates the
    // request on its own side. Blink and clipboard keep their dedicated
    // paths (they target serial nodes, not mesh devices).
    final runsThere =
        plan != null &&
        plan.request.target.isNotEmpty &&
        plan.request.target != widget.mesh.identity.id &&
        plan.request.approval == AgentApproval.approved &&
        plan.request.action != AgentActions.ledBlink &&
        plan.request.action != AgentActions.clipboardWrite;
    // Path 2: A message with an attached action — these come from
    // _localAnswer() for webSearch, noteCreate, timerSet, openUrl,
    // systemInfo, volumeSet. The message is shown immediately and the
    // side-effect (open browser, save note, etc.) runs in the background.
    // A reminder card is different: it registers the promise with this
    // device's reminder engine (which fires later, on its own) instead of
    // running an executor stub — nothing is in flight, so it is never
    // pending. A spoken call/text/email is the third case: it asks for the
    // yes first, and a question is not work in flight either.
    final action = message?.action;
    final hasSideEffect =
        action != null &&
        action != AgentActions.reminderSet &&
        _selfRunActions.contains(action);
    final confirmsFirst =
        hasSideEffect &&
        _lastInputWasVoice &&
        _voiceConfirmActions.contains(action);

    _conversation.appendResult(
      result,
      asUser: asUser,
      replaceLast: replaceLast,
      spoken: spoken,
      pending: runsHere || (hasSideEffect && !confirmsFirst),
    );
    if (runsHere) unawaited(_runSelfAction(plan.request));
    if (runsThere) unawaited(_sendAgentRequest(plan.request));
    if (message == null) return;
    if (action == AgentActions.reminderSet) {
      final dueAt = DateTime.tryParse(
        message.arguments?['dueAt']?.toString() ?? '',
      );
      final text = message.arguments?['text']?.toString() ?? '';
      if (dueAt != null && text.isNotEmpty) {
        _reminderEngine.register(text, dueAt);
      }
    }
    if (!hasSideEffect) return;
    final request = AgentRequest(
      requestId: 'ui-${DateTime.now().microsecondsSinceEpoch}',
      target: widget.mesh.identity.id,
      action: action,
      arguments: message.arguments ?? const {},
    );
    if (!confirmsFirst) {
      unawaited(_runSelfAction(request));
      return;
    }
    // Spoken contact actions are confirmed by voice first — "call mom"
    // heard, not typed, asks before dialing. Typed ones run straight away:
    // the user already wrote what they meant.
    setState(() {
      _voiceConfirm = (request: request, question: message.text);
    });
    _conversation.appendResult(
      AgentDispatchResult(
        status: AgentResultStatus.needsInfo,
        dispatch: AgentMessage(
          '${message.text} Say "yes" to confirm, or "no" to cancel.',
        ),
      ),
      replaceLast: true,
    );
  }

  Future<void> _runSelfAction(AgentRequest request) async {
    setState(() {
      _sending = true;
      _reply = null;
    });
    try {
      final outcome = await _executor.run(request);
      if (!mounted) return;
      _showSelfOutcome(
        _statusFor(outcome),
        outcome.message,
        request: request,
        candidates: outcome.candidates,
      );
    } catch (error) {
      // A platform call that throws is still something the user has to be
      // told about. Before this, the throw escaped an unawaited future: the
      // core kept claiming the device was working, no card appeared, and the
      // only trace was a console the user never sees.
      if (mounted) {
        _showSelfOutcome(
          AgentResultStatus.unavailable,
          'That didn\'t run — the device action failed: $error',
          request: request,
        );
      }
    } finally {
      // In `finally` on purpose: the core reads `_sending` as "an action is
      // being carried out", so when the await ends — however it ends — the
      // claim ends with it. The live line goes with it: a finished fetch must
      // not leave its last percentage standing in for the result.
      if (mounted) {
        setState(() {
          _sending = false;
          _fetchProgress = null;
        });
      }
    }
  }

  /// One utterance, then the recognized words run through the same pipeline
  /// as typing them — the "command based" assistant, spoken. Devices without
  /// a speech service answer honestly instead of pretending to listen.
  Future<void> _listen() async {
    final speech = SpeechInput.current;
    if (!speech.available) {
      _conversation.appendResult(
        AgentDispatchResult(
          status: AgentResultStatus.succeeded,
          dispatch: const AgentMessage(
            'Voice input isn\'t set up on this device yet — type it, or '
            'tap one of the example chips below.',
          ),
        ),
        spoken: true, // a spoken attempt — read the answer out loud
      );
      return;
    }
    setState(() => _listening = true);
    final heard = await speech.listen();
    if (!mounted) return;
    setState(() => _listening = false);
    final text = heard?.trim() ?? '';
    if (text.isEmpty) {
      _conversation.appendResult(
        const AgentDispatchResult(
          status: AgentResultStatus.succeeded,
          dispatch: AgentMessage(
            'I didn\'t catch that — could you say it again?',
          ),
        ),
        spoken: true, // the user just spoke — the retry prompt is read aloud
      );
      return;
    }
    _controller.text = text;
    _onSubmit(voice: true);
  }

  /// The status a device action's own outcome deserves.
  ///
  /// A failed action is not always a failure. When the reason is that the
  /// action needed something from the user — a contact, a query, a duration —
  /// Nexus is asking a question, and calling that "Unavailable" would report
  /// the feature as broken instead of the sentence as incomplete.
  AgentResultStatus _statusFor(ActionResult outcome) {
    if (outcome.ok) return AgentResultStatus.succeeded;
    return outcome.needsDetail
        ? AgentResultStatus.needsInfo
        : AgentResultStatus.unavailable;
  }

  /// Shows the outcome of an action this device ran itself.
  ///
  /// [status] is the caller's judgement about what happened, and the three
  /// callers know different things: the executor knows whether it was asking
  /// a question ([_statusFor]), a refusal is the user's own choice
  /// ([AgentResultStatus.denied]), and an exception is a real failure.
  void _showSelfOutcome(
    AgentResultStatus status,
    String message, {
    AgentRequest? request,
    List<String> candidates = const [],
  }) {
    final ok = status == AgentResultStatus.succeeded;
    setState(() {
      _sending = false;
      // The contact lookup found close names but nothing exact — offer them
      // as "who did you mean?" and LEARN the answer ("alx" -> Alex). The
      // Kotlin message already names the candidates.
      if (!ok && candidates.isNotEmpty && request != null) {
        _contactConfirm = (request: request, candidates: candidates);
      }
    });
    if (!ok && candidates.isNotEmpty && request != null) {
      _conversation.appendResult(
        AgentDispatchResult(
          status: AgentResultStatus.needsInfo,
          dispatch: AgentMessage(
            '$message Say "yes" for the first one — or "no" to cancel.',
          ),
        ),
        replaceLast: true,
      );
      return;
    }
    _conversation.appendResult(
      AgentDispatchResult(
        status: status,
        message: ok ? '' : message,
        dispatch: ok ? AgentMessage(message) : null,
      ),
      replaceLast: true,
    );
    // "call me sam" changed the profile — greet by the new name immediately.
    if (request?.action == AgentActions.profileSet) {
      unawaited(_syncProfile());
    }
  }

  void _onSubmit({bool voice = false}) {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    HapticFeedback.selectionClick();
    // From here on a thread exists, so the first-run greeting has been read.
    // No setState: the ask about to run notifies and rebuilds anyway.
    _everConversed = true;
    _lastInput = text;
    _lastInputWasVoice = voice;
    _controller.clear();
    final yes = _isYes(text);
    final no = _isNo(text);
    // A voice-triggered call/text/email is waiting for a spoken yes/no —
    // typed input never lands here (typed contact actions run directly).
    if (_voiceConfirm != null) {
      final vc = _voiceConfirm!;
      if (yes) {
        _voiceConfirm = null;
        unawaited(_runSelfAction(vc.request));
      } else if (no) {
        _voiceConfirm = null;
        // The user's own no. A choice, not a failure — the core must not
        // colour itself red for something they decided.
        _showSelfOutcome(AgentResultStatus.denied, 'Cancelled — nothing was sent.');
      } else {
        _voiceConfirm = null; // moved on: run the new request
        _execute(text, spoken: voice);
      }
      return;
    }
    // "who did you mean?" after an unresolved contact — "yes" calls the
    // closest match AND learns the wording ("alx" means Alex from now on).
    if (_contactConfirm != null) {
      final cc = _contactConfirm!;
      if (yes) {
        _contactConfirm = null;
        final chosen = cc.candidates.first;
        final original = cc.request.arguments['contact']?.toString() ?? '';
        if (chosen != original) {
          _service.learnContactAlias(original, chosen);
        }
        final args = Map<String, dynamic>.of(cc.request.arguments)
          ..['contact'] = chosen;
        unawaited(
          _runSelfAction(
            AgentRequest(
              requestId: 'ui-${DateTime.now().microsecondsSinceEpoch}',
              target: cc.request.target,
              action: cc.request.action,
              arguments: args,
            ),
          ),
        );
      } else if (no) {
        _contactConfirm = null;
        _showSelfOutcome(
          AgentResultStatus.denied,
          'Okay — I won\'t call anyone.',
        );
      } else {
        _contactConfirm = null; // moved on: run the new request
        _execute(text, spoken: voice);
      }
      return;
    }
    // An Approve/Deny bar is showing — spoken (or typed) yes/no answers it.
    final lastResult = _conversation.lastResult;
    if (lastResult != null &&
        lastResult.status == AgentResultStatus.required &&
        (yes || no)) {
      _execute(
        _lastInput,
        approval: yes
            ? AgentApproval.approved
            : AgentApproval.denied,
        replaceLast: true,
        spoken: voice,
      );
      return;
    }
    final pending = _conversation.pendingKey;
    // A clarification is open. The next input answers it — UNLESS it is
    // itself a command: the user moved on, so the new request runs and the
    // stale question is dropped instead of silently swallowing the command
    // ("call mom" must never be learned as the meaning of "open deezer").
    if (pending != null && !_service.parsesAsCommand(text)) {
      _execute(text, answerTo: pending, spoken: voice);
    } else {
      if (pending != null) _service.cancelPending(pending);
      _execute(text, spoken: voice);
    }
  }

  bool _isYes(String text) => RegExp(
        r'^(yes|yep|yeah|yah|y|ok|okay|sure|oui|correct|affirmative|go ahead)$',
        caseSensitive: false,
      ).hasMatch(text.trim().toLowerCase());

  bool _isNo(String text) => RegExp(
        r"^(no|nope|n|non|negative|cancel|stop|dont|don't)$",
        caseSensitive: false,
      ).hasMatch(text.trim().toLowerCase());

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

  /// What to say about a result this device produced, in this device's own
  /// voice: the action's own words first, then its reason, then the status's
  /// honest explanation. The remote equivalent is [AgentResultStatus.reportFrom],
  /// which speaks in the peer's name instead — the two must not be swapped,
  /// because each one's wording is only true of the device it describes.
  String _describeOutcome(AgentDispatchResult reply) {
    if (reply.dispatch case final AgentMessage message) {
      return message.text;
    }
    if (reply.message.isNotEmpty) return reply.message;
    return reply.status.explain();
  }

  /// Runs an action and shows its outcome on whichever plan card is open.
  Future<void> _runAction(Future<String> Function() action) async {
    setState(() {
      _sending = true;
      _reply = null;
    });
    try {
      final outcome = await action();
      if (mounted) setState(() => _reply = outcome);
    } catch (error) {
      // Same rule as [_runSelfAction]: a failure is reported, never silent.
      if (mounted) {
        setState(() => _reply = 'Something went wrong: $error');
      }
    } finally {
      // "working" may only outlive the await if the await never ended, which
      // cannot happen.
      if (mounted) setState(() => _sending = false);
    }
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
      if (reply == null) return 'Could not reach $deviceName.';
      // One voice for the outcome: the status's own vocabulary says what
      // happened in the device's name, preferring whatever the device said
      // and never falling back to a fragment with no reason behind it.
      return reply.status.reportFrom(
        deviceName,
        message: reply.message,
        words: switch (reply.dispatch) {
          final AgentMessage message => message.text,
          _ => null,
        },
      );
    });
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
      // The peer gets the same honest status we would show locally: a request
      // missing a detail comes back as a question, not as a broken feature.
      final status = _statusFor(outcome);
      result = AgentDispatchResult(
        status: status,
        message: outcome.ok ? '' : outcome.message,
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
  ///
  /// [wrapped] lays them out under the greeting, centred and on as many lines
  /// as they need; the default is one scrollable row above the composer.
  /// [limit] caps how many are offered where the next line costs more than
  /// one more suggestion is worth.
  Widget _suggestionChips({bool wrapped = false, int limit = 6}) {
    // The skill loop's visible payoff: skills the user genuinely reaches
    // for lead the chips, shown by a canonical example that always parses —
    // even when no single phrase repeats often enough to be a habit. A
    // real routine (the same phrase twice or more) still comes first,
    // because their own words beat any example.
    final habits = _habits;
    final personal = habits == null || habits.every((h) => h.count < 2)
        ? const <Habit>[]
        : habits.where((h) => h.count >= 2).take(3).toList();
    final skillExamples = <String>[];
    for (final skill in _skills ?? const <SkillUse>[]) {
      if (skillExamples.length >= 4) break;
      final example = skill.example;
      if (skillExamples.contains(example) ||
          personal.any((h) => h.phrase == example)) {
        continue;
      }
      skillExamples.add(example);
    }
    final totalSkillUses = (_skills ?? const <SkillUse>[])
        .fold<int>(0, (sum, skill) => sum + skill.uses);
    final List<String> suggestions;
    if (personal.isNotEmpty) {
      suggestions = [
        ...personal.map((h) => h.phrase),
        ...skillExamples,
      ].take(6).toList();
    } else if (totalSkillUses >= 2) {
      // A real skill pattern exists (a single stray ask is not a routine).
      // Discovery leads: the help chip's phrase comes from the registry too.
      final discovery = _phrase(AgentActions.helpGet, _platform);
      suggestions = [
        if (discovery != null) discovery,
        ...skillExamples,
      ].take(6).toList();
    } else {
      suggestions = suggestionExamplesFor(_platform);
    }
    final palette = NexusPalette.of(context);
    final chips = [
      for (final s in suggestions.take(limit))
        ActionChip(
          // A soft surface pill, not an outlined button: these are words to
          // try, and a row of bordered controls reads as a toolbar rather
          // than as three things a person might say.
          label: Text(s, style: NexusType.caption1),
          shape: const StadiumBorder(),
          side: BorderSide.none,
          backgroundColor: palette.surfaceSecondary,
          onPressed: () {
            _controller.text = s;
            _onSubmit();
          },
        ),
    ];
    if (wrapped) {
      // Under the greeting they wrap and centre, the way every chat app
      // built after ChatGPT opens a blank thread, instead of running off the
      // side of the screen where nobody scrolls them.
      return Wrap(
        alignment: WrapAlignment.center,
        spacing: NexusSpace.sm,
        runSpacing: NexusSpace.sm,
        children: chips,
      );
    }
    // A chip is a tap target a thumb has to hit one-handed, so its row is the
    // full [NexusSize.minTouch] tall and the chip is centred in it: the
    // measured target on the phone was 40dp, under both Android's 48dp and
    // this app's own minimum.
    return SizedBox(
      height: NexusSize.minTouch,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: NexusSpace.lg),
        children: [
          for (final chip in chips)
            Padding(
              padding: const EdgeInsets.only(right: NexusSpace.sm),
              child: Center(child: chip),
            ),
          // Room to scroll the last chip clear of the edge.
          const SizedBox(width: NexusSpace.lg),
        ],
      ),
    );
  }

  /// True while first-run setup is open — the one place that decides. The
  /// chat input is hidden then, so typing mid-onboarding can never submit a
  /// command or close the setup early.
  bool get _onboardingActive {
    final p = _profileState;
    return _profileLoaded && p != null && !p.onboarded;
  }

  /// First-run guidance: a real setup flow (names + permissions) the very
  /// first time the app runs; the plain welcome card afterwards.
  Widget _welcomeView() {
    if (_onboardingActive) {
      return _onboardingView();
    }
    return _legacyWelcomeView();
  }

  /// The plain first-run page once setup is done: the greeting, the
  /// suggestions directly under it, and then what Nexus can really run.
  ///
  /// The greeting is the page's own heading now rather than a line inside the
  /// card, because the card was the second thing the eye reached: the first
  /// thing on a blank screen should be the thing to say, not a panel about
  /// the app. The card keeps only the steps.
  Widget _legacyWelcomeView() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        NexusSpace.lg,
        NexusSpace.huge,
        NexusSpace.lg,
        NexusSpace.xxl,
      ),
      children: [
        Text(
          'Hello! I am Nexus.',
          textAlign: TextAlign.center,
          style: NexusType.title.copyWith(
            color: NexusColors.text,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: NexusSpace.sm),
        Text(
          'Type what you want, the way you would say it.',
          textAlign: TextAlign.center,
          style: NexusType.body.copyWith(color: NexusColors.muted),
        ),
        const SizedBox(height: NexusSpace.xxl),
        _suggestionChips(wrapped: true, limit: 4),
        const SizedBox(height: NexusSpace.xxl),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: NexusColors.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: NexusColors.accent.withValues(alpha: 0.35),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _firstStep(
                Icons.touch_app_rounded,
                'Tap a suggestion',
                'the chips below run real things I can do',
              ),
              if (_phrase(AgentActions.callPlace, _platform) case final call?)
                _firstStep(
                  Icons.call_rounded,
                  '"$call"',
                  'I dial, or ask once who you mean — then remember',
                )
              else if (_phrase(AgentActions.emailSend, _platform)
                  case final email?)
                _firstStep(
                  Icons.mail_rounded,
                  '"$email"',
                  'I write, or ask once who you mean — then remember',
                ),
              _firstStep(
                Icons.memory_rounded,
                '"remember that …"',
                'a fact I keep; ask ${_quoted(_phrase(AgentActions.memoryRecall, _platform))}',
              ),
              _firstStep(
                Icons.devices_rounded,
                'Pair your devices',
                'in Devices — then I can act on them too',
              ),
              Text(
                'If I misunderstand, tell me what you meant — I learn.',
                style: NexusType.caption.copyWith(color: NexusColors.muted),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// One line of the welcome card: a real capability, in the words a person
  /// would actually say it. Deliberately not hand-wrapped — the card has to
  /// reflow at any width, and hard-coded line breaks only look right on the
  /// one screen they were typed on.
  Widget _firstStep(IconData icon, String label, String detail) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: NexusColors.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(
                style: NexusType.caption.copyWith(color: NexusColors.muted),
                children: [
                  TextSpan(
                    text: label,
                    style: const TextStyle(
                      color: NexusColors.text,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const TextSpan(text: ' — '),
                  TextSpan(text: detail),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The first-run setup: your name, the assistant's name, and the three
  /// permissions it works with — each granted through the REAL flow the
  /// action uses (the system asks, exactly like Siri's setup), never a
  /// pretend toggle. "Start" saves everything and the assistant greets
  /// you by name.
  Widget _onboardingView() {
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Set me up — 30 seconds.',
                style: NexusType.callout.copyWith(
                  color: NexusColors.text,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Tell me your name and what to call me, then grant the '
                'permissions I work with. You can change all of this later.',
                style: NexusType.caption.copyWith(color: NexusColors.muted),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _onboardAssistant,
                decoration: InputDecoration(
                  labelText: 'What should I be called?',
                  hintText: 'Nexus',
                  labelStyle: NexusType.caption1.copyWith(
                    color: NexusColors.muted,
                  ),
                  hintStyle: NexusType.caption.copyWith(
                    color: NexusColors.muted,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: NexusColors.border),
                  ),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                ),
                style: NexusType.caption.copyWith(color: NexusColors.text),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _onboardName,
                decoration: InputDecoration(
                  labelText: 'Your name',
                  hintText: 'what should I call you?',
                  labelStyle: NexusType.caption1.copyWith(
                    color: NexusColors.muted,
                  ),
                  hintStyle: NexusType.caption.copyWith(
                    color: NexusColors.muted,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: NexusColors.border),
                  ),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                ),
                style: NexusType.caption.copyWith(color: NexusColors.text),
              ),
              const SizedBox(height: 14),
              _permRow(
                'Voice',
                'ask me things out loud',
                'voice',
                Icons.mic_rounded,
              ),
              _permRow(
                'Calendar',
                'see what is on your calendar',
                'calendar',
                Icons.calendar_month_rounded,
              ),
              _permRow(
                'Location',
                'weather where you are',
                'location',
                Icons.place_rounded,
              ),
              const SizedBox(height: 6),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => unawaited(_finishOnboarding()),
                  child: const Text('Start'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _permRow(String title, String what, String kind, IconData icon) {
    final state = _onboardPerms[kind];
    final status = switch (state) {
      true => 'Ready ✓',
      false => 'Not yet — retry, or allow it in Settings',
      _ => 'Needs your permission',
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(
            icon,
            size: 18,
            color: state == true ? NexusColors.accent : NexusColors.muted,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: NexusType.caption.copyWith(
                    color: NexusColors.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '$what — $status',
                  style: NexusType.caption1.copyWith(color: NexusColors.muted),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: state == true
                ? null
                : () => unawaited(_setupPermission(kind)),
            child: Text(state == true ? 'Done' : 'Set up'),
          ),
        ],
      ),
    );
  }

  /// Runs the REAL capability flow so the system permission dialog appears
  /// (voice listen, calendar read, location) — the setup is not a fake
  /// toggle, it is the action itself, once.
  Future<void> _setupPermission(String kind) async {
    bool? result;
    switch (kind) {
      case 'voice':
        final speech = SpeechInput.current;
        if (!speech.available) {
          result = false;
        } else {
          final heard = await speech.listen();
          result = heard != null && heard.trim().isNotEmpty;
        }
      case 'calendar':
        final out = await _executor.run(
          AgentRequest(
            requestId: 'onboard-${DateTime.now().microsecondsSinceEpoch}',
            target: widget.mesh.identity.id,
            action: AgentActions.calendarRead,
            arguments: const {'when': 'today'},
          ),
        );
        result = out.ok;
      case 'location':
        final out = await _executor.run(
          AgentRequest(
            requestId: 'onboard-${DateTime.now().microsecondsSinceEpoch}',
            target: widget.mesh.identity.id,
            action: AgentActions.locationGet,
          ),
        );
        result = out.ok;
    }
    if (!mounted) return;
    setState(() => _onboardPerms[kind] = result);
  }

  /// Saves the names, marks setup done, and says the first real hello —
  /// by name, with a time-of-day greeting, exactly like a person would.
  Future<void> _finishOnboarding() async {
    final raw = _onboardName.text.trim();
    final assistant = _onboardAssistant.text.trim().isEmpty
        ? 'Nexus'
        : _proper(_onboardAssistant.text.trim());
    final p = UserProfile(
      userName: raw.isEmpty ? null : _proper(raw),
      assistantName: assistant,
      onboarded: true,
    );
    await _profile.save(p);
    // The names are the memory's anchors — tell every paired device, so the
    // first "call me sam" on one device is known on all of them.
    unawaited(
      widget.mesh.broadcastProfile(
        userName: p.userName,
        assistantName: p.assistantName,
      ),
    );
    if (!mounted) return;
    _service.setIdentity(userName: p.userName, assistantName: p.assistantName);
    setState(() => _profileState = p);
    final hour = DateTime.now().hour;
    final dayPart = hour < 12
        ? 'Good morning'
        : (hour < 18 ? 'Good afternoon' : 'Good evening');
    final who = p.userName == null ? '' : ', ${p.userName}';
    _conversation.appendResult(
      AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(
          '$dayPart$who! I\'m $assistant, your assistant — running right '
          'on this device. Ask me for the weather, directions, music, '
          'timers, or what is on your calendar. If I don\'t understand, '
          'tell me what you meant and I\'ll learn.',
        ),
      ),
    );
  }

  /// "sam smith" → "Sam Smith": names are proper when spoken back.
  static String _proper(String s) => s
      .split(' ')
      .where((w) => w.isNotEmpty)
      .map((w) => w[0].toUpperCase() + w.substring(1))
      .join(' ');

  /// Opens the dream review from outside this screen — the Settings row
  /// "What I still misunderstand" reaches the same sheet the header menu
  /// does, through the one service that owns what this device learned.
  void openDreamReview() {
    if (!mounted) return;
    unawaited(_showDreamReview(context));
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
    await showNexusSheet<void>(
      context: context,
      color: NexusPalette.of(context).bg,
      builder: (context, controller) => _DreamSheet(
        service: _service,
        insights: insights,
        platform: _platform,
        scroll: controller,
      ),
    );
  }

  /// Loads the persisted profile once after the first frame: names feed
  /// the service's identity (personalized greetings) and the welcome card
  /// becomes a real setup flow when first-run setup is pending.
  Future<void> _loadProfile() async {
    var p = await _profile.read();
    // Renames synced over the mesh while this device was closed sit in the
    // store — wake up knowing them, where the local profile still carries
    // its untouched defaults. Per field: a name the user actually set
    // locally wins over the synced fallback (renames carry no timestamps,
    // so the established local-correction rule decides).
    final syncedUser = widget.mesh.store.profileUserName;
    final syncedAssistant = widget.mesh.store.profileAssistantName;
    final merged = p.copyWith(
      userName: p.userName ?? syncedUser,
      assistantName: p.assistantName == 'Nexus'
          ? syncedAssistant ?? p.assistantName
          : p.assistantName,
    );
    if (merged.userName != p.userName ||
        merged.assistantName != p.assistantName) {
      p = merged;
      await _profile.save(p);
    }
    if (!mounted) return;
    _service.setIdentity(
      userName: p.userName,
      assistantName: p.assistantName,
    );
    setState(() {
      _profileState = p;
      _profileLoaded = true;
      // Prefill the assistant name once so first-run setup starts with
      // the default, ready to edit.
      if (!p.onboarded && _onboardAssistant.text.isEmpty) {
        _onboardAssistant.text = p.assistantName;
      }
    });
  }

  /// Re-reads the profile after a name change ("call me sam") so greetings
  /// and the onboarded flag stay fresh without a restart — and tells every
  /// paired device, so the rename is known everywhere.
  Future<void> _syncProfile() async {
    final p = await _profile.read();
    if (!mounted) return;
    final changed =
        p.userName != _profileState?.userName ||
        p.assistantName != _profileState?.assistantName;
    _service.setIdentity(
      userName: p.userName,
      assistantName: p.assistantName,
    );
    setState(() => _profileState = p);
    if (changed) {
      unawaited(
        widget.mesh.broadcastProfile(
          userName: p.userName,
          assistantName: p.assistantName,
        ),
      );
    }
  }

  /// A paired device renamed the user or the assistant — adopt the names
  /// into the local profile (keeping local onboarding state), so every
  /// device answers as one person. Never re-broadcasts: the name came FROM
  /// the mesh, sending it back would loop forever.
  Future<void> _adoptRemoteProfile(String? userName, String? assistantName) async {
    final current = await _profile.read();
    if (!mounted) return;
    final updated = current.copyWith(
      userName: userName ?? current.userName,
      assistantName: assistantName ?? current.assistantName,
    );
    if (updated.userName == current.userName &&
        updated.assistantName == current.assistantName) {
      return;
    }
    await _profile.save(updated);
    if (!mounted) return;
    _service.setIdentity(
      userName: updated.userName,
      assistantName: updated.assistantName,
    );
    setState(() => _profileState = updated);
  }

  /// Reads the ask log once and updates the proactive surfaces from it: the
  /// phrases this user asks most (personal predictions) and the skills they
  /// genuinely use (the skill loop). Called after the first frame and after
  /// every ask; [setState] only when the picture changed, so idle starts cost
  /// one rebuild at most.
  Future<void> _refreshFromLog() async {
    final lines = await QueryLog.i.readAll();
    if (!mounted) return;
    final habits = const Predictions().habits(lines);
    final skills = const SkillRanking().rank(lines);
    final oldSkills = _skills ?? const <SkillUse>[];
    final changed =
        habits.length != (_habits?.length ?? 0) ||
        skills.length != oldSkills.length ||
        skills.indexed.any(
          (e) =>
              e.$2.id != oldSkills[e.$1].id || e.$2.uses != oldSkills[e.$1].uses,
        ) ||
        habits.any(
          (h) => !(_habits ?? const []).any((o) => o.phrase == h.phrase),
        );
    if (!changed) return;
    setState(() {
      _habits = habits;
      _skills = skills;
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
    final palette = NexusPalette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: NexusSpace.page),
      child: Container(
        key: const ValueKey('reminder-banner'),
        padding: const EdgeInsets.fromLTRB(
          NexusSpace.lg,
          NexusSpace.sm,
          NexusSpace.xs,
          NexusSpace.sm,
        ),
        decoration: BoxDecoration(
          color: palette.surfaceElevated,
          borderRadius: NexusRadius.card,
          border: Border.all(color: palette.separator),
        ),
        child: Row(
          children: [
            Icon(Icons.alarm_rounded, size: 18, color: palette.accent),
            const SizedBox(width: NexusSpace.md),
            Expanded(
              child: Text(
                'Reminder: ${reminder.text}',
                style: Theme.of(
                  context,
                ).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            IconButton(
              tooltip: 'Done',
              icon: const Icon(Icons.check_rounded, size: 18),
              color: palette.success,
              onPressed: _reminderEngine.acknowledge,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // The header is the orb, the name and one line of state — no icon
        // buttons. Both actions it used to carry are still one gesture away:
        // a long press on this row opens the conversation menu (New
        // conversation, What I still misunderstand), and the review is also
        // a row in Settings. The conversation is the point of this screen, so
        // the header stays one row tall.
        Padding(
          padding: const EdgeInsets.fromLTRB(
            NexusSpace.page,
            NexusSpace.xl,
            NexusSpace.page,
            0,
          ),
          child: InkWell(
            onLongPress: () => unawaited(_showConversationMenu()),
            borderRadius: NexusRadius.row,
            child: NexusPresence(
              state: _coreState,
              contextLine: _presenceLine,
            ),
          ),
        ),
        // A reminder that fired, waiting for a "Done".
        _reminderBanner(),
        if (widget.brain != null) _brainStatusLine(),
        // The conversation, and only the conversation, takes the room that is
        // left. Everything above it is a status line; everything below it is
        // the composer, where a thumb already is.
        Expanded(
          child: ListenableBuilder(
            listenable: widget.mesh,
            builder: (context, _) => _buildResult(),
          ),
        ),

        // While first-run setup is open, the composer and the example chips
        // are out of the tree entirely — nothing to focus, submit, or tap.
        if (!_onboardingActive) ...[
          // One-tap examples, directly above the field they fill in — but
          // only while there is a thread for them to sit above. On a blank
          // screen they live inside the greeting, under it, and are not drawn
          // a second time here.
          if (!_greetingShown) _suggestionChips(),
          _composer(),
        ],
      ],
    );
  }

  /// True while the thread area is holding a greeting rather than a
  /// conversation. The chips belong to whichever of the two surfaces is
  /// showing them, never both, so the same three suggestions cannot appear
  /// twice on one screen.
  bool get _greetingShown => _conversation.isEmpty && _incoming() == null;

  /// The input bar: the app's primary action, at the bottom of the screen
  /// where the hand already is — never a control you have to reach for.
  ///
  /// Both of its controls sit inside the field rather than beside it: the
  /// composer is one object that floats over the thread, and a mic or a send
  /// button outside the pill would be a second object next to it.
  Widget _composer() {
    final palette = NexusPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NexusSpace.page,
        NexusSpace.sm,
        NexusSpace.page,
        NexusSpace.sm,
      ),
      child: Container(
        decoration: BoxDecoration(
          // The one thing that floats over the thread: a seated composer, so
          // it reads as a layer above the conversation, not a box drawn on it.
          color: palette.surfaceSecondary,
          borderRadius: NexusRadius.composer,
          border: Border.all(color: palette.separator),
          boxShadow: NexusShadow.raised,
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                focusNode: _focus,
                onSubmitted: (_) => _onSubmit(),
                textInputAction: TextInputAction.send,
                decoration: InputDecoration(
                  hintText: _conversation.pendingKey == null
                      ? _askHintFor(_platform)
                      : 'Answer the question — or type a new command',
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: NexusSpace.lg,
                    vertical: NexusSpace.lg,
                  ),
                ),
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ),
            IconButton(
              tooltip: _listening ? 'Listening…' : 'Speak your question',
              icon: Icon(
                _listening ? Icons.mic_rounded : Icons.mic_none_rounded,
                size: 22,
                color: _listening ? palette.accent : palette.textSecondary,
              ),
              onPressed: _listening ? null : () => unawaited(_listen()),
            ),
            // The app's primary action: labelled for screen readers, filled
            // so it is unmistakably the thing to press, with its own 48dp
            // target.
            Padding(
              padding: const EdgeInsets.only(right: NexusSpace.xs),
              child: IconButton.filled(
                tooltip: 'Send',
                icon: const Icon(Icons.arrow_upward_rounded, size: 20),
                onPressed: _onSubmit,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// One line that says what Nexus is doing right now, in words — the same
  /// truth the Core shows in colour and motion. Nothing here is inferred from
  /// a timer: each case is a signal this view actually has.
  String get _presenceLine {
    final mesh = widget.mesh;
    switch (_coreState) {
      case NexusCoreState.listening:
        return 'Listening — say it when you are ready';
      case NexusCoreState.thinking:
        return 'Thinking about what you asked';
      case NexusCoreState.working:
        return 'Working on it';
      case NexusCoreState.error:
        return 'That last one did not work';
      case NexusCoreState.offline:
        return 'No paired device is reachable right now';
      case NexusCoreState.idle:
        final total = mesh.pairedDevices.length;
        if (total == 0) return 'Ready — ask me anything';
        final online = mesh.onlineCount;
        return online == total
            ? 'Ready · all $total devices reachable'
            : 'Ready · $online of $total devices reachable';
    }
  }

  /// What the core is allowed to say right now.
  ///
  /// Every signal here is one the view genuinely has — the microphone, the
  /// brain exchange it started, an action in flight, the last result, the
  /// mesh — and none of them is inferred from a timer or a mood. The mapping
  /// itself lives in [coreStateFor], with the states this build cannot
  /// evidence left out of the vocabulary entirely.
  NexusCoreState get _coreState {
    final mesh = widget.mesh;
    final last = _conversation.lastResult;
    return coreStateFor(
      listening: _listening,
      thinking: _brainThinking,
      // `_sending` is exactly "an action is being carried out": the view sets
      // it around a local device action and around a request handed to a
      // paired device, and nowhere else.
      working: _sending,
      // The vocabulary decides what counts as a failure (see
      // [AgentResultStatusWording.isFailure]): only a thing Nexus genuinely
      // could not do. A question, a no the user gave, and a gate they have
      // not answered are all something other than an error.
      failed: last != null && last.status.isFailure,
      // Offline only means something when there is something to be offline
      // from. With no paired devices Nexus is whole on its own, and saying
      // "offline" would invent a problem.
      offline: mesh.pairedDevices.isNotEmpty && mesh.onlineCount == 0,
    );
  }

  /// The conversation's secondary actions, in one place instead of two icon
  /// buttons in the header: a long press on the header row opens this sheet.
  /// Both entries call exactly the methods the old buttons did.
  Future<void> _showConversationMenu() async {
    // Two verbs: an action sheet is the shape iOS gives them, with the blur,
    // the separated Cancel button and the tap-outside barrier the framework
    // already draws. The old subtitles were the same sentence the labels
    // already say.
    await showNexusActions<void>(
      context: context,
      actions: (popup) => [
        CupertinoActionSheetAction(
          onPressed: () {
            Navigator.pop(popup);
            _startNewConversation();
          },
          child: const Text('New conversation'),
        ),
        CupertinoActionSheetAction(
          onPressed: () {
            Navigator.pop(popup);
            unawaited(_showDreamReview(context));
          },
          child: const Text('What I still misunderstand'),
        ),
      ],
    );
  }

  /// Clears the thread and gets out of the way, so the next thing the user
  /// types starts a conversation rather than continuing the one they just
  /// ended — a pending question is dropped from the service too, so it can
  /// never swallow that new input.
  ///
  /// Work already running is deliberately not cancelled or hidden: a phone
  /// call in progress finishes and still reports its outcome. A conversation
  /// ending is not a reason to leave the user uninformed about what Nexus did.
  void _startNewConversation() {
    final pending = _conversation.pendingKey;
    if (pending != null) _service.cancelPending(pending);
    _conversation.reset();
    setState(() {
      _everConversed = true; // a thread existed; this is not a first run
      _reply = null;
      _voiceConfirm = null;
      _contactConfirm = null;
      _controller.clear();
    });
    _focus.requestFocus();
  }

  Widget _buildResult() {
    if (_conversation.isEmpty && _incoming() == null) {
      // Setup must be completable before the composer appears: the composer is
      // hidden while onboarding is active, so skipping the setup view once a
      // device has been paired would hide the only way to finish it.
      if (_onboardingActive) return _welcomeView();
      // The greeting belongs to a device that has never talked to Nexus.
      // Once a thread has existed, an empty thread is an invitation, not a
      // hello — and clearing a conversation must never feel like being reset
      // to the first day.
      return widget.mesh.pairedDevices.isEmpty && !_everConversed
          ? _welcomeView()
          : _emptyChat();
    }

    final incoming = _incoming();
    // reverse:true is the chat pattern — the newest exchange pins to the
    // bottom automatically, and the incoming-request card (last child) stays
    // pinned at the top.
    final entries = _conversation.entries.reversed.toList();
    return ListView(
      reverse: true,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      children: [
        for (final (i, entry) in entries.indexed) ...[
          // Keyed by the entry itself, so the entrance belongs to the card
          // that just arrived rather than to the position it took: the list
          // is newest-first, so without a key every card would hand its
          // animation to whatever replaced it at the same index.
          KeyedSubtree(
            key: ObjectKey(entry),
            child: i == 0
                ? _AnswerEntrance(child: _entryView(entry, isLast: true))
                : _entryView(entry, isLast: false),
          ),
          const SizedBox(height: 12),
        ],
        if (incoming != null) ...[
          _incomingRequestView(incoming),
          const SizedBox(height: 12),
        ],
      ],
    );
  }

  /// One quiet line about the local brain: probing, offline (tap to retry
  /// after installing Ollama or pulling a model), or the installed model.
  /// Only shown when a brain is attached.
  Widget _brainStatusLine() {
    final palette = NexusPalette.of(context);
    final brain = widget.brain;
    // A mesh model ("mesh:…") means the brain lives on a paired device —
    // say so in words the phone user understands, and never tell them to
    // install Ollama.
    //
    // A phone is that case even before anything is paired: its brain *is* a
    // [DistributedBrain], because Android cannot run Ollama at all. The phone
    // showed a dead end ("install Ollama and pull a model") to somebody with
    // no way to install it; what they can actually do is pair their PC.
    final viaMesh =
        widget.brain is DistributedBrain ||
        _conversation.brainModel.startsWith('mesh:');
    final (icon, color, text) = switch (_conversation.brainHealth) {
      BrainHealth.probing => (
        Icons.sync_rounded,
        palette.textSecondary,
        'Looking for your local brain…',
      ),
      BrainHealth.offline => (
        Icons.memory_rounded,
        palette.warning,
        viaMesh
            ? 'No brain reachable — pair your PC to share its brain (tap to retry)'
            : 'Local brain offline — install Ollama and pull a model (tap to retry)',
      ),
      BrainHealth.online => (
        Icons.auto_awesome_rounded,
        palette.success,
        viaMesh
            ? 'Brain: your PC (via mesh)'
            : 'Local brain: ${_conversation.brainModel}',
      ),
    };
    // A pressable, not a bare GestureDetector: this strip answers the finger
    // on touch-down and settles on a spring, where a GestureDetector only
    // reacted once the finger came up.
    return NexusPressable(
      onTap: _conversation.brainHealth == BrainHealth.probing || brain == null
          ? null
          : () => unawaited(_conversation.probe(brain)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          NexusSpace.page,
          NexusSpace.xs,
          NexusSpace.page,
          0,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 12, color: color),
            const SizedBox(width: NexusSpace.xs),
            Flexible(
              child: Text(
                text,
                textAlign: TextAlign.center,
                style: NexusType.caption2.copyWith(color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The quiet way back into the teach loop after the brain answered: one
  /// tap opens the same learn dialog the dream review uses, so the phrase
  /// can still become a real command (and sync to every paired device).
  Widget _teachAffordance(ConversationEntry entry) {
    final key = entry.teachKey!;
    final phrase = key.startsWith('teach:')
        ? key.substring('teach:'.length)
        : key;
    return Align(
      alignment: Alignment.centerLeft,
      child: NexusPressable(
        borderRadius: BorderRadius.circular(NexusRadius.xs),
        onTap: () => unawaited(_teachThis(phrase, entry)),
        child: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            'Or teach me what this means',
            style: NexusType.caption1.copyWith(
              color: NexusColors.accent.withValues(alpha: 0.9),
              decoration: TextDecoration.underline,
              decorationColor: NexusColors.accent.withValues(alpha: 0.5),
            ),
          ),
        ),
      ),
    );
  }

  /// Opens the teach dialog for a phrase the brain answered. On success the
  /// reply card becomes the learning confirmation (one bubble pair stays one
  /// pair), and the taught phrase works everywhere from the next ask.
  Future<void> _teachThis(String phrase, ConversationEntry entry) async {
    HapticFeedback.selectionClick();
    final learned = await showDialog<AgentDispatchResult>(
      context: context,
      builder: (_) => _TeachPhraseDialog(
        phrase: phrase,
        service: _service,
        platform: _platform,
      ),
    );
    if (!mounted || learned == null) return;
    _conversation.replaceEntry(entry, learned);
  }

  /// One exchange in the thread: a user bubble, or an assistant card with its
  /// status chip (only on the newest exchange, so history stays calm).
  Widget _entryView(ConversationEntry entry, {required bool isLast}) {
    if (entry.userText case final String user) {
      // The user's own words, right-aligned on a quiet surface. Deliberately
      // not accent-tinted any more: colour in this app means "Nexus is doing
      // something", and a column of blue balloons spends it on decoration.
      return Align(
        alignment: Alignment.centerRight,
        child: Semantics(
          container: true,
          label: 'You: $user',
          child: Container(
            constraints: const BoxConstraints(maxWidth: 320),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: NexusPalette.of(context).surfaceSecondary,
              borderRadius: const BorderRadius.all(Radius.circular(18)),
            ),
            child: Text(
              user,
              style: NexusType.body.copyWith(color: NexusColors.text),
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
            entry.pending
                ? _workingChip(_fetchProgress)
                : _statusChip(result.status, result.message),
            const SizedBox(height: 12),
          ],
          if (result.dispatch case final AgentDeviceList list)
            _deviceListView(list.devices),
          if (result.dispatch case final AgentActionPlan plan) _planView(plan),
          if (result.dispatch case final AgentMessage message)
            isLast && message.live
                ? _liveClockView()
                : _messageView(
                    message,
                    // Regenerate is offered only where re-asking cannot re-run
                    // anything: a card that answered a question the
                    // interpreter did not know ran no action, so asking again
                    // is a second answer rather than a second side effect.
                    regenerate: isLast && entry.teachKey != null,
                  ),
          // The brain answered a "teach me" phrase — keep the teaching loop
          // one quiet tap away instead of losing it to the conversation.
          if (isLast && entry.teachKey != null) _teachAffordance(entry),
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

  /// The greeting a blank conversation opens on.
  ///
  /// Large, centred, and with nothing above it — no glyph, no card — with the
  /// suggestions directly under it, which is the shape ChatGPT, Claude and
  /// DeepSeek all converge on: a blank thread is an invitation to say
  /// something, so the first thing on screen is what to say. The previous
  /// version put a 44px icon and two lines in the middle of the page and left
  /// the chips in a separate row at the bottom, saying the same thing twice
  /// in two places, neither of them where the eye starts.
  Widget _emptyChat() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        NexusSpace.xxl,
        NexusSpace.huge,
        NexusSpace.xxl,
        NexusSpace.xl,
      ),
      children: [
        Text(
          'Ask me anything — I listen and do.',
          textAlign: TextAlign.center,
          style: NexusType.title.copyWith(
            color: NexusColors.text,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: NexusSpace.sm),
        Text(
          'Type below, or tap a suggestion to try one.',
          textAlign: TextAlign.center,
          style: NexusType.body.copyWith(color: NexusColors.muted),
        ),
        const SizedBox(height: NexusSpace.xxl),
        _suggestionChips(wrapped: true, limit: 4),
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
                  style: NexusType.callout.copyWith(
                    color: NexusColors.text,
                    fontWeight: FontWeight.w600,
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
                  style: NexusType.callout.copyWith(
                    color: NexusColors.text,
                    fontWeight: FontWeight.w600,
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

  /// The chip a card wears while its own action is still running.
  ///
  /// A plan is not an outcome, so until the executor returns there is no
  /// result to report — only the fact that work is in flight. The word comes
  /// from [NexusCoreState.working] so the card and the core say the same thing
  /// at the same moment, and no chip can claim a result before one exists.
  /// The chip a still-running action wears. [label] is the live line a fetch
  /// reports while it moves bytes; without one it says the core's own word
  /// for work in flight, which is what every other action says.
  /// What Nexus is doing right now, in one word and three dots.
  ///
  /// The dots are the DeepSeek cue: work in progress is shown as motion that
  /// small, not as a spinner. A spinner is the shape a machine uses for
  /// "blocked on something I cannot name", and Nexus is not blocked — it is
  /// reading what you asked.
  Widget _workingChip([String? label]) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: NexusColors.accent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const _ThinkingDots(),
              const SizedBox(width: NexusSpace.sm),
              Text(
                label ?? NexusCoreState.working.label,
                style: NexusType.caption1.copyWith(
                  color: NexusColors.accent,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _statusChip(AgentResultStatus status, String message) {
    // Which tint a status wears is ours to choose; what it says is the
    // status's own business (see `AgentResultStatusWording`). The chip may
    // never be a bare verdict, so it shows the status's explanation whenever
    // the result arrived without a reason of its own.
    final color = switch (status) {
      AgentResultStatus.succeeded => NexusColors.ok,
      AgentResultStatus.required => NexusColors.warn,
      AgentResultStatus.denied => NexusColors.danger,
      AgentResultStatus.unavailable => NexusColors.muted,
      AgentResultStatus.needsInfo => NexusColors.warn,
    };
    final explanation = status.explain(message);
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            status.label,
            style: NexusType.caption1.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (explanation.isNotEmpty) ...[
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              explanation,
              style: NexusType.caption1.copyWith(color: NexusColors.muted),
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
                  style: NexusType.callout.copyWith(
                    color: NexusColors.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          if (ask.hint != null) ...[
            const SizedBox(height: 6),
            Text(
              ask.hint!,
              style: NexusType.caption1.copyWith(color: NexusColors.muted),
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
                        style: NexusType.callout.copyWith(
                          color: NexusColors.text,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      d.id,
                      style: NexusType.caption2.copyWith(
                        color: NexusColors.muted,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      d.online ? 'Online' : 'Offline',
                      style: NexusType.caption2.copyWith(
                        color: d.online ? NexusColors.ok : NexusColors.muted,
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
          style: NexusType.caption1.copyWith(color: NexusColors.muted),
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
          style: NexusType.caption2.copyWith(color: NexusColors.muted),
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
        style: NexusType.caption1.copyWith(color: NexusColors.muted),
      ),
      const SizedBox(height: 6),
      Text(
        'Target: ${request.target} · Action: ${request.action}',
        style: NexusType.caption2.copyWith(color: NexusColors.muted),
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
        style: NexusType.caption1.copyWith(
          color: failed ? NexusColors.danger : NexusColors.text,
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
      case AgentActions.calendarRead:
        return 'Read calendar';
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
        // Naming a queued action is the registry's job — a raw id like
        // 'calendar.add' is not something to show a person.
        return capabilityFor(request.action)?.label ?? request.action;
    }
  }

  /// One of Nexus's own answers: full width, no bubble.
  ///
  /// This is the single biggest difference from a chat app that gives both
  /// sides a balloon. The reply is the page's own text, set at a comfortable
  /// reading size and leading, so a long answer reads as a document instead of
  /// as a caption inside a box — and the two sides are told apart by *where*
  /// they sit rather than by two competing fills.
  ///
  /// Its verbs are one long press away, as an action sheet (see
  /// [_showAnswerActions]) and as the card's own semantics actions, because a
  /// screen reader cannot press and hold.
  Widget _messageView(AgentMessage message, {bool regenerate = false}) {
    final actions = _answerActions(message, regenerate: regenerate);
    return Semantics(
      container: true,
      customSemanticsActions: {
        for (final action in actions)
          CustomSemanticsAction(label: action.label): action.run,
      },
      child: NexusPressable(
        onLongPress: () => unawaited(
          _showAnswerActions(actions, title: message.text),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: NexusSpace.xs),
          child: SizedBox(
            width: double.infinity,
            child: Text(
              message.text,
              style: NexusType.body.copyWith(
                color: NexusColors.text,
                // Looser than the token's leading: a reply is read in
                // sentences, and 15pt at 1.33 is a caption's rhythm.
                height: 1.45,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The verbs on one of Nexus's own answers, in the order the sheet shows
  /// them. Empty for a live widget (the clock), whose text is not a copy of
  /// anything stable.
  List<({String label, VoidCallback run})> _answerActions(
    AgentMessage message, {
    required bool regenerate,
  }) => [
    (label: 'Copy', run: () => unawaited(_copyAnswer(message.text))),
    if (regenerate && _lastInput.isNotEmpty)
      (label: 'Regenerate', run: _regenerate),
  ];

  /// Copies an answer to the system clipboard and says so. A silent copy is
  /// indistinguishable from a long press that did nothing, so the snackbar is
  /// part of the action rather than decoration.
  Future<void> _copyAnswer(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Copied.')));
  }

  /// Asks the last question again, exactly as typing it once more would —
  /// the answer is regenerated, not a stored one replayed.
  void _regenerate() {
    _controller.text = _lastInput;
    _onSubmit();
  }

  /// Opens the answer's verbs as an action sheet. An action sheet rather than
  /// an inline row: the card has no room for chrome, and a short list of verbs
  /// is the shape iOS gives exactly this.
  Future<void> _showAnswerActions(
    List<({String label, VoidCallback run})> actions, {
    required String title,
  }) async {
    HapticFeedback.selectionClick();
    final chosen = await showNexusActions<String>(
      context: context,
      title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
      actions: (popup) => [
        for (final action in actions)
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(popup, action.label),
            child: Text(action.label),
          ),
      ],
    );
    if (chosen == null) return;
    for (final action in actions) {
      if (action.label == chosen) action.run();
    }
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

/// A registry phrase in quotes for a hint line.
String _quoted(String? phrase) => phrase == null ? 'ask me' : '"$phrase"';

/// The registry phrase for [id] on [platform], or null when that system
/// cannot reach it — the only way this file asks for wording to show a user.
String? _phrase(String id, String platform) => advertisedPhrase(id, platform);

/// The empty input's placeholder, named after two phrases the capability
/// registry says Nexus can actually run on [platform], so the hint can never
/// advertise a dead end.
String _askHintFor(String platform) {
  final phrases = [
    _phrase(AgentActions.weatherGet, platform),
    _phrase(AgentActions.navOpen, platform),
  ].whereType<String>().toList();
  return phrases.isEmpty
      ? 'Ask anything…'
      : 'Ask anything — ${phrases.map((p) => '"$p"').join(', ')}…';
}

/// The teach dialog's placeholder, drawn from the registry's own device
/// phrase rather than spelled out beside it.
String _teachHint(String platform) {
  final phrase = _phrase(AgentActions.deviceList, platform);
  return phrase == null ? 'means…' : 'means… e.g. "$phrase"';
}

/// Three dots pulsing in sequence while Nexus is working — the only motion an
/// answer in progress carries.
///
/// Each dot is a third of the cycle behind the one before it, so the group
/// reads as one travelling pulse instead of three blinks. Small (16×6) and
/// slow (1.2 s) on purpose: this sits in the corner of the eye above an answer
/// the user has not read yet, and anything faster or bigger would compete with
/// the reading rather than report on the writing.
class _ThinkingDots extends StatefulWidget {
  const _ThinkingDots();

  @override
  State<_ThinkingDots> createState() => _ThinkingDotsState();
}

class _ThinkingDotsState extends State<_ThinkingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void initState() {
    super.initState();
    _pulse.repeat();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reduce motion stops the loop rather than shortening it: three dots that
    // never move are still three dots, and the word beside them already says
    // what is happening.
    if (MediaQuery.maybeDisableAnimationsOf(context) == true) {
      _pulse.stop();
      _pulse.value = 0;
    } else if (!_pulse.isAnimating) {
      _pulse.repeat();
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = NexusPalette.of(context);
    return SizedBox(
      width: 16,
      height: 6,
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, _) => CustomPaint(
          painter: _ThinkingDotsPainter(
            color: palette.accent,
            phase: _pulse.value,
          ),
          size: const Size(16, 6),
        ),
      ),
    );
  }
}

/// Three 3px dots, one every 5px, each at a different point in the same cycle.
class _ThinkingDotsPainter extends CustomPainter {
  _ThinkingDotsPainter({required this.color, required this.phase});

  final Color color;
  final double phase;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = size.height / 2;
    final paint = Paint();
    for (var i = 0; i < 3; i++) {
      // A third of the cycle apart, lifted 0.45 -> 1.0 and back so the pulse
      // travels rather than flashing.
      final t = (phase + i / 3) % 1.0;
      paint.color = color.withValues(alpha: 0.45 + 0.55 * (1 - (t * 2 - 1).abs()));
      canvas.drawCircle(
        Offset(radius + i * (size.width - size.height) / 2, radius),
        radius,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_ThinkingDotsPainter old) =>
      old.phase != phase || old.color != color;
}

/// A card that fades in as it appears.
///
/// A reply arrives whole — there is no token stream to animate — so this is
/// the whole animation, and it is opacity only: no slide, no scale, and above
/// all no typewriter. Text that is already complete and is then revealed
/// letter by letter is a performance the reader has to sit through, and it is
/// the clearest tell that a model is behind the screen.
///
/// The duration is the design system's opacity value rather than a new one;
/// see `docs/notes/motion-audit.md` §12. With reduce motion on, the card is
/// simply there.
class _AnswerEntrance extends StatefulWidget {
  const _AnswerEntrance({required this.child});

  final Widget child;

  @override
  State<_AnswerEntrance> createState() => _AnswerEntranceState();
}

class _AnswerEntranceState extends State<_AnswerEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: NexusMotion.fast,
  )..forward();

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.maybeDisableAnimationsOf(context) == true) {
      return widget.child;
    }
    return FadeTransition(
      opacity: CurvedAnimation(parent: _fade, curve: Curves.easeOut),
      child: widget.child,
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
      style: NexusType.callout.copyWith(
        color: NexusColors.text,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

/// The "or teach me what this means" dialog: one field, one check — the
/// same learning the dream review uses, so a phrase the brain answered can
/// still become a real command. Pops with the learning result on success.
class _TeachPhraseDialog extends StatefulWidget {
  final String phrase;
  final CommandService service;

  /// The system this device is — what the placeholder may name.
  final String platform;

  const _TeachPhraseDialog({
    required this.phrase,
    required this.service,
    required this.platform,
  });

  @override
  State<_TeachPhraseDialog> createState() => _TeachPhraseDialogState();
}

class _TeachPhraseDialogState extends State<_TeachPhraseDialog> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _teach() {
    final meaning = _controller.text.trim();
    if (meaning.isEmpty) return;
    final result = widget.service.learn(widget.phrase, meaning);
    if (result.status == AgentResultStatus.needsInfo) {
      final ask = result.dispatch as AgentClarification?;
      setState(() {
        _error = ask == null
            ? result.message
            : '${ask.question} ${ask.hint ?? ''}';
      });
      return;
    }
    Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: NexusColors.surface,
      title: Text(
        'Teach "${widget.phrase}"',
        style: NexusType.body.copyWith(
          color: NexusColors.text,
          fontWeight: FontWeight.w600,
        ),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            onSubmitted: (_) => _teach(),
            decoration: InputDecoration(
              isDense: true,
              hintText: _teachHint(widget.platform),
              border: const OutlineInputBorder(),
            ),
            style: NexusType.caption.copyWith(color: NexusColors.text),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                style: NexusType.caption1.copyWith(color: NexusColors.danger),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _teach,
          child: const Text('Teach'),
        ),
      ],
    );
  }
}

/// The dream review: phrases the assistant gave up on, mined from its own
/// log, each teachable in place. One taught phrase closes that gap forever.
class _DreamSheet extends StatefulWidget {
  final CommandService service;
  final List<DreamInsight> insights;

  /// The system this device is — what a row's placeholder may name.
  final String platform;

  /// The sheet's scroll controller: the framework watches it so a downward
  /// drag on a scrolled-to-top list dismisses the sheet.
  final ScrollController scroll;

  const _DreamSheet({
    required this.service,
    required this.insights,
    required this.platform,
    required this.scroll,
  });

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
                    style: NexusType.body.copyWith(
                      color: NexusColors.text,
                      fontWeight: FontWeight.w700,
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
              style: NexusType.caption1.copyWith(color: NexusColors.muted),
            ),
            const SizedBox(height: 14),
            if (widget.insights.isEmpty)
              Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  'Sweet dreams.',
                  style: NexusType.caption.copyWith(color: NexusColors.muted),
                ),
              )
            else
              Flexible(
                child: ListView.builder(
                  controller: widget.scroll,
                  shrinkWrap: true,
                  itemCount: open.length,
                  itemBuilder: (context, index) => _DreamRow(
                    service: widget.service,
                    phrase: open[index].phrase,
                    count: open[index].count,
                    platform: widget.platform,
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

  /// The system this device is — what the placeholder may name.
  final String platform;

  const _DreamRow({
    required this.service,
    required this.phrase,
    required this.count,
    required this.onTaught,
    required this.platform,
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
    final palette = NexusPalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: NexusSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '"${widget.phrase}"  ·  asked ${widget.count} '
            '${widget.count == 1 ? 'time' : 'times'}',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('dream-meaning'),
                  controller: _controller,
                  onSubmitted: (_) => _teach(),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: _teachHint(widget.platform),
                    border: const OutlineInputBorder(),
                  ),
                  style: NexusType.caption.copyWith(color: NexusColors.text),
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
              padding: const EdgeInsets.only(top: NexusSpace.xs),
              child: Text(
                _error!,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: palette.danger),
              ),
            ),
        ],
      ),
    );
  }
}
