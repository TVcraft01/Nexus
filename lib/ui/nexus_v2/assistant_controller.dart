import 'dart:async';

import 'package:flutter/foundation.dart' show ChangeNotifier, ValueListenable;

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
import 'nexus_orb.dart';

/// Everything the assistant screen knows about what Nexus is doing, and the
/// orchestration that carries one ask out.
///
/// The widget draws this; it does not own any of it. There is one writer for
/// the connection state — [_setPresence] — so the microphone opening, an ask
/// with the brain and a device action running all land in a single place, and
/// the globe, the presence line and the composer all read from those same
/// signals rather than from copies of them. One ask's device work shares a
/// single skeleton in [_carryOut]: local and remote differ in where the answer
/// comes from and nowhere else.
///
/// The words live here too, because they are all statements about that same
/// state: [stateLine] is the presence line's reading of [orbState], and
/// [statusWords] is the card's reading of the result status it was given.
class NexusAssistantController extends ChangeNotifier {
  NexusAssistantController({
    required this.mesh,
    this.brain,
    DeviceExecutor? executor,
  }) : _executor = executor ?? DeviceExecutor() {
    conversation.addListener(_onConversationChanged);
    _speaking = SpeechPlayback.current.speaking;
    SpeechPlayback.current.listen();
    _speaking.addListener(_onSpeakingChanged);
    _service = CommandService(
      devices: _devices,
      local: AgentDeviceSnapshot(
        id: mesh.identity.id,
        name: mesh.identity.name,
        online: true,
        capabilities: defaultCapabilitiesFor(mesh.identity.platform),
      ),
      locallyExecutable: _selfRunActions,
      memory: AgentMemory(
        learned: mesh.store.agentLearned,
        defaults: mesh.store.agentDefaults,
        facts: mesh.store.agentFacts,
      ),
      onMemoryChanged: () {
        mesh.store
          ..agentLearned = _service.learnedSnapshot
          ..agentDefaults = _service.defaultsSnapshot
          ..agentFacts = _service.factsSnapshot;
        unawaited(mesh.store.save());
      },
      onPhraseLearned: (phrase, meaning) =>
          unawaited(mesh.broadcastLearnedPhrase(phrase, meaning)),
      onFactLearned: (fact) => unawaited(mesh.broadcastFact(fact)),
      onDefaultLearned: (key, value) =>
          unawaited(mesh.broadcastDefault(key, value)),
    );
    mesh.onLearnedPhraseReceived = _service.adoptLearned;
    mesh.onFactReceived = _service.adoptFact;
    mesh.onDefaultReceived = _service.adoptDefault;
  }

  final MeshService mesh;
  final LocalBrain? brain;
  final DeviceExecutor _executor;

  /// The thread, the brain exchange and the pending question — owned by the
  /// engine, read here and rendered by the view.
  final ConversationEngine conversation = ConversationEngine();

  final SharedPrefsProfileStore _profile = SharedPrefsProfileStore();
  late final CommandService _service;

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
  /// checked with [CommandService.carriesOut], so a starter is only ever
  /// something the shipped path really answers.
  static const _starterPhrases = [
    'what time is it',
    'what is the weather',
  ];

  // ── The connection state: one owner, one writer ──────────────────────────

  bool _listening = false;
  bool _thinking = false;
  bool _working = false;
  bool _disposed = false;
  late final ValueListenable<bool> _speaking;

  /// Whether the microphone is really open.
  bool get listening => _listening;

  /// Whether an ask is with the brain or a device action is running — the one
  /// answer the composer's send button and the globe both read.
  bool get busy => _thinking || _working;

  /// Whether a voice is really coming out, from the speech engine's own
  /// utterance start/stop. On a platform that cannot report it this stays
  /// false and the globe never claims Nexus is speaking.
  bool get speaking => _speaking.value;

  /// The only writer of those signals, so a change to one of them lands in one
  /// obvious place and rebuilds once.
  void _setPresence({bool? listening, bool? thinking, bool? working}) {
    final nextListening = listening ?? _listening;
    final nextThinking = thinking ?? _thinking;
    final nextWorking = working ?? _working;
    if (nextListening == _listening &&
        nextThinking == _thinking &&
        nextWorking == _working) {
      return;
    }
    _listening = nextListening;
    _thinking = nextThinking;
    _working = nextWorking;
    _notify();
  }

  /// What the globe shows, derived from those signals and from nothing else.
  /// The mapping itself lives in [orbStateFor], with the states this build
  /// cannot evidence left out of the vocabulary entirely.
  NexusOrbState get orbState {
    final last = conversation.lastResult;
    return orbStateFor(
      listening: _listening,
      thinking: _thinking,
      speaking: speaking,
      working: _working,
      failed: last?.status == AgentResultStatus.unavailable,
      // Offline only means something when there is something to be offline
      // from: with no paired devices Nexus is whole on its own.
      offline: mesh.pairedDevices.isNotEmpty && mesh.onlineCount == 0,
    );
  }

  /// What Nexus is doing, in words — the same truth the globe shows in motion,
  /// read off the same state. Nothing here is inferred from a timer.
  String get stateLine => switch (orbState) {
        NexusOrbState.listening => 'Listening — say it when you are ready',
        NexusOrbState.thinking => 'Thinking about what you asked',
        NexusOrbState.working => 'Working on it',
        NexusOrbState.speaking => 'Speaking',
        NexusOrbState.error => 'That last one did not work',
        NexusOrbState.offline => 'No paired device is reachable right now',
        NexusOrbState.idle => 'Ready — ask me anything',
      };

  // ── The thread, the profile and what may be offered ──────────────────────

  List<ConversationEntry> get entries => conversation.entries;
  bool get hasThread => conversation.entries.isNotEmpty;
  String? get pendingKey => conversation.pendingKey;

  UserProfile? _profileState;
  bool _profileLoaded = false;
  List<Habit>? _habits;

  /// Who Nexus is here, for the presence row and the composer's hint.
  String get assistantName => _profileState?.assistantName ?? 'Nexus';

  /// The lead line of an empty thread: one greeting, once — not a stack of
  /// introductions before the user can type.
  String get emptyLead {
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

  /// What Nexus may offer right now, and only what is true.
  ///
  /// First the user's own routines — phrases they really ask twice or more —
  /// and otherwise a couple of conversation-sized starters. Every candidate has
  /// to pass [CommandService.carriesOut], the same walk the composer takes: a
  /// phrase that only parses, and would end at a gate nothing can open, is
  /// never offered as a chip.
  List<String> get suggestions {
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

  Future<void> loadProfile() async {
    final profile = await _profile.read();
    if (_disposed) return;
    _profileState = profile;
    _profileLoaded = true;
    _notify();
  }

  Future<void> loadHabits() async {
    final lines = await QueryLog.i.readAll();
    if (_disposed) return;
    _habits = const Predictions().habits(lines, limit: 4);
    _notify();
  }

  // ── One ask, end to end ──────────────────────────────────────────────────

  /// The text of the newest ask — what a retry re-runs and what the brain
  /// exchange is about.
  String _lastAsk = '';

  /// Entries already read out loud, by identity, so a spoken exchange is
  /// spoken exactly once even when the thread is rebuilt around it.
  final Set<ConversationEntry> _spokenEntries = {};

  /// How to honestly try the newest failure again, or null when re-running is
  /// not something we can truthfully offer (a missing detail is a question,
  /// not a failure).
  Future<void> Function()? _retry;

  /// Whether the newest failure can be tried again — what the view draws the
  /// button from.
  bool get canRetry => _retry != null;

  /// An unresolved contact: what Nexus was asked to do and the real near
  /// matches the platform found. A question with real choices, never a guess.
  ({AgentRequest request, String message, List<String> candidates})? _confirm;
  ({AgentRequest request, String message, List<String> candidates})?
      get confirm => _confirm;

  /// Whether an ask would be taken right now. Empty text and a screen that is
  /// already busy are the only two refusals, and the composer keeps its text
  /// for both — which is why this is answered without waiting for the ask.
  bool accepts(String input) => input.trim().isNotEmpty && !busy;

  /// Takes an ask and starts it. An ask that [accepts] refuses is dropped.
  Future<void> submit(String input, {bool voice = false}) async {
    final text = input.trim();
    if (!accepts(text)) return;
    _lastAsk = text;
    // An open question: the next input answers it — unless it is itself a
    // command. The user moving on must never be learned as the meaning of a
    // phrase that was never about it.
    final pending = conversation.pendingKey;
    final answers = pending != null && !_service.parsesAsCommand(text);
    if (pending != null && !answers) _service.cancelPending(pending);
    _confirm = null;
    _retry = null;
    _setPresence(thinking: true);

    // Nothing in this build can grant a local approval, so asking for one
    // would only ever produce a card with no way forward; the actions this
    // phone runs are declared executable up front instead.
    final result = _service.execute(
      text,
      requestId: 'v2-${DateTime.now().microsecondsSinceEpoch}',
      answerTo: answers ? pending : null,
    );
    conversation.appendResult(result, asUser: text, spoken: voice);
    try {
      await _handle(result, voice: voice);
    } finally {
      _setPresence(thinking: false);
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
            target: mesh.identity.id,
            action: message.action!,
            arguments: message.arguments ?? const {},
          ),
          spoken: voice,
        );
      case final AgentClarification ask
          when brain != null &&
              ask.key.startsWith('teach:') &&
              conversation.brainHealth != BrainHealth.offline:
        // A phrase the interpreter does not know: hand it to the local brain
        // for a real conversational reply. The interpreter's own question
        // stays on the card meanwhile, so the user is never left with nothing.
        _setPresence(thinking: true);
        await _conversationFallback(_lastAsk, result);
      case _:
        break;
    }
  }

  Future<void> _conversationFallback(
    String input,
    AgentDispatchResult result,
  ) async {
    final local = brain;
    if (local == null) return;
    try {
      await conversation.converse(
        brain: local,
        input: input,
        original: result,
        context: _context,
        onBrainAnswered: (key) {
          if (key != null) _service.cancelPending(key);
        },
      );
    } finally {
      // The exchange is over however it ended; the globe stops thinking.
      _setPresence(thinking: false);
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
    if (plan.request.target == mesh.identity.id &&
        _selfRunActions.contains(plan.request.action)) {
      await _runLocal(plan.request, spoken: spoken);
      return;
    }
    if (plan.request.target.isEmpty) return;
    await _runRemote(plan.request, spoken: spoken);
  }

  /// The skeleton both kinds of run share: the globe starts working, the ask
  /// is carried out, whatever came back becomes a card, and the globe stops
  /// again — with one honest sentence and one-tap recovery when the platform
  /// itself threw.
  Future<void> _carryOut({
    required Future<void> Function() run,
    required String Function(Object error) describe,
    required Future<void> Function() tryAgain,
  }) async {
    _setPresence(thinking: false, working: true);
    try {
      await run();
    } catch (error) {
      _showFailure(describe(error));
      _retry = tryAgain;
      _notify();
    } finally {
      _setPresence(working: false);
    }
  }

  /// Runs an action on another device and shows its own answer in its name.
  Future<void> _runRemote(AgentRequest request, {required bool spoken}) {
    return _carryOut(
      run: () async {
        final deviceName = this.deviceName(request.target);
        final reply = await mesh.sendAgentRequest(request.target, request);
        if (_disposed) return;
        final words = switch (reply?.dispatch) {
          final AgentMessage message => message.text,
          _ => reply?.message ?? '',
        };
        conversation.appendResult(
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
        _retry = reply == null ? () => _runRemote(request, spoken: false) : null;
        _notify();
      },
      describe: (error) => 'I could not reach that device: $error',
      tryAgain: () => _runRemote(request, spoken: false),
    );
  }

  /// Runs an action on this device and shows its own outcome.
  ///
  /// Three endings, three honest cards: it worked; it could not (with the
  /// reason and one-tap retry); or it needs one detail — and when the platform
  /// found near matches, that detail is a real question with real choices and
  /// the answer is learned.
  Future<void> _runLocal(AgentRequest request, {required bool spoken}) {
    return _carryOut(
      run: () async {
        final outcome = await _executor.run(request);
        if (_disposed) return;
        if (!outcome.ok && outcome.candidates.isNotEmpty) {
          conversation.appendResult(
            AgentDispatchResult(
              status: AgentResultStatus.needsInfo,
              message: outcome.message,
            ),
            replaceLast: true,
            spoken: spoken,
          );
          _confirm = (
            request: request,
            message: outcome.message,
            candidates: outcome.candidates.take(3).toList(),
          );
          _retry = null;
          _notify();
          return;
        }
        conversation.appendResult(
          AgentDispatchResult(
            status: _statusFor(outcome),
            message: outcome.ok ? '' : outcome.message,
            dispatch: outcome.ok ? AgentMessage(outcome.message) : null,
          ),
          replaceLast: true,
          spoken: spoken,
        );
        // A question's recovery is answering it, not running it again: only a
        // genuine failure earns the retry.
        _retry = outcome.ok || outcome.needsDetail
            ? null
            : () => _runLocal(request, spoken: false);
        _notify();
      },
      describe: (error) =>
          'That did not run — the device action failed: $error',
      tryAgain: () => _runLocal(request, spoken: false),
    );
  }

  /// Replaces the newest card with a failure that carries its reason.
  void _showFailure(String reason) {
    conversation.appendResult(
      AgentDispatchResult(
        status: AgentResultStatus.unavailable,
        message: reason,
      ),
      replaceLast: true,
    );
  }

  /// Tries the newest failure again, once. The button goes as it is pressed,
  /// so it can never be pressed twice for one attempt.
  Future<void> retryNow() async {
    final retry = _retry;
    _retry = null;
    _notify();
    if (retry != null) await retry();
  }

  /// The user picked a real name from the near matches: run the action with it
  /// and remember the wording — "alx" means Alex from now on, here and on
  /// every paired device.
  Future<void> confirmWith(String candidate) async {
    final pending = _confirm;
    if (pending == null) return;
    final original = pending.request.arguments['contact']?.toString() ?? '';
    if (candidate.isNotEmpty && candidate != original) {
      _service.learnContactAlias(original, candidate);
    }
    final args = Map<String, dynamic>.of(pending.request.arguments)
      ..['contact'] = candidate;
    _confirm = null;
    _notify();
    await _runLocal(
      AgentRequest(
        requestId: 'v2-${DateTime.now().microsecondsSinceEpoch}',
        target: pending.request.target,
        action: pending.request.action,
        arguments: args,
      ),
      spoken: false,
    );
  }

  /// The user chose not to pick one: the question becomes their own answer, so
  /// the thread never leaves a question hanging over them.
  void dismissConfirm() {
    _confirm = null;
    conversation.appendResult(
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
  Future<void> listen() async {
    if (listening || busy) return;
    final speech = SpeechInput.current;
    if (!speech.available) {
      conversation.appendResult(
        const AgentDispatchResult(
          status: AgentResultStatus.unavailable,
          message:
              'Voice input is not set up on this device — typing works exactly the same way.',
        ),
        spoken: true,
      );
      return;
    }
    _setPresence(listening: true);
    try {
      final heard = await speech.listen();
      if (_disposed) return;
      final text = heard?.trim() ?? '';
      if (text.isEmpty) {
        conversation.appendResult(
          const AgentDispatchResult(
            status: AgentResultStatus.needsInfo,
            message: 'I did not catch that — say it again?',
          ),
          spoken: true,
        );
        return;
      }
      await submit(text, voice: true);
    } finally {
      // The microphone is closed however the utterance ended — including when
      // the platform call threw.
      _setPresence(listening: false);
    }
  }

  /// Clears the thread, so the next thing the user types starts a conversation
  /// rather than continuing the one they ended.
  void startNewConversation() {
    final pending = conversation.pendingKey;
    if (pending != null) _service.cancelPending(pending);
    conversation.clear();
    _confirm = null;
    _retry = null;
    _notify();
  }

  // ── Words ────────────────────────────────────────────────────────────────

  /// The status an action's own outcome deserves: a missing detail is a
  /// question, not a broken feature.
  static AgentResultStatus _statusFor(ActionResult outcome) {
    if (outcome.ok) return AgentResultStatus.succeeded;
    return outcome.needsDetail
        ? AgentResultStatus.needsInfo
        : AgentResultStatus.unavailable;
  }

  /// What each status means in words a person reads. Never the enum's own
  /// name, which is an implementation detail — and never "Done" for something
  /// that was only a question or a refusal.
  static String statusWords(AgentResultStatus status) => switch (status) {
        AgentResultStatus.succeeded => 'Done',
        // Core always sets its own message for this one ("Local approval is
        // required."), so this line is only the fallback that keeps the table
        // exhaustive — no control the user could press is missing with it.
        AgentResultStatus.required => 'Waiting for your approval',
        AgentResultStatus.denied => 'You said no — nothing happened',
        AgentResultStatus.unavailable => 'That did not work',
        AgentResultStatus.needsInfo => 'I need one more thing',
      };

  /// Whether a status is a failure the user has to be told about.
  static bool isFailure(AgentResultStatus status) =>
      status == AgentResultStatus.unavailable;

  /// The user's own verb, so a choice reads like the thing they asked for
  /// ("Call Alex", not "Use Alex").
  static String verbFor(String action) => switch (action) {
        AgentActions.callPlace => 'Call',
        AgentActions.messageSend => 'Text',
        AgentActions.emailSend => 'Email',
        _ => 'Use',
      };

  /// What a request will do, in the words a person would use. Only what the
  /// arguments really say: no invented destination, no promised outcome.
  static String describeRequest(AgentRequest request) {
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

  /// The device list answer, from the real snapshots the interpreter was given.
  static String deviceSummary(AgentDeviceList list) {
    if (list.devices.isEmpty) return 'None are paired yet.';
    return [
      for (final device in list.devices)
        device.online ? '${device.name} · reachable' : '${device.name} · asleep',
    ].join('\n');
  }

  String deviceName(String id) {
    if (id == mesh.identity.id) return mesh.identity.name;
    for (final device in mesh.pairedDevices) {
      if (device.id == id) return device.name;
    }
    return id;
  }

  // ── Wiring ───────────────────────────────────────────────────────────────

  List<AgentDeviceSnapshot> _devices() {
    return [
      AgentDeviceSnapshot(
        id: mesh.identity.id,
        name: mesh.identity.name,
        online: true,
        capabilities: defaultCapabilitiesFor(mesh.identity.platform),
      ),
      for (final d in mesh.pairedDevices)
        AgentDeviceSnapshot(
          id: d.id,
          name: d.name,
          online: mesh.isOnline(d.id),
          capabilities: defaultCapabilitiesFor(d.platform),
        ),
    ];
  }

  void _onSpeakingChanged() => _notify();

  void _onConversationChanged() {
    _notify();
    // Voice mode: a reply to a spoken ask is read out loud, exactly once,
    // wherever the card landed. Typed exchanges stay quiet, so the assistant
    // never starts talking at somebody who did not speak to it.
    for (final entry in conversation.entries) {
      if (!_spokenEntries.add(entry)) continue;
      if (!entry.spokenAsk) continue;
      final text = ConversationEngine.speakableText(entry);
      if (text != null) unawaited(SpeechOutput.current.speak(text));
    }
  }

  /// Notifies unless the screen is already gone: a device action that lands
  /// after the user left has nothing to redraw.
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    mesh.onLearnedPhraseReceived = null;
    mesh.onFactReceived = null;
    mesh.onDefaultReceived = null;
    _speaking.removeListener(_onSpeakingChanged);
    conversation.removeListener(_onConversationChanged);
    conversation.dispose();
    super.dispose();
  }
}
