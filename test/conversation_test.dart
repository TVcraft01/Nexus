// The shared-memory seam: persona with memory injection and the bounded
// history projection — pure Dart, no view, mesh, or network.
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent_contract.dart';
import 'package:nexus/core/conversation.dart';

void main() {
  group('buildSystemPrompt', () {
    test('carries the persona, names, and honesty rules', () {
      final prompt = buildSystemPrompt(
        const ConversationContext(userName: 'Sam'),
      );
      expect(prompt, contains('Nexus'));
      expect(prompt, contains('Sam'));
      expect(prompt, contains('no internet'));
      expect(prompt, contains('never pretend'));
    });

    test('injects facts, taught phrases, defaults, and habits', () {
      final prompt = buildSystemPrompt(
        const ConversationContext(
          userName: 'Sam',
          facts: ['my favorite color is teal'],
          learned: {'bring me home': 'show my devices'},
          defaults: {'timer.set.seconds': '5 minutes'},
          habits: ['call mom', 'what time is it'],
        ),
      );
      expect(prompt, contains('my favorite color is teal'));
      expect(prompt, contains('"bring me home" means "show my devices"'));
      expect(prompt, contains('timer.set.seconds -> 5 minutes'));
      expect(prompt, contains('call mom'));
    });

    test('reflects the skills the user reaches for most', () {
      final prompt = buildSystemPrompt(
        const ConversationContext(userName: 'Sam', skills: ['Timers', 'Calls']),
      );
      expect(prompt, contains('Skills Sam reaches for most: Timers, Calls'));
      expect(prompt, isNot(contains('Skills Sam reaches for most: Calls, Timers')));
    });

    test('bounds the memory block', () {
      final prompt = buildSystemPrompt(
        ConversationContext(facts: [for (var i = 0; i < 25; i++) 'fact $i']),
      );
      expect(prompt, contains('fact 0'));
      expect(prompt, contains('fact 9'));
      expect(prompt, isNot(contains('fact 10')));
    });

    test('an empty memory still yields a working persona', () {
      final prompt = buildSystemPrompt(const ConversationContext());
      expect(prompt, contains('Nexus'));
      expect(prompt, isNot(contains('What you know about')));
    });
  });

  group('buildChatHistory', () {
    test('projects user bubbles and messages, in order', () {
      final turns = buildChatHistory(
        [
          (userText: 'hi', dispatch: null),
          (userText: null, dispatch: const AgentMessage('hello!')),
          (userText: 'how are you', dispatch: null),
        ],
        input: 'how are you',
      );
      expect([for (final t in turns) t.role], ['user', 'assistant', 'user']);
      expect(turns.first.content, 'hi');
      expect(turns[1].content, 'hello!');
      // The input equals the last user bubble — it is not duplicated.
      expect(turns, hasLength(3));
      expect(turns.last.content, 'how are you');
    });

    test('filters plans, clarifications, and placeholders', () {
      final turns = buildChatHistory(
        [
          (userText: 'call mom', dispatch: null),
          (
            userText: null,
            dispatch: const AgentActionPlan(
              AgentRequest(
                requestId: 'r',
                target: 'phone',
                action: AgentActions.callPlace,
              ),
            ),
          ),
          (userText: 'is that ok', dispatch: null),
          (
            userText: null,
            dispatch: const AgentClarification(
              key: 'teach:x',
              question: 'I don\'t understand "x" yet.',
            ),
          ),
          (userText: null, dispatch: const AgentMessage('Thinking…')),
        ],
        input: 'is that ok',
        placeholderTexts: {'Thinking…'},
      );
      expect([for (final t in turns) t.content], ['call mom', 'is that ok']);
    });

    test('bounds the window and always ends with the input', () {
      final entries = <({String? userText, AgentDispatch? dispatch})>[
        for (var i = 0; i < 30; i++)
          i.isEven
              ? (userText: 'u$i', dispatch: null)
              : (userText: null, dispatch: AgentMessage('m$i')),
      ];
      final turns = buildChatHistory(entries, input: 'u29');
      // 30 turns trimmed to the last 20; the last window turn is an
      // assistant message, so the input is appended as the final user turn.
      expect(turns, hasLength(21));
      expect(turns.first.content, 'u10');
      expect(turns.last.content, 'u29');
      expect(turns.last.role, 'user');
    });

    test('a lone placeholder collapses to just the input', () {
      final turns = buildChatHistory(
        [
          (userText: 'my day was awful', dispatch: null),
          (userText: null, dispatch: const AgentMessage('Thinking…')),
        ],
        input: 'my day was awful',
        placeholderTexts: {'Thinking…'},
      );
      expect(turns, hasLength(1));
      expect(turns.single.content, 'my day was awful');
    });
  });
}