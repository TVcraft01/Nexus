// The things Nexus remembers about its person, in one file they own.
//
// This is deliberately not the chat transcript: a transcript is what was said,
// and a memory is the small set of facts that should follow the user from one
// conversation to the next — a name, where they live, what they asked Nexus to
// remember. The file is plain JSON in the app's documents directory, so the
// user can inspect it, back it up, or delete it, and uninstalling the app takes
// it with everything else.
//
// Three rules shape it:
//
//   * nothing leaves the device. This is a file, not a service;
//   * a fact is only stored when the user said it in a shape that clearly means
//     "remember this" — the detector is deliberately narrow, because a wrong
//     memory is worse than a missing one;
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
    show ChangeNotifier, debugPrint, visibleForTesting;
import 'package:path_provider/path_provider.dart'
    show getApplicationDocumentsDirectory;

/// The file's name inside the app's documents directory.
const String kMemoryFileName = 'nexus_memory.json';

/// The most facts the file keeps. A memory that grows without limit becomes a
/// second transcript, and a small model handed all of it forgets the question.
const int kMemoryFactLimit = 80;

/// The longest sentence remembered. Anything longer is a message, not a fact.
const int kMemoryTextLimit = 320;

/// One remembered sentence and when it was learned.
class MemoryNote {
  const MemoryNote({required this.text, required this.learnedAt});

  final String text;
  final DateTime learnedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'text': text,
    'learnedAt': learnedAt.toIso8601String(),
  };

  static MemoryNote? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final String text = (raw['text'] as String?)?.trim() ?? '';
    if (text.isEmpty) return null;
    final DateTime when =
        DateTime.tryParse((raw['learnedAt'] as String?) ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0);
    return MemoryNote(
      text: text.length <= kMemoryTextLimit
          ? text
          : '${text.substring(0, kMemoryTextLimit - 1)}…',
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
    if (decoded is! Map) return;
    final Object? rows = decoded['facts'];
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

  /// Remembers [text] if it is new. Answers whether anything changed.
  ///
  /// Deduplicated case-insensitively and without punctuation, because "My name
  /// is TVCraft" said twice is one fact, not two lines the model has to choose
  /// between.
  Future<bool> remember(String text) async {
    await attach();
    final String cleaned = _clean(text);
    if (cleaned.isEmpty) return false;
    final String key = _key(cleaned);
    if (_notes.any((MemoryNote note) => _key(note.text) == key)) return false;
    _notes = <MemoryNote>[
      ..._notes,
      MemoryNote(text: cleaned, learnedAt: DateTime.now()),
    ];
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
  /// A correction is handled before the ordinary detector: "no, it's Sam" does
  /// not contain either of the shapes [extractMemoryFacts] knows, and adding it
  /// as a new fact would leave the model with two names and no way to choose.
  /// The corrected fact takes the place of the one it is about, so the file
  /// keeps one answer per slot (name, home, favourite colour) rather than a
  /// history of every attempt.
  Future<List<String>> absorb(String said) async {
    await attach();
    final List<String> added = <String>[];
    final String? correction = memoryCorrection(said, _notes);
    if (correction != null) {
      final String slot = memorySlot(correction);
      if (await _replace(slot, correction)) added.add(correction);
    }
    for (final String fact in extractMemoryFacts(said)) {
      if (await remember(fact)) added.add(fact);
    }
    return added;
  }

  /// Puts [text] in the place of the last fact with the same [slot].
  ///
  /// One fact per slot is the point: a model told both "My name is TVCraft" and
  /// "My name is TVCraft01" has no reason to prefer the newer sentence, and the
  /// user has already said which one is right.
  Future<bool> _replace(String slot, String text) async {
    final String cleaned = _clean(text);
    if (cleaned.isEmpty) return false;
    final int index = _notes.lastIndexWhere(
      (MemoryNote note) => memorySlot(note.text) == slot,
    );
    if (index < 0) return remember(cleaned);
    if (_key(_notes[index].text) == _key(cleaned)) return false;
    final List<MemoryNote> next = List<MemoryNote>.of(_notes)
      ..[index] = MemoryNote(text: cleaned, learnedAt: DateTime.now());
    _notes = <MemoryNote>[
      for (int i = 0; i < next.length; i++)
        if (i == index || _key(next[i].text) != _key(cleaned)) next[i],
    ];
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
      'What you remember about the user. Use it only when it is relevant:\n',
    );
    for (final MemoryNote note in _notes) {
      buffer.writeln('- ${note.text}');
    }
    return buffer.toString().trimRight();
  }

  Future<void> _persist() async {
    final String json = jsonEncode(<String, Object?>{
      'version': 1,
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

/// Which remembered fact a sentence is about: `name`, `location`, a favourite
/// thing, or `other`.
///
/// A slot is what makes a correction possible. Without it, "no, it's Sam" is
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
  return 'other';
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
          _factForSlot(memorySlot(previous.text), value);
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
    if (memorySlot(note.text) == 'name') {
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

String _factForSlot(String slot, String value) {
  if (slot == 'location') return 'I live in $value';
  if (slot.startsWith('favourite:')) {
    return 'My favourite ${slot.substring('favourite:'.length)} is $value';
  }
  if (slot.startsWith('mine:')) {
    return 'My ${slot.substring('mine:'.length)} is $value';
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
