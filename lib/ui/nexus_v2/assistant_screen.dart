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

/// Human-facing assistant surface. The command/brain/device layers remain
/// separate; this class owns only presentation and the user conversation.
class NexusV2AssistantScreen extends StatefulWidget {
  final MeshService mesh;
  final LocalBrain? brain;

  const NexusV2AssistantScreen({super.key, required this.mesh, this.brain});

  @override
  State<NexusV2AssistantScreen> createState() => _NexusV2AssistantScreenState();
}

class _NexusV2AssistantScreenState extends State<NexusV2AssistantScreen> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _conversation = ConversationEngine();
  final _executor = DeviceExecutor();
  final _profile = SharedPrefsProfileStore();
  late final CommandService _service;

  UserProfile? _profileState;
  bool _loadingProfile = true;
  bool _sending = false;
  bool _listening = false;
  String? _approvalInput;

  static const _localActions = {
    AgentActions.webSearch, AgentActions.noteCreate, AgentActions.timerSet,
    AgentActions.openUrl, AgentActions.weatherGet, AgentActions.navOpen,
    AgentActions.locationGet, AgentActions.musicSearch, AgentActions.currencyGet,
    AgentActions.timezoneGet, AgentActions.calendarAdd, AgentActions.calendarRead,
    AgentActions.shoppingListAdd, AgentActions.shoppingListGet, AgentActions.emailSend,
    AgentActions.systemInfo, AgentActions.volumeSet, AgentActions.appOpen,
    AgentActions.appClose, AgentActions.screenshot, AgentActions.batteryGet,
    AgentActions.brightnessSet, AgentActions.flashlightToggle, AgentActions.wifiToggle,
    AgentActions.bluetoothToggle, AgentActions.lockScreen, AgentActions.callPlace,
    AgentActions.messageSend, AgentActions.mediaPlay, AgentActions.mediaPause,
    AgentActions.mediaNext, AgentActions.mediaPrev, AgentActions.mediaShuffle,
    AgentActions.mediaRepeat, AgentActions.alarmSet, AgentActions.defineWord,
    AgentActions.appDefault, AgentActions.profileSet, AgentActions.profileGet,
  };

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
      locallyExecutable: _localActions,
      memory: AgentMemory(
        learned: widget.mesh.store.agentLearned,
        defaults: widget.mesh.store.agentDefaults,
        facts: widget.mesh.store.agentFacts,
      ),
      onMemoryChanged: _saveMemory,
      onPhraseLearned: (p, m) => unawaited(widget.mesh.broadcastLearnedPhrase(p, m)),
      onFactLearned: (f) => unawaited(widget.mesh.broadcastFact(f)),
      onDefaultLearned: (k, v) => unawaited(widget.mesh.broadcastDefault(k, v)),
    );
    widget.mesh.onLearnedPhraseReceived = _service.adoptLearned;
    widget.mesh.onFactReceived = _service.adoptFact;
    widget.mesh.onDefaultReceived = _service.adoptDefault;
    unawaited(_loadProfile());
  }

  void _saveMemory() {
    widget.mesh.store
      ..agentLearned = _service.learnedSnapshot
      ..agentDefaults = _service.defaultsSnapshot
      ..agentFacts = _service.factsSnapshot;
    unawaited(widget.mesh.store.save());
  }

  List<AgentDeviceSnapshot> _devices() => [
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

  Future<void> _loadProfile() async {
    final profile = await _profile.read();
    if (!mounted) return;
    setState(() {
      _profileState = profile;
      _loadingProfile = false;
    });
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

  Future<void> _submitText(String value) async {
    final text = value.trim();
    if (text.isEmpty || _sending) return;
    HapticFeedback.selectionClick();
    _input.clear();
    setState(() => _sending = true);

    final approval = _approvalInput == text ? AgentApproval.approved : AgentApproval.required;
    _approvalInput = null;
    final result = _service.execute(
      text,
      requestId: 'v2-${DateTime.now().microsecondsSinceEpoch}',
      approval: approval,
    );
    _conversation.appendResult(result, asUser: text);

    switch (result.dispatch) {
      case final AgentActionPlan plan:
        if (plan.request.approval == AgentApproval.required) {
          if (mounted) setState(() { _approvalInput = text; _sending = false; });
          return;
        }
        await _dispatch(plan);
      case final AgentMessage message:
        if (message.action != null && _localActions.contains(message.action)) {
          await _runLocal(
            AgentRequest(
              requestId: 'v2-${DateTime.now().microsecondsSinceEpoch}',
              target: widget.mesh.identity.id,
              action: message.action!,
              arguments: message.arguments ?? const {},
            ),
          );
        }
        if (message.action == null && widget.brain != null) {
          await _fallback(text, result);
        }
      case AgentClarification _:
        if (widget.brain != null) await _fallback(text, result);
      case _:
        break;
    }
    if (mounted) setState(() => _sending = false);
  }

  Future<void> _fallback(String text, AgentDispatchResult original) async {
    final brain = widget.brain;
    if (brain == null) return;
    await _conversation.converse(
      brain: brain,
      input: text,
      original: original,
      context: () => ConversationContext(
        userName: _profileState?.userName,
        assistantName: _profileState?.assistantName ?? 'Nexus',
        facts: _service.factsSnapshot,
        learned: _service.learnedSnapshot,
        defaults: _service.defaultsSnapshot,
      ),
      onBrainAnswered: (pending) {
        if (pending != null) _service.cancelPending(pending);
      },
    );
  }

  Future<void> _dispatch(AgentActionPlan plan) async {
    if (plan.request.target == widget.mesh.identity.id && _localActions.contains(plan.request.action)) {
      await _runLocal(plan.request);
      return;
    }
    if (plan.request.target.isEmpty) return;
    final reply = await widget.mesh.sendAgentRequest(plan.request.target, plan.request);
    if (!mounted) return;
    _conversation.appendResult(
      AgentDispatchResult(
        status: reply == null ? AgentResultStatus.unavailable : AgentResultStatus.succeeded,
        message: reply == null ? 'I couldn’t reach that device.' : _describe(reply),
        dispatch: reply == null ? null : AgentMessage(_describe(reply)),
      ),
      replaceLast: true,
    );
  }

  Future<void> _runLocal(AgentRequest request) async {
    final result = await _executor.run(request);
    if (!mounted) return;
    _conversation.appendResult(
      AgentDispatchResult(
        status: result.ok ? AgentResultStatus.succeeded : AgentResultStatus.unavailable,
        message: result.message,
        dispatch: result.ok ? AgentMessage(result.message) : null,
      ),
      replaceLast: true,
    );
  }

  String _describe(AgentDispatchResult result) {
    if (result.dispatch case final AgentMessage m) return m.text;
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
      _conversation.appendResult(const AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage('Voice input isn’t available on this device yet.'),
      ));
      return;
    }
    setState(() => _listening = true);
    final heard = await speech.listen();
    if (!mounted) return;
    setState(() => _listening = false);
    if (heard == null || heard.trim().isEmpty) {
      _conversation.appendResult(const AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage('I didn’t catch that.'),
      ));
      return;
    }
    await _submitText(heard);
  }

  void _usePrompt(String text) => unawaited(_submitText(text));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final assistantName = _loadingProfile ? 'Nexus' : (_profileState?.assistantName ?? 'Nexus');
    final entries = _conversation.entries;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 22, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(assistantName, style: theme.textTheme.displaySmall),
                  const SizedBox(height: 3),
                  Text('Ask naturally. Nexus will work out the rest.', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                ]),
              ),
              IconButton(
                tooltip: 'New conversation',
                onPressed: entries.isEmpty
                    ? null
                    : () => setState(() => _conversation.clear()),
                icon: const Icon(Icons.edit_outlined),
              ),
            ],
          ),
        ),
        Expanded(
          child: entries.isEmpty
              ? _welcome(theme)
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
                  itemCount: entries.length,
                  itemBuilder: (context, index) => _entry(entries[index], theme),
                ),
        ),
        if (_approvalInput != null) _approvalBanner(theme),
        _composer(theme),
      ],
    );
  }

  Widget _welcome(ThemeData theme) {
    final name = _profileState?.userName;
    final greeting = name == null || name.isEmpty ? 'What can I help with?' : 'What can I help you with, $name?';
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(28, 20, 28, 28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(greeting, style: theme.textTheme.headlineMedium, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text('You don’t need to learn commands. Just tell me what you want.', textAlign: TextAlign.center, style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 22),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                _Prompt('What can you do?', _usePrompt),
                _Prompt('What’s on my calendar?', _usePrompt),
                _Prompt('Find my devices', _usePrompt),
                _Prompt('Remember something', _usePrompt),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _entry(ConversationEntry entry, ThemeData theme) {
    if (entry.userText != null) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 390),
          margin: const EdgeInsets.only(bottom: 14),
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withValues(alpha: 0.14),
            borderRadius: const BorderRadius.only(topLeft: Radius.circular(18), topRight: Radius.circular(18), bottomLeft: Radius.circular(18), bottomRight: Radius.circular(5)),
          ),
          child: Text(entry.userText!, style: theme.textTheme.bodyLarge),
        ),
      );
    }
    final text = ConversationEngine.speakableText(entry) ??
        (entry.result?.message.isNotEmpty ?? false ? entry.result!.message : null) ??
        'Done.';
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(right: 28, bottom: 16),
        child: Text(text, style: theme.textTheme.bodyLarge),
      ),
    );
  }

  Widget _approvalBanner(ThemeData theme) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
            child: Row(children: [
              const Icon(Icons.lock_outline_rounded, size: 18),
              const SizedBox(width: 10),
              const Expanded(child: Text('Nexus needs your approval before doing this.')),
              TextButton(onPressed: () => setState(() => _approvalInput = null), child: const Text('Not now')),
              FilledButton(onPressed: () => unawaited(_submitText(_approvalInput!)), child: const Text('Allow')),
            ]),
          ),
        ),
      );

  Widget _composer(ThemeData theme) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 7, 16, 12),
        child: SafeArea(
          top: false,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: theme.colorScheme.outline),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 5, 6, 5),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    focusNode: _focus,
                    minLines: 1,
                    maxLines: 5,
                    textCapitalization: TextCapitalization.sentences,
                    onSubmitted: _sending ? null : _submitText,
                    decoration: const InputDecoration(hintText: 'Message Nexus', border: InputBorder.none, filled: false),
                  ),
                ),
                IconButton(tooltip: 'Voice', onPressed: _listening ? null : () => unawaited(_listen()), icon: Icon(_listening ? Icons.graphic_eq_rounded : Icons.mic_none_rounded)),
                IconButton.filled(tooltip: 'Send', onPressed: _sending ? null : () => unawaited(_submitText(_input.text)), icon: const Icon(Icons.arrow_upward_rounded)),
              ]),
            ),
          ),
        ),
      );
}

class _Prompt extends StatelessWidget {
  final String text;
  final ValueChanged<String> onTap;
  const _Prompt(this.text, this.onTap);

  @override
  Widget build(BuildContext context) => ActionChip(
        label: Text(text),
        onPressed: () => onTap(text),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      );
}
