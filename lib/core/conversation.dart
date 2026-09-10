// One shared memory, one voice: everything the assistant knows about its
// person, assembled into the local brain's context. This is the seam between
// the assistant's persisted knowledge (facts, taught phrases, remembered
// defaults, profile names, habits) and the model prompt — pure Dart, fully
// testable, no view, mesh, or network in sight.
//
// Phase 2: the memory block in the system prompt is what makes conversation
// *informed* — the model is told the facts the user taught, the commands
// they taught, the defaults they picked, and the things they ask about most,
// on every device that shares the same memory.
import 'agent_contract.dart';
import 'brain.dart';

/// Everything the assistant knows about its person, fed into the brain's
/// context on every conversation. All fields are optional; an empty context
/// still produces a working persona.
class ConversationContext {
  /// What the assistant calls the user ("call me sam" → "Sam").
  final String? userName;

  /// What the user calls the assistant (default "Nexus").
  final String assistantName;

  /// Things the user told the assistant about their world ("my wifi
  /// password is nexus"), plain text for the model to ground on.
  final List<String> facts;

  /// Phrases the user taught, mapped to the command they mean — the model
  /// should know what the user's own words do.
  final Map<String, String> learned;

  /// Remembered answers to "which …?" questions ("timer length → 5 minutes").
  final Map<String, dynamic> defaults;

  /// The phrases this user asks most, mined from the ask log.
  final List<String> habits;

  /// The skills this user reaches for most (labels, most used first) — so
  /// the model knows what matters to them.
  final List<String> skills;

  const ConversationContext({
    this.userName,
    this.assistantName = 'Nexus',
    this.facts = const [],
    this.learned = const {},
    this.defaults = const {},
    this.habits = const [],
    this.skills = const [],
  });
}

/// Who Nexus is when it talks, plus what it knows about its person. Kept
/// here (not in the view) so the persona and the memory block are one place.
/// The memory block is bounded on purpose — a few of each kind, so the
/// prompt stays small and the model keeps its head in the conversation.
String buildSystemPrompt(ConversationContext context) {
  final user = context.userName ?? 'the user';
  final memory = <String>[
    for (final fact in context.facts.take(10)) fact,
    if (context.learned.isNotEmpty)
      'Commands $user has taught: '
          '${context.learned.entries.take(8).map((e) => '"${e.key}" means "${e.value}"').join('; ')}.',
    if (context.defaults.isNotEmpty)
      'Remembered preferences: '
          '${context.defaults.entries.take(5).map((e) => '${e.key} -> ${e.value}').join('; ')}.',
    if (context.habits.isNotEmpty)
      'Things $user asks about often: ${context.habits.take(5).join(', ')}.',
    if (context.skills.isNotEmpty)
      'Skills $user reaches for most: ${context.skills.take(5).join(', ')}.',
  ];
  return [
    'You are ${context.assistantName}, a personal assistant that lives on '
        '$user\'s own devices — a local-first helper with no cloud account and '
        'no internet connection. Everything you know comes from this '
        'conversation.',
    if (memory.isNotEmpty)
      'What you know about $user (private, local to their devices): '
          '${memory.join(' ')}',
    'Talk like a helpful friend: warm, concise, and natural. Keep answers '
        'short unless the question genuinely needs detail.',
    'You have no live internet access and no knowledge of current events — '
        'say so honestly instead of inventing facts.',
    '${context.assistantName} can also DO things for $user through real '
        'commands: reminders, timers, notes, web search, opening apps, '
        'weather, calculator, and controlling paired devices. If $user asks '
        'for an action, tell them to just ask directly (for example: "set a '
        'timer for 5 minutes" or "add milk to my shopping list") — never '
        'pretend you performed an action.',
  ].join('\n');
}

/// Builds the bounded conversation history for the brain from the assistant
/// thread. User bubbles become user turns; plain assistant messages become
/// assistant turns. Everything else — action plans, clarifications, device
/// lists, live widgets — is UI internals the model must never see and is
/// filtered out here. [placeholderTexts] skips transient placeholders (a
/// peer's "Thinking…" card is not a real assistant turn). The window is
/// bounded to [maxTurns] (~10 exchanges by default), and the current input
/// is always the final turn.
List<ChatTurn> buildChatHistory(
  List<({String? userText, AgentDispatch? dispatch})> entries, {
  required String input,
  int maxTurns = 20,
  Set<String> placeholderTexts = const {},
}) {
  final turns = <ChatTurn>[];
  for (final entry in entries) {
    if (entry.userText case final String user) {
      turns.add((role: 'user', content: user));
    } else if (entry.dispatch case final AgentMessage message
        when !placeholderTexts.contains(message.text)) {
      turns.add((role: 'assistant', content: message.text));
    }
  }
  if (turns.length > maxTurns) {
    turns.removeRange(0, turns.length - maxTurns);
  }
  // The current input is the final turn — added even when the thread ends
  // elsewhere, so the brain always sees it.
  if (turns.isEmpty || turns.last.content != input) {
    turns.add((role: 'user', content: input));
  }
  return turns;
}