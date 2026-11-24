// Settings → Automations: the agents that work on this PC.
//
// The agent core landed in roadmap items 4–4b with no way in. An agent could be
// made by writing JSON and started from a URL printed to the developer log, and
// nothing on screen said so. This page is that way in.
//
// It is deliberately a list and a sheet, not a dashboard: the same words the
// executor logs (status, policy, what the last run said), the same tiers the
// gate enforces, and no control that is not real. Every button here calls the
// service the background tick calls, so a scheduled run and a run from this
// page cannot disagree about what an agent is allowed to do.

part of '../main_ui.dart';

/// The page itself, for a test that pushed it.
const Key kNexusAgentsPage = Key('nexus-agents-page');

/// The + in the page header: the screen's one primary action.
const Key kNexusAgentNew = Key('nexus-agent-new');

/// The two states of the global stop.
const Key kNexusAgentsHalt = Key('nexus-agents-halt');
const Key kNexusAgentsResume = Key('nexus-agents-resume');

/// One agent's row, by name.
Key nexusAgentRowKey(String name) => ValueKey<String>('agent-row-$name');

/// The form's save button.
const Key kNexusAgentSave = Key('nexus-agent-save');

/// Whether this build has an automation to offer, said in the row's own words.
///
/// A screen with nothing to say about a feature that cannot run is a promise
/// about nothing, so Settings asks this before it draws the row.
String nexusAgentsSubtitle(AppServices services) {
  final List<AgentDefinition> agents =
      services.agents?.savedAgents ?? const <AgentDefinition>[];
  if (agents.isEmpty) return 'Give one a job and the hours to do it in';
  final int running = agents
      .where((AgentDefinition agent) => agent.status == AgentStatus.running)
      .length;
  final String count = agents.length == 1 ? '1 automation' : '${agents.length} automations';
  return running == 0 ? '$count · none running' : '$count · $running running';
}

/// The Automations screen.
class AgentsPage extends StatefulWidget {
  const AgentsPage({
    super.key,
    required this.store,
    required this.service,
    this.dashboard,
    this.tools = const <Tool>[],
  });

  /// Where the definitions live. The page reads it back after every write, so
  /// it always draws what is on disk rather than what a button assumed.
  final AgentStore store;

  /// The background service: start, pause, run now, halt, undo.
  final AgentService service;

  /// The local-only dashboard, when this launch serves one. Its URL carries a
  /// per-launch key, so it can only be opened from here or the developer log.
  final AgentDashboard? dashboard;

  /// The tools an agent may be given here. Empty on a build with no tool set,
  /// where the honest answer is that a new agent has nothing it could run.
  final List<Tool> tools;

  @override
  State<AgentsPage> createState() => _AgentsPageState();
}

class _AgentsPageState extends State<AgentsPage> {
  /// The agent whose manual run is in flight. One at a time: two taps on two
  /// agents are two runs, but two taps on one agent must not be.
  String? _running;

  List<AgentDefinition> get _agents => widget.store.savedAgents;

  Future<void> _say(String line) async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(line)),
    );
  }

  Future<void> _run(AgentDefinition agent) async {
    setState(() => _running = agent.name);
    try {
      final AgentRun run = await widget.service.runNow(agent.name);
      await _say(run.result);
    } on AgentServiceError catch (error) {
      await _say(error.message);
    } catch (error) {
      await _say('That run failed: $error');
    } finally {
      if (mounted) setState(() => _running = null);
    }
  }

  Future<void> _halt() async {
    final bool? yes = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialog) => AlertDialog(
        backgroundColor: context.ui.surface,
        title: Text('Halt all automations?', style: NexusType.rowTitle(context.ui)),
        content: Text(
          'Nothing new will start, and a run already working stops before its '
          'next step. Nothing already done is undone.',
          style: NexusType.rowMeta(context.ui).copyWith(height: 1.5),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text('Cancel', style: TextStyle(color: context.ui.textMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(
              'Halt all',
              style: TextStyle(color: context.ui.danger),
            ),
          ),
        ],
      ),
    );
    if (yes != true) return;
    widget.service.haltAll();
    if (mounted) setState(() {});
  }

  void _resume() {
    widget.service.resumeAgents();
    setState(() {});
  }

  Future<void> _open(AgentDefinition agent) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.ui.background,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (BuildContext sheet) => _AgentSheet(
        store: widget.store,
        service: widget.service,
        name: agent.name,
        running: _running == agent.name,
        onRun: () => _run(agent),
        onChanged: () {
          if (mounted) setState(() {});
        },
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _new() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.ui.background,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (BuildContext sheet) => _NewAgentSheet(
        store: widget.store,
        tools: widget.tools,
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _openDashboard() async {
    final String? url = widget.dashboard?.url;
    if (url == null) return;
    final bool opened = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!opened) await _say('Could not open the dashboard in a browser.');
  }

  @override
  Widget build(BuildContext context) {
    final NexusUiColors c = context.ui;
    final List<AgentDefinition> agents = _agents;
    final bool halted = widget.service.halted;
    final String? dashboardUrl = widget.dashboard?.url;
    return Scaffold(
      key: kNexusAgentsPage,
      backgroundColor: c.background,
      appBar: AppBar(
        backgroundColor: c.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('Automations', style: NexusType.pageTitle(c)),
        actions: <Widget>[
          IconButton(
            key: kNexusAgentNew,
            tooltip: 'New automation',
            onPressed: widget.tools.isEmpty ? null : () => unawaited(_new()),
            icon: const Icon(Icons.add_rounded),
            color: c.accent,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: NexusLayout.content),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                NexusLayout.gutter,
                0,
                NexusLayout.gutter,
                32,
              ),
              children: <Widget>[
                if (halted) ...<Widget>[
                  _HaltedCard(onResume: _resume),
                  const SizedBox(height: 8),
                ],
                const NexusSectionLabel('Automations', first: true),
                if (agents.isEmpty)
                  _EmptyAgents(
                    canCreate: widget.tools.isNotEmpty,
                    onCreate: widget.tools.isEmpty ? null : _new,
                  )
                else
                  for (final AgentDefinition agent in agents) ...<Widget>[
                    NexusRow(
                      key: nexusAgentRowKey(agent.name),
                      title: agent.name,
                      subtitle: _shortGoal(agent.goal),
                      leading: NexusIconTile(
                        agent.status == AgentStatus.running
                            ? Icons.play_circle_outline_rounded
                            : Icons.smart_toy_outlined,
                      ),
                      trailing: _running == agent.name
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Row(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Text(
                                  _statusWord(agent.status),
                                  style: NexusType.rowMeta(c).copyWith(
                                    color:
                                        agent.status == AgentStatus.running
                                        ? c.online
                                        : c.textMuted,
                                  ),
                                ),
                                const SizedBox(width: 2),
                                const NexusChevron(),
                              ],
                            ),
                      onTap: () => unawaited(_open(agent)),
                    ),
                    const SizedBox(height: 2),
                  ],
                if (dashboardUrl != null) ...<Widget>[
                  const NexusSectionLabel('This PC'),
                  NexusRow(
                    title: 'Dashboard',
                    subtitle: 'The same controls in your browser — this PC only',
                    leading: const NexusIconTile(Icons.open_in_browser_rounded),
                    trailing: const NexusChevron(),
                    onTap: () => unawaited(_openDashboard()),
                  ),
                ],
                if (agents.isNotEmpty) ...<Widget>[
                  const NexusSectionLabel('Everything'),
                  if (halted)
                    NexusRow(
                      key: kNexusAgentsResume,
                      title: 'Resume automations',
                      subtitle: 'They stay stopped until you start one again',
                      leading: const NexusIconTile(Icons.play_arrow_rounded),
                      trailing: const NexusChevron(),
                      onTap: _resume,
                    )
                  else
                    NexusRow(
                      key: kNexusAgentsHalt,
                      title: 'Halt all',
                      subtitle:
                          'Stops every automation, including one that is running',
                      leading: const NexusIconTile(Icons.stop_rounded),
                      dangerTitle: true,
                      trailing: const NexusChevron(),
                      onTap: () => unawaited(_halt()),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// What the agent does, on the row's one line. The whole goal is one tap
  /// away in the sheet; a row that wrapped to four lines pushed the next agent
  /// off the screen, which is the opposite of what a list is for.
  static String _shortGoal(String goal) => goal.length <= 64
      ? goal
      : '${goal.substring(0, 63).trimRight()}…';
}

String _statusWord(AgentStatus status) => switch (status) {
  AgentStatus.running => 'Running',
  AgentStatus.paused => 'Paused',
  AgentStatus.stopped => 'Stopped',
};

/// "just now", "12 min ago", then a date — never a raw timestamp.
String _whenLine(DateTime? at) {
  if (at == null) return 'it has not run yet';
  final Duration ago = DateTime.now().difference(at);
  if (ago.inMinutes < 1) return 'just now';
  if (ago.inMinutes < 60) return '${ago.inMinutes} min ago';
  if (ago.inHours < 24) return '${ago.inHours} h ago';
  return 'on ${at.day}/${at.month}/${at.year}';
}

class _HaltedCard extends StatelessWidget {
  const _HaltedCard({required this.onResume});

  final VoidCallback onResume;

  @override
  Widget build(BuildContext context) {
    final NexusUiColors c = context.ui;
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 10),
      decoration: BoxDecoration(
        color: c.raised,
        borderRadius: const BorderRadius.all(NexusLayout.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('Everything is halted', style: NexusType.rowTitle(c)),
          const SizedBox(height: 3),
          Text(
            'No automation will start, on a schedule or by hand, until you '
            'resume them.',
            style: NexusType.rowMeta(c).copyWith(height: 1.4),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: onResume,
              child: const Text('Resume'),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyAgents extends StatelessWidget {
  const _EmptyAgents({required this.canCreate, this.onCreate});

  final bool canCreate;
  final VoidCallback? onCreate;

  @override
  Widget build(BuildContext context) {
    final NexusUiColors c = context.ui;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            canCreate
                ? 'No automations yet. Give one a job — "check my Wi-Fi signal '
                      'and speed" — and the hours it may work in.'
                : 'This build has no tools to give an automation yet. On this '
                      'PC they run with the model installed here.',
            style: NexusType.rowMeta(c).copyWith(height: 1.5),
          ),
          if (canCreate) ...<Widget>[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: onCreate,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('New automation'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One agent's details and its controls.
class _AgentSheet extends StatefulWidget {
  const _AgentSheet({
    required this.store,
    required this.service,
    required this.name,
    required this.running,
    required this.onRun,
    required this.onChanged,
  });

  final AgentStore store;
  final AgentService service;
  final String name;
  final bool running;
  final Future<void> Function() onRun;
  final VoidCallback onChanged;

  @override
  State<_AgentSheet> createState() => _AgentSheetState();
}

class _AgentSheetState extends State<_AgentSheet> {
  bool _busy = false;

  AgentDefinition? get _agent => widget.store.agent(widget.name);

  Future<void> _say(String line) async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(line)),
    );
  }

  Future<void> _toggle(AgentDefinition agent) async {
    setState(() => _busy = true);
    try {
      if (agent.status == AgentStatus.running) {
        await widget.service.pause(agent.name);
      } else {
        await widget.service.start(agent.name);
      }
    } on AgentServiceError catch (error) {
      await _say(error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
      widget.onChanged();
    }
  }

  Future<void> _run() async {
    await widget.onRun();
    if (mounted) setState(() {});
  }

  Future<void> _undo(AgentDefinition agent) async {
    setState(() => _busy = true);
    try {
      final List<RollbackResult> results = await widget.service.undoLastRun(
        agent.name,
      );
      final int failed = results
          .where((RollbackResult result) => !result.ok)
          .length;
      await _say(
        failed == 0
            ? 'Put back ${results.length} step(s) from the last run.'
            : 'Could not put back $failed of ${results.length} step(s).',
      );
    } on AgentServiceError catch (error) {
      await _say(error.message);
    } catch (error) {
      await _say('That undo failed: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
      widget.onChanged();
    }
  }

  Future<void> _delete(AgentDefinition agent) async {
    final NexusUiColors c = context.ui;
    final bool? yes = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialog) => AlertDialog(
        backgroundColor: c.surface,
        title: Text('Delete ${agent.name}?', style: NexusType.rowTitle(c)),
        content: Text(
          'Its definition and schedule are removed from this PC. Its log '
          'lines stay.',
          style: NexusType.rowMeta(c).copyWith(height: 1.5),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text('Cancel', style: TextStyle(color: c.textMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text('Delete automation', style: TextStyle(color: c.danger)),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await widget.store.remove(agent.name);
    widget.onChanged();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final NexusUiColors c = context.ui;
    final AgentDefinition? agent = _agent;
    if (agent == null) return const SizedBox.shrink();
    final bool running = agent.status == AgentStatus.running;
    final bool canUndo = widget.service.canUndoLastRun(agent.name);
    final bool halted = widget.service.halted;
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(agent.name, style: NexusType.pageTitle(c)),
                ),
                IconButton(
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: Icon(Icons.close_rounded, color: c.textMuted),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              agent.goal,
              style: NexusType.bubble(c).copyWith(color: c.textStrong),
            ),
            const SizedBox(height: 14),
            NexusRow(
              title: 'Stands',
              subtitle: _statusWord(agent.status),
              leading: const NexusIconTile(Icons.play_circle_outline_rounded),
            ),
            NexusRow(
              title: 'Runs',
              subtitle: AgentSchedule.parse(agent.schedule) == null
                  ? 'Only when you run it'
                  : agent.schedule!,
              leading: const NexusIconTile(Icons.schedule_rounded),
            ),
            NexusRow(
              title: 'May do on its own',
              subtitle: agent.approval.label,
              leading: const NexusIconTile(Icons.verified_user_outlined),
            ),
            NexusRow(
              title: 'Last run',
              subtitle: _whenLine(agent.lastRunAt),
              leading: const NexusIconTile(Icons.history_rounded),
            ),
            if (agent.lastResult.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
                child: Text(
                  agent.lastResult,
                  style: NexusType.rowMeta(c).copyWith(height: 1.5),
                ),
              ),
            const SizedBox(height: 16),
            if (halted)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  'Everything is halted, so nothing will run until you resume.',
                  style: NexusType.rowMeta(c).copyWith(color: c.danger),
                ),
              ),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: halted || _busy || widget.running ? null : _run,
                icon: widget.running
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow_rounded, size: 20),
                label: Text(widget.running ? 'Running' : 'Run now'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: _busy ? null : () => unawaited(_toggle(agent)),
                child: Text(
                  running ? 'Pause it' : 'Start on its schedule',
                ),
              ),
            ),
            if (canUndo) ...<Widget>[
              const SizedBox(height: 4),
              Center(
                child: TextButton(
                  onPressed: _busy ? null : () => unawaited(_undo(agent)),
                  child: const Text('Undo last run'),
                ),
              ),
            ],
            Center(
              child: TextButton(
                onPressed: _busy ? null : () => unawaited(_delete(agent)),
                child: Text(
                  'Delete automation',
                  style: TextStyle(color: c.danger),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The new-agent form: a name, the job, the hours, the policy, the tools.
class _NewAgentSheet extends StatefulWidget {
  const _NewAgentSheet({required this.store, required this.tools});

  final AgentStore store;
  final List<Tool> tools;

  @override
  State<_NewAgentSheet> createState() => _NewAgentSheetState();
}

class _NewAgentSheetState extends State<_NewAgentSheet> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _goal = TextEditingController();
  final TextEditingController _schedule = TextEditingController();

  AgentApprovalPolicy _policy = AgentApprovalPolicy.askEveryChange;

  /// Preselected: the tools that only read. A change is the user's to grant,
  /// and a destructive one is never a default.
  late final Set<String> _selected = <String>{
    for (final Tool tool in widget.tools)
      if (tool.risk == RiskTier.read) tool.name,
  };

  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _goal.dispose();
    _schedule.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final String name = _name.text.trim();
    final String goal = _goal.text.trim();
    final String schedule = _schedule.text.trim();
    final String? problem = switch (null) {
      _ when name.isEmpty => 'Give the automation a name.',
      _ when widget.store.agent(name) != null =>
        'There is already an automation called “$name”.',
      _ when goal.isEmpty => 'Say what it should do.',
      _ when schedule.isNotEmpty && AgentSchedule.parse(schedule) == null =>
        'Write the hours as 9:00-18:00, or leave the field empty.',
      _ when _selected.isEmpty => 'Choose at least one tool it may use.',
      _ => null,
    };
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _error = null;
      _saving = true;
    });
    await widget.store.put(
      AgentDefinition(
        name: name,
        goal: goal,
        tools: _selected.toList()..sort(),
        schedule: schedule.isEmpty ? null : schedule,
        approval: _policy,
      ),
    );
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final NexusUiColors c = context.ui;
    final double bottom = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      'New automation',
                      style: NexusType.pageTitle(c),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(Icons.close_rounded, color: c.textMuted),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'It runs on this PC with the model installed here. It can only '
                'use the tools you tick below.',
                style: NexusType.rowMeta(c).copyWith(height: 1.5),
              ),
              const SizedBox(height: 16),
              _Field(
                label: 'Name',
                hint: 'Wi-Fi check',
                controller: _name,
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 12),
              _Field(
                label: 'What should it do?',
                hint: 'Check my Wi-Fi signal and speed',
                controller: _goal,
                maxLines: 2,
              ),
              const SizedBox(height: 12),
              _Field(
                label: 'When may it run?',
                hint: '9:00-18:00 on weekdays',
                helper: 'Leave it empty to run only when you ask.',
                controller: _schedule,
              ),
              const SizedBox(height: 18),
              const NexusSectionLabel('What it may do on its own'),
              for (final AgentApprovalPolicy policy
                  in AgentApprovalPolicy.values)
                NexusRow(
                  title: policy.label,
                  semanticLabel: 'May do on its own. ${policy.label}. '
                      '${_policy == policy ? 'Chosen.' : 'Not chosen.'}',
                  trailing: _policy == policy
                      ? Icon(Icons.check_rounded, size: 20, color: c.accent)
                      : null,
                  onTap: () => setState(() => _policy = policy),
                ),
              const NexusSectionLabel('Tools it may use'),
              for (final Tool tool in widget.tools)
                NexusRow(
                  title: tool.name.replaceAll('_', ' '),
                  subtitle:
                      '${tool.description} · ${tool.risk.level} risk',
                  trailing: Checkbox(
                    value: _selected.contains(tool.name),
                    activeColor: c.accent,
                    onChanged: (bool? value) => setState(() {
                      if (value ?? false) {
                        _selected.add(tool.name);
                      } else {
                        _selected.remove(tool.name);
                      }
                    }),
                  ),
                  onTap: () => setState(() {
                    if (!_selected.remove(tool.name)) {
                      _selected.add(tool.name);
                    }
                  }),
                ),
              if (_error != null) ...<Widget>[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: NexusType.rowMeta(c).copyWith(color: c.danger),
                ),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: kNexusAgentSave,
                  onPressed: _saving ? null : () => unawaited(_save()),
                  child: Text(_saving ? 'Saving' : 'Create automation'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One form field, drawn from the same tokens as every row on the page.
class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.controller,
    this.hint,
    this.helper,
    this.maxLines = 1,
    this.textInputAction,
  });

  final String label;
  final String? hint;
  final String? helper;
  final TextEditingController controller;
  final int maxLines;
  final TextInputAction? textInputAction;

  @override
  Widget build(BuildContext context) {
    final NexusUiColors c = context.ui;
    OutlineInputBorder border(Color color) => OutlineInputBorder(
      borderRadius: const BorderRadius.all(NexusLayout.card),
      borderSide: BorderSide(color: color),
    );
    return TextField(
      controller: controller,
      maxLines: maxLines,
      textInputAction: textInputAction,
      style: NexusType.bubble(c),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        helperText: helper,
        helperMaxLines: 2,
        filled: true,
        fillColor: c.surface,
        labelStyle: TextStyle(color: c.textMuted),
        hintStyle: NexusType.hint(c),
        helperStyle: NexusType.rowMeta(c),
        enabledBorder: border(c.hairline),
        focusedBorder: border(c.accent),
        border: border(c.hairline),
      ),
    );
  }
}
