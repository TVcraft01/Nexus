// The conversation engine — one owner of the assistant thread and of the
// local-brain orchestration behind it. The view renders from this state and
// never mutates the thread itself: user bubbles and assistant cards land
// here, the generation ticket keeps concurrent conversations from clobbering
// each other, and the teach flow survives every brain failure. Pure Dart
// plus [ChangeNotifier], so the whole state machine is unit-testable without
// a widget tree.
import 'package:flutter/foundation.dart' show ChangeNotifier;

import 'agent_contract.dart';
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
/// spoken ask is answered out loud wherever its reply lands.
class ConversationEntry {
  final String? userText;
  final AgentDispatchResult? result;
  final String? teachKey;
  final bool spokenAsk;

  ConversationEntry.user(this.userText) : result = null, teachKey = null, spokenAsk = false;
  ConversationEntry.result(this.result, {this.teachKey, this.spokenAsk = false})
    : userText = null;
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
  }) {
    if (replaceLast && _entries.isNotEmpty) {
      // A spoken re-run (an aloud "yes" to an Approve/Deny bar) keeps the
      // exchange voiced even when the original ask was typed.
      if (spoken) _lastAskSpoken = true;
      _entries[_entries.length - 1] = ConversationEntry.result(
        result,
        teachKey: teachKey,
        spokenAsk: _lastAskSpoken,
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
    final index = _entries.indexOf(entry);
    if (index == -1) return;
    // The replacement answers the same ask as the card it replaces — its
    // spoken attribution carries over, even when that card sits mid-thread.
    _entries[index] = ConversationEntry.result(
      result,
      teachKey: teachKey,
      spokenAsk: entry.spokenAsk,
    );
    if (index == _entries.length - 1) {
      _pendingKey = switch (result.dispatch) {
        final AgentClarification clarification => clarification.key,
        _ => null,
      };
    }
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
  Future<void> converse({
    required LocalBrain brain,
    required String input,
    required AgentDispatchResult original,
    required ConversationContext Function() context,
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
    final thinking = _entries.last;
    final reply = await brain.reply(system: system, history: history);
    if (_disposed) return;
    if (reply.text == null) {
      // The teach card returns on THIS card — a newer exchange's card is
      // never touched. Only a failed latest exchange, and only an
      // unreachable one, marks the brain offline: a quiet empty reply is
      // not evidence of an outage.
      replaceEntry(thinking, original);
      if (seq == _converseSeq && !reply.reachable) {
        _brainHealth = BrainHealth.offline;
        _notify();
      }
    } else {
      final stale = teachKeyOf(original);
      replaceEntry(
        thinking,
        AgentDispatchResult(
          status: AgentResultStatus.succeeded,
          dispatch: AgentMessage(reply.text!),
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
