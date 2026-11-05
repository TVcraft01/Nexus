// One conversation with the agent, from the user's side.
//
// The session is the loop the contract describes, in order: restate the ask as
// a goal, plan it through the model, validate it, ask once with every tier
// visible, execute under the approval, and report what changed and what was
// measured. It holds the state a conversation needs — the plan waiting for a
// yes or no, the options a question is offering, the agent it just made — and
// nothing else: the tools, the tiers and the rollback all live where the
// contract put them.
//
// Two answers come from local records rather than a model, on purpose: "what
// agents do I have" and "when do I actually use this" are questions about
// Nexus's own store, and a model that answered them could invent an agent. The
// working-hours offer is counted from the usage log, and the user still picks.
import 'agent_records.dart';
import 'approval.dart';
import 'executor.dart';
import 'plan.dart';
import 'plan_validator.dart';
import 'planner.dart';
import 'risk.dart';
import 'tools/revert_guard.dart';
import 'working_hours.dart';

enum SessionState {
  /// Nothing is waiting; the next thing said is a new ask.
  ready,

  /// A plan was shown and is waiting for a yes or a no.
  awaitingApproval,

  /// A numbered list was offered and is waiting for a number.
  awaitingChoice,
}

/// One of the numbered things a question offers, and the goal picking it means.
class SessionOption {
  const SessionOption({required this.text, required this.goal});

  final String text;
  final String goal;
}

/// What the session says back, plus what a test wants to look at: the plan it
/// made, the approval it took, the progress it reported and the report itself.
class AgentTurn {
  const AgentTurn({
    required this.say,
    this.state = SessionState.ready,
    this.progress = const <String>[],
    this.plan,
    this.approval,
    this.execution,
  });

  final String say;
  final SessionState state;

  /// What the executor called back, one line per step as it started.
  final List<String> progress;

  final Plan? plan;
  final Approval? approval;
  final ExecutionReport? execution;
}

/// "will it work all the time?" — the ask that gets the hours offer.
final RegExp _alwaysAsk = RegExp(
  r'all the time|always|every time|all day|24/7',
);

/// What counts as yes. Generous on the words, strict on the meaning: anything
/// else is a no, because a plan that runs on an ambiguous answer is not one the
/// user approved.
final RegExp _yes = RegExp(
  r'^(yes|yeah|yep|sure|ok|okay|do it|go ahead|please do|y)\b',
);

/// What keeps a guarded change: the word that stops its revert timer.
final RegExp _keepAsk = RegExp(r'^(keep|keep it|keep that|yes,? keep)\b');

class AgentSession {
  AgentSession({
    required this.planner,
    required this.validator,
    required this.executor,
    required this.records,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Planner planner;
  final PlanValidator validator;
  final Executor executor;
  final AgentRecords records;
  final DateTime Function() _now;

  SessionState _state = SessionState.ready;
  Plan? _awaitingPlan;
  List<SessionOption> _options = const <SessionOption>[];
  String? _lastAgent;
  String? _openQuestion;

  /// Tools whose last change is inside its keep-or-revert window.
  final List<PendingRevert> _keep = <PendingRevert>[];

  SessionState get state => _state;

  /// Handles whatever the user said next, according to what the session is
  /// waiting for.
  Future<AgentTurn> say(String text) async {
    final ask = text.trim();
    if (ask.isEmpty) {
      return const AgentTurn(say: 'What would you like me to do?');
    }
    if (_keep.isNotEmpty && _keepAsk.hasMatch(ask.toLowerCase())) {
      // Answered before anything else: a timer is running, and the word that
      // stops it must not be read as a new ask.
      for (final tool in _keep) {
        tool.keep();
      }
      _keep.clear();
      return const AgentTurn(
        say: 'Kept — the change stays and the timer is off.',
      );
    }
    if (_state == SessionState.awaitingApproval) return _answerApproval(ask);
    if (_state == SessionState.awaitingChoice) return _choose(ask);
    return _start(ask);
  }

  /// A new ask: local question, or plan, validate, and ask.
  Future<AgentTurn> _start(String ask) async {
    final local = _answerLocally(ask);
    if (local != null) return local;

    final goal = _openQuestion == null ? ask : '$_openQuestion — $ask';
    _openQuestion = null;
    final validation = validator.validate(await planner.propose(goal: goal));
    if (validation is PlanRejected) return _rejected(validation, goal);

    final plan = (validation as PlanAccepted).plan;
    if (plan.steps.isEmpty) return _offer(plan.questions, goal);
    if (plan.steps.every((step) => !step.risk.needsApproval)) {
      // Reading only: there is nothing to ask about, so it does not ask.
      return _run(plan, Approval.granted(plan: plan, words: '', at: _now()));
    }
    _awaitingPlan = plan;
    _state = SessionState.awaitingApproval;
    return AgentTurn(
      say: askApproval(plan),
      state: SessionState.awaitingApproval,
      plan: plan,
    );
  }

  Future<AgentTurn> _answerApproval(String words) async {
    final plan = _awaitingPlan;
    _awaitingPlan = null;
    _state = SessionState.ready;
    if (plan == null) {
      return const AgentTurn(
        say: 'There is nothing waiting for your yes or no.',
      );
    }
    if (!_yes.hasMatch(words.toLowerCase())) {
      return AgentTurn(
        say: 'Nothing ran. I have dropped the plan.',
        plan: plan,
        approval: Approval.denied(plan: plan, words: words, at: _now()),
      );
    }
    // The approval names the exact steps that were shown; the executor checks
    // every one of them again.
    return _run(plan, Approval.granted(plan: plan, words: words, at: _now()));
  }

  Future<AgentTurn> _choose(String words) async {
    final options = _options;
    final index = _indexOf(words, options);
    if (index == null) {
      return AgentTurn(
        say: 'Which one?\n${_numbered(options)}',
        state: SessionState.awaitingChoice,
      );
    }
    _options = const <SessionOption>[];
    _state = SessionState.ready;
    final option = options[index];

    final validation = validator.validate(
      await planner.propose(goal: option.goal),
    );
    if (validation is PlanRejected) return _rejected(validation, option.goal);
    final plan = (validation as PlanAccepted).plan;
    if (plan.steps.isEmpty) return _offer(plan.questions, option.goal);

    // Picking a numbered option is the approval: the option was the plan in
    // plain words, and the user chose it. The approval still names the exact
    // steps, so the executor's check is the same one it always makes.
    return _run(plan, Approval.granted(plan: plan, words: words, at: _now()));
  }

  /// Runs [plan] and says what happened — what changed, what was measured, or
  /// what came back and what did not.
  Future<AgentTurn> _run(Plan plan, Approval approval) async {
    final progress = <String>[];
    final before = <String>{
      for (final agent in records.savedAgents) agent.name,
    };
    try {
      final report = await executor.run(
        plan,
        approval,
        onProgress: progress.add,
      );
      final created = <String>[
        for (final agent in records.savedAgents)
          if (!before.contains(agent.name)) agent.name,
      ];
      if (created.isNotEmpty) _lastAgent = created.last;
      final where = created.isEmpty
          ? ''
          : ' Ask me “what agents do I have” to see it.';
      final keep = _pendingReverts(plan);
      final timer = keep.isEmpty
          ? ''
          : ' Say “keep it” to keep this; otherwise I put it back in '
                '${_secondsLeft(keep)} seconds.';
      return AgentTurn(
        say: '${_report(report)}$where$timer',
        progress: progress,
        plan: plan,
        approval: approval,
        execution: report,
      );
    } on TierNotApproved catch (error) {
      return AgentTurn(
        say: 'Nothing ran: “${error.step.description}” was not approved.',
        progress: progress,
        plan: plan,
        approval: approval,
      );
    }
  }

  /// The tools whose change is still inside its keep-or-revert window.
  ///
  /// The session asks its own tools rather than tracking tickets itself: the
  /// tool armed the timer, so the tool is what knows whether one is running.
  List<PendingRevert> _pendingReverts(Plan plan) {
    final pending = <PendingRevert>[];
    for (final step in plan.steps) {
      // Typed Object? on purpose: `PendingRevert` is not a subtype of `Tool`,
      // so Dart only promotes it from a variable it could have been.
      final Object? candidate = executor.registry.lookup(step.tool);
      if (candidate is PendingRevert && candidate.pendingRevert != null) {
        pending.add(candidate);
      }
    }
    _keep
      ..clear()
      ..addAll(pending);
    return pending;
  }

  int _secondsLeft(List<PendingRevert> pending) {
    final deadline = pending.first.pendingRevert?.deadline;
    if (deadline == null) return 0;
    final left = deadline.difference(_now()).inSeconds;
    return left < 0 ? 0 : left;
  }

  String _report(ExecutionReport report) => switch (report.status) {
    ExecutionStatus.done => _done(report),
    ExecutionStatus.stopped =>
      'I stopped before “${report.stoppedAt?.description ?? 'the next step'}” '
          'because the stop switch is on. Nothing after that ran.',
    ExecutionStatus.failed => _failed(report),
  };

  String _done(ExecutionReport report) {
    final changed = report.changed;
    if (changed.isEmpty) {
      return 'Done — I only looked, so nothing changed.';
    }
    final measured = report.measured;
    final evidence = measured.isEmpty
        ? ''
        : ' Measured: ${measured.join('; ')}.';
    return 'Done — ${changed.map(_plain).join('; ')}.$evidence';
  }

  String _failed(ExecutionReport report) {
    final parts = <String>['I stopped: ${_plain(report.failure)}.'];
    if (report.undone.isNotEmpty) {
      parts.add(
        'I put back: ${report.undone.map((result) => result.what).join('; ')}.',
      );
    }
    if (report.couldNotUndo.isNotEmpty) {
      parts.add('I could not undo: ${report.couldNotUndo.join('; ')}.');
    }
    if (report.undone.isEmpty && report.couldNotUndo.isEmpty) {
      parts.add('Nothing had been changed.');
    }
    return parts.join(' ');
  }

  /// The two questions answered from Nexus's own records, not from a model.
  AgentTurn? _answerLocally(String ask) {
    final lower = ask.toLowerCase();
    if (lower.contains('what agents') || lower.contains('which agents')) {
      final agents = records.savedAgents;
      if (agents.isEmpty) {
        return const AgentTurn(say: 'There are no agents on this device yet.');
      }
      final lines = <String>[
        for (final agent in agents)
          '${agent.name} — ${agent.goal}. Tools: ${agent.tools.join(', ')}. '
              '${agent.schedule == null ? 'Runs only when you ask.' : 'Runs ${agent.schedule}.'}',
      ];
      return AgentTurn(say: 'On this device:\n${lines.join('\n')}');
    }

    final name = _lastAgent;
    final agent = name == null ? null : records.agent(name);
    if (agent == null || agent.schedule != null) return null;
    if (!_alwaysAsk.hasMatch(lower)) return null;

    final hours = suggestWorkingHours(records.mailUsage);
    final label = hours?.label ?? 'during working hours';
    _options = <SessionOption>[
      SessionOption(
        text: 'Run ${agent.name} $label',
        goal: 'Run ${agent.name} $label',
      ),
      SessionOption(
        text: 'Run ${agent.name} all the time',
        goal: 'Run ${agent.name} all the time',
      ),
      SessionOption(
        text: 'Only run ${agent.name} when I ask',
        goal: 'Only run ${agent.name} when I ask',
      ),
    ];
    _state = SessionState.awaitingChoice;
    final learned = hours == null
        ? 'I have no usage log to learn from.'
        : 'Your mail use over the last 3 weeks is ${hours.label}.';
    return AgentTurn(
      say:
          'Not yet — it only runs while Nexus is open. $learned '
          'When should it run?\n${_numbered(_options)}',
      state: SessionState.awaitingChoice,
    );
  }

  /// A rejected plan, said as itself: faults are "I cannot do this", questions
  /// are "I need to know".
  AgentTurn _rejected(PlanRejected rejected, String goal) {
    if (rejected.faults.isEmpty && rejected.questions.isNotEmpty) {
      return _offer(rejected.questions, goal);
    }
    final said = StringBuffer('I did not run anything.');
    if (rejected.faults.isNotEmpty) {
      said.write(' ${rejected.faults.join(' ')}');
    }
    if (rejected.questions.isNotEmpty) {
      said.write(' ${rejected.questions.join(' ')}');
    }
    return AgentTurn(say: said.toString());
  }

  /// Asks what is missing — or, when the model asked several things at once
  /// with nothing to do yet, offers them as choices.
  AgentTurn _offer(List<String> questions, String goal) {
    if (questions.isEmpty) {
      return const AgentTurn(say: 'I could not work out what to do with that.');
    }
    if (questions.length == 1) {
      _openQuestion = goal;
      return AgentTurn(say: questions.first);
    }
    _options = <SessionOption>[
      for (final question in questions)
        SessionOption(text: question, goal: question),
    ];
    _state = SessionState.awaitingChoice;
    return AgentTurn(
      say:
          'I can do that. One thing to choose first:\n'
          '${_numbered(_options)}',
      state: SessionState.awaitingChoice,
    );
  }

  static int? _indexOf(String words, List<SessionOption> options) {
    final trimmed = words.trim();
    final number = int.tryParse(trimmed);
    if (number != null) {
      return number >= 1 && number <= options.length ? number - 1 : null;
    }
    final lower = trimmed.toLowerCase();
    final index = options.indexWhere(
      (option) => lower.contains(option.text.toLowerCase()),
    );
    return index < 0 ? null : index;
  }

  static String _numbered(List<SessionOption> options) => <String>[
    for (final (index, option) in options.indexed)
      '${index + 1}. ${option.text}',
  ].join('\n');

  static String _plain(String text) =>
      text.trim().replaceFirst(RegExp(r'[.]+$'), '');
}
