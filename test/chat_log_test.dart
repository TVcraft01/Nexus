// The conversation that survives a restart, at the level below the screen:
// what is written, what is read back, and what happens when what is on disk is
// not what this build wrote.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/chat_log.dart';
import 'package:nexus/core/vision_ai.dart' show kNexusVisionMissingText;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a conversation written is the conversation read back', () async {
    final chat = ChatLog(store: MemoryChatLogStore());
    chat.save(<ChatEntry>[
      const ChatEntry('what is the weather?', mine: true),
      const ChatEntry('Warm and clear.'),
      const ChatEntry('No PC found on your network.', failed: true),
    ]);

    // A second log over the same store is the next launch.
    final next = ChatLog(store: MemoryChatLogStore())
      ..save(chat.entries)
      ..clear()
      ..save(chat.entries);
    await next.attach();

    expect(next.hasChat, isTrue);
    expect(next.length, 3);
    expect(next.entries.first.mine, isTrue);
    expect(next.entries[1].mine, isFalse);
    expect(
      next.entries.last.failed,
      isTrue,
      reason: 'a question that went unanswered is part of the conversation',
    );
  });

  test('the memory store answers null until something is written', () async {
    final store = MemoryChatLogStore();
    expect(await store.read(), isNull);
    await store.write(<ChatEntry>[const ChatEntry('hello', mine: true)]);
    expect(await store.read(), hasLength(1));
    // A cleared conversation is an empty list, not an absent one: the difference
    // is what tells `attach` whether there is anything to put on screen.
    await store.write(const <ChatEntry>[]);
    final List<ChatEntry>? written = await store.read();
    expect(written, isNotNull);
    expect(written, isEmpty);
  });

  test('clearing forgets the conversation, and does so on disk', () async {
    final store = MemoryChatLogStore();
    final chat = ChatLog(store: store)
      ..save(<ChatEntry>[
        const ChatEntry('what is the weather?', mine: true),
        const ChatEntry('Warm and clear.'),
      ]);
    expect(chat.hasChat, isTrue);

    chat.clear();
    expect(chat.hasChat, isFalse);
    expect(chat.length, 0);

    // A write that is not awaited: the store is the next launch's problem, and
    // it has to be empty by the time that launch reads it.
    await Future<void>.delayed(Duration.zero);
    expect(await store.read(), isEmpty);

    final next = ChatLog(store: store);
    await next.attach();
    expect(next.hasChat, isFalse);
  });

  test('attach reads once and leaves the memory alone after that', () async {
    final store = MemoryChatLogStore(<ChatEntry>[
      const ChatEntry('remembered', mine: true),
    ]);
    final chat = ChatLog(store: store);
    await chat.attach();
    expect(chat.entries.single.text, 'remembered');

    // Something else writes; a second attach is not a second read — the screen
    // that is open owns the thread now.
    await store.write(<ChatEntry>[const ChatEntry('written later')]);
    await chat.attach();
    expect(chat.entries.single.text, 'remembered');
  });

  group('the old key-value hallucination', () {
    test('is recognised at the start of a line, not in ordinary prose', () {
      for (final String text in <String>[
        'song: Yesterday, artist: The Beatles',
        'title: Yellow\nartist: Coldplay',
        'Album: Past and Present',
        'Here it is:\n  artist: The Beatles',
        'Sure — song: Yesterday, artist: The Beatles',
      ]) {
        expect(looksLikeOldHallucination(text), isTrue, reason: text);
      }
      for (final String text in <String>[
        'The title: a history',
        'I like that song a lot.',
        'The artist is on tour.',
        'The title: a history of the album cover',
        'title',
      ]) {
        expect(looksLikeOldHallucination(text), isFalse, reason: text);
      }
    });

    test(
      'is scrubbed from stored answers on attach, and written back',
      () async {
        final store = MemoryChatLogStore(<ChatEntry>[
          const ChatEntry('song: Yesterday, artist: The Beatles'),
          const ChatEntry('title: Yellow\nalbum: Parachutes'),
          const ChatEntry('title: my own note', mine: true),
          const ChatEntry('A real answer.'),
        ]);
        final chat = ChatLog(store: store);

        await chat.attach();

        expect(chat.entries[0].text, kOldHallucinationText);
        expect(chat.entries[1].text, kOldHallucinationText);
        expect(
          chat.entries[2].text,
          'title: my own note',
          reason: 'the migration never edits the user\'s words',
        );
        expect(chat.entries[3].text, 'A real answer.');

        // The repair is on disk, not just in this launch's memory.
        await Future<void>.delayed(Duration.zero);
        final List<ChatEntry>? stored = await store.read();
        expect(stored![0].text, kOldHallucinationText);
        expect(stored[1].text, kOldHallucinationText);

        final next = ChatLog(store: store);
        await next.attach();
        expect(next.entries.first.text, kOldHallucinationText);
      },
    );

    test('leaves a failed notice alone', () async {
      final chat = ChatLog(
        store: MemoryChatLogStore(<ChatEntry>[
          const ChatEntry('title: not an answer', failed: true),
        ]),
      );
      await chat.attach();
      expect(chat.entries.single.text, 'title: not an answer');
    });
  });

  group('the old no-vision notice', () {
    test('is recognised without catching ordinary prose', () {
      expect(looksLikeOldVisionNotice(kNexusVisionMissingText), isTrue);
      expect(
        looksLikeOldVisionNotice(
          'I can see you attached a photo, but my vision module is not '
          'installed yet.',
        ),
        isTrue,
      );
      expect(looksLikeOldVisionNotice('The vision module is ready.'), isFalse);
    });

    test('is rewritten as active on attach, and kept with its photo', () async {
      final store = MemoryChatLogStore(<ChatEntry>[
        const ChatEntry(
          kNexusVisionMissingText,
          imagePath: '/tmp/nexus-photo.png',
        ),
        const ChatEntry(kNexusVisionMissingText, mine: true),
      ]);
      final chat = ChatLog(store: store);

      await chat.attach();

      expect(chat.entries.first.text, kVisionActiveText);
      expect(
        chat.entries.first.imagePath,
        '/tmp/nexus-photo.png',
        reason: 'the repaired line still belongs to its picture',
      );
      expect(
        chat.entries.last.text,
        kNexusVisionMissingText,
        reason: 'the migration never edits the user\'s words',
      );

      await Future<void>.delayed(Duration.zero);
      final List<ChatEntry>? stored = await store.read();
      expect(stored!.first.text, kVisionActiveText);
    });
  });

  test('vision evidence round-trips through the stored row', () {
    const ChatEntry entry = ChatEntry(
      'Photo attached',
      mine: true,
      imagePath: '/tmp/photo.jpg',
      visionText: 'NEXUS VISION TEST',
      visionLabels: <String>['Monochrome', 'Device'],
    );

    final ChatEntry? back = ChatEntry.fromJson(entry.toJson());
    expect(back!.visionText, 'NEXUS VISION TEST');
    expect(back.visionLabels, <String>['Monochrome', 'Device']);
    expect(back.imagePath, '/tmp/photo.jpg');
  });

  test('every picture in a multi-image turn survives storage', () {
    const ChatEntry entry = ChatEntry(
      'Compare these',
      mine: true,
      imagePath: '/tmp/one.jpg',
      imagePaths: <String>['/tmp/one.jpg', '/tmp/two.jpg', '/tmp/three.jpg'],
    );

    final ChatEntry back = ChatEntry.fromJson(entry.toJson())!;
    expect(back.imagePath, '/tmp/one.jpg');
    expect(back.allImagePaths, <String>[
      '/tmp/one.jpg',
      '/tmp/two.jpg',
      '/tmp/three.jpg',
    ]);
  });

  test('one line of junk does not lose the rest of the file', () {
    expect(
      ChatEntry.fromJson(const <String, Object?>{'text': 'hello', 'mine': true})
          ?.mine,
      isTrue,
    );
    expect(ChatEntry.fromJson(const <String, Object?>{'text': ''}), isNull);
    expect(ChatEntry.fromJson(const <String, Object?>{'text': 7}), isNull);
    expect(ChatEntry.fromJson('not a row'), isNull);
    expect(ChatEntry.fromJson(null), isNull);
  });

  test('the preferences store round-trips through real JSON', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final store = SharedPrefsChatLogStore();

    // Nothing has ever been written.
    expect(await store.read(), isNull);

    await store.write(<ChatEntry>[
      const ChatEntry('hello', mine: true),
      const ChatEntry('hi there'),
    ]);
    final List<ChatEntry>? read = await store.read();
    expect(read, hasLength(2));
    expect(read!.first.text, 'hello');
    expect(read.first.mine, isTrue);
    expect(read.last.text, 'hi there');
    expect(read.last.failed, isFalse);

    // A file this build would not write: a string where the list belongs. The
    // honest recovery is an empty conversation, not a crash on launch.
    SharedPreferences.setMockInitialValues(<String, Object>{
      SharedPrefsChatLogStore.key: '{"not": "a list"}',
    });
    expect(await SharedPrefsChatLogStore().read(), isNull);

    SharedPreferences.setMockInitialValues(<String, Object>{
      SharedPrefsChatLogStore.key: 'not json at all',
    });
    expect(await SharedPrefsChatLogStore().read(), isNull);
  });

  test('the documents store survives a restart and a wipe', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final Directory documents = await Directory.systemTemp.createTemp(
      'nexus-chats-',
    );
    addTearDown(() async {
      if (await documents.exists()) await documents.delete(recursive: true);
    });
    final store = DocumentsChatLogStore(directory: () async => documents);
    final ChatSession session = ChatSession(
      id: 'chat-1',
      createdAt: DateTime.utc(2026, 10, 19),
      updatedAt: DateTime.utc(2026, 10, 19),
      entries: const <ChatEntry>[
        ChatEntry('what is the weather?', mine: true),
        ChatEntry('Warm and clear.'),
      ],
    );

    await store.writeSessions(<ChatSession>[session], 'chat-1');

    // The next launch reads the same conversation, from a file in documents —
    // not from a preference, and not from a cache somewhere else.
    final ChatLog next = ChatLog(store: store, sessions: store);
    await next.attach();
    expect(next.entries, hasLength(2));
    expect(next.entries.last.text, 'Warm and clear.');

    await next.clearAll();
    expect(await store.readSessions(), isNull);
    expect(await store.read(), isNull);
  });

  test('overlapping saves all land, and the newest one wins', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final Directory documents = await Directory.systemTemp.createTemp(
      'nexus-chats-race-',
    );
    addTearDown(() async {
      if (await documents.exists()) await documents.delete(recursive: true);
    });
    final store = DocumentsChatLogStore(directory: () async => documents);

    // Two saves started in the same turn share a `.tmp` file. The second used
    // to lose its rename to the first and log a PathNotFoundException even
    // though nothing was wrong — so start a burst and demand a clean result.
    final List<Future<void>> saves = <Future<void>>[];
    for (int i = 0; i < 8; i++) {
      final String id = 'chat-$i';
      saves.add(
        store.writeSessions(<ChatSession>[
          ChatSession(
            id: id,
            createdAt: DateTime.utc(2026, 10, 19),
            updatedAt: DateTime.utc(2026, 10, 19),
            entries: <ChatEntry>[ChatEntry('save $i', mine: true)],
          ),
        ], id),
      );
    }
    await Future.wait(saves);

    final ChatSessionData? data = await store.readSessions();
    expect(data, isNotNull);
    expect(data!.sessions.single.id, 'chat-7');
    expect(data.activeId, 'chat-7');
    expect(data.sessions.single.entries.single.text, 'save 7');
    final leftovers = await documents
        .list()
        .where((FileSystemEntity e) => e.path.endsWith('.tmp'))
        .toList();
    expect(leftovers, isEmpty, reason: 'a finished save leaves no temp file');
  });

  test('an old answer with reasoning is split when it is read back', () {
    // Written by a build that kept the model's working-out in `text`. The
    // reopened thread must draw the grey bubble and the answer, not the two
    // run together.
    final ChatEntry? labelled = ChatEntry.fromJson(<String, Object?>{
      'text': 'Thought: check the map\n\nThe map is on the table.',
    });
    expect(labelled, isNotNull);
    expect(labelled!.reasoning, 'check the map');
    expect(labelled.text, 'The map is on the table.');

    final ChatEntry? tagged = ChatEntry.fromJson(<String, Object?>{
      'text': '<thought>weigh the options</thought>Choose the left path.',
    });
    expect(tagged!.reasoning, 'weigh the options');
    expect(tagged.text, 'Choose the left path.');

    // The user's own words are never parsed, even if they start with a label.
    final ChatEntry? mine = ChatEntry.fromJson(<String, Object?>{
      'text': 'Thought: I should ask Nexus',
      'mine': true,
    });
    expect(mine!.reasoning, isNull);
    expect(mine.text, 'Thought: I should ask Nexus');

    // A reply whose reasoning was already stored keeps both halves untouched.
    final ChatEntry? stored = ChatEntry.fromJson(<String, Object?>{
      'text': 'The map is on the table.',
      'reasoning': 'check the map',
    });
    expect(stored!.reasoning, 'check the map');
    expect(stored.text, 'The map is on the table.');
  });
}
