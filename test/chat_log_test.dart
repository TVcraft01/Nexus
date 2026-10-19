// The conversation that survives a restart, at the level below the screen:
// what is written, what is read back, and what happens when what is on disk is
// not what this build wrote.
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/chat_log.dart';
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
}
