// The conversation engine, unit-tested without a widget tree: thread
// ownership, pending-question state, the ticket-sequenced brain exchange,
// and brain health. Widget tests still prove the real surface; these pin
// the state machine itself.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent_contract.dart';
import 'package:nexus/core/brain.dart';
import 'package:nexus/core/conversation.dart';
import 'package:nexus/core/conversation_engine.dart';

const _teachResult = AgentDispatchResult(
  status: AgentResultStatus.needsInfo,
  dispatch: AgentClarification(
    question: 'I don\'t understand "x" yet.',
    key: 'teach:x',
    hint: 'Teach me what it should mean.',
  ),
);

AgentDispatchResult _message(String text) => AgentDispatchResult(
  status: AgentResultStatus.succeeded,
  dispatch: AgentMessage(text),
);

/// A brain that answers instantly (or with a null/empty reply) and records
/// what it was given. Mirrors [LocalBrain]: an unreachable server has no
/// discoverable model either, so [availableModel] reports null and the probe
/// marks the engine offline.
class _FakeBrain extends LocalBrain {
  _FakeBrain({this.replyText = 'hi'});

  String? replyText;
  bool reachable = true;
  String? lastSystem;
  List<ChatTurn>? lastHistory;
  int replyCalls = 0;

  @override
  Future<String?> availableModel({bool refresh = false}) async =>
      reachable ? 'llama3.2:3b' : null;

  @override
  Future<BrainReply> reply({
    required String system,
    required List<ChatTurn> history,
    double temperature = 0.7,
    int maxTokens = 300,
  }) {
    replyCalls++;
    lastSystem = system;
    lastHistory = history;
    return Future.value((text: replyText, reachable: reachable));
  }
}

/// A brain whose replies the test releases by hand, in order.
class _GatedBrain extends LocalBrain {
  final List<Completer<BrainReply>> gates = [];

  @override
  Future<String?> availableModel({bool refresh = false}) async => 'llama3.2:3b';

  @override
  Future<BrainReply> reply({
    required String system,
    required List<ChatTurn> history,
    double temperature = 0.7,
    int maxTokens = 300,
  }) {
    final gate = Completer<BrainReply>();
    gates.add(gate);
    return gate.future;
  }
}

void main() {
  group('thread ownership', () {
    test('a result with a clarification opens the pending question', () {
      final engine = ConversationEngine();
      engine.appendResult(_teachResult, asUser: 'x');
      expect(engine.entries, hasLength(2));
      expect(engine.entries.first.userText, 'x');
      expect(engine.entries.last.result, same(_teachResult));
      expect(engine.pendingKey, 'teach:x');
    });

    test('a plain message closes any pending question', () {
      final engine = ConversationEngine();
      engine.appendResult(_teachResult, asUser: 'x');
      engine.appendResult(_message('ok'), replaceLast: true);
      expect(engine.pendingKey, isNull);
      expect(engine.lastResult!.dispatch, isA<AgentMessage>());
    });

    test('replaceLast rewrites the tail; replaceEntry rewrites its own card',
        () {
      final engine = ConversationEngine();
      engine.appendResult(_message('a'));
      final first = engine.entries.last;
      engine.appendResult(_message('b'));
      final second = engine.entries.last;
      engine.appendResult(_message('c'));

      engine.replaceEntry(first, _message('a2'));
      engine.replaceEntry(second, _message('b2'));
      engine.appendResult(_message('c2'), replaceLast: true);

      final texts = [
        for (final e in engine.entries)
          (e.result!.dispatch as AgentMessage).text,
      ];
      expect(texts, ['a2', 'b2', 'c2']);
    });

    test('a superseded card resolving cannot steal the tail\'s pending state',
        () {
      final engine = ConversationEngine();
      // Exchange A: teach card (pending).
      engine.appendResult(_teachResult, asUser: 'a');
      final aCard = engine.entries.last;
      // Exchange B: a fresh teach card supersedes.
      engine.appendResult(_teachResult, asUser: 'b');
      expect(engine.pendingKey, 'teach:x');
      // A resolves later into a plain message — the tail still owns the
      // question.
      engine.replaceEntry(aCard, _message('a answered'));
      expect(engine.pendingKey, 'teach:x');
      expect(
        engine.entries.last.result!.dispatch,
        isA<AgentClarification>(),
      );
    });

    test('replacing an entry that is no longer there is a no-op', () {
      final engine = ConversationEngine();
      final ghost = ConversationEntry.result(_message('gone'));
      engine.appendResult(_message('here'));
      engine.replaceEntry(ghost, _message('nope'));
      expect(engine.entries, hasLength(1));
    });
  });

  group('brain health', () {
    test('probe discovers the model and health', () async {
      final engine = ConversationEngine();
      await engine.probe(_FakeBrain());
      expect(engine.brainHealth, BrainHealth.online);
      expect(engine.brainModel, 'llama3.2:3b');
    });

    test('a probing engine is not offline, so conversation still tries', () async {
      final brain = _FakeBrain();
      final engine = ConversationEngine();
      // The view probes at startup; until that resolves the engine is still
      // "probing" — which must not block a conversation the user already
      // typed, and a reachable reply must not be misreported as an outage.
      await engine.converse(
        brain: brain,
        input: 'x',
        original: _teachResult,
        context: () => const ConversationContext(),
      );
      expect(brain.replyCalls, 1);
      expect(engine.brainHealth, isNot(BrainHealth.offline));
    });
  });

  group('the brain exchange', () {
    test('success swaps the teach card for the reply and reports the key',
        () async {
      final brain = _FakeBrain(replyText: 'cheer up!');
      final engine = ConversationEngine();
      await engine.probe(brain);
      engine.appendResult(_teachResult, asUser: 'i had a rough day');

      String? answered;
      await engine.converse(
        brain: brain,
        input: 'i had a rough day',
        original: _teachResult,
        context: () => const ConversationContext(),
        onBrainAnswered: (key) => answered = key,
      );

      expect(answered, 'teach:x');
      final tail = engine.entries.last;
      expect((tail.result!.dispatch as AgentMessage).text, 'cheer up!');
      expect(tail.teachKey, 'teach:x'); // the teach loop stays one tap away
      expect(engine.pendingKey, isNull);
    });

    test('an unreachable brain restores the teach card and flips offline',
        () async {
      final brain = _FakeBrain()..replyText = null..reachable = false;
      final engine = ConversationEngine();
      await engine.probe(brain);
      engine.appendResult(_teachResult, asUser: 'x');

      await engine.converse(
        brain: brain,
        input: 'x',
        original: _teachResult,
        context: () => const ConversationContext(),
      );

      expect(engine.entries.last.result, same(_teachResult));
      expect(engine.pendingKey, 'teach:x');
      expect(engine.brainHealth, BrainHealth.offline);
    });

    test('a stale exchange\'s failure cannot flip health for a newer one',
        () async {
      final brain = _GatedBrain();
      final engine = ConversationEngine();
      await engine.probe(brain);

      engine.appendResult(_teachResult, asUser: 'a');
      final a = engine.converse(
        brain: brain,
        input: 'a',
        original: _teachResult,
        context: () => const ConversationContext(),
      );
      engine.appendResult(_teachResult, asUser: 'b');
      final b = engine.converse(
        brain: brain,
        input: 'b',
        original: _teachResult,
        context: () => const ConversationContext(),
      );
      expect(brain.gates, hasLength(2));

      // B (the latest) resolves fine first.
      brain.gates[1].complete((text: 'fine', reachable: true));
      await b;
      expect(engine.brainHealth, BrainHealth.online);
      // A fails unreachable afterwards — it is stale, so health must stay
      // exactly as the newer exchange left it.
      brain.gates[0].complete((text: null, reachable: false));
      await a;
      expect(engine.brainHealth, BrainHealth.online);
      // And B's reply still owns the tail.
      expect(
        (engine.entries.last.result!.dispatch as AgentMessage).text,
        'fine',
      );
    });

    test('an empty but reachable reply restores the card and stays online',
        () async {
      final brain = _FakeBrain()..replyText = null..reachable = true;
      final engine = ConversationEngine();
      await engine.probe(brain);
      engine.appendResult(_teachResult, asUser: 'x');

      await engine.converse(
        brain: brain,
        input: 'x',
        original: _teachResult,
        context: () => const ConversationContext(),
      );

      expect(engine.entries.last.result, same(_teachResult));
      expect(engine.brainHealth, BrainHealth.online);
    });

    test('conversation is skipped when the brain is proven offline', () async {
      final brain = _FakeBrain()..replyText = null..reachable = false;
      final engine = ConversationEngine();
      await engine.probe(brain); // offline
      engine.appendResult(_teachResult, asUser: 'x');

      await engine.converse(
        brain: brain,
        input: 'x',
        original: _teachResult,
        context: () => const ConversationContext(),
      );

      // No Thinking card ever appeared; the teach card stands untouched.
      expect(brain.replyCalls, 0);
      expect(engine.entries.last.result, same(_teachResult));
    });

    test('a peer\'s Thinking card never reaches the next exchange\'s history',
        () async {
      final brain = _FakeBrain();
      final engine = ConversationEngine();
      await engine.probe(brain);
      engine.appendResult(_teachResult, asUser: 'a');
      await engine.converse(
        brain: brain,
        input: 'a',
        original: _teachResult,
        context: () => const ConversationContext(),
      );
      // A second exchange while the first reply card is still visible.
      engine.appendResult(_teachResult, asUser: 'b');
      await engine.converse(
        brain: brain,
        input: 'b',
        original: _teachResult,
        context: () => const ConversationContext(),
      );
      // The first exchange is real context (user turn + its answer); the
      // transient Thinking card of a peer exchange is the only thing the
      // next brain must never see — its placeholder would read as Nexus
      // having already answered the pending question.
      final texts = [for (final t in brain.lastHistory!) t.content];
      expect(texts, ['a', 'hi', 'b']);
      expect(texts, isNot(contains('Thinking…')));
      expect(brain.lastHistory!.last.content, 'b');
    });

    test('a reply landing after dispose is safe', () async {
      final brain = _GatedBrain();
      final engine = ConversationEngine();
      await engine.probe(brain);
      engine.appendResult(_teachResult, asUser: 'x');
      final pending = engine.converse(
        brain: brain,
        input: 'x',
        original: _teachResult,
        context: () => const ConversationContext(),
      );
      expect(brain.gates, hasLength(1));
      engine.dispose();
      brain.gates[0].complete((text: 'late', reachable: true));
      await pending; // must not throw
    });
  });

  group('voice: spoken asks get speakable replies', () {
    test('a spoken ask marks the exchange; plain replies are speakable', () {
      final engine = ConversationEngine();
      engine.appendResult(_message('Sure!'), asUser: 'hi', spoken: true);
      expect(engine.lastAskSpoken, isTrue);
      expect(ConversationEngine.speakableText(engine.last!), 'Sure!');
    });

    test('a typed ask stays quiet', () {
      final engine = ConversationEngine();
      engine.appendResult(_message('Sure!'), asUser: 'hi');
      expect(engine.lastAskSpoken, isFalse);
      expect(ConversationEngine.speakableText(engine.last!), 'Sure!');
    });

    test('a spoken re-run (aloud yes/no) keeps the exchange voiced', () {
      final engine = ConversationEngine();
      engine.appendResult(_teachResult, asUser: 'hi'); // typed ask
      engine.appendResult(
        _message('Approved.'),
        replaceLast: true,
        spoken: true,
      );
      expect(engine.lastAskSpoken, isTrue);
    });

    test('a spoken attempt with nothing heard still counts as spoken', () {
      final engine = ConversationEngine();
      engine.appendResult(
        _message('I didn\'t catch that — could you say it again?'),
        spoken: true,
      );
      expect(engine.lastAskSpoken, isTrue);
      expect(
        ConversationEngine.speakableText(engine.last!),
        startsWith('I didn\'t catch'),
      );
    });

    test('UI cards are never speakable; plain answers are', () {
      // Action-attached message (its real outcome replaces it a moment
      // later) — silent.
      expect(
        ConversationEngine.speakableText(
          ConversationEntry.result(
            AgentDispatchResult(
              status: AgentResultStatus.succeeded,
              dispatch: const AgentMessage(
                'Calling mom…',
                action: AgentActions.callPlace,
              ),
            ),
          ),
        ),
        isNull,
      );
      // A clarification question, the Thinking placeholder, an empty
      // message, and a user bubble are all silent.
      expect(
        ConversationEngine.speakableText(ConversationEntry.result(_teachResult)),
        isNull,
      );
      expect(
        ConversationEngine.speakableText(
          ConversationEntry.result(_message(thinkingPlaceholder)),
        ),
        isNull,
      );
      expect(
        ConversationEngine.speakableText(ConversationEntry.result(_message(''))),
        isNull,
      );
      expect(
        ConversationEngine.speakableText(ConversationEntry.user('hi')),
        isNull,
      );
      expect(
        ConversationEngine.speakableText(ConversationEntry.result(_message('Hi!'))),
        'Hi!',
      );
    });

    test('a brain answer to a spoken ask is speakable', () async {
      final brain = _FakeBrain(replyText: 'cheer up!');
      final engine = ConversationEngine();
      await engine.probe(brain);
      engine.appendResult(_teachResult, asUser: 'x', spoken: true);
      await engine.converse(
        brain: brain,
        input: 'x',
        original: _teachResult,
        context: () => const ConversationContext(),
      );
      expect(engine.lastAskSpoken, isTrue);
      expect(ConversationEngine.speakableText(engine.last!), 'cheer up!');
    });

    test('a superseded reply keeps its spoken ask when it lands mid-thread', () async {
      final brain = _GatedBrain();
      final engine = ConversationEngine();
      await engine.probe(brain);
      // Two rapid spoken unknown phrases — each opens its own exchange.
      engine.appendResult(_teachResult, asUser: 'a', spoken: true);
      final pendingA = engine.converse(
        brain: brain,
        input: 'a',
        original: _teachResult,
        context: () => const ConversationContext(),
      );
      engine.appendResult(_teachResult, asUser: 'b', spoken: true);
      final pendingB = engine.converse(
        brain: brain,
        input: 'b',
        original: _teachResult,
        context: () => const ConversationContext(),
      );
      // B answers first, then A's slower reply lands mid-thread.
      brain.gates[1].complete((text: 'B!', reachable: true));
      await pendingB;
      expect(ConversationEngine.speakableText(engine.last!), 'B!');
      brain.gates[0].complete((text: 'A!', reachable: true));
      await pendingA;
      // A's answer is not the tail anymore, but it kept the spoken
      // attribution of the ask that produced it.
      final aAnswer = engine.entries.firstWhere(
        (e) => ConversationEngine.speakableText(e) == 'A!',
      );
      expect(aAnswer.spokenAsk, isTrue);
      expect(ConversationEngine.speakableText(engine.last!), 'B!');
    });

    test('a typed ask after a spoken one marks only its own exchange', () {
      final engine = ConversationEngine();
      engine.appendResult(_message('A?'), asUser: 'a', spoken: true);
      engine.appendResult(_message('B!'), asUser: 'b'); // typed
      final entries = engine.entries;
      expect(entries[1].spokenAsk, isTrue); // the spoken ask's answer
      expect(entries[3].spokenAsk, isFalse); // the typed ask's answer
    });
  });
}