import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../../core/agent_contract.dart';
import '../../core/brain.dart';
import '../../core/command_service.dart';
import '../../core/conversation.dart';
import '../../core/conversation_engine.dart';
import '../../core/profile.dart';
import '../../core/speech.dart';
import '../../mesh/mesh_service.dart';
import '../device_executor.dart';
import 'design_system.dart';

/// Human-first presentation layer for Nexus' existing assistant engines.
///
/// The UI speaks in human terms while CommandService, ConversationEngine,
/// DeviceExecutor and the mesh remain responsible for interpretation and work.
class NexusV2AssistantView extends StatefulWidget {
  final MeshService mesh;
  final LocalBrain? brain;

  const NexusV2AssistantView({super.key, required this.mesh, this.brain});

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

  final _input = TextEditingController();
  final _focus = FocusNode();
  final _conversation = ConversationEngine();
  final _executor = DeviceExecutor();
  final _profile = SharedPrefsProfileStore();
  late final CommandService _service;

  UserProfile? _profileState;
  bool _profileLoaded = false;
  bool _sending = false;
  bool _listening = false;
  String? _pendingApproval;

  @override
  void initState() {
    super.initState();
    _conversation.addListener(_onConversationChanged);
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
  }

  @override
  void dispose() {
    widget.mesh.onLearnedPhraseReceived = null;
    widget.mesh.onFactReceived = null;
    widget.mesh.onDefaultReceived = null;
    _conversation.removeListener(_onConversationChanged);
    _conversation.dispose();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onConversationChanged() {
    if (mounted) setState(() {});
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

  String get _greeting {
    final name = _profileState?.userName;
    final hour = DateTime.now().hour;
    final part = hour < 12
        ? 'Good morning'
        : hour < 18
            ? 'Good afternoon'
            : 'Good evening';
    return name == null || name.isEmpty ? '$part.' : '$part, $name.';
  }

  Future<void> _submit({bool voice = false}) async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    HapticFeedback.selectionClick();
    _input.clear();
    setState(() => _sending = true);

    final approved = _pendingApproval == text;
    final result = _service.execute(
      text,
      requestId: 'v2-${DateTime.now().microsecondsSinceEpoch}',
      approval: approved ? AgentApproval.approved : AgentApproval.required,
    );
    _pendingApproval = null;
    _conversation.appendResult(result, asUser: text, spoken: voice);

    switch (result.dispatch) {
      case final AgentActionPlan plan:
        if (plan.request.approval == AgentApproval.required) {
          if (mounted) {
            setState(() {
              _sending = false;
              _pendingApproval = text;
            });
          }
          return;
        }
        await _dispatchPlan(plan, spoken: voice);
      case final AgentMessage message:
        if (message.action != null && _selfRunActions.contains(message.action)) {
          final request = AgentRequest(
            requestId: 'v2-${DateTime.now().microsecondsSinceEpoch}',
            target: widget.mesh.identity.id,
            action: message.action!,
            arguments: message.arguments ?? const {},
          );
          await _runLocal(request, spoken: voice);
        } else if (message.action == null && widget.brain != null) {
          await _conversationFallback(text, result);
        }
      case AgentClarification _:
        if (widget.brain != null) await _conversationFallback(text, result);
      case _:
        break;
    }
    if (mounted) setState(() => _sending = false);
  }

  Future<void> _conversationFallback(
    String text,
    AgentDispatchResult result,
  ) async {
    final brain = widget.brain;
    if (brain == null) return;
    await _conversation.converse(
      brain: brain,
      input: text,
      original: result,
      context: _context,
      onBrainAnswered: (key) {
        if (key != null) _service.cancelPending(key);
      },
    );
  }

  ConversationContext _context() => ConversationContext(
        userName: _profileState?.userName,
        assistantName: _profileState?.assistantName ?? 'Nexus',
        facts: _service.factsSnapshot,
        learned: _service.learnedSnapshot,
        defaults: _service.defaultsSnapshot,
      );

  Future<void> _dispatchPlan(
    AgentActionPlan plan, {
    required bool spoken,
  }) async {
    if (plan.request.target == widget.mesh.identity.id &&
        _selfRunActions.contains(plan.request.action)) {
      await _runLocal(plan.request, spoken: spoken);
      return;
    }
    if (plan.request.target.isEmpty) return;
    final reply = await widget.mesh.sendAgentRequest(
      plan.request.target,
      plan.request,
    );
    if (!mounted) return;
    _conversation.appendResult(
      AgentDispatchResult(
        status: reply == null
            ? AgentResultStatus.unavailable
            : AgentResultStatus.succeeded,
        message: reply == null
            ? 'I could not reach that device.'
            : _describe(reply),
        dispatch: reply == null ? null : AgentMessage(_describe(reply)),
      ),
      replaceLast: true,
      spoken: spoken,
    );
  }

  Future<void> _runLocal(
    AgentRequest request, {
    required bool spoken,
  }) async {
    final outcome = await _executor.run(request);
    if (!mounted) return;
    _conversation.appendResult(
      AgentDispatchResult(
        status: outcome.ok
            ? AgentResultStatus.succeeded
            : AgentResultStatus.unavailable,
        message: outcome.message,
        dispatch: outcome.ok ? AgentMessage(outcome.message) : null,
      ),
      replaceLast: true,
      spoken: spoken,
    );
  }

  String _describe(AgentDispatchResult result) {
    if (result.dispatch case final AgentMessage message) {
      return message.text;
    }
    if (result.message.isNotEmpty) return result.message;
    return switch (result.status) {
      AgentResultStatus.succeeded => 'Done.',
      AgentResultStatus.denied => 'I didn’t do that.',
      AgentResultStatus.unavailable => 'I couldn’t do that.',
      AgentResultStatus.required => 'I need your approval first.',
      AgentResultStatus.needsInfo => 'I need a little more information.',
    };
  }

  Future<void> _listen() async {
    if (_listening || _sending) return;
    final speech = SpeechInput.current;
    if (!speech.available) {
      _conversation.appendResult(
        const AgentDispatchResult(
          dispatch: AgentMessage('Voice input is not available on this device yet.'),
        ),
      );
      return;
    }
    setState(() => _listening = true);
    final heard = await speech.listen();
    if (!mounted) return;
    setState(() => _listening = false);
    if (heard == null || heard.trim().isEmpty) {
      _conversation.appendResult(
        const AgentDispatchResult(
          dispatch: AgentMessage('I didn’t catch that.'),
        ),
      );
      return;
    }
    _input.text = heard.trim();
    await _submit(voice: true);
  }

  void _usePrompt(String text) {
    _input.text = text;
    _focus.requestFocus();
    unawaited(_submit());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = _conversation.entries;
    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          NexusV2PageTitle(
            title: _profileLoaded
                ? (_profileState?.assistantName ?? 'Nexus')
                : 'Nexus',
            subtitle: entries.isEmpty ? 'Ready when you are.' : 'Here to help.',
            trailing: entries.isEmpty
                ? null
                : IconButton(
                    tooltip: 'New conversation',
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () => setState(() => _conversation.clear()),
                  ),
          ),
          Expanded(
            child: entries.isEmpty
                ? _welcome(theme)
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(20, 6, 20, 22),
                    itemCount: entries.length,
                    itemBuilder: (context, index) =>
                        _message(entries[index], theme),
                  ),
          ),
          if (_pendingApproval != null)
            _ApprovalBar(
              onApprove: _approvePending,
              onDismiss: () => setState(() => _pendingApproval = null),
            ),
          _composer(theme),
        ],
      ),
    );
  }

  Widget _welcome(ThemeData theme) => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(28, 12, 28, 28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                _greeting,
                style: theme.textTheme.headlineMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Text(
                  'Tell me what you want to do. You don’t need to learn commands.',
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 24),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: const [
                  _Prompt('What can you do?'),
                  _Prompt('What’s on my calendar?'),
                  _Prompt('Find my other devices'),
                  _Prompt('Remember this for me'),
                ],
              ),
            ],
          ),
        ),
      );

  Widget _message(ConversationEntry entry, ThemeData theme) {
    if (entry.userText != null) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 440),
          margin: const EdgeInsets.only(bottom: 12, left: 42),
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withValues(alpha: 0.13),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(18),
              topRight: Radius.circular(18),
              bottomLeft: Radius.circular(18),
              bottomRight: Radius.circular(6),
            ),
          ),
          child: Text(entry.userText!, style: theme.textTheme.bodyLarge),
        ),
      );
    }

    final text = ConversationEngine.speakableText(entry) ??
        entry.message ??
        'I’m ready.';
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 16, right: 36),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(text, style: theme.textTheme.bodyLarge),
            if (entry.status != null &&
                entry.status != AgentResultStatus.succeeded) ...[
              const SizedBox(height: 5),
              Text(
                entry.status!.name,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _composer(ThemeData theme) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Material(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(20),
          child: Container(
            constraints: const BoxConstraints(minHeight: 52),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: theme.colorScheme.outline),
            ),
            padding: const EdgeInsets.fromLTRB(12, 4, 6, 4),
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
                    decoration: const InputDecoration(
                      hintText: 'Ask Nexus anything…',
                      border: InputBorder.none,
                      filled: false,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: _listening ? 'Listening…' : 'Use voice',
                  onPressed: _listening ? null : () => unawaited(_listen()),
                  icon: Icon(
                    _listening ? Icons.graphic_eq_rounded : Icons.mic_none_rounded,
                  ),
                  color: _listening
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 2),
                IconButton.filled(
                  tooltip: 'Send',
                  onPressed: _sending ? null : () => unawaited(_submit()),
                  icon: _sending
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

  Future<void> _approvePending() async {
    final pending = _pendingApproval;
    if (pending == null) return;
    _pendingApproval = pending;
    _input.text = pending;
    await _submit();
  }
}

class _Prompt extends StatelessWidget {
  final String text;
  const _Prompt(this.text);

  @override
  Widget build(BuildContext context) => ActionChip(
        label: Text(text),
        onPressed: () {
          final state = context.findAncestorStateOfType<
              _NexusV2AssistantViewState>();
          state?._usePrompt(text);
        },
      );
}

class _ApprovalBar extends StatelessWidget {
  final VoidCallback onApprove;
  final VoidCallback onDismiss;
  const _ApprovalBar({required this.onApprove, required this.onDismiss});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 2),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
            child: Row(
              children: [
                const Expanded(
                  child: Text('Nexus needs your approval before doing this.'),
                ),
                TextButton(
                  onPressed: onDismiss,
                  child: const Text('Not now'),
                ),
                FilledButton(
                  onPressed: onApprove,
                  child: const Text('Allow'),
                ),
              ],
            ),
          ),
        ),
      );
}
