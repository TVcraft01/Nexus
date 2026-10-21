// What Nexus remembers about its person, and what it is allowed to remember.
//
// The memory is one JSON file in the app's documents folder, not a transcript:
// these tests prove the narrow detector, the deduplication, the prompt turn the
// model sees, and that Privacy's delete leaves no file behind.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/local_ai_service.dart';
import 'package:nexus/core/memory_service.dart';

void main() {
  late Directory documents;
  late MemoryService memory;

  setUp(() async {
    documents = await Directory.systemTemp.createTemp('nexus-memory-');
    memory = MemoryService(
      store: FileMemoryStore(directory: () async => documents),
    );
  });

  tearDown(() async {
    LocalAiService.memoryContext = null;
    if (await documents.exists()) await documents.delete(recursive: true);
  });

  File memoryFile() =>
      File('${documents.path}${Platform.pathSeparator}$kMemoryFileName');

  group('what is worth remembering', () {
    test('a name is a fact, and a mood is not', () {
      expect(extractMemoryFacts('My name is TVCraft'), <String>[
        'My name is TVCraft',
      ]);
      expect(extractMemoryFacts('I am tired'), isEmpty);
      expect(extractMemoryFacts('What is 144 divided by 12?'), isEmpty);
    });

    test('an explicit remember keeps the sentence after it', () {
      expect(extractMemoryFacts('Remember that my bike is blue.'), <String>[
        'my bike is blue',
      ]);
      expect(
        extractMemoryFacts('remember the wifi password is swordfish'),
        <String>['the wifi password is swordfish'],
      );
    });

    test('the other shapes are read without inventing a fact', () {
      expect(extractMemoryFacts('Call me Sam'), contains('Call me Sam'));
      expect(extractMemoryFacts('I live in Lyon'), contains('I live in Lyon'));
      expect(
        extractMemoryFacts('My favourite colour is green'),
        contains('My favourite colour is green'),
      );
    });
  });

  group('the remembered facts', () {
    test('are saved as JSON in the app documents folder', () async {
      expect(await memory.absorb('My name is TVCraft'), <String>[
        'My name is TVCraft',
      ]);

      final File file = memoryFile();
      expect(file.existsSync(), isTrue);
      final Map<String, Object?> raw =
          jsonDecode(await file.readAsString()) as Map<String, Object?>;
      expect(raw['version'], kMemoryFileVersion);
      final List<Object?> facts = raw['facts']! as List<Object?>;
      expect(facts, hasLength(1));
      // A fact is a topic and the value that belongs to it, not a sentence:
      // that shape is what lets a correction overwrite instead of append.
      final Map<String, Object?> row = facts.single! as Map<String, Object?>;
      expect(row['topic'], 'name');
      expect(row['fact'], 'TVCraft');
      expect(memory.notes.single.text, 'My name is TVCraft');
    });

    test('survive a restart and reach the system turn', () async {
      await memory.remember('My name is TVCraft');

      final MemoryService next = MemoryService(
        store: FileMemoryStore(directory: () async => documents),
      );
      await next.attach();

      expect(next.notes.single.text, 'My name is TVCraft');
      expect(next.systemContext, contains('- name: TVCraft'));
      expect(
        next.systemContext,
        startsWith('What you remember about the user'),
      );
    });

    test('are told as facts about the user, never in their voice', () async {
      await memory.remember('My name is TVCraft');
      await memory.remember('I live in Lyon');
      final String context = memory.systemContext;
      // "My name is TVCraft" in a system turn is a sentence a model can read as
      // its own name — the 1B answered "You are Nexus" on the phone. Topic and
      // value cannot be misread that way.
      expect(context, contains('- name: TVCraft'));
      expect(context, contains('- location: Lyon'));
      expect(context, isNot(contains('My name is')));
      expect(context, contains('not about you'));
    });

    test('are told to the brain after the app has installed them', () async {
      await memory.remember('My name is TVCraft');
      LocalAiService.memoryContext = () => memory.systemContext;

      expect(
        LocalAiService.systemWithMemory('You are Nexus.'),
        'You are Nexus.\n\n${memory.systemContext}',
      );
      expect(
        LocalAiService.systemWithMemory('You are Nexus.'),
        contains('TVCraft'),
      );
    });

    test('an empty memory leaves the system turn untouched', () {
      LocalAiService.memoryContext = () => '';
      expect(
        LocalAiService.systemWithMemory('You are Nexus.'),
        'You are Nexus.',
      );
    });

    test('the same fact said twice is one line', () async {
      expect(await memory.remember('My name is TVCraft'), isTrue);
      expect(await memory.remember('my name is tvcraft!'), isFalse);
      expect(memory.length, 1);
    });
  });

  group('corrections replace the fact they are about', () {
    test("\"no, it's …\" overwrites the previous name", () async {
      await memory.remember('My name is TVCraft');

      expect(await memory.absorb("no, it's Sam"), <String>['My name is Sam']);
      expect(memory.length, 1);
      expect(memory.notes.single.text, 'My name is Sam');
      expect(memory.systemContext, isNot(contains('TVCraft')));
    });

    test('"I am …" overwrites the name and leaves other facts alone', () async {
      await memory.remember('My name is TVCraft');
      await memory.remember('I live in Lyon');

      expect(await memory.absorb('I am Sam'), <String>['My name is Sam']);
      expect(memory.length, 2);
      expect(memory.systemContext, contains('- name: Sam'));
      expect(memory.systemContext, contains('- location: Lyon'));
      expect(memory.systemContext, isNot(contains('TVCraft')));
    });

    test('a mood is still not a name', () async {
      await memory.remember('My name is TVCraft');
      await memory.absorb('I am tired');
      expect(memory.notes.single.text, 'My name is TVCraft');
    });
  });

  group('the tags a reply writes', () {
    test('a remember tag stores the topic it names', () async {
      expect(
        await memory.applyTag(const MemoryTag(topic: 'name', fact: 'TVCraft')),
        '🧠 Memory updated: name is TVCraft',
      );
      expect(memory.notes.single.topic, 'name');
      expect(memory.notes.single.fact, 'TVCraft');
      // The model still reads a sentence: the topic is the vault's shape, not
      // the prompt's.
      expect(memory.systemContext, contains('- name: TVCraft'));
    });

    test('a second value for the same topic overwrites the first', () async {
      await memory.applyTag(const MemoryTag(topic: 'name', fact: 'TVCraft'));
      expect(
        await memory.applyTag(
          const MemoryTag(topic: 'name', fact: 'TVCraft01'),
        ),
        '🧠 Memory updated: name is TVCraft01',
      );
      expect(memory.length, 1);
      expect(memory.notes.single.fact, 'TVCraft01');
      expect(memory.systemContext, endsWith('- name: TVCraft01'));
    });

    test('the same value again is not a change and says nothing', () async {
      await memory.applyTag(const MemoryTag(topic: 'name', fact: 'TVCraft'));
      expect(
        await memory.applyTag(const MemoryTag(topic: 'name', fact: 'TVCraft')),
        isNull,
      );
    });

    test('a forget tag deletes the topic it names', () async {
      await memory.remember('My name is TVCraft');
      await memory.remember('I live in Lyon');

      expect(
        await memory.applyTag(const MemoryTag(topic: 'name', forget: true)),
        '🧠 Memory deleted: name',
      );
      expect(memory.length, 1);
      expect(memory.systemContext, isNot(contains('TVCraft')));
      expect(memory.systemContext, contains('- location: Lyon'));
      // Forgetting what is not there changes nothing, so it says nothing.
      expect(
        await memory.applyTag(const MemoryTag(topic: 'name', forget: true)),
        isNull,
      );
    });

    test('a friendly topic and its key are the same slot', () async {
      await memory.applyTag(
        const MemoryTag(topic: 'favourite colour', fact: 'green'),
      );
      expect(
        await memory.applyTag(
          const MemoryTag(topic: 'favourite:colour', fact: 'blue'),
        ),
        isNotNull,
      );
      expect(memory.length, 1);
      expect(memory.systemContext, contains('- favourite colour: blue'));
      expect(await memory.forget('favourite colour'), isTrue);
      expect(memory.isEmpty, isTrue);
    });

    test('a tag is taken out of the words, in any spacing', () {
      final MemoryTagSplit split = splitMemoryTags(
        "Sure. [remember: 'name' = 'TVCraft']",
      );
      expect(split.hasTags, isTrue);
      expect(split.text.trim(), 'Sure.');
      expect(split.tags.single.topic, 'name');
      expect(split.tags.single.fact, 'TVCraft');
      expect(splitMemoryTags('[forget:name]').tags.single.forget, isTrue);
      expect(splitMemoryTags('plain words').hasTags, isFalse);
    });

    test('a half-written tag is hidden while the answer streams', () {
      expect(
        splitMemoryTags("Sure, [remember: 'name' = 'TVC", streaming: true).text,
        'Sure, ',
      );
      // A complete one is hidden in both modes.
      expect(
        splitMemoryTags("Sure. [forget: 'name' ]", streaming: true).text,
        'Sure. ',
      );
    });

    test('a user who types a tag changes the vault directly', () async {
      await memory.absorb("[remember: 'name' = 'Sam']");
      expect(memory.notes.single.text, 'My name is Sam');
      // The tag itself is not remembered as a sentence.
      expect(memory.length, 1);
    });
  });

  // The tag exists to file what the user said, not to let the model write
  // whatever it believes. Seen on the phone: asked "what is my name?", the 1B
  // model answered with a tag for its own name, and the vault would have
  // overwritten the user's.
  group('tags are grounded in what the user said', () {
    test('a fact the question never mentioned is refused', () async {
      await memory.rememberFact('name', 'TVCraft01');
      final List<String> lines = await memory.applyTags(const <MemoryTag>[
        MemoryTag(topic: 'name', fact: 'Nexus'),
      ], said: 'what is my name');
      expect(lines, isEmpty);
      expect(memory.notes.single.fact, 'TVCraft01');
    });

    test(
      'a correction the user did say is kept, punctuation and all',
      () async {
        await memory.rememberFact('name', 'TVCraft');
        final List<String> lines = await memory.applyTags(const <MemoryTag>[
          MemoryTag(topic: 'name', fact: 'TVCraft01'),
        ], said: "No, call me TVCraft01");
        expect(lines.single, '🧠 Memory updated: name is TVCraft01');
        expect(memory.notes.single.fact, 'TVCraft01');
      },
    );

    test('a typed tag needs no grounding, because the user wrote it', () async {
      final List<String> lines = await memory.applyTags(const <MemoryTag>[
        MemoryTag(topic: 'wifi', fact: 'swordfish'),
      ], said: "[remember: 'wifi' = 'swordfish']");
      expect(lines, hasLength(1));
      expect(memory.notes.single.fact, 'swordfish');
    });

    test('short words are not a reason to refuse', () {
      expect(memoryGroundedIn('Lyon', 'I live in lyon!'), isTrue);
      expect(memoryGroundedIn('name is Nexus', 'what is my name'), isFalse);
    });
  });

  group('the vault', () {
    test('one note can be deleted without touching the others', () async {
      await memory.remember('My name is TVCraft');
      await memory.remember('I live in Lyon');

      final MemoryNote name = memory.notes.first;
      expect(await memory.forgetNote(name), isTrue);
      expect(memory.length, 1);
      expect(memory.notes.single.text, 'I live in Lyon');
      // Deleting it twice is not a second deletion.
      expect(await memory.forgetNote(name), isFalse);
      expect(await memory.forgetNote(memory.notes.single), isTrue);
      expect(memory.isEmpty, isTrue);
    });

    test('a fact typed by hand is the topic it was given', () async {
      expect(await memory.rememberFact('home', 'Lyon'), isTrue);
      expect(memory.notes.single.topicLabel, 'home');
      expect(memory.notes.single.text, 'My home is Lyon');
    });

    test('a version 1 file is read as topics', () async {
      await memoryFile().writeAsString(
        jsonEncode(<String, Object?>{
          'version': 1,
          'facts': <Map<String, Object?>>[
            <String, Object?>{
              'text': 'My name is TVCraft',
              'learnedAt': '2026-01-01T00:00:00.000',
            },
            <String, Object?>{
              'text': 'I live in Lyon',
              'learnedAt': '2026-01-02T00:00:00.000',
            },
          ],
        }),
      );

      final MemoryService upgraded = MemoryService(
        store: FileMemoryStore(directory: () async => documents),
      );
      await upgraded.attach();

      expect(upgraded.notes.map((MemoryNote n) => n.topic), <String>[
        'name',
        'location',
      ]);
      expect(upgraded.notes.first.fact, 'TVCraft');
      expect(upgraded.systemContext, contains('- name: TVCraft'));
    });
  });

  group('delete all memory', () {
    test('removes the file and forgets every fact', () async {
      await memory.remember('My name is TVCraft');
      await memory.remember('I live in Lyon');
      expect(memory.length, 2);

      await memory.clear();

      expect(memory.length, 0);
      expect(memory.systemContext, isEmpty);
      expect(memoryFile().existsSync(), isFalse);
    });

    test('is safe to repeat, and a fresh service sees nothing', () async {
      await memory.remember('My name is TVCraft');
      await memory.clear();
      await memory.clear();

      final MemoryService next = MemoryService(
        store: FileMemoryStore(directory: () async => documents),
      );
      await next.attach();
      expect(next.notes, isEmpty);
    });
  });
}
