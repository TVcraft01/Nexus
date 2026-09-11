import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../core/agent_contract.dart';
import '../core/brain.dart';
import '../core/command_service.dart';
import '../core/conversation.dart';
import '../core/conversation_engine.dart';
import '../core/profile.dart';
import '../core/reminders.dart';
import '../core/speech.dart';
import '../mesh/mesh_service.dart';
import 'cable_pair_page.dart';
import 'device_executor.dart';
import 'pair_sheet.dart';
import 'theme.dart';

class NexusExperience extends StatefulWidget {
  final MeshService mesh;
  final LocalBrain? brain;
  final Future<dynamic> Function()? onCheckForUpdate;

  const NexusExperience({
    super.key,
    required this.mesh,
    this.brain,
    this.onCheckForUpdate,
  });

  @override
  State<NexusExperience> createState() => _NexusExperienceState();
}

class _NexusExperienceState extends State<NexusExperience> {
  int _index = 0;

  static const _labels = ['Assistant', 'Devices', 'Files', 'Settings'];
  static const _icons = [
    Icons.chat_bubble_outline_rounded,
    Icons.devices_other_rounded,
    Icons.folder_outlined,
    Icons.settings_outlined,
  ];

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.mesh,
      builder: (context, _) {
        final pages = <Widget>[
          NexusAssistantPage(mesh: widget.mesh, brain: widget.brain),
          NexusDevicesPage(mesh: widget.mesh),
          NexusFilesPage(mesh: widget.mesh),
          NexusSettingsPage(
            mesh: widget.mesh,
            onCheckForUpdate: widget.onCheckForUpdate,
          ),
        ];

        return Scaffold(
          backgroundColor: NexusColors.bg,
          body: SafeArea(
            bottom: false,
            child: Row(
              children: [
                if (_isDesktop(context))
                  _NexusSidebar(
                    index: _index,
                    labels: _labels,
                    icons: _icons,
                    onChanged: (value) => setState(() => _index = value),
                  ),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    switchInCurve: Curves.easeOut,
                    switchOutCurve: Curves.easeIn,
                    child: KeyedSubtree(
                      key: ValueKey(_index),
                      child: pages[_index],
                    ),
                  ),
                ),
              ],
            ),
          ),
          bottomNavigationBar: _isDesktop(context)
              ? null
              : _NexusBottomBar(
                  index: _index,
                  labels: _labels,
                  icons: _icons,
                  onChanged: (value) => setState(() => _index = value),
                ),
        );
      },
    );
  }

  bool _isDesktop(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= 720;
}

class _NexusSidebar extends StatelessWidget {
  final int index;
  final List<String> labels;
  final List<IconData> icons;
  final ValueChanged<int> onChanged;

  const _NexusSidebar({
    required this.index,
    required this.labels,
    required this.icons,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 220,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          color: NexusColors.surface,
          border: Border(right: BorderSide(color: NexusColors.border)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(10, 0, 10, 26),
                child: Text(
                  'Nexus',
                  style: TextStyle(
                    color: NexusColors.text,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                  ),
                ),
              ),
              for (var i = 0; i < labels.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: _NavRow(
                    label: labels[i],
                    icon: icons[i],
                    selected: index == i,
                    onTap: () => onChanged(i),
                  ),
                ),
              const Spacer(),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 10),
                child: Text(
                  'One assistant. Every device.',
                  style: TextStyle(
                    color: NexusColors.faint,
                    fontSize: 11.5,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NexusBottomBar extends StatelessWidget {
  final int index;
  final List<String> labels;
  final List<IconData> icons;
  final ValueChanged<int> onChanged;

  const _NexusBottomBar({
    required this.index,
    required this.labels,
    required this.icons,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return NavigationBar(
      selectedIndex: index,
      onDestinationSelected: onChanged,
      destinations: [
        for (var i = 0; i < labels.length; i++)
          NavigationDestination(icon: Icon(icons[i]), label: labels[i]),
      ],
    );
  }
}

class _NavRow extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _NavRow({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected
          ? NexusColors.accent.withValues(alpha: 0.11)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          height: 44,
          child: Row(
            children: [
              const SizedBox(width: 12),
              Icon(
                icon,
                size: 20,
                color: selected ? NexusColors.accent : NexusColors.muted,
              ),
              const SizedBox(width: 12),
              Text(
                label,
                style: TextStyle(
                  color: selected ? NexusColors.text : NexusColors.muted,
                  fontSize: 14,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class NexusPage extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget child;
  final List<Widget> actions;

  const NexusPage({
    super.key,
    required this.title,
    this.subtitle,
    required this.child,
    this.actions = const [],
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 900;
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1180),
            child: Column(
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(wide ? 40 : 20, 28, wide ? 40 : 20, 14),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: Theme.of(context).textTheme.displaySmall,
                            ),
                            if (subtitle != null) ...[
                              const SizedBox(height: 5),
                              Text(
                                subtitle!,
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            ],
                          ],
                        ),
                      ),
                      ...actions,
                    ],
                  ),
                ),
                Expanded(child: child),
              ],
            ),
          ),
        );
      },
    );
  }
}

class NexusAssistantPage extends StatefulWidget {
  final MeshService mesh;
  final LocalBrain? brain;

  const NexusAssistantPage({super.key, required this.mesh, this.brain});

  @override
  State<NexusAssistantPage> createState() => _NexusAssistantPageState();
}

class _NexusAssistantPageState extends State<NexusAssistantPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _conversation = ConversationEngine();
  final _executor = DeviceExecutor();
  final _profile = SharedPrefsProfileStore();
  late final CommandService _service;
  UserProfile? _profileState;
  bool _listening = false;
  bool _sending = false;
  final Set<ConversationEntry> _spoken = {};
  ReminderEngine? _reminders;

  static const _localActions = {
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

  @override
  void initState() {
    super.initState();
    _conversation.addListener(_refresh);
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
      onMemoryChanged: _persistMemory,
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
    _reminders = ReminderEngine()
      ..onPersist = (list) {
        widget.mesh.store.agentReminders = [
          for (final r in list) jsonEncode(r.toJson()),
        ];
        unawaited(widget.mesh.store.save());
      }
      ..onBroadcast = (r) {
        unawaited(widget.mesh.broadcastReminder(jsonEncode(r.toJson())));
      }
      ..onFired = (r) {
        _conversation.appendResult(
          AgentDispatchResult(
            status: AgentResultStatus.succeeded,
            dispatch: AgentMessage('Reminder: ${r.text}'),
          ),
        );
      }
      ..seed(widget.mesh.store.agentReminders)
      ..start();
    if (widget.mesh.onReminderReceived == null) {
      widget.mesh.onReminderReceived = _reminders!.adopt;
    }
    if (widget.brain != null) unawaited(_conversation.probe(widget.brain!));
  }

  Future<void> _loadProfile() async {
    final p = await _profile.read();
    if (!mounted) return;
    _service.setIdentity(userName: p.userName, assistantName: p.assistantName);
    setState(() {
      _profileState = p;
    });
  }

  void _persistMemory() {
    widget.mesh.store.agentLearned = _service.learnedSnapshot;
    widget.mesh.store.agentDefaults = _service.defaultsSnapshot;
    widget.mesh.store.agentFacts = _service.factsSnapshot;
    unawaited(widget.mesh.store.save());
  }

  List<AgentDeviceSnapshot> _devices() => [
        for (final d in widget.mesh.pairedDevices)
          AgentDeviceSnapshot(
            id: d.id,
            name: d.name,
            online: widget.mesh.isOnline(d.id),
            capabilities: defaultCapabilitiesFor(d.platform),
          ),
        AgentDeviceSnapshot(
          id: widget.mesh.identity.id,
          name: widget.mesh.identity.name,
          online: true,
          capabilities: defaultCapabilitiesFor(widget.mesh.identity.platform),
        ),
      ];

  void _refresh() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      }
    });
    for (final e in _conversation.entries) {
      if (!e.spokenAsk || _spoken.contains(e)) continue;
      _spoken.add(e);
      final text = ConversationEngine.speakableText(e);
      if (text != null) unawaited(SpeechOutput.current.speak(text));
    }
  }

  ConversationContext _context() => ConversationContext(
        userName: _profileState?.userName,
        assistantName: _profileState?.assistantName ?? 'Nexus',
        facts: _service.factsSnapshot,
        learned: _service.learnedSnapshot,
      );

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    _input.clear();
    final result = _service.execute(text, requestId: 'ui-${DateTime.now().microsecondsSinceEpoch}');
    _conversation.appendResult(result, asUser: text);
    if (result.dispatch case final AgentActionPlan plan) {
      await _executePlan(plan);
    } else if (result.dispatch case final AgentMessage msg when msg.action != null && _localActions.contains(msg.action)) {
      await _executeRequest(AgentRequest(
        requestId: 'ui-${DateTime.now().microsecondsSinceEpoch}',
        target: widget.mesh.identity.id,
        action: msg.action!,
        arguments: msg.arguments ?? const {},
        approval: AgentApproval.approved,
      ));
    } else if (result.dispatch is AgentClarification && widget.brain != null) {
      await _conversation.converse(
        brain: widget.brain!,
        input: text,
        original: result,
        context: _context,
      );
    }
  }

  Future<void> _executePlan(AgentActionPlan plan) async {
    final request = plan.request;
    if (request.target == widget.mesh.identity.id && _localActions.contains(request.action)) {
      await _executeRequest(request);
      return;
    }
    if (request.target.isNotEmpty && request.target != widget.mesh.identity.id) {
      setState(() => _sending = true);
      final reply = await widget.mesh.sendAgentRequest(request.target, request);
      if (!mounted) return;
      setState(() => _sending = false);
      if (reply == null) {
        _conversation.appendResult(
          const AgentDispatchResult(
            status: AgentResultStatus.unavailable,
            message: 'That device could not be reached.',
          ),
          replaceLast: true,
        );
      } else {
        _conversation.appendResult(reply, replaceLast: true);
      }
    }
  }

  Future<void> _executeRequest(AgentRequest request) async {
    setState(() => _sending = true);
    final outcome = await _executor.run(request);
    if (!mounted) return;
    setState(() => _sending = false);
    _conversation.appendResult(
      AgentDispatchResult(
        status: outcome.ok ? AgentResultStatus.succeeded : AgentResultStatus.unavailable,
        message: outcome.message,
        dispatch: outcome.ok ? AgentMessage(outcome.message) : null,
      ),
      replaceLast: true,
    );
  }

  Future<void> _listen() async {
    if (_listening) return;
    final speech = SpeechInput.current;
    if (!speech.available) {
      _conversation.appendResult(
        const AgentDispatchResult(
          status: AgentResultStatus.unavailable,
          message: 'Voice input is not available on this device.',
        ),
      );
      return;
    }
    setState(() => _listening = true);
    final text = (await speech.listen())?.trim();
    if (!mounted) return;
    setState(() => _listening = false);
    if (text == null || text.isEmpty) return;
    _input.text = text;
    await _send();
  }

  @override
  void dispose() {
    widget.mesh.onLearnedPhraseReceived = null;
    widget.mesh.onFactReceived = null;
    widget.mesh.onDefaultReceived = null;
    widget.mesh.onReminderReceived = null;
    _reminders?.dispose();
    _conversation.removeListener(_refresh);
    _conversation.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final name = _profileState?.userName;
    final entries = _conversation.entries;
    return NexusPage(
      title: _profileState?.assistantName ?? 'Assistant',
      subtitle: name == null ? 'What can I help you with?' : 'What can I do for you, $name?',
      actions: [
        if (widget.brain != null)
          _BrainPill(health: _conversation.brainHealth),
      ],
      child: Column(
        children: [
          Expanded(
            child: entries.isEmpty
                ? _AssistantEmpty(onSuggestion: (s) {
                    _input.text = s;
                    unawaited(_send());
                  })
                : ListView.separated(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                    itemCount: entries.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 20),
                    itemBuilder: (_, i) => _conversationRow(entries[i]),
                  ),
          ),
          _Composer(
            controller: _input,
            listening: _listening,
            sending: _sending,
            onMic: _listen,
            onSend: _send,
          ),
        ],
      ),
    );
  }

  Widget _conversationRow(ConversationEntry entry) {
    if (entry.userText case final text?) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 560),
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
          decoration: BoxDecoration(
            color: NexusColors.accent.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Text(text, style: Theme.of(context).textTheme.bodyLarge),
        ),
      );
    }

    final result = entry.result!;
    final Widget content;
    switch (result.dispatch) {
      case final AgentMessage message:
        content = Text(message.text, style: Theme.of(context).textTheme.bodyLarge);
      case final AgentClarification question:
        content = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(question.question, style: Theme.of(context).textTheme.bodyLarge),
            if (question.hint != null) ...[
              const SizedBox(height: 6),
              Text(question.hint!, style: Theme.of(context).textTheme.bodySmall),
            ],
          ],
        );
      case final AgentDeviceList devices:
        content = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: devices.devices
              .map((d) => Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      '${d.online ? 'Online' : 'Offline'}  ${d.name}',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ))
              .toList(),
        );
      case final AgentActionPlan plan:
        final target = _devices().where((d) => d.id == plan.request.target).firstOrNull;
        content = _ActionRow(
          title: _actionTitle(plan.request),
          detail: target == null ? null : 'On ${target.name}',
        );
      case null:
        content = Text(
          result.message.isEmpty ? 'I could not do that.' : result.message,
          style: Theme.of(context).textTheme.bodyLarge,
        );
    }

    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: content,
      ),
    );
  }

  String _actionTitle(AgentRequest request) {
    final a = request.arguments;
    switch (request.action) {
      case AgentActions.appOpen:
        return 'Open ${a['query'] ?? 'app'}';
      case AgentActions.webSearch:
        return 'Search for ${a['query'] ?? ''}';
      case AgentActions.timerSet:
        return 'Set a timer';
      case AgentActions.callPlace:
        return 'Call ${a['contact'] ?? ''}';
      case AgentActions.messageSend:
        return 'Message ${a['contact'] ?? ''}';
      case AgentActions.mediaPlay:
        return 'Play music';
      case AgentActions.screenshot:
        return 'Take a screenshot';
      default:
        return request.action;
    }
  }
}

class _AssistantEmpty extends StatelessWidget {
  final ValueChanged<String> onSuggestion;
  const _AssistantEmpty({required this.onSuggestion});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'What can I take care of?',
              style: Theme.of(context).textTheme.displaySmall?.copyWith(fontSize: 28),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            Text(
              'Talk naturally. Nexus figures out whether to answer, ask, or act.',
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                for (final s in const [
                  'What can you do?',
                  'What is the weather?',
                  'Show my devices',
                  'Set a timer for 5 minutes',
                ])
                  TextButton(
                    onPressed: () => onSuggestion(s),
                    style: TextButton.styleFrom(
                      backgroundColor: NexusColors.surface,
                      foregroundColor: NexusColors.text,
                      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Text(s),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  final TextEditingController controller;
  final bool listening;
  final bool sending;
  final VoidCallback onMic;
  final Future<void> Function() onSend;

  const _Composer({
    required this.controller,
    required this.listening,
    required this.sending,
    required this.onMic,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: NexusColors.surfaceHi,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: NexusColors.borderStrong),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 6, 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    minLines: 1,
                    maxLines: 5,
                    onSubmitted: (_) => unawaited(onSend()),
                    decoration: const InputDecoration(
                      hintText: 'Ask Nexus anything…',
                      border: InputBorder.none,
                      filled: false,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: listening ? 'Listening' : 'Voice input',
                  onPressed: sending ? null : onMic,
                  icon: Icon(
                    listening ? Icons.mic_rounded : Icons.mic_none_rounded,
                    color: listening ? NexusColors.accent : NexusColors.muted,
                  ),
                ),
                IconButton.filled(
                  tooltip: 'Send',
                  onPressed: sending ? null : () => unawaited(onSend()),
                  icon: sending
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
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  final String title;
  final String? detail;
  const _ActionRow({required this.title, this.detail});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: NexusColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: NexusColors.border),
      ),
      child: Row(
        children: [
          const Icon(Icons.arrow_forward_rounded, size: 17, color: NexusColors.accent),
          const SizedBox(width: 10),
          Expanded(child: Text(title, style: Theme.of(context).textTheme.bodyMedium)),
          if (detail != null)
            Text(detail!, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _BrainPill extends StatelessWidget {
  final BrainHealth health;
  const _BrainPill({required this.health});

  @override
  Widget build(BuildContext context) {
    final (color, text) = switch (health) {
      BrainHealth.probing => (NexusColors.muted, 'Connecting'),
      BrainHealth.online => (NexusColors.ok, 'Ready'),
      BrainHealth.offline => (NexusColors.warn, 'Offline'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(text, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }
}

class NexusDevicesPage extends StatelessWidget {
  final MeshService mesh;
  const NexusDevicesPage({super.key, required this.mesh});

  @override
  Widget build(BuildContext context) {
    return NexusPage(
      title: 'Devices',
      subtitle: 'Everything connected to Nexus.',
      actions: [
        FilledButton.icon(
          onPressed: () => _addDevice(context),
          icon: const Icon(Icons.add, size: 18),
          label: const Text('Add device'),
        ),
      ],
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
        children: [
          _SectionLabel('Connected'),
          const SizedBox(height: 8),
          if (mesh.pairedDevices.isEmpty)
            _EmptyPanel(
              title: 'No devices yet',
              message: 'Connect a phone, computer, or another Nexus device to get started.',
              action: FilledButton(onPressed: () => _addDevice(context), child: const Text('Add device')),
            )
          else
            ...mesh.pairedDevices.map((d) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _DeviceRow(
                    name: d.name,
                    platform: d.platform,
                    online: mesh.isOnline(d.id),
                    onTap: () => _deviceActions(context, d),
                  ),
                )),
          if (mesh.nearbyDevices.isNotEmpty) ...[
            const SizedBox(height: 22),
            _SectionLabel('Nearby'),
            const SizedBox(height: 8),
            ...mesh.nearbyDevices
                .where((d) => !mesh.isPaired(d.id))
                .map((d) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _DeviceRow(
                        name: d.name,
                        platform: d.platform,
                        online: true,
                        trailing: const Icon(Icons.add_circle_outline_rounded),
                        onTap: () => showPairSheet(context, mesh: mesh, nearby: d),
                      ),
                    )),
          ],
          if (mesh.serialDevices.isNotEmpty) ...[
            const SizedBox(height: 22),
            _SectionLabel('Connected by cable'),
            const SizedBox(height: 8),
            ...mesh.serialDevices.map((d) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _DeviceRow(
                    name: d.name,
                    platform: 'USB',
                    online: d.online,
                    trailing: const Icon(Icons.usb_rounded),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => CablePairPage(mesh: mesh)),
                    ),
                  ),
                )),
          ],
        ],
      ),
    );
  }

  Future<void> _addDevice(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) {
        final hasCable = defaultTargetPlatform == TargetPlatform.linux ||
            defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.macOS;
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
            children: [
              Text('Connect a device', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              Text('Choose the easiest way available.', style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 12),
              _ChoiceRow(
                icon: Icons.qr_code_2_rounded,
                title: 'QR code or code',
                detail: 'Connect another Nexus device nearby or by address.',
                onTap: () {
                  Navigator.pop(sheet);
                  showPairSheet(context, mesh: mesh);
                },
              ),
              if (hasCable && mesh.serialDevices.isNotEmpty)
                _ChoiceRow(
                  icon: Icons.usb_rounded,
                  title: 'Use a cable',
                  detail: 'The connected device will ask for permission before installation.',
                  onTap: () {
                    Navigator.pop(sheet);
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => CablePairPage(mesh: mesh)),
                    );
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _deviceActions(BuildContext context, PairedDevice d) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(d.name),
              subtitle: Text(d.platform),
            ),
            const Divider(),
            _ChoiceRow(
              icon: Icons.edit_outlined,
              title: 'Rename',
              detail: 'Choose a name that is easy to recognize.',
              onTap: () async {
                Navigator.pop(sheet);
                final controller = TextEditingController(text: d.name);
                final name = await showDialog<String>(
                  context: context,
                  builder: (dialog) => AlertDialog(
                    title: const Text('Rename device'),
                    content: TextField(controller: controller, autofocus: true),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('Cancel')),
                      FilledButton(onPressed: () => Navigator.pop(dialog, controller.text.trim()), child: const Text('Save')),
                    ],
                  ),
                );
                controller.dispose();
                if (name != null && name.isNotEmpty) await mesh.renamePairedDevice(d.id, name);
              },
            ),
            _ChoiceRow(
              icon: Icons.info_outline,
              title: 'Details',
              detail: '${mesh.isOnline(d.id) ? 'Online' : 'Offline'} · ${d.platform}',
              onTap: () {},
            ),
            _ChoiceRow(
              icon: Icons.link_off_rounded,
              title: 'Forget device',
              detail: 'You will need to pair it again.',
              danger: true,
              onTap: () async {
                Navigator.pop(sheet);
                await mesh.forgetDevice(d.id);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class NexusFilesPage extends StatefulWidget {
  final MeshService mesh;
  const NexusFilesPage({super.key, required this.mesh});

  @override
  State<NexusFilesPage> createState() => _NexusFilesPageState();
}

class _NexusFilesPageState extends State<NexusFilesPage> {
  PairedDevice? _device;
  String _path = '';
  List<FileEntry>? _entries;
  bool _loading = false;

  List<PairedDevice> get _devices => widget.mesh.pairedDevices.toList();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _devices.isEmpty) return;
      _select(_devices.first);
    });
  }

  Future<void> _select(PairedDevice device) async {
    setState(() {
      _device = device;
      _path = '';
      _entries = null;
    });
    await _load();
  }

  Future<void> _load() async {
    final device = _device;
    if (device == null || _loading) return;
    setState(() => _loading = true);
    final entries = await widget.mesh.listRemoteFiles(device, _path);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _entries = entries;
    });
  }

  Future<void> _download(FileEntry entry) async {
    final device = _device;
    if (device == null) return;
    final dir = await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
    final savePath = '${dir.path}${Platform.pathSeparator}${entry.name}';
    final file = await widget.mesh.pullRemoteFile(device, entry.path, savePath: savePath);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(file == null ? 'Could not download ${entry.name}.' : 'Saved ${entry.name}.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return NexusPage(
      title: 'Files',
      subtitle: _device == null ? 'Browse files from your connected devices.' : 'Browsing ${_device!.name}.',
      actions: [
        if (_devices.length > 1)
          PopupMenuButton<PairedDevice>(
            tooltip: 'Choose device',
            onSelected: _select,
            itemBuilder: (_) => [for (final d in _devices) PopupMenuItem(value: d, child: Text(d.name))],
            icon: const Icon(Icons.devices_other_rounded),
          ),
      ],
      child: _device == null
          ? _EmptyPanel(
              title: 'Connect a device first',
              message: 'Your files stay on your devices. Pair one to browse them here.',
            )
          : Column(
              children: [
                if (_path.isNotEmpty)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () {
                        final sep = Platform.pathSeparator;
                        final i = _path.lastIndexOf(sep);
                        setState(() => _path = i <= 0 ? '' : _path.substring(0, i));
                        unawaited(_load());
                      },
                      icon: const Icon(Icons.arrow_back_rounded),
                      label: Text(_path.split(Platform.pathSeparator).last),
                    ),
                  ),
                Expanded(
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : RefreshIndicator(
                          onRefresh: _load,
                          child: ListView.builder(
                            padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
                            itemCount: _entries?.length ?? 0,
                            itemBuilder: (_, i) {
                              final entry = _entries![i];
                              return _FileRow(
                                entry: entry,
                                onTap: () {
                                  if (entry.isDir) {
                                    setState(() {
                                      _path = entry.path;
                                      _entries = null;
                                    });
                                    unawaited(_load());
                                  } else {
                                    unawaited(_download(entry));
                                  }
                                },
                                onDelete: () async {
                                  final ok = await widget.mesh.deleteRemoteFile(_device!, entry.path);
                                  if (ok) unawaited(_load());
                                },
                              );
                            },
                          ),
                        ),
                ),
              ],
            ),
    );
  }
}

class NexusSettingsPage extends StatelessWidget {
  final MeshService mesh;
  final Future<dynamic> Function()? onCheckForUpdate;

  const NexusSettingsPage({super.key, required this.mesh, this.onCheckForUpdate});

  @override
  Widget build(BuildContext context) {
    return NexusPage(
      title: 'Settings',
      subtitle: 'How Nexus behaves on this device.',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
        children: [
          _SettingGroup(
            title: 'Your Nexus',
            children: [
              _SettingRow(
                icon: Icons.devices_other_outlined,
                title: 'Devices',
                detail: '${mesh.pairedDevices.length} connected',
                onTap: null,
              ),
              _SettingRow(
                icon: Icons.auto_awesome_outlined,
                title: 'Assistant',
                detail: 'Personal preferences and memory',
                onTap: null,
              ),
            ],
          ),
          _SettingGroup(
            title: 'Behavior',
            children: [
              _SettingSwitch(
                icon: Icons.content_copy_outlined,
                title: 'Clipboard sync',
                value: mesh.store.clipboardSync,
                onChanged: (v) {
                  mesh.store.clipboardSync = v;
                  unawaited(mesh.store.save());
                },
              ),
              _SettingSwitch(
                icon: Icons.sync_outlined,
                title: 'Discover nearby devices',
                value: mesh.store.broadcastDiscovery,
                onChanged: (v) {
                  mesh.store.broadcastDiscovery = v;
                  unawaited(mesh.store.save());
                },
              ),
              _SettingSwitch(
                icon: Icons.system_update_outlined,
                title: 'Automatic updates',
                value: mesh.store.autoUpdate,
                onChanged: (v) {
                  mesh.store.autoUpdate = v;
                  unawaited(mesh.store.save());
                },
              ),
            ],
          ),
          _SettingGroup(
            title: 'About',
            children: [
              _SettingRow(
                icon: Icons.system_update_alt_outlined,
                title: 'Check for updates',
                detail: onCheckForUpdate == null ? 'Not available' : 'Check now',
                onTap: onCheckForUpdate == null ? null : () => unawaited(onCheckForUpdate!()),
              ),
              _SettingRow(
                icon: Icons.lock_outline,
                title: 'Privacy',
                detail: 'Your data stays on your devices.',
                onTap: () => _showInfo(context, 'Privacy', 'Nexus is designed around local-first operation. Pairing and device communication stay within the Nexus mesh.'),
              ),
              _SettingRow(
                icon: Icons.info_outline,
                title: 'Nexus',
                detail: appVersionLabel,
                onTap: () => _showInfo(context, 'About Nexus', 'Nexus connects your devices and gives you one assistant across them.'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showInfo(BuildContext context, String title, String body) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(body, style: Theme.of(context).textTheme.bodyMedium),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingGroup extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _SettingGroup({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 12, bottom: 8),
            child: Text(
              title.toUpperCase(),
              style: const TextStyle(
                color: NexusColors.faint,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.7,
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              color: NexusColors.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: NexusColors.border),
            ),
            child: Column(children: [for (var i = 0; i < children.length; i++) ...[children[i], if (i != children.length - 1) const Divider(indent: 52, endIndent: 16)]]),
          ),
        ],
      ),
    );
  }
}

class _SettingRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String detail;
  final VoidCallback? onTap;
  const _SettingRow({required this.icon, required this.title, required this.detail, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      minVerticalPadding: 10,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14),
      leading: Icon(icon, color: NexusColors.muted),
      title: Text(title),
      subtitle: Text(detail),
      trailing: onTap == null ? null : const Icon(Icons.chevron_right_rounded, color: NexusColors.faint),
      onTap: onTap,
    );
  }
}

class _SettingSwitch extends StatelessWidget {
  final IconData icon;
  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _SettingSwitch({required this.icon, required this.title, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      minVerticalPadding: 10,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14),
      leading: Icon(icon, color: NexusColors.muted),
      title: Text(title),
      trailing: Switch(value: value, onChanged: onChanged),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 4),
        child: Text(text, style: Theme.of(context).textTheme.titleMedium),
      );
}

class _DeviceRow extends StatelessWidget {
  final String name;
  final String platform;
  final bool online;
  final Widget? trailing;
  final VoidCallback onTap;
  const _DeviceRow({required this.name, required this.platform, required this.online, required this.onTap, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: NexusColors.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: NexusColors.surfaceHi,
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(_platformIcon(platform), color: NexusColors.muted, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Container(width: 7, height: 7, decoration: BoxDecoration(color: online ? NexusColors.ok : NexusColors.faint, shape: BoxShape.circle)),
                        const SizedBox(width: 6),
                        Text(online ? 'Online' : 'Offline', style: Theme.of(context).textTheme.bodySmall),
                        const SizedBox(width: 7),
                        Text(platform, style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                  ],
                ),
              ),
              trailing ?? const Icon(Icons.chevron_right_rounded, color: NexusColors.faint),
            ],
          ),
        ),
      ),
    );
  }

  IconData _platformIcon(String platform) {
    switch (platform) {
      case 'android':
        return Icons.phone_android_rounded;
      case 'windows':
        return Icons.desktop_windows_rounded;
      case 'linux':
        return Icons.computer_rounded;
      case 'macos':
        return Icons.laptop_mac_rounded;
      case 'USB':
        return Icons.usb_rounded;
      default:
        return Icons.devices_other_rounded;
    }
  }
}

class _FileRow extends StatelessWidget {
  final FileEntry entry;
  final VoidCallback onTap;
  final Future<void> Function() onDelete;
  const _FileRow({required this.entry, required this.onTap, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 4),
          child: Row(
            children: [
              Icon(entry.isDir ? Icons.folder_rounded : Icons.description_outlined, color: entry.isDir ? NexusColors.accent : NexusColors.muted),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(entry.name, style: Theme.of(context).textTheme.bodyLarge, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text(entry.isDir ? 'Folder' : _size(entry.size), style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'More',
                onSelected: (v) {
                  if (v == 'delete') unawaited(onDelete());
                },
                itemBuilder: (_) => const [PopupMenuItem(value: 'delete', child: Text('Delete'))],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

class _ChoiceRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String detail;
  final VoidCallback onTap;
  final bool danger;
  const _ChoiceRow({required this.icon, required this.title, required this.detail, required this.onTap, this.danger = false});

  @override
  Widget build(BuildContext context) {
    final color = danger ? NexusColors.danger : NexusColors.text;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      minVerticalPadding: 10,
      leading: Icon(icon, color: danger ? NexusColors.danger : NexusColors.muted),
      title: Text(title, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
      subtitle: Text(detail),
      trailing: const Icon(Icons.chevron_right_rounded, color: NexusColors.faint),
      onTap: onTap,
    );
  }
}

class _EmptyPanel extends StatelessWidget {
  final String title;
  final String message;
  final Widget? action;
  const _EmptyPanel({required this.title, required this.message, this.action});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 34, 24, 30),
      decoration: BoxDecoration(
        color: NexusColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: NexusColors.border),
      ),
      child: Column(
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
          const SizedBox(height: 6),
          Text(message, style: Theme.of(context).textTheme.bodyMedium, textAlign: TextAlign.center),
          if (action != null) ...[const SizedBox(height: 18), action!],
        ],
      ),
    );
  }
}

String get appVersionLabel => 'v0.1.52';
