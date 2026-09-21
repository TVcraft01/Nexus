import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../../core/agent_contract.dart';
import '../../core/brain.dart';
import '../../core/conversation_engine.dart';
import '../../mesh/mesh_service.dart';
import '../device_executor.dart';
import 'assistant_controller.dart';
import 'design_system.dart';
import 'nexus_orb.dart';

/// The assistant screen, and only that: it lays the state out and paints it.
///
/// One compact presence row (the globe plus one line saying what Nexus is
/// doing), the thread, and the composer where the thumb already is. Nothing
/// above the thread is a hero, because the user came here to talk.
///
/// Every decision and every signal lives in [NexusAssistantController]:
/// [CommandService] works out what an ask means, [ConversationEngine] owns the
/// thread and the brain exchange, [DeviceExecutor] runs what this device can
/// really run, and the mesh carries the rest. This file invents nothing — it
/// renders what the controller says, and its only state is the text field.
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
  late final NexusAssistantController _controller;
  final _input = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _controller = NexusAssistantController(
      mesh: widget.mesh,
      brain: widget.brain,
      executor: widget.executor,
    );
    unawaited(_controller.loadProfile());
    // The habits are read straight after the first frame, so the first paint is
    // never held up by a query log the user cannot see yet.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_controller.loadHabits());
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Sends what is in the field, if the controller takes it as an ask. The
  /// field keeps its text when it does not (empty, or something already
  /// running), so a refusal never eats what the user typed.
  void _send() {
    final text = _input.text;
    if (!_controller.accepts(text)) return;
    _input.clear();
    unawaited(_controller.submit(text));
  }

  void _usePrompt(String text) {
    HapticFeedback.selectionClick();
    _focus.requestFocus();
    if (!_controller.accepts(text)) return;
    unawaited(_controller.submit(text));
  }

  void _startNewConversation() {
    HapticFeedback.selectionClick();
    _controller.startNewConversation();
    _input.clear();
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final theme = Theme.of(context);
        final entries = _controller.entries;
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
                child: _presence(
                  theme,
                  hasThread: entries.isNotEmpty,
                ),
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
                        // reverse: the chat pattern — the newest exchange pins
                        // to the bottom by itself, so nothing has to scroll it.
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
            if (_controller.confirm != null) _confirmCard(theme),
            SafeArea(top: false, child: _composer(theme)),
          ],
        );
      },
    );
  }

  /// The whole introduction: the globe, who Nexus is, and what it is doing.
  /// One row, one line — the conversation below is the content.
  Widget _presence(ThemeData theme, {required bool hasThread}) {
    final name = _controller.assistantName;
    final orbState = _controller.orbState;
    return Row(
      children: [
        NexusOrb(
          state: orbState,
          size: 44,
          semanticLabel: '$name — ${orbState.label}',
        ),
        const SizedBox(width: NexusV2Space.md),
        Expanded(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(text: name, style: theme.textTheme.titleMedium),
                TextSpan(
                  text: '   ${_controller.stateLine}',
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
    final suggestions = _controller.suggestions;
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
                _controller.emptyLead,
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
            if (isLast && _controller.canRetry) ...[
              const SizedBox(height: NexusV2Space.xs),
              TextButton.icon(
                onPressed: () => unawaited(_controller.retryNow()),
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
              : NexusAssistantController.statusWords(result.status),
          null,
        ),
      AgentMessage m when m.text == thinkingPlaceholder => ('Thinking…', null),
      AgentMessage m => (m.text, null),
      AgentClarification c => (c.question, c.hint),
      AgentActionPlan p => (
          NexusAssistantController.describeRequest(p.request),
          'on ${_controller.deviceName(p.request.target)}',
        ),
      AgentDeviceList l => (
          'Your devices',
          NexusAssistantController.deviceSummary(l),
        ),
    };
    // A failure with nothing else to say reads headline-first: what kind of
    // thing happened, then the platform's own reason under it in the error
    // colour. Left as a plain body, a failure would look like any answer.
    final failure = NexusAssistantController.isFailure(result.status);
    final bareFailure = dispatch == null && failure;
    final headline = bareFailure
        ? NexusAssistantController.statusWords(result.status)
        : body;
    // Otherwise the reason is only added when it says something the body does
    // not: a question is not restated as a failure, and a "Done" adds nothing.
    final reason = bareFailure
        ? (result.message.isEmpty ? null : result.message)
        : (result.status == AgentResultStatus.succeeded ||
                result.message == body
            ? null
            : (result.message.isNotEmpty
                ? result.message
                : NexusAssistantController.statusWords(result.status)));
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
              color: failure
                  ? theme.colorScheme.error
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }

  /// The question the platform's near matches deserve: the real names as real
  /// choices, plus a way out that leaves nothing hanging.
  Widget _confirmCard(ThemeData theme) {
    final confirm = _controller.confirm!;
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
                      onPressed: () =>
                          unawaited(_controller.confirmWith(name)),
                      child: Text(
                        '${NexusAssistantController.verbFor(confirm.request.action)} $name',
                      ),
                    ),
                  TextButton(
                    onPressed: _controller.dismissConfirm,
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
    final busy = _controller.busy;
    final listening = _controller.listening;
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
                  onSubmitted: (_) => _send(),
                  decoration: InputDecoration(
                    hintText: _controller.pendingKey != null
                        ? 'Answer the question, or ask something else'
                        : 'Ask ${_controller.assistantName} anything…',
                    border: InputBorder.none,
                    filled: false,
                  ),
                ),
              ),
              IconButton(
                tooltip: listening ? 'Listening…' : 'Use voice',
                onPressed: listening || busy
                    ? null
                    : () => unawaited(_controller.listen()),
                icon: Icon(
                  listening ? Icons.graphic_eq_rounded : Icons.mic_none_rounded,
                ),
                color: listening
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 2),
              IconButton.filled(
                tooltip: busy ? 'Working…' : 'Send',
                onPressed: busy ? null : _send,
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
