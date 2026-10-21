// The things Nexus remembers about its person, as a topic-keyed vault.
//
// This is deliberately not the chat transcript: a transcript is what was said,
// and a memory is the small set of facts that should follow the user from one
// conversation to the next — a name, where they live, what they asked Nexus to
// remember. The file is plain JSON in the app's documents directory, so the
// user can inspect it, back it up, or delete it, and uninstalling the app takes
// it with everything else.
//
// Four rules shape it:
//
//   * nothing leaves the device. This is a file, not a service;
//   * a fact is *about* something. "My name is TVCraft" is the topic `name` and
//     the value `TVCraft`, and a second statement about the same topic replaces
//     the first instead of arguing with it — a name change is a correction, not
//     a second name;
//   * the model may ask for a change explicitly (`[remember: 'name' = 'Sam']`,
//     `[forget: 'name']`), and those tags are stripped from what the user reads;
//   * the service never throws at a caller. A missing documents folder, a
//     corrupt file, a refused write all leave the app working with whatever it
//     has in memory.
//
// The model is told the facts as a system-turn suffix. It is not told the whole
// file, and it is not told where the file is.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show ChangeNotifier, debugPrint, immutable, visibleForTesting;
import 'package:path_provider/path_provider.dart'
    show getApplicationDocumentsDirectory;

/// The file's name inside the app's documents directory.
const String kMemoryFileName = 'nexus_memory.json';

/// The shape this build writes. Version 1 stored whole sentences under `text`;
/// version 2 stores a `topic` and the value that belongs to it, which is what
/// makes a correction an overwrite instead of a second line.
const int kMemoryFileVersion = 2;

/// The most facts the file keeps. A memory that grows without limit becomes a
/// second transcript, and a small model handed all of it forgets the question.
const int kMemoryFactLimit = 80;

/// The longest value remembered. Anything longer is a message, not a fact.
const int kMemoryTextLimit = 320;

/// The topic of a fact that has no topic of its own — "Remember that my bike is
/// blue". These append rather than overwrite, because two notes with nothing in
/// common are not two answers to one question.
const String kMemoryNoteTopic = 'other';

/// One remembered fact: what it is about, what it says, and when it was learned.
@immutable
class MemoryNote {
  const MemoryNote({
    required this.topic,
    required this.fact,
    required this.learnedAt,
  });

  /// What the fact is about — `name`, `location`, `favourite:colour`,
  /// `mine:home`, or [kMemoryNoteTopic] for a free-standing note.
  final String topic;

  /// The value itself — `TVCraft`, not "My name is TVCraft". A free-standing
  /// note keeps its whole sentence here, because the sentence *is* the fact.
  final String fact;

  final DateTime learnedAt;

  /// The sentence this fact is, as the model and the vault read it.
  String get text => memorySentence(topic, fact);

  /// What the vault's row calls the topic: "name", "favourite colour", "note".
  String get topicLabel => memoryTopicLabel(topic);

  Map<String, Object?> toJson() => <String, Object?>{
    'topic': topic,
    'fact': fact,
    'learnedAt': learnedAt.toIso8601String(),
  };

  /// Reads one row of either version.
  ///
  /// A version 1 row is `{"text": "My name is TVCraft"}`: the topic is derived
  /// from the sentence with the same narrow detector the rest of the vault uses,
  /// and the value is taken out of it. That is what lets an installed phone
  /// upgrade without re-teaching Nexus its own name.
  static MemoryNote? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final String? storedTopic = (raw['topic'] as String?)?.trim();
    final String storedFact = (raw['fact'] as String?)?.trim() ?? '';
    final String legacy = (raw['text'] as String?)?.trim() ?? '';
    final String payload = storedFact.isEmpty ? legacy : storedFact;
    if (payload.isEmpty) return null;
    final bool hasTopic = storedTopic != null && storedTopic.isNotEmpty;
    final String topic = hasTopic ? storedTopic : memorySlot(payload);
    final String fact = hasTopic ? payload : memoryValueFor(topic, payload);
    final DateTime when =
        DateTime.tryParse((raw['learnedAt'] as String?) ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0);
    return MemoryNote(
      topic: topic,
      fact: fact.length <= kMemoryTextLimit
          ? fact
          : '${fact.substring(0, kMemoryTextLimit - 1)}…',
      learnedAt: when,
    );
  }
}

/// Storage behind the facts. Injectable so a test writes a temp directory
/// instead of the machine's documents folder.
abstract class MemoryStore {
  /// Null means there is no file yet.
  Future<String?> read();

  Future<void> write(String json);

  Future<void> delete();
}

/// The real one: `nexus_memory.json` in the app's private documents directory.
class FileMemoryStore implements MemoryStore {
  FileMemoryStore({Future<Directory?> Function()? directory})
    : _directory = directory ?? _defaultDirectory;

  final Future<Directory?> Function() _directory;

  static Future<Directory?> _defaultDirectory() async {
    try {
      final Directory documents = await getApplicationDocumentsDirectory();
      return await Directory('${documents.path}/nexus').create(recursive: true);
    } catch (error) {
      debugPrint('MEMORY: no documents folder ($error)');
      return null;
    }
  }

  Future<File?> _file() async {
    final Directory? dir = await _directory();
    return dir == null ? null : File('${dir.path}/$kMemoryFileName');
  }

  @override
  Future<String?> read() async {
    final File? file = await _file();
    if (file == null || !await file.exists()) return null;
    try {
      return await file.readAsString();
    } catch (error) {
      debugPrint('MEMORY: could not read the file ($error)');
      return null;
    }
  }

  @override
  Future<void> write(String json) async {
    final File? file = await _file();
    if (file == null) return;
    try {
      await file.parent.create(recursive: true);
      final File tmp = File('${file.path}.tmp');
      await tmp.writeAsString(json, flush: true);
      await tmp.rename(file.path);
    } catch (error) {
      debugPrint('MEMORY: could not write the file ($error)');
    }
  }

  @override
  Future<void> delete() async {
    final File? file = await _file();
    if (file == null) return;
    try {
      if (await file.exists()) await file.delete();
    } catch (error) {
      debugPrint('MEMORY: could not delete the file ($error)');
    }
  }
}

/// In-memory store for tests.
class MemoryMemoryStore implements MemoryStore {
  MemoryMemoryStore([this._json]);

  String? _json;

  @override
  Future<String?> read() async => _json;

  @override
  Future<void> write(String json) async => _json = json;

  @override
  Future<void> delete() async => _json = null;
}

/// One change a reply (or the user) asked for in a memory tag.
///
/// Either a fact to keep under [topic], or — with [forget] — the topic to drop.
/// Parsed by [splitMemoryTags]; nothing here talks to the file.
@immutable
class MemoryTag {
  const MemoryTag({required this.topic, this.fact, this.forget = false});

  /// The topic as written, lower-cased and unquoted. [memoryCanonicalTopic]
  /// turns the friendly spellings ("favourite colour") into vault keys.
  final String topic;

  /// The value for a remember tag. Null for a forget tag.
  final String? fact;

  /// True when this tag deletes rather than stores.
  final bool forget;

  @override
  String toString() =>
      forget ? 'MemoryTag.forget($topic)' : 'MemoryTag($topic = $fact)';
}

/// What one piece of text carried: the words without the tags, and the tags.
@immutable
class MemoryTagSplit {
  const MemoryTagSplit({required this.text, required this.tags});

  /// The text with every complete tag removed — this is what the bubble shows
  /// and what is spoken.
  final String text;

  /// The changes the tags asked for, in the order they appeared.
  final List<MemoryTag> tags;

  bool get hasTags => tags.isNotEmpty;
}

/// Matches a complete `[remember: …]` or `[forget: …]` tag.
final RegExp _memoryTag = RegExp(
  r'\[\s*(remember|forget)\s*:([^\]]*)\]',
  caseSensitive: false,
);

/// Splits [raw] into the words to show and the memory changes to apply.
///
/// [streaming] is true while the model is still writing. It changes one thing:
/// a tag that has opened but not closed is cut from the text, so the user never
/// watches `[remember: 'name' = 'TV` arrive in the bubble and then disappear
/// when the bracket lands. The same tag is returned only once it is complete.
MemoryTagSplit splitMemoryTags(String raw, {bool streaming = false}) {
  final List<MemoryTag> tags = <MemoryTag>[];
  String text = raw.replaceAllMapped(_memoryTag, (Match match) {
    final MemoryTag? tag = _tagFrom(match.group(1)!, match.group(2)!);
    if (tag != null) tags.add(tag);
    return '';
  });
  if (streaming) {
    final int dangling = _danglingTagStart(text);
    if (dangling >= 0) text = text.substring(0, dangling);
  }
  return MemoryTagSplit(text: text, tags: tags);
}

MemoryTag? _tagFrom(String kind, String body) {
  final bool forget = kind.toLowerCase() == 'forget';
  if (forget) {
    final String topic = _unquote(body.split('=').first);
    if (topic.isEmpty) return null;
    return MemoryTag(topic: topic.toLowerCase(), forget: true);
  }
  final int at = body.indexOf('=');
  if (at < 0) return null;
  final String topic = _unquote(body.substring(0, at));
  final String fact = _unquote(body.substring(at + 1));
  if (fact.isEmpty) return null;
  return MemoryTag(
    topic: topic.isEmpty ? kMemoryNoteTopic : topic.toLowerCase(),
    fact: fact,
  );
}

String _unquote(String raw) {
  String value = raw.trim();
  const List<String> quotes = <String>['"', "'", '“', '”', '‘', '’'];
  if (value.length >= 2) {
    final String first = value[0];
    final String last = value[value.length - 1];
    if (quotes.contains(first) && quotes.contains(last)) {
      value = value.substring(1, value.length - 1).trim();
    }
  }
  return value
      .replaceAll(RegExp(r'^[\s,]+'), '')
      .replaceAll(RegExp(r'[\s,]+$'), '');
}

/// Where an unterminated tag starts, or -1 when every `[` is ordinary text.
int _danglingTagStart(String text) {
  final int open = text.lastIndexOf('[');
  if (open < 0) return -1;
  final String rest = text
      .substring(open + 1)
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), ' ');
  if (rest.isEmpty) return open;
  for (final String word in const <String>['remember', 'forget']) {
    if (word.startsWith(rest)) return open;
    if (rest.startsWith(word)) {
      final String after = rest.substring(word.length).trimLeft();
      return after.isEmpty || after.startsWith(':') ? open : -1;
    }
  }
  return -1;
}

/// The app's remembered facts, loaded once and written after every change.
class MemoryService extends ChangeNotifier {
  MemoryService({MemoryStore? store}) : _store = store ?? FileMemoryStore();

  /// Test seam, in the same shape as [ChatLog.override]. The app never sets it.
  @visibleForTesting
  static MemoryService Function()? override;

  static MemoryService? _instance;

  /// One service for the app: two would be two answers to what the user told
  /// Nexus, and the one the prompt reads might be the one that missed a write.
  static MemoryService get instance =>
      override?.call() ?? (_instance ??= MemoryService());

  /// Tests only.
  @visibleForTesting
  static void debugReset() => _instance = null;

  final MemoryStore _store;
  List<MemoryNote> _notes = const <MemoryNote>[];
  bool _attached = false;

  /// The facts, oldest first.
  List<MemoryNote> get notes => List<MemoryNote>.unmodifiable(_notes);

  bool get isEmpty => _notes.isEmpty;

  int get length => _notes.length;

  /// Reads the file once. Idempotent; a missing or corrupt file is simply no
  /// memories, never a failed launch.
  Future<void> attach() async {
    if (_attached) return;
    _attached = true;
    final String? raw;
    try {
      raw = await _store.read();
    } catch (error) {
      debugPrint('MEMORY: could not load ($error)');
      return;
    }
    if (raw == null || raw.trim().isEmpty) return;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (error) {
      debugPrint('MEMORY: the file is not JSON ($error)');
      return;
    }
    // Version 2 wraps the rows in an object so the version can be stated; a
    // bare list is accepted too, because that is the shape the vault writes in
    // its simplest form and a hand-edited file should not be thrown away.
    final Object? rows = decoded is List
        ? decoded
        : (decoded is Map ? decoded['facts'] : null);
    if (rows is! List) return;
    final List<MemoryNote> loaded = <MemoryNote>[];
    for (final Object? row in rows) {
      final MemoryNote? note = MemoryNote.fromJson(row);
      if (note != null) loaded.add(note);
    }
    _notes = loaded.length > kMemoryFactLimit
        ? loaded.sublist(loaded.length - kMemoryFactLimit)
        : loaded;
    notifyListeners();
  }

  /// Remembers [text] if it is new, deriving its topic from the sentence.
  /// Answers whether anything changed.
  ///
  /// Deduplicated case-insensitively and without punctuation, because "My name
  /// is TVCraft" said twice is one fact, not two lines the model has to choose
  /// between. A *different* value under the same topic is not a duplicate: it is
  /// a correction, and it replaces the old value.
  Future<bool> remember(String text) async {
    await attach();
    final String cleaned = _clean(text);
    if (cleaned.isEmpty) return false;
    final String topic = memorySlot(cleaned);
    return rememberFact(topic, memoryValueFor(topic, cleaned));
  }

  /// Stores [fact] under [topic], replacing whatever that topic held before.
  Future<bool> rememberFact(String topic, String fact) async {
    await attach();
    final String key = memoryCanonicalTopic(topic);
    final String value = _clean(fact);
    if (key.isEmpty || value.isEmpty) return false;
    final MemoryNote note = MemoryNote(
      topic: key,
      fact: value.length <= kMemoryTextLimit
          ? value
          : '${value.substring(0, kMemoryTextLimit - 1)}…',
      learnedAt: DateTime.now(),
    );
    if (key == kMemoryNoteTopic) {
      // A note with no topic is not an answer to a question: two of them are two
      // notes, and only the identical sentence is dropped.
      if (_notes.any(
        (MemoryNote existing) =>
            existing.topic == kMemoryNoteTopic &&
            _key(existing.fact) == _key(value),
      )) {
        return false;
      }
      return _append(note);
    }
    final int index = _notes.lastIndexWhere(
      (MemoryNote existing) => existing.topic == key,
    );
    if (index < 0) return _append(note);
    if (_key(_notes[index].fact) == _key(value)) return false;
    final List<MemoryNote> next = List<MemoryNote>.of(_notes);
    next[index] = note;
    _notes = next;
    notifyListeners();
    await _persist();
    return true;
  }

  /// Adds [note] at the end and writes. Always true: the caller already
  /// established that nothing identical was there.
  Future<bool> _append(MemoryNote note) async {
    _notes = <MemoryNote>[..._notes, note];
    if (_notes.length > kMemoryFactLimit) {
      _notes = _notes.sublist(_notes.length - kMemoryFactLimit);
    }
    notifyListeners();
    await _persist();
    return true;
  }

  /// Reads [said] for facts worth keeping, and remembers them. Answers the
  /// facts added, so the caller can log or test the extraction without another
  /// read of the file.
  ///
  /// Anything in [said] that is a [MemoryTag] is applied exactly and taken out
  /// of the text the sentence detector reads: `[remember: 'name' = 'TVCraft']` is
  /// a command, not something to remember as a sentence.
  Future<List<String>> absorb(String said) async {
    await attach();
    final List<String> added = <String>[];
    final MemoryTagSplit split = splitMemoryTags(said);
    for (final MemoryTag tag in split.tags) {
      await applyTag(tag);
    }
    final String words = split.text;
    // A correction is handled before the ordinary detector: "no, it's Sam" does
    // not contain either of the shapes [extractMemoryFacts] knows, and adding it
    // as a new fact would leave the model with two names and no way to choose.
    final String? correction = memoryCorrection(words, _notes);
    if (correction != null) {
      final String topic = memorySlot(correction);
      if (await rememberFact(topic, memoryValueFor(topic, correction))) {
        added.add(correction);
      }
    }
    for (final String fact in extractMemoryFacts(words)) {
      if (await remember(fact)) added.add(fact);
    }
    return added;
  }

  /// Applies one tag, answering the pill the thread shows — or null when the
  /// tag changed nothing (the same value, or a topic with nothing to forget).
  ///
  /// A tag whose fact is not in [said] is refused: the tag exists to record
  /// what the user said in a shape the app can file, not to let the model
  /// write anything it believes. Asked "what is my name?", the 1B model
  /// answered with `[remember: 'name' = 'Nexus']` — its own name — which would
  /// have quietly overwritten the user's in their own vault. [said] is null
  /// for a typed tag, which needs no grounding because the user wrote it.
  Future<String?> applyTag(MemoryTag tag, {String? said}) async {
    if (tag.forget) {
      if (!await forget(tag.topic)) return null;
      return '🧠 Memory deleted: ${memoryTopicLabel(memoryCanonicalTopic(tag.topic))}';
    }
    final String fact = tag.fact ?? '';
    if (fact.trim().isEmpty) return null;
    if (said != null && !memoryGroundedIn(fact, said)) {
      debugPrint('MEMORY: ignored a tag the user did not say ($fact)');
      return null;
    }
    if (!await rememberFact(tag.topic, fact)) return null;
    return '🧠 Memory updated: '
        '${memoryTopicLabel(memoryCanonicalTopic(tag.topic))} is $fact';
  }

  /// Applies every tag, answering the pills to show in order.
  ///
  /// [said] is what the user wrote this turn. Supplying it makes the vault
  /// refuse a tag for something they never said — see [memoryGroundedIn]. The
  /// model's own tags pass it; a tag the user typed does not, because typing
  /// `[remember: …]` *is* the instruction.
  Future<List<String>> applyTags(
    Iterable<MemoryTag> tags, {
    String? said,
  }) async {
    final List<String> lines = <String>[];
    for (final MemoryTag tag in tags) {
      final String? line = await applyTag(tag, said: said);
      if (line != null) lines.add(line);
    }
    return lines;
  }

  /// Deletes everything remembered about [topic]. Answers whether anything went.
  Future<bool> forget(String topic) async {
    await attach();
    final List<MemoryNote> next = <MemoryNote>[
      for (final MemoryNote note in _notes)
        if (!_matchesTopic(note, topic)) note,
    ];
    if (next.length == _notes.length) return false;
    _notes = next;
    notifyListeners();
    await _persist();
    return true;
  }

  /// Deletes exactly [note] — the trash can beside one row of the vault.
  Future<bool> forgetNote(MemoryNote note) async {
    await attach();
    final int index = _notes.indexWhere(
      (MemoryNote existing) =>
          existing.topic == note.topic && existing.fact == note.fact,
    );
    if (index < 0) return false;
    _notes = List<MemoryNote>.of(_notes)..removeAt(index);
    notifyListeners();
    await _persist();
    return true;
  }

  /// Forgets everything — the one destructive action in Privacy.
  Future<void> clear() async {
    _notes = const <MemoryNote>[];
    _attached = true;
    notifyListeners();
    try {
      await _store.delete();
    } catch (error) {
      debugPrint('MEMORY: could not delete ($error)');
    }
  }

  /// What the model is told, or an empty string when there is nothing.
  ///
  /// A system suffix rather than a user turn: the facts are context for every
  /// answer, and putting them in the conversation would make the model believe
  /// the user had just repeated them.
  String get systemContext {
    if (_notes.isEmpty) return '';
    final buffer = StringBuffer(
      'What you remember about the user. These are facts about them, not about '
      'you; use them only when they are relevant:\n',
    );
    for (final MemoryNote note in _notes) {
      // Topic and value, not the display sentence: "My name is TVCraft" in a
      // system turn is a sentence the model can read as its own name, and the
      // 1B did exactly that on the phone. "- name: TVCraft" cannot be misread.
      buffer.writeln(
        note.topic == kMemoryNoteTopic
            ? '- ${note.fact}'
            : '- ${note.topicLabel}: ${note.fact}',
      );
    }
    return buffer.toString().trimRight();
  }

  Future<void> _persist() async {
    final String json = jsonEncode(<String, Object?>{
      'version': kMemoryFileVersion,
      'facts': <Map<String, Object?>>[
        for (final MemoryNote note in _notes) note.toJson(),
      ],
    });
    try {
      await _store.write(json);
    } catch (error) {
      debugPrint('MEMORY: could not save ($error)');
    }
  }

  static bool _matchesTopic(MemoryNote note, String wanted) {
    final String key = _topicKey(wanted);
    if (key.isEmpty) return false;
    return key == _topicKey(note.topic) || key == _topicKey(note.topicLabel);
  }

  static String _clean(String text) {
    String value = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    value = value.replaceFirst(RegExp(r'[.!?]+$'), '');
    if (value.length > kMemoryTextLimit) {
      value = '${value.substring(0, kMemoryTextLimit - 1)}…';
    }
    return value;
  }

  static String _key(String text) => text
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9\s]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

/// The vault's topic for a value written the friendly way.
///
/// "favourite colour" and "favourite:colour" are the same topic, and so are
/// "name" and "my name". Without this, a tag the model wrote in a different
/// spelling would create a second slot the user cannot see the point of.
String memoryCanonicalTopic(String topic) {
  final String key = topic
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'^my\s+'), '')
      .replaceAll(RegExp(r'\s+'), ' ');
  if (key.isEmpty) return kMemoryNoteTopic;
  if (key == 'name' || key == 'user name' || key == 'username') return 'name';
  if (key == 'location' ||
      key == 'city' ||
      key == 'home city' ||
      key == 'where i live') {
    return 'location';
  }
  final RegExpMatch? favourite = RegExp(r'^(?:favourite|favorite)\s+(.+)$')
      .firstMatch(key);
  if (favourite != null) {
    return 'favourite:${favourite.group(1)!.trim().replaceAll(' ', '-')}';
  }
  if (key == 'note' || key == 'other' || key == 'notes') {
    return kMemoryNoteTopic;
  }
  if (RegExp(r'^(home|work|birthday|email|phone|address)$').hasMatch(key)) {
    return 'mine:$key';
  }
  return key;
}

/// The sentence a topic and its value make — what the model is told and what the
/// vault's rows read.
String memorySentence(String topic, String fact) {
  final String value = fact.trim();
  if (value.isEmpty) return '';
  switch (topic) {
    case 'name':
      return 'My name is $value';
    case 'location':
      return 'I live in $value';
    case kMemoryNoteTopic:
      return value;
  }
  if (topic.startsWith('favourite:')) {
    final String thing = topic
        .substring('favourite:'.length)
        .replaceAll('-', ' ');
    return 'My favourite $thing is $value';
  }
  if (topic.startsWith('mine:')) {
    return 'My ${topic.substring('mine:'.length)} is $value';
  }
  return value;
}

/// The value inside a sentence about [topic]: "My name is TVCraft" is
/// `TVCraft`, and a note with no topic is its own value.
String memoryValueFor(String topic, String fact) {
  final String text = fact.trim();
  if (topic == 'name') {
    final RegExpMatch? named = RegExp(
      r'^(?:my name is|call me)\s+(.+)$',
      caseSensitive: false,
    ).firstMatch(text);
    return named == null ? text : _correctionValue(named.group(1));
  }
  if (topic == 'location') {
    final RegExpMatch? lived = RegExp(
      r'^i live in\s+(.+)$',
      caseSensitive: false,
    ).firstMatch(text);
    return lived == null ? text : _correctionValue(lived.group(1));
  }
  if (topic.startsWith('favourite:') || topic.startsWith('mine:')) {
    final int at = text.lastIndexOf(' is ');
    if (at >= 0) return _correctionValue(text.substring(at + 4));
  }
  return text;
}

/// What a topic is called in the vault: short, lower-case, and never a key.
String memoryTopicLabel(String topic) {
  if (topic == 'name') return 'name';
  if (topic == 'location') return 'location';
  if (topic.startsWith('favourite:')) {
    return 'favourite ${topic.substring('favourite:'.length).replaceAll('-', ' ')}';
  }
  if (topic.startsWith('mine:')) return topic.substring('mine:'.length);
  if (topic == kMemoryNoteTopic || topic.isEmpty) return 'note';
  return topic;
}

String _topicKey(String topic) => topic
    .trim()
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9: -]'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// Which remembered fact a sentence is about: `name`, `location`, a favourite
/// thing, or [kMemoryNoteTopic].
///
/// A topic is what makes a correction possible. Without it, "no, it's Sam" is
/// only a sentence; with it, the service knows which of the facts it already
/// holds has to make way for the new answer.
String memorySlot(String fact) {
  final String text = fact.trim().toLowerCase();
  if (text.startsWith('my name is') || text.startsWith('call me')) {
    return 'name';
  }
  if (text.startsWith('i live in')) return 'location';
  final favourites = RegExp(r'^my (?:favourite|favorite) ([a-z]+) is ')
      .firstMatch(text);
  if (favourites != null) return 'favourite:${favourites.group(1)}';
  final possessions = RegExp(
    r'^my (home|work|birthday|email|phone|address) is ',
  ).firstMatch(text);
  if (possessions != null) return 'mine:${possessions.group(1)}';
  return kMemoryNoteTopic;
}

/// A sentence that corrects a fact Nexus already holds, rewritten as the fact
/// it should become — or null when [said] is not a correction.
///
/// Two shapes are recognised, because they are the two people actually use:
/// "no, it's Sam" after being told the wrong name, and "I am Sam" as a plain
/// statement of identity. The first takes its slot from the most recent fact,
/// so it also repairs a home city or a favourite colour. "I am" is always about
/// the name, and is deliberately narrow: "I am tired" is a mood, not a fact,
/// and it must never overwrite the name the user gave Nexus yesterday.
String? memoryCorrection(String said, List<MemoryNote> notes) {
  final String text = said.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (text.isEmpty) return null;

  final no = RegExp(
    r"^no\b[\s,.:;-]*(?:it'?s|it is|that'?s|that is)\s+(.+)$",
    caseSensitive: false,
  ).firstMatch(text);
  if (no != null) {
    final String value = _correctionValue(no.group(1));
    if (value.isEmpty) return null;
    final MemoryNote? previous = notes.isEmpty ? null : notes.last;
    if (previous != null) {
      return _factWithValue(previous.text, value) ??
          _factForSlot(previous.topic, value);
    }
    return _looksLikeName(value) ? 'My name is $value' : null;
  }

  final iAm = RegExp(
    r'^i am\s+([A-Za-z][A-Za-z0-9\u2019._-]{0,30})\s*[.!]*$',
    caseSensitive: false,
  ).firstMatch(text);
  if (iAm == null) return null;
  final String value = _correctionValue(iAm.group(1));
  if (value.isEmpty || !_looksLikeName(value)) return null;
  MemoryNote? name;
  for (final MemoryNote note in notes.reversed) {
    if (note.topic == 'name') {
      name = note;
      break;
    }
  }
  if (name != null) {
    return _factWithValue(name.text, value) ?? 'My name is $value';
  }
  // Without a previous name there is nothing to correct, and a bare "I am" is
  // too often a mood to invent one from. The one exception is a capitalised,
  // name-shaped word, which is how people write a name when introducing it.
  return value[0] == value[0].toUpperCase() ? 'My name is $value' : null;
}

String _correctionValue(String? raw) => (raw ?? '')
    .trim()
    .replaceAll(RegExp(r'^[,\s]+'), '')
    .replaceAll(RegExp(r'[,\s]+$'), '')
    .replaceFirst(RegExp(r'[.!?]+$'), '');

/// Swaps the value in a fact while keeping the sentence that introduced it:
/// "Call me TVCraft" becomes "Call me TVCraft01", not a second kind of fact.
String? _factWithValue(String fact, String value) {
  final int at = fact.lastIndexOf(' is ');
  if (at >= 0) return '${fact.substring(0, at + 4)}$value';
  if (fact.toLowerCase().startsWith('call me ')) return 'Call me $value';
  return null;
}

String _factForSlot(String topic, String value) {
  if (topic == 'location') return 'I live in $value';
  if (topic.startsWith('favourite:')) {
    return 'My favourite ${topic.substring('favourite:'.length)} is $value';
  }
  if (topic.startsWith('mine:')) {
    return 'My ${topic.substring('mine:'.length)} is $value';
  }
  return 'My name is $value';
}

/// Words that follow "I am" in ordinary conversation far more often than a
/// name does. The list is not trying to be a dictionary — it only has to keep
/// the common moods and states from being written into the name slot.
const Set<String> _notNames = <String>{
  'a',
  'an',
  'angry',
  'available',
  'awake',
  'back',
  'bored',
  'busy',
  'confused',
  'curious',
  'done',
  'early',
  'excited',
  'fine',
  'free',
  'glad',
  'going',
  'good',
  'great',
  'happy',
  'here',
  'home',
  'hungry',
  'ill',
  'in',
  'just',
  'late',
  'learning',
  'lost',
  'married',
  'nervous',
  'new',
  'not',
  'ok',
  'okay',
  'old',
  'on',
  'ready',
  'sad',
  'sick',
  'single',
  'sleepy',
  'sorry',
  'still',
  'sure',
  'the',
  'thinking',
  'thirsty',
  'tired',
  'trying',
  'upset',
  'very',
  'well',
  'working',
  'young',
};

bool _looksLikeName(String value) {
  if (!RegExp(r"^[A-Za-z][A-Za-z0-9\u2019._-]{0,30}$").hasMatch(value)) {
    return false;
  }
  return !_notNames.contains(value.toLowerCase());
}

/// The words [text] is made of, lowercased and stripped of punctuation.
Set<String> memoryWords(String text) =>
    RegExp(r'[a-z0-9]+')
        .allMatches(text.toLowerCase())
        .map((RegExpMatch m) => m.group(0)!)
        .toSet();

/// Whether [fact] is something [said] actually contains.
///
/// A tag is a transcription, not new information: the model's job is to file
/// what the user said under a topic, and every word of three letters or more in
/// the fact has to be a word the user used. Short words are skipped because "my
/// name is TVCraft" against "my name's TVCraft" would otherwise be refused
/// over an apostrophe. A fact that is nothing but short words (`name = 2`) is
/// accepted, since there is nothing to check it against.
bool memoryGroundedIn(String fact, String said) {
  final Set<String> words = memoryWords(said);
  for (final String word in memoryWords(fact)) {
    if (word.length < 3) continue;
    if (!words.contains(word)) return false;
  }
  return true;
}

/// The sentences in [said] that clearly ask Nexus to remember something.
///
/// Narrow on purpose. "I am tired" is a mood, not a fact about the user's
/// world, and a service that stored it would keep telling the model something
/// that was true for one afternoon. The patterns that survive are the ones
/// people actually use when they want an assistant to know a thing.
List<String> extractMemoryFacts(String said) {
  final String text = said.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (text.isEmpty) return const <String>[];
  final List<String> facts = <String>[];

  void add(String? value) {
    if (value == null) return;
    final String cleaned = value
        .trim()
        .replaceAll(RegExp(r'^[,\s]+'), '')
        .replaceAll(RegExp(r'[,\s]+$'), '')
        .replaceFirst(RegExp(r'[.!?]+$'), '');
    if (cleaned.isEmpty || cleaned.length > kMemoryTextLimit) return;
    final String lower = cleaned.toLowerCase();
    if (lower == 'that' || lower == 'this') return;
    facts.add(cleaned);
  }

  final remember = RegExp(
    r'\bremember (?:that )?(.+)$',
    caseSensitive: false,
  ).firstMatch(text);
  if (remember != null) add(remember.group(1));

  final name = RegExp(
    r'\bmy name is ([^.!?\n]+)',
    caseSensitive: false,
  ).firstMatch(text);
  if (name != null) add('My name is ${name.group(1)!.trim()}');

  final callMe = RegExp(
    r'\bcall me ([^.!?\n]+)',
    caseSensitive: false,
  ).firstMatch(text);
  if (callMe != null) add('Call me ${callMe.group(1)!.trim()}');

  final live = RegExp(
    r'\bi live in ([^.!?\n]+)',
    caseSensitive: false,
  ).firstMatch(text);
  if (live != null) add('I live in ${live.group(1)!.trim()}');

  // "My favourite colour is green" — the same shape as the noun list below,
  // with one more word between the possessive and the verb.
  final favourite = RegExp(
    r'\bmy (favourite|favorite) ([a-z]+) is ([^.!?\n]+)',
    caseSensitive: false,
  ).firstMatch(text);
  if (favourite != null) {
    add(
      'My ${favourite.group(1)!.toLowerCase()} '
      '${favourite.group(2)!.toLowerCase()} is '
      '${favourite.group(3)!.trim()}',
    );
  }

  final mine = RegExp(
    r'\bmy (favourite|favorite|home|work|birthday|email|phone|address) '
    r'is ([^.!?\n]+)',
    caseSensitive: false,
  ).firstMatch(text);
  if (mine != null) {
    add('My ${mine.group(1)!.toLowerCase()} is ${mine.group(2)!.trim()}');
  }

  // "Remember that…" already says what to keep; the rest of the sentence is
  // not a second fact. The other patterns can coexist in one message.
  return facts.toSet().toList();
}
