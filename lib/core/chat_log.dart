// The conversation, saved between launches.
//
// A chat that forgets is not an assistant, it is a search box: the user's
// second question is usually about the first answer, and an app that opens on
// the welcome screen every morning throws the thing they were working on away.
// So the thread lives on disk, and this file is the one place that knows how it
// gets there and what it is made of.
//
// Deliberately a *store of lines* rather than the screen's message type: a
// bubble is a drawing decision (this one is mine, that one is still being
// written), and a file that carried it would be a file that has to be migrated
// every time the shell changes how it paints. [ChatEntry] is the smallest thing
// that can be read back into a bubble — who said it, what they said, and whether
// it was the shell admitting it could not answer.
//
// The shape follows `paired_devices.dart`, which is the pattern this app already
// uses for "a list the user owns": an injectable [ChatLogStore] (in memory in
// tests, one JSON string in preferences on a phone), a [ChangeNotifier]
// singleton so the two screens that care — the thread and the Settings row that
// clears it — cannot disagree, and a `debugReset`/`override` seam for tests.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart'
    show ChangeNotifier, debugPrint, immutable, visibleForTesting;
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
  };

  /// Reads one stored line. Null for anything that is not one — a file half
  /// written by a killed process is not a reason to lose the rest of it.
  static ChatEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? text = raw['text'];
    if (text is! String || text.trim().isEmpty) return null;
    final Object? image = raw['image'];
    final Object? file = raw['file'];
    return ChatEntry(
      text,
      mine: raw['mine'] == true,
      failed: raw['failed'] == true,
      system: raw['system'] == true,
      ok: raw['ok'] != false,
      imagePath: image is String && image.isNotEmpty ? image : null,
      filePath: file is String && file.isNotEmpty ? file : null,
    );
  }

  @override
  String toString() => 'ChatEntry(${mine ? 'me' : 'nexus'}: $text)';
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

/// SharedPreferences-backed store used in production: one JSON list under one
/// key, which is what a conversation of this size is.
///
/// A file in the documents directory would do as well; a preference is chosen
/// because the app already keeps the other list a user owns (their paired
/// devices) the same way, and one place to look for "what survives a restart"
/// is worth more than a second mechanism that is marginally faster.
///
/// A store that is not there — a desktop run, a widget test — refuses to fail:
/// reads answer null and writes do nothing, so a missing plugin costs the
/// session's memory of the chat and never the screen.
class SharedPrefsChatLogStore implements ChatLogStore {
  /// The key the list is stored under.
  static const String key = 'chat_log';

  SharedPreferences? _prefs;

  Future<SharedPreferences?> _instance() async {
    try {
      return _prefs ??= await SharedPreferences.getInstance();
    } catch (error) {
      debugPrint('CHAT: no preferences store ($error)');
      return null;
    }
  }

  @override
  Future<List<ChatEntry>?> read() async {
    final String? raw = (await _instance())?.getString(key);
    if (raw == null) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      // Corrupt is not the same as absent, but the honest recovery is: start
      // empty rather than refuse to open the app.
      debugPrint('CHAT: the stored conversation could not be read');
      return null;
    }
    if (decoded is! List) return null;
    final entries = <ChatEntry>[];
    for (final Object? row in decoded) {
      final ChatEntry? entry = ChatEntry.fromJson(row);
      if (entry != null) entries.add(entry);
    }
    return entries;
  }

  @override
  Future<void> write(List<ChatEntry> entries) async {
    final SharedPreferences? prefs = await _instance();
    if (prefs == null) return;
    await prefs.setString(
      key,
      jsonEncode(entries.map((ChatEntry e) => e.toJson()).toList()),
    );
  }
}

/// The app's conversation, as one object both ends of it listen to.
///
/// The thread screen owns what is on screen; this owns what is remembered. They
/// are kept in step by two calls — [save] when the thread changes, and a listen
/// for the one change the thread does not make itself, [clear] from Settings.
class ChatLog extends ChangeNotifier {
  ChatLog({ChatLogStore? store}) : _store = store ?? SharedPrefsChatLogStore();

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

  final ChatLogStore _store;
  List<ChatEntry> _entries = const <ChatEntry>[];
  bool _attached = false;

  /// The conversation, oldest first.
  List<ChatEntry> get entries => List<ChatEntry>.unmodifiable(_entries);

  /// True when there is something to come back to — what the Settings row asks
  /// before it offers to delete it.
  bool get hasChat => _entries.isNotEmpty;

  /// How many lines are remembered.
  int get length => _entries.length;

  /// Reads the stored conversation, once. Called when the thread screen comes
  /// up and again by Settings; the second call costs nothing and a call with no
  /// store at all leaves the memory alone.
  Future<void> attach() async {
    if (_attached) return;
    _attached = true;
    final List<ChatEntry>? stored = await _store.read();
    if (stored == null) return;
    // One-time history cleanup at launch. Old model answers that were stored as
    // `song: …` records are not something the user can act on, and a prompt
    // change cannot repair what is already on disk — only a migration can.
    // The user's own lines are never touched: they may legitimately write
    // "title: …" and the app has no business editing their words.
    var scrubbed = false;
    final List<ChatEntry> cleaned = <ChatEntry>[];
    for (final ChatEntry entry in stored) {
      if (!entry.mine &&
          !entry.system &&
          !entry.failed &&
          looksLikeOldHallucination(entry.text)) {
        cleaned.add(
          ChatEntry(
            kOldHallucinationText,
            imagePath: entry.imagePath,
            filePath: entry.filePath,
          ),
        );
        scrubbed = true;
      } else {
        cleaned.add(entry);
      }
    }
    _entries = cleaned;
    if (scrubbed) _persist();
    notifyListeners();
  }

  /// Replaces what is remembered with [entries] — the thread, as the screen
  /// holds it. Deliberately not awaited by callers: the bubble is already on
  /// screen, and a slow write is not a reason to hold the frame.
  void save(List<ChatEntry> entries) {
    _entries = List<ChatEntry>.of(entries);
    notifyListeners();
    _persist();
  }

  /// Forgets the conversation — on disk first, because the notification is what
  /// makes the thread screen drop its bubbles, and a screen that emptied itself
  /// while the store still held the lines would hand them back on the next
  /// launch.
  void clear() {
    if (_entries.isEmpty) return;
    _entries = const <ChatEntry>[];
    notifyListeners();
    _persist();
  }

  /// Writes the conversation back. Deliberately not awaited by callers, and
  /// never a failure the user hears about: losing a write costs one launch's
  /// memory, and there is nothing they could do about it.
  void _persist() {
    final List<ChatEntry> snapshot = List<ChatEntry>.of(_entries);
    _store.write(snapshot).catchError((Object error) {
      debugPrint('CHAT: could not store the conversation ($error)');
    });
  }
}
