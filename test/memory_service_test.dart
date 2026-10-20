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
      expect(raw['version'], 1);
      final List<Object?> facts = raw['facts']! as List<Object?>;
      expect(facts, hasLength(1));
      expect(
        (facts.single! as Map<String, Object?>)['text'],
        'My name is TVCraft',
      );
    });

    test('survive a restart and reach the system turn', () async {
      await memory.remember('My name is TVCraft');

      final MemoryService next = MemoryService(
        store: FileMemoryStore(directory: () async => documents),
      );
      await next.attach();

      expect(next.notes.single.text, 'My name is TVCraft');
      expect(next.systemContext, contains('My name is TVCraft'));
      expect(
        next.systemContext,
        startsWith('What you remember about the user'),
      );
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
      expect(memory.systemContext, contains('My name is Sam'));
      expect(memory.systemContext, contains('I live in Lyon'));
      expect(memory.systemContext, isNot(contains('TVCraft')));
    });

    test('a mood is still not a name', () async {
      await memory.remember('My name is TVCraft');
      await memory.absorb('I am tired');
      expect(memory.notes.single.text, 'My name is TVCraft');
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
