import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent_contract.dart';
import 'package:nexus/core/command_interpreter.dart';
import 'package:nexus/core/command_service.dart';

void main() {
  const devices = [
    AgentDeviceSnapshot(
      id: 'esp32',
      name: 'Desk ESP32',
      online: true,
      capabilities: [DeviceCapability(AgentActions.ledBlink)],
    ),
    AgentDeviceSnapshot(id: 'phone', name: 'My Phone', online: true),
  ];
  final service = CommandService(devices: () => devices);

  test('lists the injected snapshots', () {
    final result = service.execute('show my devices');
    expect(result.status, AgentResultStatus.succeeded);
    expect((result.dispatch! as AgentDeviceList).devices, devices);
  });

  test('resolves exact ID and unique display name', () {
    for (final target in ['esp32', 'Desk ESP32']) {
      final result = service.execute(
        'blink the $target',
        approval: AgentApproval.approved,
        requestId: target,
      );
      expect(result.status, AgentResultStatus.succeeded, reason: target);
      final plan = (result.dispatch! as AgentActionPlan).request;
      expect(plan.target, 'esp32', reason: target);
      expect(
        plan.isAuthorized(
          DeviceCapabilities(
            deviceId: 'esp32',
            capabilities: [DeviceCapability(AgentActions.ledBlink)],
          ),
        ),
        isTrue,
        reason: target,
      );
    }
  });

  test('rejects ambiguous and missing names', () {
    final ambiguous = CommandService(
      devices: () => const [
        AgentDeviceSnapshot(id: 'a', name: 'Board', online: true),
        AgentDeviceSnapshot(id: 'b', name: 'Board', online: true),
      ],
    ).execute('blink the board', approval: AgentApproval.approved);
    expect(ambiguous.status, AgentResultStatus.unavailable);

    // Missing target stays unavailable even before any approval decision —
    // there must never be an approval prompt for a device that does not exist.
    for (final approval in [AgentApproval.approved, AgentApproval.required]) {
      final missing = service.execute('blink the unknown', approval: approval);
      expect(
        missing.status,
        AgentResultStatus.unavailable,
        reason: approval.name,
      );
      expect(missing.dispatch, isNull);
    }
  });

  test('requires and respects explicit local approval', () {
    for (final approval in [AgentApproval.required, AgentApproval.denied]) {
      final result = service.execute('blink the esp32', approval: approval);
      expect(
        result.status,
        approval == AgentApproval.required
            ? AgentResultStatus.required
            : AgentResultStatus.denied,
      );
      expect(result.dispatch, isNull);
    }
  });

  group('locally executable intents', () {
    test('greeting answers', () {
      final result = service.execute('hello');
      expect(result.status, AgentResultStatus.succeeded);
      expect((result.dispatch! as AgentMessage).text, contains('Hello'));
    });

    test('time and date answer locally', () {
      final time = service.execute('what time is it');
      expect(time.status, AgentResultStatus.succeeded);
      expect(
        (time.dispatch! as AgentMessage).text,
        matches(RegExp(r"It's \d{2}:\d{2}\.")),
      );

      final date = service.execute("what's the date");
      expect(date.status, AgentResultStatus.succeeded);
      expect(
        (date.dispatch! as AgentMessage).text,
        contains(DateTime.now().year.toString()),
      );
    });

    test('simple math computes locally', () {
      final result = service.execute('what is 2 plus 2');
      expect(result.status, AgentResultStatus.succeeded);
      expect((result.dispatch! as AgentMessage).text, '2+2 = 4');

      final bare = service.execute('10 / 2');
      expect(bare.status, AgentResultStatus.succeeded);
      expect((bare.dispatch! as AgentMessage).text, '10 / 2 = 5');
    });

    test('broken math is an honest unavailable', () {
      final result = service.execute('calculate 1 divided by 0');
      expect(result.status, AgentResultStatus.unavailable);
      expect(result.dispatch, isNull);
    });
  });

  group('clipboard.write', () {
    test('requires approval, then produces a typed plan', () {
      final pending = service.execute('copy hello to my phone');
      expect(pending.status, AgentResultStatus.required);
      expect(pending.dispatch, isNull);

      final approved = service.execute(
        'copy hello to my phone',
        approval: AgentApproval.approved,
        requestId: 'copy-1',
      );
      expect(approved.status, AgentResultStatus.succeeded);
      final plan = (approved.dispatch! as AgentActionPlan).request;
      expect(plan.action, AgentActions.clipboardWrite);
      expect(plan.target, 'local');
      expect(plan.arguments['text'], 'hello');
      expect(plan.requestId, 'copy-1');
    });

    test('denied and empty text never plan', () {
      final denied = service.execute(
        'copy hello',
        approval: AgentApproval.denied,
      );
      expect(denied.status, AgentResultStatus.denied);
      expect(denied.dispatch, isNull);

      final empty = service.execute(
        'copy to my phone',
        approval: AgentApproval.approved,
      );
      expect(empty.status, AgentResultStatus.unavailable);
      expect(empty.dispatch, isNull);
    });
  });

  group('the catalog always answers or teaches — nothing silent', () {
    test(
      'recognized commands dispatch their action so the executor stays honest',
      () {
        // Every recognized phrase yields a local message carrying the action
        // (the view/executor decides what this platform can really do). It
        // must never be a teach prompt or a silent unavailable.
        for (final phrase in [
          'call mom',
          'text john',
          'set an alarm for 7am',
          "what's the weather",
          'search for cats',
          'pause the music',
        ]) {
          final result = service.execute(phrase);
          expect(result.status, AgentResultStatus.succeeded, reason: phrase);
          final msg = result.dispatch! as AgentMessage;
          expect(msg.text, isNotEmpty, reason: phrase);
          expect(msg.action, isNotNull, reason: phrase);
        }
      },
    );

    test('unrecognized phrases ask to be taught — never fake a result', () {
      for (final phrase in ['navigate to the office', 'turn on the lights']) {
        final result = service.execute(phrase);
        expect(result.status, AgentResultStatus.needsInfo, reason: phrase);
        expect(
          (result.dispatch! as AgentClarification).key,
          startsWith('teach:'),
          reason: phrase,
        );
      }
    });
  });

  group('evaluateMath', () {
    test('evaluates the four operations with precedence and parens', () {
      expect(evaluateMath('2+2'), 4);
      expect(evaluateMath('2*3+4'), 10);
      expect(evaluateMath('10/2'), 5);
      expect(evaluateMath('(1+2)*3'), 9);
      expect(evaluateMath('10 - 3 - 2'), 5);
      expect(evaluateMath('2+2+2+2'), 8);
    });

    test('rejects invalid or unsafe input', () {
      expect(evaluateMath(''), isNull);
      expect(evaluateMath('1/0'), isNull);
      expect(evaluateMath('abc'), isNull);
      expect(evaluateMath('2+'), isNull);
      expect(evaluateMath('(2+2'), isNull);
    });
  });

  group('near-miss suggestions never act without confirmation', () {
    test('a typo of a known command is offered as "did you mean", not run', () {
      for (final phrase in [
        'tex mom saying hi',
        'what time is is',
        'what do you now about me',
      ]) {
        final result = service.execute(phrase);
        expect(result.status, AgentResultStatus.needsInfo, reason: phrase);
        final ask = result.dispatch! as AgentClarification;
        expect(ask.key, startsWith('near:'), reason: phrase);
        expect(ask.question, contains('Did you mean'), reason: phrase);
      }
    });

    test('every suggestion-catalog entry parses — a confirmed suggestion runs verbatim', () {
      const interpreter = CommandInterpreter();
      for (final phrase in CommandInterpreter.suggestionCatalog) {
        expect(
          interpreter.interpret(phrase).outcome,
          InterpretOutcome.matched,
          reason: phrase,
        );
      }
    });

    test('confirming a suggestion runs it and remembers the phrase', () {
      final first = service.execute('tex mom saying hi');
      final key = (first.dispatch! as AgentClarification).key;
      final confirmed = service.execute('yes', answerTo: key);
      expect(confirmed.status, AgentResultStatus.succeeded);
      expect(
        (confirmed.dispatch! as AgentMessage).action,
        AgentActions.messageSend,
      );

      // The phrase is remembered on this device…
      expect(service.learnedSnapshot, contains('tex mom saying hi'));
      // …and now runs directly, with no question at all.
      final direct = service.execute('tex mom saying hi');
      expect(direct.status, AgentResultStatus.succeeded);
    });

    test('correcting a bad suggestion falls into the normal teach loop', () {
      final first = service.execute('what time is is');
      final key = (first.dispatch! as AgentClarification).key;
      // Not a "yes" — the user answers with the real command instead.
      final taught = service.execute('show my devices', answerTo: key);
      expect(taught.status, AgentResultStatus.succeeded);
      expect(service.learnedSnapshot['what time is is'], 'show my devices');
    });

    test('phrases with no near match still go straight to the teach loop', () {
      for (final phrase in [
        'navigate to the office',
        'turn on the lights',
        'teleport me to mars',
      ]) {
        final result = service.execute(phrase);
        expect(result.status, AgentResultStatus.needsInfo, reason: phrase);
        expect(
          (result.dispatch! as AgentClarification).key,
          startsWith('teach:'),
          reason: phrase,
        );
      }
    });

    test(
      'a "yes" after a rejected suggestion runs the suggestion, not the typo',
      () {
        // Regression: re-answering a "did you mean" question with something
        // non-command must not clobber the stored suggestion — a later plain
        // "yes" has to run the suggested meaning, or it dead-ends by trying
        // to interpret the original typo again.
        // Fresh service: the shared one may already know "what time is is"
        // from an earlier test in this file.
        final isolated = CommandService(devices: () => devices);
        final first = isolated.execute('what time is is');
        final key = (first.dispatch! as AgentClarification).key;
        expect(key, startsWith('near:'));

        // Not a command → re-asks the same question.
        final reask = isolated.execute('no', answerTo: key);
        expect(reask.status, AgentResultStatus.needsInfo);
        expect((reask.dispatch! as AgentClarification).key, key);

        // Now "yes" → must run the suggested time answer.
        final yes = isolated.execute('yes', answerTo: key);
        expect(yes.status, AgentResultStatus.succeeded);
        expect(yes.dispatch, isA<AgentMessage>());
        expect(isolated.learnedSnapshot['what time is is'], 'what time is it');
      },
    );
  });

  group('fact memory: remember, recall, forget', () {
    test('"remember that …" stores a fact and says so', () {
      var changed = 0;
      final learnedFacts = <String>[];
      final facts = CommandService(
        devices: () => const [],
        onMemoryChanged: () => changed++,
        onFactLearned: learnedFacts.add,
      );
      final result = facts.execute('remember that my wifi password is nexus');
      expect(result.status, AgentResultStatus.succeeded);
      expect((result.dispatch! as AgentMessage).text, contains('Remembered'));
      expect(facts.factsSnapshot, ['my wifi password is nexus']);
      expect(learnedFacts, ['my wifi password is nexus']);
      expect(changed, 1);
    });

    test('duplicate facts (any casing) are answered, not stored twice', () {
      final facts = CommandService(devices: () => const []);
      facts.execute('remember that mom likes tea');
      final again = facts.execute('Remember that Mom likes tea');
      expect(again.status, AgentResultStatus.succeeded);
      expect((again.dispatch! as AgentMessage).text, contains('already'));
      expect(facts.factsSnapshot.length, 1);
    });

    test('"remember to …" is a reminder, never a fact', () {
      final facts = CommandService(devices: () => const []);
      final result = facts.execute('remember to buy milk');
      expect(result.status, AgentResultStatus.succeeded);
      expect(
        (result.dispatch! as AgentMessage).action,
        AgentActions.reminderSet,
      );
      expect(facts.factsSnapshot, isEmpty);
    });

    test('framing-word-only content is refused, never stored', () {
      // The interpreter's regex backtracks on a bare "remember that" into
      // capturing the framing word itself — the service must answer as if
      // nothing was said, and "forget that" must never delete facts that
      // merely contain the word.
      final facts = CommandService(devices: () => const []);
      for (final phrase in ['remember that', 'remember this', 'forget that']) {
        final result = facts.execute(phrase);
        expect(result.status, AgentResultStatus.unavailable, reason: phrase);
      }
      expect(facts.factsSnapshot, isEmpty);

      facts.execute('remember that my bike code is 4321');
      final forgetThat = facts.execute('forget that');
      expect(forgetThat.status, AgentResultStatus.unavailable);
      expect(facts.factsSnapshot, ['my bike code is 4321']);
    });

    test('"remember this: …" stores the content, not the colon form', () {
      final facts = CommandService(devices: () => const []);
      final result = facts.execute('remember this: mom prefers text');
      expect((result.dispatch! as AgentMessage).text, contains('Remembered'));
      expect(facts.factsSnapshot, ['mom prefers text']);
    });

    test(
      'personal questions are answered from memory, web fallback is honest',
      () {
        final facts = CommandService(devices: () => const []);
        facts.execute('remember that my wifi password is nexus4321');
        facts.execute('remember that mom is Martine 06 12 34 56 78');
        facts.execute('remember that the bike code is 4321');

        AgentMessage ask(String q) =>
            facts.execute(q).dispatch! as AgentMessage;

        // The three question forms hit memory, not the web.
        expect(ask('what is my wifi password').text, contains('nexus4321'));
        expect(ask("what is mom's number").text, contains('martine'));
        expect(ask('who is mom').text, contains('martine'));
        expect(ask('where is the bike code').text, contains('4321'));

        // Loose wording reaches the right fact.
        expect(
          ask('what do you know about internet').text,
          contains('wifi password'),
        );
        expect(ask('what do you know about family').text, contains('mom is'));

        // Nothing stored → honest web fallback, never a fake answer.
        final unknown = ask('what is the capital of france');
        expect(unknown.text, contains("don't know that yet"));
        expect(unknown.action, AgentActions.webSearch);
        expect(unknown.arguments, containsPair('query', isNotEmpty));

        // Non-personal and arithmetic paths untouched.
        expect(ask('what is 2 plus 2').text, contains('='));
        expect(
          facts.execute('search for cats').status,
          AgentResultStatus.succeeded,
        );
      },
    );

    test('recall answers empty, all, and by topic', () {
      final facts = CommandService(devices: () => const []);
      final none = facts.execute('what do you know about me');
      expect((none.dispatch! as AgentMessage).text, contains('yet'));

      facts.execute('remember that my bike code is 4321');
      facts.execute('remember that mom prefers text messages');
      final all = facts.execute('what do you know about me');
      final allText = (all.dispatch! as AgentMessage).text;
      expect(allText, contains('bike code'));
      expect(allText, contains('mom prefers'));

      final topic = facts.execute('what do you know about bike');
      final topicText = (topic.dispatch! as AgentMessage).text;
      expect(topicText, contains('bike code'));
      expect(topicText, isNot(contains('mom prefers')));
    });

    test('forget removes matching facts and reports count', () {
      final facts = CommandService(devices: () => const []);
      facts.execute('remember that my bike code is 4321');
      facts.execute('remember that my bike shop is on 5th');
      facts.execute('remember that mom prefers text messages');

      final gone = facts.execute('forget my bike');
      expect((gone.dispatch! as AgentMessage).text, contains('Forgotten 2'));
      expect(facts.factsSnapshot, ['mom prefers text messages']);

      final unknown = facts.execute('forget the moon');
      expect(
        (unknown.dispatch! as AgentMessage).text,
        contains('don\'t remember anything like'),
      );
    });

    test('facts survive a restart via AgentMemory', () {
      final first = CommandService(devices: () => const []);
      first.execute('remember that my bike code is 4321');

      // "Restart": a fresh service rebuilt from the persisted snapshot.
      final second = CommandService(
        devices: () => const [],
        memory: AgentMemory(facts: first.factsSnapshot),
      );
      final recall = second.execute('what do you know about me');
      expect((recall.dispatch! as AgentMessage).text, contains('bike code'));
    });

    test('adoptFact persists without re-broadcasting', () {
      var learned = 0;
      var changed = 0;
      final facts = CommandService(
        devices: () => const [],
        onFactLearned: (_) => learned++,
        onMemoryChanged: () => changed++,
      );
      facts.adoptFact('shared from my phone');
      facts.adoptFact('shared from my phone'); // duplicate — dropped
      facts.adoptFact('   '); // empty — dropped
      expect(facts.factsSnapshot, ['shared from my phone']);
      expect(learned, 0); // never re-broadcast a mesh-adopted fact
      expect(changed, 1);
    });
  });
}
