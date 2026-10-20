// The conversation, saved between launches.
//
// A chat that forgets is not an assistant, it is a search box: the user's
// second question is usually about the first answer, and an app that opens on
// the welcome screen every morning throws the thing they were working on away.
// So the thread lives on disk, and this file is the one place that knows how it
// gets there and what it is made of.
//
// The app now keeps more than one thread. A [ChatSession] is one conversation
// with its own title and timestamps; [ChatLog] is the list of them and one
// active id. The old single-thread storage format is still read — it becomes
// one session, so an update never loses the conversation somebody was already
// having. The API the screen uses (`entries`, `save`, `clear`) still speaks
// about the active session, which is why the composer did not have to learn
// about sessions at all.
//
// Deliberately a *store of lines* rather than the screen's message type: a
// bubble is a drawing decision (this one is mine, that one is still being
// written), and a file that carried it would be a file that has to be migrated
// every time the shell changes how it paints. [ChatEntry] is the smallest thing
// that can be read back into a bubble — who said it, what they said, and whether
// it was the shell admitting it could not answer.
library;

import 'dart:convert';
import 'dart:io' show Directory, File, Platform;

import 'package:flutter/foundation.dart'
    show ChangeNotifier, debugPrint, immutable, visibleForTesting;
import 'package:path_provider/path_provider.dart'
    show getApplicationDocumentsDirectory;
import 'package:shared_preferences/shared_preferences.dart';

/// What a stored answer is replaced with when it is one of the old
/// key-value hallucinations.
///
/// A model asked to name a song sometimes answered as a record instead of a
/// sentence — `song: Yesterday, artist: The Beatles` — and those lines were
/// saved like any other answer. They are not a description of anything the app
/// did, and leaving them in the thread is leaving a lie in the user's history.
/// The text is named here so the migration and its test cannot disagree about
/// what the replacement says.
const String kOldHallucinationText = '[Old hallucination removed]';

/// What an old "my vision module is not installed" answer becomes now that
/// the module is active.
///
/// The sentence was true when it was written and is a lie in the user's
/// history now. It is replaced as a line of its own so the old refusal does not
/// sit next to the photo it was about as though the app still could not see it.
const String kVisionActiveText = '[Vision module now active]';

/// The keys the old invented answers used, at the start of a line.
///
/// Anchored to a line rather than to the whole message so a record inside a
/// longer answer is caught too, and deliberately limited to the fields those
/// answers invented. A sentence that merely mentions a title — "the title is on
/// the cover" — does not have a colon after the word and is left alone.
final RegExp _oldKeyValueLine = RegExp(
  r'(^|\n)\s*(?:song|title|artist|album)\s*:\s*\S',
  caseSensitive: false,
);

/// The same record written inline, inside a sentence, as two known fields
/// separated by a comma: "Here it is: song: Yesterday, artist: The Beatles".
/// Two known keys — not one — so ordinary prose that happens to mention a
/// title is still left alone.
final RegExp _oldKeyValuePair = RegExp(
  r'\b(?:song|title|artist|album)\s*:\s*[^\n,]+,\s*'
  r'(?:song|title|artist|album)\s*:',
  caseSensitive: false,
);

/// Whether [text] is one of the old key-value hallucinations.
bool looksLikeOldHallucination(String text) =>
    _oldKeyValueLine.hasMatch(text) || _oldKeyValuePair.hasMatch(text);

/// The sentence the app used before ML Kit was installed. Matched anywhere in
/// the line, because it was written as one sentence and may have been quoted.
final RegExp _oldVisionNotice = RegExp(
  r'vision module is not installed',
  caseSensitive: false,
);

/// Whether [text] is the old "no vision module" notice.
bool looksLikeOldVisionNotice(String text) => _oldVisionNotice.hasMatch(text);

/// One line of the conversation, as it is stored.
///
/// [thinking] is deliberately absent: a placeholder is the screen saying "an
/// answer is on its way", and a placeholder read back after a crash would be a
/// promise with nobody left to keep it.
@immutable
class ChatEntry {
  const ChatEntry(
    this.text, {
    this.mine = false,
    this.failed = false,
    this.system = false,
    this.ok = true,
    this.imagePath,
    this.filePath,
    this.visionText,
    this.visionLabels = const <String>[],
    this.reasoning,
  });

  /// What was said, exactly as it was said. Never empty on the way in: an empty
  /// line is not a turn, it is a gap.
  final String text;

  /// True for the user's own side of the thread.
  final bool mine;

  /// True for a red notice where an answer would have been — the shell talking
  /// about itself, not the assistant answering. Kept, because a user who comes
  /// back to a conversation wants to see that their question went unanswered.
  final bool failed;

  /// True for a line the shell *did* something to make: "Flashlight on." It is
  /// not the assistant speaking, so it is never handed to the model as history,
  /// and it is stored because a resumed conversation with the action missing
  /// would read as though nothing had happened.
  final bool system;

  /// Whether a [system] line reports a success ([true], the default and the
  /// only value for any other kind of line) or a refusal. Drives the icon, and
  /// nothing else.
  final bool ok;

  /// Where an attached photo or screenshot lives, if this line carries one.
  /// [text] is its caption ("Photo attached"), so an attachment is stored as an
  /// ordinary line plus one path — no second kind of entry, and a thread read
  /// by a build that predates attachments loses the picture, not the line.
  final String? imagePath;

  /// Where a picked document lives, if this line carries one. Separate from
  /// [imagePath] because a document is not decoded as a picture — the thread
  /// draws a file chip from its name — and a build that predates it loses the
  /// chip, not the line.
  final String? filePath;

  /// What ML Kit read in the attached picture, if anything. Kept beside the
  /// picture rather than inside its caption so the bubble can show the evidence
  /// under the image and still keep "Photo attached" as the line the brain and
  /// the transcript see.
  final String? visionText;

  /// The object labels ML Kit found, best first. Empty for a line without an
  /// image, or for an image where nothing was recognised.
  final List<String> visionLabels;

  /// The model's `<thought>` text, kept so a reopened answer still has the
  /// collapsible reasoning bubble above it. It is never sent back to the model
  /// as conversation history — see `_historyBefore` in `main_ui.dart`.
  final String? reasoning;

  Map<String, Object?> toJson() => <String, Object?>{
    'text': text,
    'mine': mine,
    'failed': failed,
    // Omitted when false/untrue so the stored shape of a plain turn is exactly
    // what earlier builds wrote.
    if (system) 'system': true,
    if (!ok) 'ok': false,
    if (imagePath != null) 'image': imagePath,
    if (filePath != null) 'file': filePath,
    if (visionText != null && visionText!.trim().isNotEmpty)
      'visionText': visionText,
    if (visionLabels.isNotEmpty) 'visionLabels': visionLabels,
    if (reasoning != null && reasoning!.trim().isNotEmpty)
      'reasoning': reasoning,
  };

  /// Reads one stored line. Null for anything that is not one — a file half
  /// written by a killed process is not a reason to lose the rest of it.
  static ChatEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? text = raw['text'];
    if (text is! String || text.trim().isEmpty) return null;
    final Object? image = raw['image'];
    final Object? file = raw['file'];
    final Object? vision = raw['visionText'];
    final Object? labels = raw['visionLabels'];
    final List<String> visionLabels = <String>[];
    if (labels is List) {
      for (final Object? label in labels) {
        if (label is String && label.trim().isNotEmpty) {
          visionLabels.add(label.trim());
        }
      }
    }
    return ChatEntry(
      text,
      mine: raw['mine'] == true,
      failed: raw['failed'] == true,
      system: raw['system'] == true,
      ok: raw['ok'] != false,
      imagePath: image is String && image.isNotEmpty ? image : null,
      filePath: file is String && file.isNotEmpty ? file : null,
      visionText: vision is String && vision.trim().isNotEmpty ? vision : null,
      visionLabels: visionLabels,
      reasoning:
          raw['reasoning'] is String &&
              (raw['reasoning'] as String).trim().isNotEmpty
          ? (raw['reasoning'] as String).trim()
          : null,
    );
  }

  @override
  String toString() => 'ChatEntry(${mine ? 'me' : 'nexus'}: $text)';
}

/// One conversation: its lines, when it began, and when it was last spoken in.
///
/// [title] is derived rather than stored. A stored title would be a copy of the
/// first user line, and a copy is a thing that can disagree with the line it
/// copied after a migration. The first line the user typed is the title; an
/// empty session is called "New chat".
@immutable
class ChatSession {
  const ChatSession({
    required this.id,
    required this.createdAt,
    required this.updatedAt,
    this.entries = const <ChatEntry>[],
    this.customTitle,
    this.pinned = false,
  });

  /// Stable across restarts, and never shown. The drawer uses it to say which
  /// row is the one on screen.
  final String id;

  final DateTime createdAt;

  /// The time of the newest line, or the creation time for an empty session.
  /// This is what groups a session under Today, Yesterday, and so on.
  final DateTime updatedAt;

  final List<ChatEntry> entries;

  /// A title the user typed. Null is the common case: the first thing they
  /// said is a better title than anything the app could invent.
  final String? customTitle;

  /// True when the user pinned this conversation to the top of the drawer.
  final bool pinned;

  /// The sentence a drawer row shows.
  String get title {
    final String? named = customTitle?.trim();
    if (named != null && named.isNotEmpty) {
      return named.length <= 42 ? named : '${named.substring(0, 41)}…';
    }
    for (final ChatEntry entry in entries) {
      final String text = entry.text.trim();
      if (entry.mine && !entry.system && text.isNotEmpty) {
        final String line = text.replaceAll(RegExp(r'\s+'), ' ');
        return line.length <= 42 ? line : '${line.substring(0, 41)}…';
      }
    }
    return 'New chat';
  }

  /// True when there is nothing to reopen.
  bool get isEmpty => entries.isEmpty;

  ChatSession copyWith({
    DateTime? updatedAt,
    List<ChatEntry>? entries,
    String? customTitle,
    bool? pinned,
  }) => ChatSession(
    id: id,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    entries: entries ?? this.entries,
    customTitle: customTitle ?? this.customTitle,
    pinned: pinned ?? this.pinned,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    if (customTitle != null) 'title': customTitle,
    if (pinned) 'pinned': true,
    'entries': <Map<String, Object?>>[
      for (final ChatEntry entry in entries) entry.toJson(),
    ],
  };

  /// Reads one stored session. Null when there is no usable id or date — a
  /// session with no id cannot be selected, and one with no date cannot be
  /// grouped without inventing a time.
  static ChatSession? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final String id = (raw['id'] as String?)?.trim() ?? '';
    if (id.isEmpty) return null;
    final DateTime? created = DateTime.tryParse(
      (raw['createdAt'] as String?) ?? '',
    );
    final DateTime? updated = DateTime.tryParse(
      (raw['updatedAt'] as String?) ?? '',
    );
    if (created == null || updated == null) return null;
    final List<ChatEntry> entries = <ChatEntry>[];
    final Object? rows = raw['entries'];
    if (rows is List) {
      for (final Object? row in rows) {
        final ChatEntry? entry = ChatEntry.fromJson(row);
        if (entry != null) entries.add(entry);
      }
    }
    final String? title = (raw['title'] as String?)?.trim();
    return ChatSession(
      id: id,
      createdAt: created,
      updatedAt: updated,
      entries: entries,
      customTitle: title == null || title.isEmpty ? null : title,
      pinned: raw['pinned'] == true,
    );
  }

  @override
  String toString() => 'ChatSession($id, "$title", ${entries.length})';
}

/// The heading a drawer puts a conversation under, from the day it was last
/// used. The boundaries are calendar days rather than 24-hour periods: a chat
/// from 11:50 last night is "Yesterday" at 00:10, not "Today" because only
/// twenty minutes have passed.
String chatDateGroup(DateTime updatedAt, DateTime now) {
  final DateTime day = DateTime(now.year, now.month, now.day);
  final DateTime then = DateTime(
    updatedAt.year,
    updatedAt.month,
    updatedAt.day,
  );
  final int days = day.difference(then).inDays;
  if (days <= 0) return 'Today';
  if (days == 1) return 'Yesterday';
  if (days <= 7) return 'Previous 7 Days';
  return 'Older';
}

/// Storage behind the conversation: injectable so a test lives in memory and a
/// phone persists across restarts.
abstract class ChatLogStore {
  Future<List<ChatEntry>?> read();

  Future<void> write(List<ChatEntry> entries);
}

/// In-memory implementation for tests.
class MemoryChatLogStore implements ChatLogStore {
  MemoryChatLogStore([List<ChatEntry>? initial])
    : _entries = initial == null ? null : List<ChatEntry>.of(initial);

  /// Null means "nothing has ever been written", which is a different answer
  /// from an empty list — see [ChatLog.attach].
  List<ChatEntry>? _entries;

  @override
  Future<List<ChatEntry>?> read() async =>
      _entries == null ? null : List<ChatEntry>.of(_entries!);

  @override
  Future<void> write(List<ChatEntry> entries) async {
    _entries = List<ChatEntry>.of(entries);
  }
}

/// Everything the session list needs, read and written together so the active
/// id cannot point at a session a half-finished write forgot.
@immutable
class ChatSessionData {
  const ChatSessionData({required this.sessions, this.activeId});

  final List<ChatSession> sessions;
  final String? activeId;
}

/// The envelope both stores write. One function so the file in documents and
/// the legacy preference cannot disagree about the format.
String encodeStoredSessions(List<ChatSession> sessions, String? activeId) =>
    jsonEncode(<String, Object?>{
      'version': 2,
      'active': activeId,
      'sessions': <Map<String, Object?>>[
        for (final ChatSession session in sessions) session.toJson(),
      ],
    });

/// Reads [encodeStoredSessions]'s output, or null when it is missing or not
/// the shape this build writes.
ChatSessionData? decodeStoredSessions(String? raw) {
  if (raw == null) return null;
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    debugPrint('CHAT: the stored sessions could not be read');
    return null;
  }
  if (decoded is! Map) return null;
  final Object? rows = decoded['sessions'];
  if (rows is! List) return null;
  final List<ChatSession> sessions = <ChatSession>[];
  for (final Object? row in rows) {
    final ChatSession? session = ChatSession.fromJson(row);
    if (session != null) sessions.add(session);
  }
  final String? active = decoded['active'] as String?;
  return ChatSessionData(sessions: sessions, activeId: active);
}

/// The old single-thread format: a bare JSON list of lines.
String encodeStoredEntries(List<ChatEntry> entries) => jsonEncode(
  <Map<String, Object?>>[for (final ChatEntry entry in entries) entry.toJson()],
);

List<ChatEntry>? decodeStoredEntries(String? raw) {
  if (raw == null) return null;
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    debugPrint('CHAT: the stored conversation could not be read');
    return null;
  }
  if (decoded is! List) return null;
  final List<ChatEntry> entries = <ChatEntry>[];
  for (final Object? row in decoded) {
    final ChatEntry? entry = ChatEntry.fromJson(row);
    if (entry != null) entries.add(entry);
  }
  return entries;
}

/// Storage behind the list of conversations. Separate from [ChatLogStore] on
/// purpose: the old interface is what every existing test and the old storage
/// key still speak, and a store that cannot do sessions simply keeps working as
/// one thread.
abstract class ChatSessionStore {
  /// Null means nothing has ever been written — not an empty list.
  Future<ChatSessionData?> readSessions();

  Future<void> writeSessions(List<ChatSession> sessions, String? activeId);

  /// Removes both the session list and the old single-thread key.
  Future<void> wipeSessions();
}

/// SharedPreferences-backed store used in production: one JSON envelope under
/// [sessionsKey], plus the old [key] read for conversations written before
/// sessions existed.
class SharedPrefsChatLogStore implements ChatLogStore, ChatSessionStore {
  /// The legacy key: one JSON list, which is what earlier builds wrote.
  static const String key = 'chat_log';

  /// The session envelope. Kept apart from [key] so a downgrade still finds
  /// the old thread and a fresh install never has to read a missing key.
  static const String sessionsKey = 'chat_sessions';

  SharedPreferences? _prefs;

  Future<SharedPreferences?> _instance() async {
    try {
      return _prefs ??= await SharedPreferences.getInstance();
    } catch (error) {
      debugPrint('CHAT: no preferences store ($error)');
      return null;
    }
  }

  /// Reads the old single-thread list, or the active thread of a session
  /// envelope. Answers null when neither has ever been written.
  @override
  Future<List<ChatEntry>?> read() async {
    final SharedPreferences? prefs = await _instance();
    if (prefs == null) return null;
    final ChatSessionData? sessions = decodeStoredSessions(
      prefs.getString(sessionsKey),
    );
    if (sessions != null && sessions.sessions.isNotEmpty) {
      final String? id = sessions.activeId;
      for (final ChatSession session in sessions.sessions) {
        if (session.id == id) return session.entries;
      }
      return sessions.sessions.first.entries;
    }
    return decodeStoredEntries(prefs.getString(key));
  }

  @override
  Future<void> write(List<ChatEntry> entries) async {
    final SharedPreferences? prefs = await _instance();
    if (prefs == null) return;
    final ChatSessionData? sessions = decodeStoredSessions(
      prefs.getString(sessionsKey),
    );
    if (sessions != null && sessions.sessions.isNotEmpty) {
      final String active = sessions.activeId ?? sessions.sessions.first.id;
      final List<ChatSession> updated = <ChatSession>[
        for (final ChatSession session in sessions.sessions)
          if (session.id == active)
            session.copyWith(entries: entries, updatedAt: DateTime.now())
          else
            session,
      ];
      await prefs.setString(sessionsKey, encodeStoredSessions(updated, active));
      return;
    }
    await prefs.setString(key, encodeStoredEntries(entries));
  }

  @override
  Future<ChatSessionData?> readSessions() async {
    final SharedPreferences? prefs = await _instance();
    if (prefs == null) return null;
    return decodeStoredSessions(prefs.getString(sessionsKey));
  }

  @override
  Future<void> writeSessions(
    List<ChatSession> sessions,
    String? activeId,
  ) async {
    final SharedPreferences? prefs = await _instance();
    if (prefs == null) return;
    await prefs.setString(
      sessionsKey,
      encodeStoredSessions(sessions, activeId),
    );
  }

  @override
  Future<void> wipeSessions() async {
    final SharedPreferences? prefs = await _instance();
    if (prefs == null) return;
    await prefs.remove(sessionsKey);
    await prefs.remove(key);
  }
}

/// The production store: every conversation in one JSON file under the app's
/// private documents directory.
///
/// The legacy SharedPreferences store is kept as the migration source and as
/// the fallback on a platform where the documents folder cannot be reached. The
/// file is the app's own folder, so uninstalling Nexus removes it with the app —
/// there is no cache, no external storage and no backup copy.
const String kChatSessionsFileName = 'nexus_chats.json';
const String kLegacyChatFileName = 'nexus_chat_log.json';

class DocumentsChatLogStore implements ChatLogStore, ChatSessionStore {
  DocumentsChatLogStore({
    Future<Directory?> Function()? directory,
    SharedPrefsChatLogStore? legacy,
  }) : _directory = directory ?? _defaultDirectory,
       _legacy = legacy ?? SharedPrefsChatLogStore();

  final Future<Directory?> Function() _directory;
  final SharedPrefsChatLogStore _legacy;

  /// Saves run one at a time. Two calls that overlap share the same `.tmp`
  /// path, so the first rename wins and the second finds its source gone —
  /// a "PathNotFoundException" on a conversation that saved perfectly well.
  /// Chaining them keeps each write whole and in order.
  Future<void> _writeQueue = Future<void>.value();

  static Future<Directory?> _defaultDirectory() async {
    try {
      final Directory documents = await getApplicationDocumentsDirectory();
      return await Directory('${documents.path}${Platform.pathSeparator}nexus')
          .create(recursive: true);
    } catch (error) {
      debugPrint('CHAT: no documents folder ($error)');
      return null;
    }
  }

  Future<File?> _file(String name) async {
    final Directory? dir = await _directory();
    if (dir == null) return null;
    return File('${dir.path}${Platform.pathSeparator}$name');
  }

  @override
  Future<List<ChatEntry>?> read() async {
    final ChatSessionData? data = await readSessions();
    if (data != null && data.sessions.isNotEmpty) {
      final String? id = data.activeId;
      for (final ChatSession session in data.sessions) {
        if (session.id == id) return session.entries;
      }
      return data.sessions.first.entries;
    }
    final File? legacyFile = await _file(kLegacyChatFileName);
    if (legacyFile != null && await legacyFile.exists()) {
      try {
        return decodeStoredEntries(await legacyFile.readAsString());
      } catch (error) {
        debugPrint('CHAT: could not read the legacy file ($error)');
      }
    }
    return _legacy.read();
  }

  @override
  Future<void> write(List<ChatEntry> entries) async {
    final File? file = await _file(kLegacyChatFileName);
    if (file == null) {
      await _legacy.write(entries);
      return;
    }
    try {
      await file.writeAsString(encodeStoredEntries(entries), flush: true);
    } catch (error) {
      debugPrint('CHAT: could not write the legacy file ($error)');
    }
  }

  @override
  Future<ChatSessionData?> readSessions() async {
    final File? file = await _file(kChatSessionsFileName);
    if (file != null && await file.exists()) {
      try {
        final ChatSessionData? data = decodeStoredSessions(
          await file.readAsString(),
        );
        if (data != null) return data;
      } catch (error) {
        debugPrint('CHAT: could not read the chat file ($error)');
      }
    }
    // A conversation written by a build that kept its sessions in preferences
    // moves into the file the first time this build opens. The copy is written
    // before the old keys are removed, so a crash between the two leaves the
    // conversation in preferences rather than nowhere.
    final ChatSessionData? legacy = await _legacy.readSessions();
    if (legacy == null) return null;
    await writeSessions(legacy.sessions, legacy.activeId);
    return legacy;
  }

  @override
  Future<void> writeSessions(List<ChatSession> sessions, String? activeId) {
    final Future<void> next = _writeQueue.then(
      (_) => _writeSessions(sessions, activeId),
    );
    // The queue must keep draining after a failure, or one bad write would
    // freeze every save that follows it.
    _writeQueue = next.catchError((Object _) {});
    return next;
  }

  Future<void> _writeSessions(
    List<ChatSession> sessions,
    String? activeId,
  ) async {
    final File? file = await _file(kChatSessionsFileName);
    if (file == null) {
      await _legacy.writeSessions(sessions, activeId);
      return;
    }
    try {
      await file.parent.create(recursive: true);
      final File tmp = File('${file.path}.tmp');
      await tmp.writeAsString(
        encodeStoredSessions(sessions, activeId),
        flush: true,
      );
      await tmp.rename(file.path);
      // The file is now the only copy. Removing the legacy keys keeps the same
      // conversation from existing twice on disk.
      await _legacy.wipeSessions();
    } catch (error) {
      debugPrint('CHAT: could not write the chat file ($error)');
    }
  }

  @override
  Future<void> wipeSessions() async {
    await _deleteFile(kChatSessionsFileName);
    await _deleteFile(kLegacyChatFileName);
    await _legacy.wipeSessions();
  }

  Future<void> _deleteFile(String name) async {
    final File? file = await _file(name);
    if (file == null) return;
    try {
      if (await file.exists()) await file.delete();
    } catch (error) {
      debugPrint('CHAT: could not delete $name ($error)');
    }
  }
}

/// A copy of [entry] with [text] in place of its words and every other field —
/// side, flags, picture, and the vision evidence — carried over unchanged.
ChatEntry _rewritten(ChatEntry entry, String text) => ChatEntry(
  text,
  mine: entry.mine,
  failed: entry.failed,
  system: entry.system,
  ok: entry.ok,
  imagePath: entry.imagePath,
  filePath: entry.filePath,
  visionText: entry.visionText,
  visionLabels: entry.visionLabels,
);

/// Applies the one-time history cleanups to [entries], returning the cleaned
/// list and whether anything changed.
List<ChatEntry> _scrubEntries(
  List<ChatEntry> entries,
  void Function(bool changed) changed,
) {
  final List<ChatEntry> cleaned = <ChatEntry>[];
  for (final ChatEntry entry in entries) {
    final bool answer = !entry.mine && !entry.system && !entry.failed;
    if (answer && looksLikeOldVisionNotice(entry.text)) {
      cleaned.add(_rewritten(entry, kVisionActiveText));
      changed(true);
    } else if (answer && looksLikeOldHallucination(entry.text)) {
      cleaned.add(_rewritten(entry, kOldHallucinationText));
      changed(true);
    } else {
      cleaned.add(entry);
    }
  }
  return cleaned;
}

/// The app's conversation, as one object both ends of it listen to.
///
/// The thread screen owns what is on screen; this owns what is remembered. They
/// are kept in step by two calls — [save] when the thread changes, and a listen
/// for the changes the thread does not make itself, [clear] from Settings and a
/// session selected in the drawer.
class ChatLog extends ChangeNotifier {
  ChatLog({ChatLogStore? store, ChatSessionStore? sessions}) {
    final ChatLogStore actual = store ?? DocumentsChatLogStore();
    _store = actual;
    _sessionsStore =
        sessions ??
        (actual is ChatSessionStore ? actual as ChatSessionStore : null);
  }

  /// Test seam, in the same shape as [PairedDevices.override]: a widget test
  /// states where the conversation is kept instead of touching the preferences
  /// plugin. The app never sets it.
  @visibleForTesting
  static ChatLog Function()? override;

  static ChatLog? _instance;

  /// The app-wide log. Built once: two of these would be two answers to "what
  /// did I say a minute ago", and the Settings row would count the wrong one.
  static ChatLog get instance => override?.call() ?? (_instance ??= ChatLog());

  /// Forgets the app-wide instance. Tests use it; the app never does.
  @visibleForTesting
  static void debugReset() => _instance = null;

  late final ChatLogStore _store;
  late final ChatSessionStore? _sessionsStore;

  List<ChatSession> _sessions = const <ChatSession>[];
  String? _activeId;
  bool _attached = false;
  int _sessionSequence = 0;

  /// Every conversation, newest first by the time it was last used. This is
  /// what the drawer groups by date.
  List<ChatSession> get sessions => List<ChatSession>.unmodifiable(_sessions);

  /// The session on screen, or null before the first line has ever been said.
  ChatSession? get activeSession {
    for (final ChatSession session in _sessions) {
      if (session.id == _activeId) return session;
    }
    return _sessions.isEmpty ? null : _sessions.first;
  }

  String? get activeSessionId => activeSession?.id;

  /// The active conversation, oldest first.
  List<ChatEntry> get entries => List<ChatEntry>.unmodifiable(
    activeSession?.entries ?? const <ChatEntry>[],
  );

  /// True when the open conversation has something to come back to — what the
  /// Settings row asks before it offers to delete it.
  bool get hasChat => entries.isNotEmpty;

  /// How many lines are in the open conversation.
  int get length => entries.length;

  /// How many conversations have at least one line.
  int get sessionCount => _sessions
      .where((ChatSession session) => session.entries.isNotEmpty)
      .length;

  ChatSession _newSession() => ChatSession(
    id: 'chat-${DateTime.now().microsecondsSinceEpoch}-${_sessionSequence++}',
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
  );

  /// Reads the stored conversations, once. Called when the thread screen comes
  /// up and again by Settings; the second call costs nothing.
  Future<void> attach() async {
    if (_attached) return;
    _attached = true;
    ChatSessionData? data;
    try {
      data = await _sessionsStore?.readSessions();
    } catch (error) {
      debugPrint('CHAT: could not read sessions ($error)');
    }
    bool migrated = false;
    if (data == null) {
      final List<ChatEntry>? legacy;
      try {
        legacy = await _store.read();
      } catch (error) {
        debugPrint('CHAT: could not read the conversation ($error)');
        return;
      }
      if (legacy == null) return;
      final ChatSession session = ChatSession(
        id: 'chat-legacy',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        entries: legacy,
      );
      data = ChatSessionData(
        sessions: <ChatSession>[session],
        activeId: session.id,
      );
      migrated = true;
    }
    var scrubbed = false;
    final List<ChatSession> cleaned = <ChatSession>[
      for (final ChatSession session in data.sessions)
        session.copyWith(
          entries: _scrubEntries(session.entries, (bool changed) {
            if (changed) scrubbed = true;
          }),
        ),
    ];
    _sessions = cleaned;
    final String? active = data.activeId;
    _activeId = cleaned.any((ChatSession session) => session.id == active)
        ? active
        : (cleaned.isEmpty ? null : cleaned.first.id);
    if (migrated || scrubbed || _activeId != active) _persistSessions();
    notifyListeners();
  }

  /// Replaces the open conversation with [entries] — the thread, as the screen
  /// holds it. Deliberately not awaited by callers: the bubble is already on
  /// screen, and a slow write is not a reason to hold the frame.
  void save(List<ChatEntry> entries) {
    final DateTime now = DateTime.now();
    ChatSession? session = activeSession;
    if (session == null) {
      session = _newSession();
      _sessions = <ChatSession>[..._sessions, session];
      _activeId = session.id;
    }
    final int index = _sessions.indexWhere(
      (ChatSession item) => item.id == session!.id,
    );
    if (index < 0) return;
    _sessions = List<ChatSession>.of(_sessions)
      ..[index] = session.copyWith(
        entries: List<ChatEntry>.of(entries),
        updatedAt: now,
      );
    notifyListeners();
    _persist();
  }

  /// Starts a fresh conversation. An already-empty draft is reused rather than
  /// adding a second empty row to the drawer.
  void newChat() {
    final ChatSession? current = activeSession;
    if (current != null && current.entries.isEmpty) {
      _activeId = current.id;
      notifyListeners();
      _persistSessions();
      return;
    }
    final ChatSession session = _newSession();
    _sessions = <ChatSession>[..._sessions, session];
    _activeId = session.id;
    notifyListeners();
    _persistSessions();
  }

  /// Gives [id] the name the user typed. Unknown ids are ignored, and a blank
  /// name is refused rather than stored: a row with no words is a row that
  /// cannot be found again.
  void renameSession(String id, String title) {
    final String cleaned = title.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (cleaned.isEmpty) return;
    final int index = _sessions.indexWhere((ChatSession item) => item.id == id);
    if (index < 0) return;
    _sessions = List<ChatSession>.of(_sessions)
      ..[index] = _sessions[index].copyWith(customTitle: cleaned);
    notifyListeners();
    _persistSessions();
  }

  /// Pins [id] to the top of the drawer, or unpins it if it is already there.
  void togglePinned(String id) {
    final int index = _sessions.indexWhere((ChatSession item) => item.id == id);
    if (index < 0) return;
    _sessions = List<ChatSession>.of(_sessions)
      ..[index] = _sessions[index].copyWith(pinned: !_sessions[index].pinned);
    notifyListeners();
    _persistSessions();
  }

  /// Makes [id] the conversation on screen. Unknown ids are ignored: a drawer
  /// row that was deleted under a tap must not empty the thread.
  void selectSession(String id) {
    if (!_sessions.any((ChatSession session) => session.id == id)) return;
    if (_activeId == id) return;
    _activeId = id;
    notifyListeners();
    _persistSessions();
  }

  /// Forgets the open conversation — on disk first, because the notification is
  /// what makes the thread screen drop its bubbles, and a screen that emptied
  /// itself while the store still held the lines would hand them back on the
  /// next launch.
  void clear() {
    final ChatSession? session = activeSession;
    if (session == null || session.entries.isEmpty) return;
    final int index = _sessions.indexWhere(
      (ChatSession item) => item.id == session.id,
    );
    if (index < 0) return;
    _sessions = List<ChatSession>.of(_sessions)
      ..[index] = session.copyWith(
        entries: const <ChatEntry>[],
        updatedAt: DateTime.now(),
      );
    notifyListeners();
    _persist();
  }

  /// Forgets the conversations in [ids] — the drawer's multi-select delete.
  ///
  /// Deleting the open conversation does not leave an empty screen pointing at
  /// nothing: the next most recent conversation becomes active, or a fresh draft
  /// takes its place when the last one is gone. Unknown ids are ignored, so a
  /// selection that went stale under the dialog is harmless.
  void deleteSessions(Iterable<String> ids) {
    final Set<String> doomed = ids.toSet();
    if (doomed.isEmpty) return;
    final bool activeGone = _activeId != null && doomed.contains(_activeId);
    final List<ChatSession> kept = <ChatSession>[
      for (final ChatSession session in _sessions)
        if (!doomed.contains(session.id)) session,
    ];
    if (kept.length == _sessions.length) return;
    if (kept.isEmpty) {
      final ChatSession fresh = _newSession();
      _sessions = <ChatSession>[fresh];
      _activeId = fresh.id;
    } else {
      _sessions = kept;
      if (activeGone) {
        _sessions = List<ChatSession>.of(kept)
          ..sort(
            (ChatSession a, ChatSession b) =>
                b.updatedAt.compareTo(a.updatedAt),
          );
        _activeId = _sessions.first.id;
      }
    }
    notifyListeners();
    _persistSessions();
  }

  /// Forgets every conversation. Used by Settings → Privacy's one destructive
  /// button; the caller also clears the remembered facts and attachments.
  Future<void> clearAll() async {
    _sessions = const <ChatSession>[];
    _activeId = null;
    _sessions = <ChatSession>[_newSession()];
    _activeId = _sessions.first.id;
    notifyListeners();
    if (_sessionsStore != null) {
      try {
        await _sessionsStore.wipeSessions();
      } catch (error) {
        debugPrint('CHAT: could not wipe sessions ($error)');
      }
    } else {
      try {
        await _store.write(const <ChatEntry>[]);
      } catch (error) {
        debugPrint('CHAT: could not wipe the conversation ($error)');
      }
    }
  }

  /// Writes the whole session list, including the active id.
  void _persistSessions() {
    final ChatSessionStore? store = _sessionsStore;
    if (store == null) {
      _persist();
      return;
    }
    final List<ChatSession> snapshot = List<ChatSession>.of(_sessions);
    final String? active = _activeId;
    store.writeSessions(snapshot, active).catchError((Object error) {
      debugPrint('CHAT: could not store sessions ($error)');
    });
  }

  /// Writes the open conversation back. Deliberately not awaited by callers,
  /// and never a failure the user hears about: losing a write costs one
  /// launch's memory, and there is nothing they could do about it.
  void _persist() {
    final ChatSessionStore? sessions = _sessionsStore;
    if (sessions != null) {
      _persistSessions();
      return;
    }
    final List<ChatEntry> snapshot = List<ChatEntry>.of(entries);
    _store.write(snapshot).catchError((Object error) {
      debugPrint('CHAT: could not store the conversation ($error)');
    });
  }
}
