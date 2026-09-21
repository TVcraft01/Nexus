import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../../core/agent_contract.dart';
import '../../core/brain.dart';
import '../../core/command_service.dart';
import '../../core/conversation.dart';
import '../../core/conversation_engine.dart';
import '../../core/device_actions.dart';
import '../../core/predictions.dart';
import '../../core/profile.dart';
import '../../core/query_log.dart';
import '../../core/speech.dart';
import '../../mesh/mesh_service.dart';
import '../device_executor.dart';
import 'design_system.dart';
import 'nexus_orb.dart';

/// Human-first presentation layer for Nexus' existing assistant engines.
///
/// This screen is a conversation, and only a conversation: one compact
/// presence row (the globe plus one line saying what Nexus is doing), the
/// thread, and the composer where the thumb already is. Nothing above the
/// thread is a hero, because the user came here to talk, not to read an
/// introduction.
///
/// Everything that decides or does stays exactly where it was —
/// [CommandService] works out what an ask means, [ConversationEngine] owns the
/// thread and the brain exchange, [DeviceExecutor] runs what this device can
/// really run, and the mesh carries the rest. This file invents nothing: a
/// suggestion is only shown when the real interpreter parses it, a globe state
/// is only shown when a real signal evidences it, and an error always carries
/// what happened plus the way to try again.
class NexusV2AssistantView extends StatefulWidget {
  const NexusV2AssistantView({
    super.key,
    required this.mesh,
    this.brain,
    this.executor,
  });

  final MeshService mesh;

  /// The optional local brain. When present, a phrase the interpreter does not
  /// know gets a real conversational reply; when it is absent (or proven
  /// offline) the interpreter's own question stays on the card instead.
  final LocalBrain? brain;

  /// The real device executor by default. Injectable for the same reason the
  /// brain is: the one path a widget test cannot otherwise drive is an action
  /// that fails by throwing, and that path decides whether the globe can be
  /// stranded claiming Nexus is working.
  final DeviceExecutor? executor;

  @override
  State<NexusV2AssistantView> createState() => _NexusV2AssistantViewState();
}

class _NexusV2AssistantViewState extends State<NexusV2AssistantView> {
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
  };

  /// The phrases Nexus may offer on a device it knows nothing about yet.
  ///
  /// Deliberately conversation-sized and platform-neutral, and each one is
  /// checked against the ability check below, so a starter is only ever
  /// something the shipped path really answers.
  static const _starterPhrases = [
    'what time is it',
    'what is the weather',
  ];

  final _input = TextEditingController();
  final _focus = FocusNode();
  final _conversation = ConversationEngine();
  late final DeviceExecutor _executor = widget.executor ?? DeviceExecutor();
  final _profile = SharedPrefsProfileStore();
  late final CommandService _service;

  UserProfile? _profileState;
  bool _profileLoaded = false;

  /// Real signals, one each: the microphone is open; an ask is with the brain;
  /// a device action is being carried out. The globe and the status line are
  /// both derived from these and from nothing else.
  bool _listening = false;
  bool _thinking = false;
  bool _working = false;

  /// Whether a voice is really coming out, from the speech engine's own
  /// utterance start/stop. On a platform that cannot report it this stays
  /// false and the globe never claims Nexus is speaking.
  late final ValueListenable<bool> _speaking;

  /// The entries already read out loud, by identity, so a spoken exchange is
  /// spoken exactly once even when the thread is rebuilt around it.
  final Set<ConversationEntry> _spokenEntries = {};

  /// An unresolved contact: what Nexus was asked to do and the real near
  /// matches the platform found. A question with real choices, never a guess.
  ({AgentRequest request, String message, List<String> candidates})? _confirm;

  /// How to honestly try the newest failure again, or null when re-running is
  /// not something we can truthfully offer (a missing detail is a question,
  /// not a failure).
  Future<void> Function()? _retry;

  /// The phrases this person really asks, mined from the ask log after the
  /// first frame. Drives the suggestions: their own words beat our examples.
  List<Habit>? _habits;

  /// The text of the newest ask — what Allow and the brain exchange re-run.
  String _lastAsk = '';

  @override
  void initState() {
    super.initState();
    _conversation.addListener(_onConversationChanged);
    _speaking = SpeechPlayback.current.speaking;
    SpeechPlayback.current.listen();
    _speaking.addListener(_onSpeakingChanged);
    _service = CommandService(
      devices: _devices,
      local: AgentDeviceSnapshot(
        id: widget.mesh.identity.id,
        name: widget.mesh.identity.name,
        online: true,
        capabilities: defaultCapabilitiesFor(widget.mesh.identity.platform),
      ),
      locallyExecutable: _selfRunActions,
      memory: AgentMemory(
        learned: widget.mesh.store.agentLearned,
        defaults: widget.mesh.store.agentDefaults,
        facts: widget.mesh.store.agentFacts,
      ),
      onMemoryChanged: () {
        widget.mesh.store
          ..agentLearned = _service.learnedSnapshot
          ..agentDefaults = _service.defaultsSnapshot
          ..agentFacts = _service.factsSnapshot;
        unawaited(widget.mesh.store.save());
      },
      onPhraseLearned: (phrase, meaning) =>
          unawaited(widget.mesh.broadcastLearnedPhrase(phrase, meaning)),
      onFactLearned: (fact) => unawaited(widget.mesh.broadcastFact(fact)),
      onDefaultLearned: (key, value) =>
          unawaited(widget.mesh.broadcastDefault(key, value)),
    );
    widget.mesh.onLearnedPhraseReceived = _service.adoptLearned;
    widget.mesh.onFactReceived = _service.adoptFact;
    widget.mesh.onDefaultReceived = _service.adoptDefault;
    unawaited(_loadProfile());
    // The user's own routines, read once the first frame is up — never on the
    // path that draws the screen.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_loadHabits());
    });
  }

  @override
  void dispose() {
    widget.mesh.onLearnedPhraseReceived = null;
    widget.mesh.onFactReceived = null;
    widget.mesh.onDefaultReceived = null;
    _speaking.removeListener(_onSpeakingChanged);
    _conversation.removeListener(_onConversationChanged);
    _conversation.dispose();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onSpeakingChanged() {
    if (mounted) setState(() {});
  }

  void _onConversationChanged() {
    if (!mounted) return;
    setState(() {});
    // Voice mode: a reply to a spoken ask is read out loud, exactly once,
    // wherever the card landed. Typed exchanges stay quiet, so the assistant
    // never starts talking at somebody who did not speak to it.
    for (final entry in _conversation.entries) {
      if (!_spokenEntries.add(entry)) continue;
      if (!entry.spokenAsk) continue;
      final text = ConversationEngine.speakableText(entry);
      if (text != null) unawaited(SpeechOutput.current.speak(text));
    }
  }

  List<AgentDeviceSnapshot> _devices() {
    return [
      AgentDeviceSnapshot(
        id: widget.mesh.identity.id,
        name: widget.mesh.identity.name,
        online: true,
        capabilities: defaultCapabilitiesFor(widget.mesh.identity.platform),
      ),
      for (final d in widget.mesh.pairedDevices)
        AgentDeviceSnapshot(
          id: d.id,
          name: d.name,
          online: widget.mesh.isOnline(d.id),
          capabilities: defaultCapabilitiesFor(d.platform),
        ),
    ];
  }

  Future<void> _loadProfile() async {
    final p = await _profile.read();
    if (!mounted) return;
    setState(() {
      _profileState = p;
      _profileLoaded = true;
    });
  }

  Future<void> _loadHabits() async {
    final lines = await QueryLog.i.readAll();
    if (!mounted) return;
    setState(() => _habits = const Predictions().habits(lines, limit: 4));
  }

  /// What Nexus may offer right now, and only what is true.
  ///
  /// First the user's own routines — phrases they really ask twice or more —
  /// and otherwise a couple of conversation-sized starters. Every candidate has
  /// to pass [CommandService.carriesOut], the same walk the composer takes: a
  /// phrase that only parses, and would end at a gate nothing can open, is
  /// never offered as a chip.
  List<String> _suggestions() {
    final out = <String>[];
    for (final habit in _habits ?? const <Habit>[]) {
      if (habit.count < 2) continue;
      if (out.contains(habit.phrase)) continue;
      if (!_service.carriesOut(habit.phrase)) continue;
      out.add(habit.phrase);
      if (out.length == 2) return out;
    }
    for (final phrase in _starterPhrases) {
      if (out.length == 2) break;
      if (out.contains(phrase)) continue;
      if (!_service.carriesOut(phrase)) continue;
      out.add(phrase);
    }
    return out;
  }

  // ── What the globe says ──────────────────────────────────────────────────

  /// The one owner of the globe's state, fed only by signals this view really
  /// has. The mapping itself lives in [orbStateFor], with the states this
  /// build cannot evidence left out of the vocabulary entirely.
  NexusOrbState get _orbState {
    final last = _conversation.lastResult;
    final mesh = widget.mesh;
    return orbStateFor(
      listening: _listening,
      thinking: _thinking,
      speaking: _speaking.value,
      working: _working,
      failed: last?.status == AgentResultStatus.unavailable,
      // Offline only means something when there is something to be offline
      // from: with no paired devices Nexus is whole on its own.
      offline: mesh.pairedDevices.isNotEmpty && mesh.onlineCount == 0,
    );
  }

  /// What Nexus is doing, in words — the same truth the globe shows in
  /// motion. Nothing here is inferred from a timer.
  String get _stateLine => switch (_orbState) {
        NexusOrbState.listening => 'Listening — say it when you are ready',
        NexusOrbState.thinking => 'Thinking about what you asked',
        NexusOrbState.working => 'Working on it',
        NexusOrbState.speaking => 'Speaking',
        NexusOrbState.error => 'That last one did not work',
        NexusOrbState.offline => 'No paired device is reachable right now',
        NexusOrbState.idle => 'Ready — ask me anything',
      };

  // ── One ask, end to end ──────────────────────────────────────────────────

  Future<void> _submit({bool voice = false}) async {
    final text = _input.text.trim();
    if (text.isEmpty || _thinking || _working) return;
    HapticFeedback.selectionClick();
    _input.clear();
    _lastAsk = text;
    // An open question: the next input answers it — unless it is itself a
    // command. The user moving on must never be learned as the meaning of a
    // phrase that was never about it.
    final pending = _conversation.pendingKey;
    final answers = pending != null && !_service.parsesAsCommand(text);
    if (pending != null && !answers) _service.cancelPending(pending);
    setState(() {
      _confirm = null;
      _retry = null;
      _thinking = true;
    });

    // Nothing in this build can grant a local approval, so asking for one
    // would only ever produce a card with no way forward; the actions this
    // phone runs are declared executable up front instead.
    final result = _service.execute(
      text,
      requestId: 'v2-${DateTime.now().microsecondsSinceEpoch}',
      answerTo: answers ? pending : null,
    );
    _conversation.appendResult(result, asUser: text, spoken: voice);
    try {
      await _handle(result, voice: voice);
    } finally {
      if (mounted) setState(() => _thinking = false);
    }
  }

  /// Carries out whatever the interpreter decided, honestly.
  Future<void> _handle(AgentDispatchResult result, {required bool voice}) async {
    switch (result.dispatch) {
      case final AgentActionPlan plan:
        await _dispatchPlan(plan, spoken: voice);
      case final AgentMessage message when message.action != null:
        if (!_selfRunActions.contains(message.action)) return;
        await _runLocal(
          AgentRequest(
            requestId: 'v2-${DateTime.now().microsecondsSinceEpoch}',
            target: widget.mesh.identity.id,
            action: message.action!,
            arguments: message.arguments ?? const {},
          ),
          spoken: voice,
        );
      case final AgentClarification ask
          when widget.brain != null &&
              ask.key.startsWith('teach:') &&
              _conversation.brainHealth != BrainHealth.offline:
        // A phrase the interpreter does not know: hand it to the local brain
        // for a real conversational reply. The interpreter's own question
        // stays on the card meanwhile, so the user is never left with nothing.
        if (mounted) setState(() => _thinking = true);
        await _conversationFallback(_lastAsk, result);
      case _:
        break;
    }
  }

  Future<void> _conversationFallback(
    String input,
    AgentDispatchResult result,
  ) async {
    final brain = widget.brain;
    if (brain == null) return;
    try {
      await _conversation.converse(
        brain: brain,
        input: input,
        original: result,
        context: _context,
        onBrainAnswered: (key) {
          if (key != null) _service.cancelPending(key);
        },
      );
    } finally {
      // The exchange is over however it ended; the globe stops thinking.
      if (mounted) setState(() => _thinking = false);
    }
  }

  ConversationContext _context() => ConversationContext(
        userName: _profileState?.userName,
        assistantName: _profileState?.assistantName ?? 'Nexus',
        facts: _service.factsSnapshot,
        learned: _service.learnedSnapshot,
        defaults: _service.defaultsSnapshot,
      );

  /// A plan aimed at another device: the peer re-gates it on its own side, and
  /// its answer is shown in its own name. A device that cannot be reached says
  /// so and stays retryable.
  Future<void> _dispatchPlan(AgentActionPlan plan, {required bool spoken}) async {
    if (plan.request.target == widget.mesh.identity.id &&
        _selfRunActions.contains(plan.request.action)) {
      await _runLocal(plan.request, spoken: spoken);
      return;
    }
    if (plan.request.target.isEmpty) return;
    await _runRemote(plan.request, spoken: spoken);
  }

  Future<void> _runRemote(AgentRequest request, {required bool spoken}) async {
    if (mounted) {
      setState(() {
        _thinking = false;
        _working = true;
      });
    }
    try {
      final deviceName = _deviceName(request.target);
      final reply = await widget.mesh.sendAgentRequest(request.target, request);
      if (!mounted) return;
      final words = switch (reply?.dispatch) {
        final AgentMessage message => message.text,
        _ => reply?.message ?? '',
      };
      _conversation.appendResult(
        AgentDispatchResult(
          status: reply == null
              ? AgentResultStatus.unavailable
              : reply.status,
          message: reply == null ? 'I could not reach $deviceName.' : '',
          dispatch: reply == null
              ? null
              : AgentMessage(
                  words.isEmpty
                      ? '$deviceName answered, but did not say what happened.'
                      : '$deviceName: $words',
                ),
        ),
        replaceLast: true,
        spoken: spoken,
      );
      setState(() {
        _retry = reply == null
            ? () => _runRemote(request, spoken: false)
            : null;
      });
    } catch (error) {
      if (mounted) {
        _showFailure('I could not reach that device: $error');
        setState(() => _retry = () => _runRemote(request, spoken: false));
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  /// Runs an action on this device and shows its own outcome.
  ///
  /// Three endings, three honest cards: it worked; it could not (with the
  /// reason and one-tap retry); or it needs one detail — and when the platform
  /// found near matches, that detail is a real question with real choices and
  /// the answer is learned.
  Future<void> _runLocal(AgentRequest request, {required bool spoken}) async {
    if (mounted) {
      setState(() {
        _thinking = false;
        _working = true;
      });
    }
    try {
      final outcome = await _executor.run(request);
      if (!mounted) return;
      if (!outcome.ok && outcome.candidates.isNotEmpty) {
        _conversation.appendResult(
          AgentDispatchResult(
            status: AgentResultStatus.needsInfo,
            message: outcome.message,
          ),
          replaceLast: true,
          spoken: spoken,
        );
        setState(() {
          _confirm = (
            request: request,
            message: outcome.message,
            candidates: outcome.candidates.take(3).toList(),
          );
          _retry = null;
        });
        return;
      }
      _conversation.appendResult(
        AgentDispatchResult(
          status: _statusFor(outcome),
          message: outcome.ok ? '' : outcome.message,
          dispatch: outcome.ok ? AgentMessage(outcome.message) : null,
        ),
        replaceLast: true,
        spoken: spoken,
      );
      setState(() {
        // A question's recovery is answering it, not running it again: only a
        // genuine failure earns the retry.
        _retry = outcome.ok || outcome.needsDetail
            ? null
            : () => _runLocal(request, spoken: false);
      });
    } catch (error) {
      // A platform call that throws is still something the user has to be told
      // about — and it is the one failure with an obvious next step.
      if (mounted) {
        _showFailure('That did not run — the device action failed: $error');
        setState(() => _retry = () => _runLocal(request, spoken: false));
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  /// Replaces the newest card with a failure that carries its reason.
  void _showFailure(String reason) {
    _conversation.appendResult(
      AgentDispatchResult(
        status: AgentResultStatus.unavailable,
        message: reason,
      ),
      replaceLast: true,
    );
  }

  /// The user picked a real name from the near matches: run the action with it
  /// and remember the wording — "alx" means Alex from now on, here and on
  /// every paired device.
  Future<void> _confirmWith(String candidate) async {
    final confirm = _confirm;
    if (confirm == null) return;
    final original = confirm.request.arguments['contact']?.toString() ?? '';
    if (candidate.isNotEmpty && candidate != original) {
      _service.learnContactAlias(original, candidate);
    }
    final args = Map<String, dynamic>.of(confirm.request.arguments)
      ..['contact'] = candidate;
    setState(() => _confirm = null);
    await _runLocal(
      AgentRequest(
        requestId: 'v2-${DateTime.now().microsecondsSinceEpoch}',
        target: confirm.request.target,
        action: confirm.request.action,
        arguments: args,
      ),
      spoken: false,
    );
  }

  /// The user chose not to pick one: the question becomes their own answer, so
  /// the thread never leaves a question hanging over them.
  void _dismissConfirm() {
    setState(() => _confirm = null);
    _conversation.appendResult(
      const AgentDispatchResult(
        status: AgentResultStatus.denied,
        message: 'Okay — nothing was sent or called.',
      ),
      replaceLast: true,
    );
  }

  /// One utterance, then the recognized words run through the same pipeline as
  /// typing them — the assistant, spoken. Every ending says something real: a
  /// device with no speech service explains itself instead of pretending to
  /// listen, and a mic that heard nothing asks again.
  Future<void> _listen() async {
    if (_listening || _thinking || _working) return;
    final speech = SpeechInput.current;
    if (!speech.available) {
      _conversation.appendResult(
        const AgentDispatchResult(
          status: AgentResultStatus.unavailable,
          message:
              'Voice input is not set up on this device — typing works exactly the same way.',
        ),
        spoken: true,
      );
      return;
    }
    setState(() => _listening = true);
    try {
      final heard = await speech.listen();
      if (!mounted) return;
      final text = heard?.trim() ?? '';
      if (text.isEmpty) {
        _conversation.appendResult(
          const AgentDispatchResult(
            status: AgentResultStatus.needsInfo,
            message: 'I did not catch that — say it again?',
          ),
          spoken: true,
        );
        return;
      }
      _input.text = text;
      await _submit(voice: true);
    } finally {
      // The microphone is closed however the utterance ended — including when
      // the platform call threw.
      if (mounted) setState(() => _listening = false);
    }
  }

  void _usePrompt(String text) {
    _input.text = text;
    _focus.requestFocus();
    unawaited(_submit());
  }

  /// Clears the thread and gets out of the way, so the next thing the user
  /// types starts a conversation rather than continuing the one they ended.
  void _startNewConversation() {
    final pending = _conversation.pendingKey;
    if (pending != null) _service.cancelPending(pending);
    _conversation.clear();
    setState(() {
      _confirm = null;
      _retry = null;
      _input.clear();
    });
    _focus.requestFocus();
  }

  // ── Words ────────────────────────────────────────────────────────────────

  /// The status an action's own outcome deserves: a missing detail is a
  /// question, not a broken feature.
  AgentResultStatus _statusFor(ActionResult outcome) {
    if (outcome.ok) return AgentResultStatus.succeeded;
    return outcome.needsDetail
        ? AgentResultStatus.needsInfo
        : AgentResultStatus.unavailable;
  }

  /// What each status means in words a person reads. Never the enum's own
  /// name, which is an implementation detail — and never "Done" for something
  /// that was only a question or a refusal.
  static String _statusWords(AgentResultStatus status) => switch (status) {
        AgentResultStatus.succeeded => 'Done',
        // Core always sets its own message for this one ("Local approval is
        // required."), so this line is only the fallback that keeps the table
        // exhaustive — no control the user could press is missing with it.
        AgentResultStatus.required => 'Waiting for your approval',
        AgentResultStatus.denied => 'You said no — nothing happened',
        AgentResultStatus.unavailable => 'That did not work',
        AgentResultStatus.needsInfo => 'I need one more thing',
      };

  static bool _isFailure(AgentResultStatus status) =>
      status == AgentResultStatus.unavailable;

  /// The user's own verb, so a choice reads like the thing they asked for
  /// ("Call Alex", not "Use Alex").
  static String _verbFor(String action) => switch (action) {
        AgentActions.callPlace => 'Call',
        AgentActions.messageSend => 'Text',
        AgentActions.emailSend => 'Email',
        _ => 'Use',
      };

  /// What a request will do, in the words a person would use. Only what the
  /// arguments really say: no invented destination, no promised outcome.
  static String _describeRequest(AgentRequest request) {
    final a = request.arguments;
    return switch (request.action) {
      AgentActions.callPlace => 'Call ${a['contact'] ?? 'someone'}',
      AgentActions.messageSend => 'Text ${a['contact'] ?? 'someone'}',
      AgentActions.emailSend => 'Email ${a['contact'] ?? 'someone'}',
      AgentActions.mediaPlay => 'Play music',
      AgentActions.mediaPause => 'Pause the music',
      AgentActions.mediaNext => 'Skip to the next track',
      AgentActions.mediaPrev => 'Go back a track',
      AgentActions.mediaShuffle => 'Toggle shuffle',
      AgentActions.mediaRepeat => 'Toggle repeat',
      AgentActions.volumeSet => 'Change the volume',
      AgentActions.brightnessSet => 'Change the screen brightness',
      AgentActions.flashlightToggle => 'Toggle the flashlight',
      AgentActions.wifiToggle => 'Toggle Wi-Fi',
      AgentActions.bluetoothToggle => 'Toggle Bluetooth',
      AgentActions.timerSet => 'Set a timer',
      AgentActions.alarmSet => 'Set an alarm',
      AgentActions.screenshot => 'Take a screenshot',
      AgentActions.lockScreen => 'Lock the screen',
      AgentActions.batteryGet => 'Check the battery',
      AgentActions.systemInfo => 'Show system info',
      AgentActions.webSearch => 'Search for ${a['query'] ?? 'that'}',
      AgentActions.noteCreate => 'Make a note',
      AgentActions.calendarAdd => 'Add the event',
      AgentActions.calendarRead => 'Read the calendar',
      AgentActions.navOpen => 'Start navigation',
      AgentActions.weatherGet => 'Check the weather',
      AgentActions.ringDevice => 'Ring the device',
      AgentActions.findDevice => 'Find the device',
      AgentActions.ledBlink => 'Blink the light',
      AgentActions.clipboardWrite => 'Copy the text',
      _ => 'Do that',
    };
  }

  String _deviceName(String id) {
    if (id == widget.mesh.identity.id) return widget.mesh.identity.name;
    for (final device in widget.mesh.pairedDevices) {
      if (device.id == id) return device.name;
    }
    return id;
  }

  /// The lead line of an empty thread: one greeting, once — not a stack of
  /// introductions before the user can type.
  String get _emptyLead {
    final name = _profileState?.userName;
    if (!_profileLoaded || name == null || name.isEmpty) {
      return 'Tell me what you need — plain words are fine.';
    }
    final hour = DateTime.now().hour;
    final part = hour < 12
        ? 'Good morning'
        : hour < 18
            ? 'Good afternoon'
            : 'Good evening';
    return '$part, $name. Tell me what you need — plain words are fine.';
  }

  // ── The screen ───────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = _conversation.entries;
    return Column(
      children: [
        SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              NexusV2Space.page,
              NexusV2Space.md,
              NexusV2Space.sm,
              NexusV2Space.sm,
            ),
            child: _presence(theme, hasThread: entries.isNotEmpty),
          ),
        ),
        Expanded(
          child: entries.isEmpty
              ? _emptyState(theme)
              // The thread keeps to a readable band: on a wide window it
              // centers rather than running a line across the whole screen.
              : Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: NexusV2Layout.readableColumn,
                    ),
                    // reverse: the chat pattern — the newest exchange pins to
                    // the bottom by itself, so nothing has to scroll it there.
                    child: ListView.builder(
                      reverse: true,
                      padding: const EdgeInsets.fromLTRB(
                        NexusV2Space.page,
                        NexusV2Space.sm,
                        NexusV2Space.page,
                        NexusV2Space.md,
                      ),
                      itemCount: entries.length,
                      itemBuilder: (context, index) => _entry(
                        entries[entries.length - 1 - index],
                        theme,
                        isLast: index == 0,
                      ),
                    ),
                  ),
                ),
        ),
        if (_confirm != null) _confirmCard(theme),
        SafeArea(top: false, child: _composer(theme)),
      ],
    );
  }

  /// The whole introduction: the globe, who Nexus is, and what it is doing.
  /// One row, one line — the conversation below is the content.
  Widget _presence(ThemeData theme, {required bool hasThread}) {
    final name = _profileState?.assistantName ?? 'Nexus';
    return Row(
      children: [
        NexusOrb(
          state: _orbState,
          size: 44,
          semanticLabel: '$name — ${_orbState.label}',
        ),
        const SizedBox(width: NexusV2Space.md),
        Expanded(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(text: name, style: theme.textTheme.titleMedium),
                TextSpan(
                  text: '   $_stateLine',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (hasThread)
          IconButton(
            tooltip: 'New conversation',
            icon: const Icon(Icons.edit_outlined),
            onPressed: _startNewConversation,
          ),
      ],
    );
  }

  Widget _emptyState(ThemeData theme) {
    final suggestions = _suggestions();
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          NexusV2Space.xl,
          NexusV2Space.md,
          NexusV2Space.xl,
          NexusV2Space.xl,
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: NexusV2Layout.readableColumn,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                _emptyLead,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (suggestions.isNotEmpty) ...[
                const SizedBox(height: NexusV2Space.lg),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: NexusV2Space.sm,
                  runSpacing: NexusV2Space.sm,
                  children: [
                    for (final suggestion in suggestions)
                      ActionChip(
                        label: Text(suggestion),
                        onPressed: () => _usePrompt(suggestion),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _entry(ConversationEntry entry, ThemeData theme, {required bool isLast}) {
    if (entry.userText case final String user) {
      return Align(
        alignment: Alignment.centerRight,
        child: Semantics(
          container: true,
          label: 'You: $user',
          child: Container(
            constraints: const BoxConstraints(
              maxWidth: NexusV2Layout.bubble,
            ),
            margin: const EdgeInsets.only(
              bottom: NexusV2Space.md,
              left: 42,
            ),
            padding: const EdgeInsets.symmetric(
              horizontal: NexusV2Space.lg,
              vertical: NexusV2Space.md,
            ),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.13),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(NexusV2Radius.bubble),
                topRight: Radius.circular(NexusV2Radius.bubble),
                bottomLeft: Radius.circular(NexusV2Radius.bubble),
                bottomRight: Radius.circular(6),
              ),
            ),
            child: Text(user, style: theme.textTheme.bodyLarge),
          ),
        ),
      );
    }
    final result = entry.result;
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 18, right: 36),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (result == null)
              Text('I’m ready.', style: theme.textTheme.bodyLarge)
            else
              _cardBody(result, theme),
            if (isLast && _retry != null) ...[
              const SizedBox(height: NexusV2Space.xs),
              TextButton.icon(
                onPressed: () {
                  final retry = _retry;
                  if (retry == null) return;
                  setState(() => _retry = null);
                  unawaited(retry());
                },
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Try again'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// One card, in the dispatch's own terms: an answer is the answer, a
  /// question is a question, a plan says what it will do, and a failure says
  /// what happened plus what to do next.
  Widget _cardBody(AgentDispatchResult result, ThemeData theme) {
    final dispatch = result.dispatch;
    final (String body, String? hint) = switch (dispatch) {
      null => (
          result.message.isNotEmpty
              ? result.message
              : _statusWords(result.status),
          null,
        ),
      AgentMessage m when m.text == thinkingPlaceholder => ('Thinking…', null),
      AgentMessage m => (m.text, null),
      AgentClarification c => (c.question, c.hint),
      AgentActionPlan p => (
          _describeRequest(p.request),
          'on ${_deviceName(p.request.target)}',
        ),
      AgentDeviceList l => ('Your devices', _deviceSummary(l)),
    };
    // A failure with nothing else to say reads headline-first: what kind of
    // thing happened, then the platform's own reason under it in the error
    // colour. Left as a plain body, a failure would look like any answer.
    final bareFailure =
        dispatch == null && _isFailure(result.status);
    final headline = bareFailure ? _statusWords(result.status) : body;
    // Otherwise the reason is only added when it says something the body does
    // not: a question is not restated as a failure, and a "Done" adds nothing.
    final reason = bareFailure
        ? (result.message.isEmpty ? null : result.message)
        : (result.status == AgentResultStatus.succeeded ||
                result.message == body
            ? null
            : (result.message.isNotEmpty
                ? result.message
                : _statusWords(result.status)));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(headline, style: theme.textTheme.bodyLarge),
        if (hint != null && hint.isNotEmpty) ...[
          const SizedBox(height: NexusV2Space.xs),
          Text(
            hint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        if (reason != null && reason.isNotEmpty) ...[
          const SizedBox(height: NexusV2Space.xs),
          Text(
            reason,
            style: theme.textTheme.bodySmall?.copyWith(
              color: _isFailure(result.status)
                  ? theme.colorScheme.error
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }

  /// The device list answer, from the real snapshots the interpreter was given.
  static String _deviceSummary(AgentDeviceList list) {
    if (list.devices.isEmpty) return 'None are paired yet.';
    return [
      for (final device in list.devices)
        device.online ? '${device.name} · reachable' : '${device.name} · asleep',
    ].join('\n');
  }

  /// The question the platform's near matches deserve: the real names as real
  /// choices, plus a way out that leaves nothing hanging.
  Widget _confirmCard(ThemeData theme) {
    final confirm = _confirm!;
    final names = confirm.candidates;
    final title = names.length == 1
        ? 'I think you mean “${names.first}”.'
        : 'Which one did you mean?';
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NexusV2Space.page,
        0,
        NexusV2Space.page,
        NexusV2Space.sm,
      ),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(NexusV2Space.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.titleMedium),
              if (confirm.message.isNotEmpty) ...[
                const SizedBox(height: NexusV2Space.xs),
                Text(confirm.message, style: theme.textTheme.bodySmall),
              ],
              const SizedBox(height: NexusV2Space.md),
              Wrap(
                spacing: NexusV2Space.sm,
                runSpacing: NexusV2Space.sm,
                children: [
                  for (final name in names)
                    FilledButton(
                      onPressed: () => unawaited(_confirmWith(name)),
                      child: Text('${_verbFor(confirm.request.action)} $name'),
                    ),
                  TextButton(
                    onPressed: _dismissConfirm,
                    child: const Text('Not now'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The input bar: the app's primary action, at the bottom of the screen
  /// where the hand already is. The mic and the send button sit inside the
  /// field, so asking by voice and asking by text are the same gesture.
  Widget _composer(ThemeData theme) {
    final busy = _thinking || _working;
    final pending = _conversation.pendingKey != null;
    final name = _profileState?.assistantName ?? 'Nexus';
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NexusV2Space.lg,
        NexusV2Space.sm,
        NexusV2Space.lg,
        NexusV2Space.sm,
      ),
      child: Material(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(NexusV2Radius.composer),
        child: Container(
          constraints: const BoxConstraints(minHeight: 52),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(NexusV2Radius.composer),
            border: Border.all(color: theme.colorScheme.outline),
          ),
          padding: const EdgeInsets.fromLTRB(
            NexusV2Space.md,
            NexusV2Space.xs,
            6,
            NexusV2Space.xs,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  focusNode: _focus,
                  minLines: 1,
                  maxLines: 5,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => unawaited(_submit()),
                  decoration: InputDecoration(
                    hintText: pending
                        ? 'Answer the question, or ask something else'
                        : 'Ask $name anything…',
                    border: InputBorder.none,
                    filled: false,
                  ),
                ),
              ),
              IconButton(
                tooltip: _listening ? 'Listening…' : 'Use voice',
                onPressed: _listening || busy
                    ? null
                    : () => unawaited(_listen()),
                icon: Icon(
                  _listening ? Icons.graphic_eq_rounded : Icons.mic_none_rounded,
                ),
                color: _listening
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 2),
              IconButton.filled(
                tooltip: busy ? 'Working…' : 'Send',
                onPressed: busy ? null : () => unawaited(_submit()),
                icon: busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.arrow_upward_rounded),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
