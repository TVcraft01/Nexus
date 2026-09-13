// Provenance: where Nexus's memory came from, proven the only way it can be —
// by using it. The tests below drive the real store, the real service and the
// real answers, and they check the three things the brief asks for: an entry
// cannot exist without an origin, memory written before origins existed
// migrates without losing anything, and "what do you know about me" /
// "why do you know that" are answered from the stored origin and source
// rather than from a canned sentence.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/agent_contract.dart';
import 'package:nexus/core/command_interpreter.dart';
import 'package:nexus/core/command_service.dart';
import 'package:nexus/core/memory.dart';
import 'package:nexus/core/store.dart';

/// A service on a named device, so the provenance of anything told to it here
/// has a source the test can check.
CommandService _service({
  String device = 'Test Desk',
  AgentMemory memory = const AgentMemory(),
  List<AgentDeviceSnapshot> devices = const [],
}) => CommandService(
  devices: () => devices,
  memory: memory,
  local: AgentDeviceSnapshot(id: 'd1', name: device, online: true),
);

String _said(AgentDispatchResult result) =>
    ((result.dispatch! as AgentMessage).text);

void main() {
  group('the model refuses a fact that has no origin', () {
    test('a stamp cannot be built without an origin and a source', () {
      expect(
        () => MemoryStamp(
          origin: MemoryOrigin.explicit,
          source: '   ',
          learnedAt: DateTime(2026, 9, 13),
        ),
        throwsArgumentError,
      );
      // A new entry must carry when it was learned; only migration may have
      // no time, and that is what legacy is for.
      expect(
        () => MemoryStamp(
          origin: MemoryOrigin.device,
          source: 'My Phone',
          learnedAt: null,
        ),
        throwsArgumentError,
      );
    });

    test('an inference cannot be recorded without what it came from', () {
      expect(
        () => MemoryStamp(
          origin: MemoryOrigin.inferred,
          source: 'repeated behaviour',
          learnedAt: DateTime(2026, 9, 13),
        ),
        throwsArgumentError,
      );
    });

    test('a fact needs text and a stamp', () {
      expect(
        () => MemoryFact('', MemoryStamp.legacy()),
        throwsArgumentError,
      );
      expect(
        () => MemoryFact(
          'my bike code is 4321',
          MemoryStamp(
            origin: MemoryOrigin.inferred,
            source: 'your habits',
            learnedAt: DateTime(2026, 9, 13),
            inferredFrom: 'you asked three times',
          ),
        ),
        returnsNormally,
      );
    });

    test('decoding refuses an entry that does not say where it came from', () {
      // No stamp at all.
      expect(
        () => MemoryFact.fromJson({'text': 'my bike code is 4321'}),
        throwsFormatException,
      );
      // A stamp with no origin.
      expect(
        () => MemoryStamp.fromJson({'source': 'you'}),
        throwsFormatException,
      );
      // A stamp with no source.
      expect(
        () => MemoryStamp.fromJson({'origin': 'explicit'}),
        throwsFormatException,
      );
      // An origin this version does not know — reading it as something else
      // would be inventing provenance.
      expect(
        () => MemoryStamp.fromJson({
          'origin': 'telepathy',
          'source': 'you',
        }),
        throwsFormatException,
      );
    });

    test('the one format with no provenance reads as legacy, not as a guess',
        () {
      final migrated = MemoryFact.fromJson('my wifi password is nexus');
      expect(migrated.text, 'my wifi password is nexus');
      expect(migrated.stamp.origin, MemoryOrigin.legacy);
      expect(migrated.stamp.learnedAt, isNull);
      expect(migrated.sentence, contains('stored before I kept sources'));
      expect(migrated.sentence, contains('don\'t know where it came from'));
      expect(migrated.sentence, isNot(contains('you told me')));
    });
  });

  group('memory written before origins existed migrates whole', () {
    late Directory tmp;
    late String path;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('nexus_provenance');
      path = '${tmp.path}/state.json';
      // The exact shape an older Nexus wrote: facts as bare strings, taught
      // phrases and remembered preferences as value maps with no provenance.
      await File(path).writeAsString(
        jsonEncode({
          'agent': {
            'facts': [
              'my wifi password is nexus',
              'mom prefers text messages',
            ],
            'learned': {'bring me home': 'show my devices'},
            'defaults': {'media.play.playlist': 'Chill Mix'},
          },
        }),
      );
    });

    tearDown(() async => tmp.delete(recursive: true));

    test('nothing is lost, and every entry gets an honest origin', () async {
      final store = NexusStore(explicitPath: path);
      await store.load();

      expect(
        [for (final fact in store.agentFacts) fact.text],
        ['my wifi password is nexus', 'mom prefers text messages'],
      );
      for (final fact in store.agentFacts) {
        expect(fact.stamp.origin, MemoryOrigin.legacy);
        expect(fact.stamp.source.trim(), isNotEmpty);
      }

      // The value maps are untouched.
      expect(store.agentLearned, {'bring me home': 'show my devices'});
      expect(store.agentDefaults, {'media.play.playlist': 'Chill Mix'});

      // And their provenance is filled in for every entry rather than absent.
      final ledger = store.agentLedger;
      expect(ledger.knows(MemoryLedgerKind.phrase, 'bring me home'), isTrue);
      expect(
        ledger.knows(MemoryLedgerKind.preference, 'media.play.playlist'),
        isTrue,
      );
      expect(
        ledger.stampFor(MemoryLedgerKind.phrase, 'bring me home').origin,
        MemoryOrigin.legacy,
      );
    });

    test('the migrated store round-trips without changing', () async {
      final store = NexusStore(explicitPath: path);
      await store.load();
      store.agentFacts = store.agentFacts;
      store.agentLedger = store.agentLedger;
      await store.save();

      final reloaded = NexusStore(explicitPath: path);
      await reloaded.load();
      expect(
        [for (final fact in reloaded.agentFacts) fact.text],
        ['my wifi password is nexus', 'mom prefers text messages'],
      );
      expect(
        reloaded.agentFacts.every((f) => f.stamp.origin == MemoryOrigin.legacy),
        isTrue,
      );
      expect(reloaded.agentLearned, {'bring me home': 'show my devices'});
    });
  });

  group('every learning point records where it came from', () {
    test('what the user tells this device', () async {
      final service = _service();
      service.execute('remember that my bike code is 4321');
      final fact = service.memoryFacts.single;
      expect(fact.stamp.origin, MemoryOrigin.explicit);
      expect(fact.stamp.source, 'Test Desk');
      expect(fact.stamp.learnedAt, isNotNull);
      expect(fact.stamp.lastUsedAt, isNull);
    });

    test('what a paired device sends', () async {
      final service = _service();
      service.adoptFact('my keys are in the hall', from: "TVcraft's phone");
      final fact = service.memoryFacts.single;
      expect(fact.stamp.origin, MemoryOrigin.device);
      expect(fact.stamp.source, "TVcraft's phone");
    });

    test('a device that cannot be named still gets a real origin', () {
      final service = _service();
      service.adoptFact('my keys are in the hall');
      expect(service.memoryFacts.single.stamp.origin, MemoryOrigin.device);
      expect(service.memoryFacts.single.stamp.source, 'a paired device');
    });

    test('a rule of Nexus\'s own says so', () async {
      final service = _service();
      // The alias is created by Nexus, off an answer the user confirmed.
      service.learnContactAlias('alx', 'Alex');
      final fact = service.memoryFacts.single;
      expect(fact.stamp.origin, MemoryOrigin.system);
      expect(fact.stamp.source, 'you confirmed "alx" meant "Alex"');
      expect(fact.sentence, contains('I created this when'));
    });

    test('a taught phrase and a remembered preference carry theirs', () {
      final service = _service();
      // Teach a phrase through the real teach flow: an unknown phrase asks,
      // and the answer it is given teaches it.
      final asked = service.execute('florble the wibble');
      final key = (asked.dispatch! as AgentClarification).key;
      service.execute('show my devices', answerTo: key);
      expect(
        service.provenanceOf(MemoryLedgerKind.phrase, 'florble the wibble').origin,
        MemoryOrigin.explicit,
      );
      expect(
        service.provenanceOf(MemoryLedgerKind.phrase, 'florble the wibble').source,
        'Test Desk',
      );

      // Answer a "which …?" question, which remembers a preference.
      final timer = service.execute('set a timer');
      if (timer.dispatch is AgentClarification) {
        service.execute(
          '5 minutes',
          answerTo: (timer.dispatch! as AgentClarification).key,
        );
      }
      expect(
        service.provenanceOf(MemoryLedgerKind.preference, 'timer.set.seconds')
            .origin,
        MemoryOrigin.explicit,
      );
    });

    test('a phrase and a preference from a peer say so', () {
      final service = _service();
      service.adoptLearned('bring me home', 'show my devices', from: 'My PC');
      service.adoptDefault('media.play.playlist', 'Chill Mix', from: 'My PC');
      expect(
        service.provenanceOf(MemoryLedgerKind.phrase, 'bring me home').origin,
        MemoryOrigin.device,
      );
      expect(
        service.provenanceOf(MemoryLedgerKind.phrase, 'bring me home').source,
        'My PC',
      );
      expect(
        service
            .provenanceOf(MemoryLedgerKind.preference, 'media.play.playlist')
            .origin,
        MemoryOrigin.device,
      );
    });

    test('an entry nobody recorded says so instead of nothing', () {
      final service = _service();
      final stamp = service.provenanceOf(
        MemoryLedgerKind.preference,
        'something.never.learned',
      );
      expect(stamp.origin, MemoryOrigin.legacy);
      expect(stamp.source.trim(), isNotEmpty);
    });
  });

  group('no inference exists, and none is presented as certainty', () {
    test('nothing Nexus does produces an inferred entry', () {
      final service = _service();
      service.execute('remember that my bike code is 4321');
      service.learnContactAlias('alx', 'Alex');
      service.adoptFact('my keys are in the hall', from: 'My Phone');
      service.adoptLearned('bring me home', 'show my devices', from: 'My PC');
      service.adoptDefault('media.play.playlist', 'Chill Mix', from: 'My PC');
      final asked = service.execute('teach me "open deezer"');
      service.execute(
        'open youtube',
        answerTo: (asked.dispatch! as AgentClarification).key,
      );

      for (final fact in service.memoryFacts) {
        expect(fact.stamp.origin, isNot(MemoryOrigin.inferred));
      }
      for (final entry in service.ledgerSnapshot.toJson()) {
        expect(entry['origin'], isNot('inferred'));
      }
    });

    test('the wording for an inference admits it is one', () {
      final inferred = MemoryStamp(
        origin: MemoryOrigin.inferred,
        source: 'you ask for it every morning',
        learnedAt: DateTime(2026, 9, 13),
        inferredFrom: 'four mornings in a row',
      );
      expect(inferred.origin.sentence('you ask for it every morning'),
          contains('I inferred this'));
      for (final origin in MemoryOrigin.values) {
        expect(
          origin.label,
          isNot(anyOf('certain', 'a fact')),
          reason: origin.name,
        );
      }
    });
  });

  group('"what do you know about me" answers from the stored origin', () {
    test('nothing stored says so plainly', () {
      final service = _service();
      expect(
        _said(service.execute('what do you know about me')),
        contains('don\'t remember anything about you yet'),
      );
    });

    test('each fact is labelled with where it came from', () {
      final service = _service();
      service.execute('remember that my bike code is 4321');
      service.adoptFact('my keys are in the hall', from: "TVcraft's phone");
      service.learnContactAlias('alx', 'Alex');

      final text = _said(service.execute('what do you know about me'));
      expect(text, contains('my bike code is 4321'));
      expect(text, contains('you told me this on Test Desk'));
      expect(text, contains('my keys are in the hall'));
      expect(text, contains("this came from TVcraft's phone"));
      expect(text, contains('alx means Alex'));
      expect(text, contains('I created this when you confirmed'));
    });

    test('a one-hit question still answers with the fact itself', () {
      final service = _service();
      service.execute('remember that my wifi password is nexus');
      // The password is the answer; the provenance is not what was asked for.
      expect(_said(service.execute('what is my wifi password')), 'my wifi password is nexus');
    });
  });

  group('"why do you know that" is powered by the stamp', () {
    test('the question is understood', () {
      for (final phrasing in const [
        'why do you know about my bike code',
        'why do you know that',
        'how do you know about my bike code',
        'where did you learn about my bike code',
      ]) {
        final result = const CommandInterpreter().interpret(phrasing);
        expect(result.outcome, InterpretOutcome.matched, reason: phrasing);
        expect(result.command!.action, AgentActions.memoryQuestion);
        expect(result.command!.arguments['kind'], 'provenance');
      }
      expect(
        const CommandInterpreter()
            .interpret('why do you know about my bike code')
            .command!
            .arguments['topic'],
        'bike code',
      );
    });

    test('it names the origin, the source and when it was learned', () {
      final service = _service();
      service.execute('remember that my bike code is 4321');
      final text = _said(service.execute('why do you know about my bike code'));
      expect(text, contains('"my bike code is 4321"'));
      expect(text, contains('you told me this on Test Desk'));
      expect(text, contains('I learned it today'));
      expect(text, isNot(contains('I have always known')));
    });

    test('a device-sent fact is attributed to the device, not the user', () {
      final service = _service();
      service.adoptFact('my keys are in the hall', from: "TVcraft's phone");
      final text = _said(service.execute('why do you know about my keys'));
      expect(text, contains("this came from TVcraft's phone"));
      expect(text, isNot(contains('you told me')));
    });

    test('a migrated fact admits it does not know', () {
      final service = _service(
        memory: AgentMemory(
          facts: [
            MemoryFact('my old note is 7', MemoryStamp.legacy()),
          ],
        ),
      );
      final text = _said(service.execute('why do you know about my old note'));
      expect(text, contains('don\'t know where it came from'));
      expect(text, isNot(contains('you told me')));
      expect(text, isNot(contains('I learned it')));
    });

    test('nothing known says so instead of searching for an answer', () {
      final service = _service();
      final result = service.execute('why do you know about my bike code');
      final text = _said(result);
      expect(text, contains('I don\'t know anything about "bike code"'));
      expect(text, contains('nothing to explain'));
      // A question about Nexus's own memory has no web answer.
      expect((result.dispatch! as AgentMessage).action, isNull);
    });

    test('asked without a topic, it asks which', () {
      final service = _service();
      final result = service.execute('why do you know that');
      // "that" is not a topic: the answer asks what to explain rather than
      // searching memory for a word the user never meant as one.
      expect(result.status, AgentResultStatus.needsInfo);
      expect(result.message, contains('why do you know about'));
    });
  });

  group('using a fact is recorded, at most once a day', () {
    test('a recall marks the facts it used', () {
      final service = _service();
      service.execute('remember that my bike code is 4321');
      expect(service.memoryFacts.single.stamp.lastUsedAt, isNull);

      service.execute('what do you know about bike');
      final used = service.memoryFacts.single.stamp.lastUsedAt;
      expect(used, isNotNull);
      // And the why-answer shows it, because that is what "currently used"
      // means — the user can see whether a fact is still earning its place.
      expect(
        _said(service.execute('why do you know about my bike code')),
        contains('Last used today'),
      );
    });

    test('a second question the same day does not rewrite the stamp', () {
      final service = _service();
      service.execute('remember that my bike code is 4321');
      service.execute('what do you know about bike');
      final first = service.memoryFacts.single;
      service.execute('what do you know about bike');
      final second = service.memoryFacts.single;
      expect(second.stamp.lastUsedAt, first.stamp.lastUsedAt);
    });

    test('the day boundary is what moves it', () {
      final stamp = MemoryStamp.now(MemoryOrigin.explicit, 'you');
      final monday = stamp.usedAt(DateTime(2026, 9, 14, 9));
      expect(monday.lastUsedAt, DateTime(2026, 9, 14, 9));
      // Same day: identical, so no write.
      expect(identical(monday.usedAt(DateTime(2026, 9, 14, 18)), monday), isTrue);
      final tuesday = monday.usedAt(DateTime(2026, 9, 15, 8));
      expect(tuesday.lastUsedAt, DateTime(2026, 9, 15, 8));
    });

    test('provenance and the used stamp survive a store round-trip', () async {
      final tmp = await Directory.systemTemp.createTemp('nexus_provenance_rt');
      addTearDown(() => tmp.delete(recursive: true));
      final path = '${tmp.path}/state.json';

      final service = _service(
        memory: AgentMemory(
          facts: [
            MemoryFact('my keys are in the hall', MemoryStamp.legacy()),
          ],
        ),
      );
      service.execute('remember that my bike code is 4321');
      service.execute('what do you know about bike');

      final store = NexusStore(explicitPath: path);
      await store.load();
      store.agentFacts = service.memoryFacts;
      await store.save();

      final reloaded = NexusStore(explicitPath: path);
      await reloaded.load();
      final bike = reloaded.agentFacts.firstWhere(
        (f) => f.text.contains('bike code'),
      );
      expect(bike.stamp.origin, MemoryOrigin.explicit);
      expect(bike.stamp.source, 'Test Desk');
      expect(bike.stamp.learnedAt, isNotNull);
      expect(bike.stamp.lastUsedAt, isNotNull);
      expect(
        reloaded.agentFacts
            .firstWhere((f) => f.text.contains('keys'))
            .stamp
            .origin,
        MemoryOrigin.legacy,
      );
    });

    test('the learned provenance travels with the values', () async {
      final tmp = await Directory.systemTemp.createTemp('nexus_provenance_led');
      addTearDown(() => tmp.delete(recursive: true));
      final path = '${tmp.path}/state.json';

      final service = _service();
      service.adoptLearned('bring me home', 'show my devices', from: 'My PC');
      service.adoptDefault('media.play.playlist', 'Chill Mix', from: 'My PC');

      final store = NexusStore(explicitPath: path);
      await store.load();
      store.agentLearned = service.learnedSnapshot;
      store.agentDefaults = service.defaultsSnapshot;
      store.agentLedger = service.ledgerSnapshot;
      await store.save();

      // A fresh service rebuilt from the store still knows where they came
      // from — so the provenance is real data, not a runtime decoration.
      final reloaded = NexusStore(explicitPath: path);
      await reloaded.load();
      final restarted = CommandService(
        devices: () => const [],
        memory: AgentMemory(
          learned: reloaded.agentLearned,
          defaults: reloaded.agentDefaults,
          facts: reloaded.agentFacts,
          ledger: reloaded.agentLedger,
        ),
      );
      expect(
        restarted.provenanceOf(MemoryLedgerKind.phrase, 'bring me home').origin,
        MemoryOrigin.device,
      );
      expect(
        restarted
            .provenanceOf(MemoryLedgerKind.preference, 'media.play.playlist')
            .source,
        'My PC',
      );
    });
  });
}
