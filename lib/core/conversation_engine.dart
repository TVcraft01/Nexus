// The conversation engine — one owner of the assistant thread and of the
// local-brain orchestration behind it. The view renders from this state and
// never mutates the thread itself: user bubbles and assistant cards land
// here, the generation ticket keeps concurrent conversations from clobbering
// each other, and the teach flow survives every brain failure. Pure Dart
// plus [ChangeNotifier], so the whole state machine is unit-testable without
// a widget tree.
import 'package:flutter/foundation.dart' show ChangeNotifier, debugPrint;

import 'agent_contract.dart';
import 'agent_loop.dart';
import 'agent_tools.dart';
import 'brain.dart';
import 'conversation.dart';

/// Local-brain health, shown as a one-line status under the input bar:
/// probing right after start, online once a model is discovered, offline
/// when Ollama is missing or has no models.
enum BrainHealth { probing, offline, online }

/// The placeholder shown while the local brain is generating a reply.
const thinkingPlaceholder = 'Thinking…';

/// One exchange in the conversation: either a user bubble or an assistant
/// card. Approval re-runs and self-run outcomes replace the last entry
/// instead of appending, so each exchange stays one bubble pair. [teachKey]
/// is set when the card is a conversational answer to a "teach me" phrase —
/// the card then offers the way back into the teach loop. [spokenAsk] is
/// true when the ask this card answers came from the microphone — a card
/// keeps its own attribution even when it replaces a mid-thread entry, so a
/// spoken ask is answered out loud wherever its reply lands. [pending] is
/// true while the card's own action is still running: the card then states
/// work in flight rather than an outcome, and the run's result replaces it —
/// success, question or failure, with whatever reason came back.
class ConversationEntry {
  final String? userText;
  final AgentDispatchResult? result;
  final String? teachKey;
  final bool spokenAsk;
  final bool pending;

  ConversationEntry.user(this.userText)
    : result = null,
      teachKey = null,
      spokenAsk = false,
      pending = false;
  ConversationEntry.result(
    this.result, {
    this.teachKey,
    this.spokenAsk = false,
    this.pending = false,
  }) : userText = null;
}

/// Owns the conversation thread and the brain exchange state machine.
/// Every mutation notifies listeners; the view listens and rebuilds, so a
/// card is never written outside this engine. After [dispose] no listener is
/// notified (async brain replies land safely on a disposed engine).
class ConversationEngine extends ChangeNotifier {
  final List<ConversationEntry> _entries = [];

  /// A clarification is open; the next input answers it. Derived from the
  /// live tail's dispatch on every append/replace.
  String? _pendingKey;

  BrainHealth _brainHealth = BrainHealth.probing;
  String _brainModel = '';

  /// Monotonic ticket for in-flight conversations. Each brain exchange
  /// claims a number; when its reply lands, only the latest ticket may flip
  /// the brain's health state, so a stale reply can never overwrite what a
  /// newer exchange concluded.
  int _converseSeq = 0;

  /// The last ask in the thread, and whether it came from the microphone.
  /// Follow-up replies that only replace the last card (approval re-runs,
  /// self-run outcomes, the brain's answer) belong to that same ask, so the
  /// flag survives replacements and resets only on a fresh user bubble.
  bool _lastAskSpoken = false;

  bool _disposed = false;

  /// The conversation so far, oldest first.
  List<ConversationEntry> get entries => List.unmodifiable(_entries);

  bool get isEmpty => _entries.isEmpty;

  ConversationEntry? get last => _entries.isEmpty ? null : _entries.last;

  /// The result card at the end of the thread, if any — e.g. the pending
  /// Approve/Deny gate the next yes/no answers.
  AgentDispatchResult? get lastResult => last?.result;

  String? get pendingKey => _pendingKey;

  BrainHealth get brainHealth => _brainHealth;

  String get brainModel => _brainModel;

  /// Whether the ask behind the thread's replies was spoken. The view reads
  /// a reply out loud only when this is true — a typed exchange stays quiet.
  bool get lastAskSpoken => _lastAskSpoken;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Appends to (or, for re-runs, updates the end of) the thread. [teachKey]
  /// marks a card that answered a "teach me" question conversationally, so
  /// it can offer the way back into the teach loop. [spoken] marks an
  /// exchange that came from the microphone — the ask bubble, the card that
  /// answers it, and every replacement of that card (Thinking → answer,
  /// action card → outcome, re-runs) all carry the same spoken attribution.
  void appendResult(
    AgentDispatchResult result, {
    String? asUser,
    bool spoken = false,
    bool replaceLast = false,
    String? teachKey,
    bool pending = false,
  }) {
    if (replaceLast && _entries.isNotEmpty) {
      // A spoken re-run (an aloud "yes" to an Approve/Deny bar) keeps the
      // exchange voiced even when the original ask was typed.
      if (spoken) _lastAskSpoken = true;
      _entries[_entries.length - 1] = ConversationEntry.result(
        result,
        teachKey: teachKey,
        spokenAsk: _lastAskSpoken,
        pending: pending,
      );
    } else {
      if (asUser != null && asUser.isNotEmpty) {
        _entries.add(ConversationEntry.user(asUser));
        _lastAskSpoken = spoken;
      } else if (spoken) {
        // A spoken attempt with no user bubble to show (the mic heard
        // nothing) still belongs to a spoken exchange — the card that
        // follows should be read out loud.
        _lastAskSpoken = true;
      }
      _entries.add(ConversationEntry.result(
        result,
        teachKey: teachKey,
        spokenAsk: _lastAskSpoken,
        pending: pending,
      ));
    }
    _pendingKey = switch (result.dispatch) {
      final AgentClarification clarification => clarification.key,
      _ => null,
    };
    _notify();
  }

  /// Replaces a specific thread entry (an in-flight conversation's card)
  /// with a new result. Unlike replaceLast, this always lands on the card it
  /// belongs to, even when newer exchanges are already in the thread. No-op
  /// when the entry is gone. Only the live tail owns the pending-question
  /// state — a superseded card resolving later must not steal it.
  void replaceEntry(
    ConversationEntry entry,
    AgentDispatchResult result, {
    String? teachKey,
  }) {
    _swapCard(entry, result, teachKey: teachKey);
  }

  /// Swaps [card] for [result] where it sits, answering the entry now in the
  /// thread — null when the card is gone, because a superseded exchange must
  /// not resurrect itself. The handle matters: one exchange may swap its card
  /// more than once (Thinking → the tool it is running → the answer), and each
  /// swap invalidates the previous entry object.
  ConversationEntry? _swapCard(
    ConversationEntry card,
    AgentDispatchResult result, {
    String? teachKey,
    bool pending = false,
  }) {
    final index = _entries.indexOf(card);
    if (index == -1) return null;
    // The replacement answers the same ask as the card it replaces — its
    // spoken attribution carries over, even when that card sits mid-thread.
    final next = ConversationEntry.result(
      result,
      teachKey: teachKey,
      spokenAsk: card.spokenAsk,
      pending: pending,
    );
    _entries[index] = next;
    if (index == _entries.length - 1) {
      _pendingKey = switch (result.dispatch) {
        final AgentClarification clarification => clarification.key,
        _ => null,
      };
    }
    _notify();
    return next;
  }

  /// Starts a new conversation: the thread goes, and the open question with
  /// it, so the next thing typed is a fresh ask rather than an answer to a
  /// question from a conversation the user has abandoned.
  ///
  /// The brain keeps its health — a new conversation is a fresh thread, not a
  /// fresh Nexus — but any exchange already in flight is made stale by
  /// bumping the ticket. Its reply then lands on a card that no longer exists
  /// ([replaceEntry] no-ops on a missing entry) and cannot flip the brain's
  /// health either, so nothing from the old conversation leaks into the new.
  void reset() {
    _entries.clear();
    _pendingKey = null;
    _lastAskSpoken = false;
    _converseSeq++;
    _notify();
  }

  /// The plain text a card would say out loud, or null when the card is UI —
  /// an action card (its real outcome replaces it a moment later), a plan, a
  /// clarification question, a device list, or the transient "Thinking…"
  /// placeholder. Only plain answers are spoken.
  static String? speakableText(ConversationEntry entry) {
    final dispatch = entry.result?.dispatch;
    return switch (dispatch) {
      final AgentMessage message
          when message.action == null &&
              message.text.isNotEmpty &&
              message.text != thinkingPlaceholder =>
        message.text,
      _ => null,
    };
  }

  /// Discovers the installed local model and reflects it in the status line.
  /// Called at startup and when the status line is tapped (retry after
  /// installing Ollama / pulling a model). Always refreshes: the retry must
  /// re-discover, so a model pulled after the last probe upgrades the choice.
  Future<void> probe(LocalBrain brain) async {
    if (_disposed) return;
    final model = await brain.availableModel(refresh: true);
    if (_disposed) return;
    _brainHealth = model == null ? BrainHealth.offline : BrainHealth.online;
    _brainModel = model ?? '';
    _notify();
  }

  /// The conversational fallback for phrases the interpreter doesn't know:
  /// builds a bounded history from the thread, asks the local brain, and
  /// swaps the teach card for the model's reply. If the brain can't answer,
  /// the original teach card comes back untouched. [context] is built at
  /// call time so the memory (profile, facts, skills) is always current.
  /// [onBrainAnswered] fires with the superseded teach key on success, so
  /// the caller can drop the service's stale question.
  ///
  /// [tools] is what the model may *do* rather than only say: with a runner
  /// wired, the exchange runs through [ToolLoop] and the card names the tool
  /// while it runs — "Looking in Downloads…" — before the answer replaces
  /// it. Without one, this is the plain single call it always was.
  Future<void> converse({
    required LocalBrain brain,
    required String input,
    required AgentDispatchResult original,
    required ConversationContext Function() context,
    ToolRunner? tools,
    void Function(String? teachKey)? onBrainAnswered,
  }) async {
    if (_disposed) return;
    // Proven offline by the last probe? Stay classic — no Thinking flash,
    // no doomed connection attempt; the teach card stands as-is.
    if (_brainHealth == BrainHealth.offline) return;
    // One shared memory, assembled by the core seam: the persona carries
    // what Nexus knows about its person, and the history is a bounded,
    // UI-free projection of the thread (plans and clarifications are
    // filtered by buildChatHistory — the model never sees UI internals).
    final system = buildSystemPrompt(context());
    final history = buildChatHistory(
      [
        for (final entry in _entries)
          (userText: entry.userText, dispatch: entry.result?.dispatch),
      ],
      input: input,
      placeholderTexts: {thinkingPlaceholder},
    );
    final seq = ++_converseSeq;
    appendResult(
      AgentDispatchResult(
        status: AgentResultStatus.succeeded,
        dispatch: AgentMessage(thinkingPlaceholder),
      ),
      replaceLast: true,
    );
    // The card this exchange owns. Each swap carries the handle forward, so
    // the reply always lands on the card the user is looking at — Thinking →
    // “Looking in Downloads…” → the answer.
    var card = _entries.last;
    // Never throws: a brain that fails answers null, which is the seam's
    // own contract — but a brain that THROWS would otherwise escape as an
    // unhandled async error and leave the Thinking card up forever. A
    // thrown exchange is a failure with a message, like every other one.
    ToolLoopReply? reply;
    try {
      reply = await ToolLoop(brain: brain, tools: tools).run(
        system: system,
        ask: input,
        history: history,
        onRunning: (call) {
          if (_disposed) return;
          card = _swapCard(
                card,
                AgentDispatchResult(
                  status: AgentResultStatus.succeeded,
                  dispatch: AgentMessage(call.runningLabel),
                ),
                // Work in flight: the card says what is happening instead of
                // wearing a finished status, and the live line of a running
                // fetch has somewhere to show.
                pending: true,
              ) ??
              card;
        },
      );
    } on Object catch (e) {
      debugPrint('NEXUS converse: brain threw ($e)');
      reply = null;
    }
    if (_disposed) return;
    final text = reply?.text;
    if (text == null) {
      // Every failure path produces a message — never the silent teach-card
      // restore, never a stuck Thinking card. The brain owned this phrase
      // (it tried), so the service's stale teach question is dropped, like
      // on success. Only a failed latest exchange, and only an unreachable
      // one, marks the brain offline: a quiet empty reply — and a throw —
      // are not evidence of an outage.
      final reachable = reply?.reachable ?? true;
      final message = reply == null
          ? 'Something went wrong while I was thinking — please try again.'
          : reachable
              ? 'I couldn\'t come up with an answer — could you rephrase that?'
              : 'The model isn\'t ready yet — it may still be downloading on '
                  'first launch. Try again in a bit.';
      _swapCard(
        card,
        AgentDispatchResult(
          status: AgentResultStatus.succeeded,
          dispatch: AgentMessage(message),
        ),
      );
      onBrainAnswered?.call(teachKeyOf(original));
      if (seq == _converseSeq && reply != null && !reply.reachable) {
        _brainHealth = BrainHealth.offline;
        _notify();
      }
    } else {
      final stale = teachKeyOf(original);
      _swapCard(
        card,
        AgentDispatchResult(
          status: AgentResultStatus.succeeded,
          dispatch: AgentMessage(text),
        ),
        teachKey: stale,
      );
      // The brain owns this phrase now — the caller drops the service's
      // stale teach question so it can never swallow a later input.
      onBrainAnswered?.call(stale);
    }
  }

  /// The teach clarification key behind a brain exchange, or null when the
  /// original result is not a teach question.
  static String? teachKeyOf(AgentDispatchResult original) {
    final dispatch = original.dispatch;
    return switch (dispatch) {
      final AgentClarification clarification
          when clarification.key.startsWith('teach:') =>
        clarification.key,
      _ => null,
    };
  }
}
