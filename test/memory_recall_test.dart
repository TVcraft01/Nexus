// A question about something the user told Nexus is answered from the vault.
//
// The case that prompted this: "remember my bike code is 4482", then "what is
// my bike code" — the 1B model answered "I don't know that yet" while the vault
// held the fact. The shell answers these itself now, and only when the vault
// really has the fact, so a question it cannot answer still reaches the model.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/memory_service.dart';

void main() {
  late Directory documents;
  late MemoryService memory;

  setUp(() async {
    documents = await Directory.systemTemp.createTemp('nexus-recall-');
    memory = MemoryService(
      store: FileMemoryStore(directory: () async => documents),
    );
  });

  tearDown(() async {
    if (await documents.exists()) await documents.delete(recursive: true);
  });

  group('a question that names the user\'s own fact', () {
    test('is read as a topic', () {
      expect(memoryQuestionTopic('what is my bike code'), 'bike code');
      expect(memoryQuestionTopic("what's my wifi password?"), 'wifi password');
      expect(memoryQuestionTopic('where is my spare key'), 'spare key');
      expect(memoryQuestionTopic('do you remember my bike code'), 'bike code');
      expect(memoryQuestionTopic('what do you know about my bike'), 'bike');
    });

    test('is not a question about the world, a device or a sum', () {
      expect(memoryQuestionTopic('what is the capital of france'), isNull);
      expect(memoryQuestionTopic('what is 2 plus 2'), isNull);
      expect(memoryQuestionTopic('what time is it'), isNull);
      expect(memoryQuestionTopic('hello'), isNull);
      expect(memoryQuestionTopic('what do you know about me'), isNull);
    });
  });

  group('the vault answers it', () {
    test('a fact with no topic of its own is answered as its sentence', () async {
      await memory.remember('my bike code is 4482');

      final MemoryNote? note = memory.noteForQuestion('what is my bike code');
      expect(note, isNotNull);
      expect(memoryAnswerSentence(note!), 'My bike code is 4482.');
    });

    test('a topic and its value become one sentence', () async {
      await memory.rememberFact('bike code', '4482');

      final MemoryNote? note = memory.noteForQuestion('where is my bike code');
      expect(note, isNotNull);
      expect(memoryAnswerSentence(note!), 'Your bike code is 4482.');
    });

    test('a question about something the vault does not hold is not '
        'answered here', () async {
      await memory.remember('my bike code is 4482');

      expect(memory.noteForQuestion('what is my car code'), isNull);
      expect(memory.noteForQuestion('what is my battery'), isNull);
    });

    test('a model-written tag leaves no quote or bracket in the vault', () async {
      await memory.rememberFact('bike code', "4482')");

      expect(memory.notes.single.fact, '4482');
      expect(
        memory.systemContext,
        contains('- bike code: 4482'),
        reason: 'the model is told the value, not the tag\'s punctuation',
      );
    });

    test('a phone number keeps its own bracket', () async {
      await memory.rememberFact('mom phone', '(555) 123-4567');

      expect(memory.notes.single.fact, '(555) 123-4567');
    });
  });
}
