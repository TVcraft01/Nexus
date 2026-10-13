// The tools the local model may ask for, in one place: what they are, the
// block that tells the model they exist, the parser for the model's call, the
// safety gate that decides whether the user's ask implied it, and the runner
// that does the real work.
//
// Two of the three tools are read-only — a folder listing and a file
// fetch — and that is the boundary, not a promise: there is no delete, no
// move, no write, and no way for the model to invent one. The third tool
// sets a reminder, which is the one action the model may take beyond
// reading. The second boundary is [toolRefusal]: a
// tool runs only when the user's own message asked for the thing it does, so
// even a model that reaches for a tool on "delete everything" gets nothing.
//
// The protocol is a prompt template rather than native function calling,
// because the seam the loop runs against ([LocalBrain.reply]) is one text
// request and one text answer. Qwen2.5's own template may support tool calls
// through the runtime, but that lives behind a different API and is not what
// the phone's tiny-brain channel and the desktop's Ollama fallback share; a
// protocol both understand is worth more than a native call one of them
// cannot make. A missing or fumbled TOOL line is a plain answer — never a
// crash, and never protocol syntax shown to the user.
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart'
    show getApplicationDocumentsDirectory;

import 'reminders.dart';
import 'storage_roots.dart';

/// The three folders a person names by name, in the words they use.
const List<String> namedFolders = ['Downloads', 'Documents', 'Pictures'];

/// One tool the model can call. The wire name is what the model writes; the
/// set is deliberately tiny.
enum NexusTool {
  /// "what's in my downloads" — the file names in one of the user's folders.
  listLocalFiles('list_local_files'),

  /// "get report.pdf from my pc" for phrasings the parser did not catch —
  /// the existing file fetch, run from the model's side.
  getFile('get_file'),

  /// "remind me to take milk at 6" for phrasings the parser did not
  /// catch — the existing reminder engine, run from the model's side.
  /// Time only: a "when" the parser cannot place in time asks the user
  /// to clarify instead of setting a wrong reminder.
  setReminder('set_reminder');

  const NexusTool(this.name);

  final String name;

  /// The tool a model-named tool is, or null when nothing here has that name.
  /// An unknown name is never runnable — the parser refuses it first.
  static NexusTool? byName(String name) {
    final wanted = name.trim().toLowerCase();
    for (final tool in values) {
      if (tool.name == wanted) return tool;
    }
    return null;
  }
}

/// The folder a model-named `dir` means, canonicalized to [namedFolders], or
/// null when it named none of them. Tolerant on the words a small model
/// reaches for ("my downloads", "docs", "photos") — the alternative is a
/// conversation about spelling.
String? folderNamed(String name) {
  var key = name.trim().toLowerCase();
  key = key.replaceFirst(RegExp(r'^(?:my|the|your)\s+'), '');
  for (final folder in namedFolders) {
    final lower = folder.toLowerCase();
    if (key == lower || key == lower.replaceFirst(RegExp(r's$'), '')) {
      return folder;
    }
  }
  return switch (key) {
    'doc' || 'docs' => 'Documents',
    'pic' || 'pics' || 'photo' || 'photos' => 'Pictures',
    _ => null,
  };
}

/// One tool call, as the model asked for it: which tool, with what arguments.
class ToolCall {
  const ToolCall(this.tool, [this.arguments = const {}]);

  final NexusTool tool;
  final Map<String, dynamic> arguments;

  String get name => tool.name;

  /// The folder for [NexusTool.listLocalFiles], canonicalized — null when the
  /// model named none of the three.
  String? get folder => folderNamed(
    (arguments['dir'] ?? arguments['folder'] ?? arguments['path'] ?? '')
        .toString(),
  );

  /// The file for [NexusTool.getFile].
  String get file =>
      (arguments['name'] ?? arguments['file'] ?? '').toString().trim();

  /// The device a fetch should come from, without the article a person adds
  /// ("my pc" and "the pc" both resolve as "pc", exactly like a typed fetch).
  String get from => (arguments['from'] ?? arguments['device'] ?? '')
      .toString()
      .trim()
      .replaceFirst(RegExp(r'^(?:from|on)\s+'), '')
      .replaceFirst(RegExp(r'^(?:my|the|your)\s+'), '');

  /// What the card says while this call runs — the same sentence the thinking
  /// placeholder would have carried, made specific.
  String get runningLabel => switch (tool) {
    NexusTool.listLocalFiles => 'Looking in ${folder ?? 'your files'}…',
    NexusTool.getFile => file.isEmpty ? 'Fetching your file…' : 'Fetching $file…',
    NexusTool.setReminder => 'Setting your reminder…',
  };

  /// What to be reminded about: "take milk".
  String get reminderWhat =>
      (arguments['what'] ?? arguments['text'] ?? '').toString().trim();

  /// When the reminder should fire, in the model's own words: "18:00",
  /// "in 20 minutes", "tomorrow at 9". Placed in time by
  /// [parseReminderWhen]; empty when the model named none.
  String get reminderWhen =>
      (arguments['when'] ?? arguments['at'] ?? '').toString().trim();
}

/// One model reply, read as a possible tool call: [call] is the tool it asked
/// for (null when it asked for none, or fumbled one), and [text] is what is
/// left of the reply once any `TOOL:` line is removed — the answer to give
/// when there is no runnable call. Protocol syntax never survives into
/// [text], so a fumbled line cannot reach the user as gibberish.
class ToolRequest {
  const ToolRequest(this.call, this.text);

  final ToolCall? call;
  final String text;
}

/// The marker that starts a tool line, wherever it sits on its line.
final RegExp _toolMarker = RegExp(r'(?:^|\s)tool\s*:\s*', caseSensitive: false);

/// The tool name directly after the marker: letters and underscores only.
final RegExp _toolName = RegExp(r'^([a-z_]+)', caseSensitive: false);

/// Reads [reply] as a tool request. Only the first well-formed call counts;
/// every `TOOL:` line is dropped from the text either way.
ToolRequest readToolRequest(String reply) {
  final kept = <String>[];
  ToolCall? call;
  for (final line in reply.split('\n')) {
    final marker = _toolMarker.firstMatch(line);
    if (marker == null) {
      kept.add(line);
      continue;
    }
    // Words before the marker ("Sure — TOOL:…") are the model's own, so they
    // stay; everything from the marker on is protocol.
    final before = line.substring(0, marker.start).trim();
    if (before.isNotEmpty) kept.add(before);
    call ??= _callIn(line.substring(marker.end).trim());
  }
  return ToolRequest(call, kept.join('\n').trim());
}

/// The call a `TOOL:` line names, or null when the line is malformed: an
/// unknown tool, a tool with no name, or arguments that are not a JSON object.
/// A call with no arguments at all is well-formed — the tool asks for what
/// it needs ("Which folder?").
ToolCall? _callIn(String rest) {
  final name = _toolName.firstMatch(rest)?.group(1) ?? '';
  final tool = NexusTool.byName(name);
  if (tool == null) return null;
  final args = rest.substring(name.length).trim();
  if (args.isEmpty) return ToolCall(tool);
  if (!args.startsWith('{') || !args.endsWith('}')) return null;
  try {
    final decoded = jsonDecode(args);
    if (decoded is! Map) return null;
    return ToolCall(tool, Map<String, dynamic>.from(decoded));
  } on FormatException {
    return null;
  }
}

/// The tool block appended to the assistant's own system prompt, with the
/// protocol the loop parses. Kept beside the parser on purpose: the words the
/// model is told and the words it is read by cannot drift apart in one file.
///
/// [pairedDevices] are the user's real paired device names, read at prompt
/// time. The get_file example names one of them — never a hardcoded example
/// a small model would copy verbatim — and with zero paired devices the
/// get_file tool is not offered at all: a tool for a capability the user
/// doesn't have is a lie the model hallucinates around.
String toolSystemPrompt(String system, {List<String> pairedDevices = const []}) {
  final names = <String>[
    for (final raw in pairedDevices)
      if (raw.trim().isNotEmpty) raw.trim(),
  ];
  final getFileLine = names.isEmpty
      ? ''
      : '\n- get_file {"name": "report.pdf", "from": "${names.first}"} — fetches a file the user named from one of their paired devices. Your paired devices: ${names.join(', ')}. "from" may be left out.';
  final fileCount = names.isEmpty ? 'one read-only tool' : 'two read-only tools';
  return '''
$system

You can also run $fileCount on this device when the user asks, plus set a reminder:
- list_local_files {"dir": "Downloads"} — lists what is in one of the user's folders. "dir" is exactly one of: Downloads, Documents, Pictures.$getFileLine
- set_reminder {"what": "take milk", "when": "18:00"} — sets a reminder that fires a notification at that time. "when" is a time today like "18:00" or "6pm", a relative time like "in 20 minutes" or "in 2 hours", or "tomorrow at 9".

To run one, reply with exactly one line and nothing else:
TOOL:<name> {"arg": "value"}

For example, the user asks "what's in my Downloads?" — reply exactly:
TOOL:list_local_files {"dir": "Downloads"}

For example, the user asks "remind me to take milk at 6pm" — reply exactly:
TOOL:set_reminder {"what": "take milk", "when": "18:00"}

Call a tool only when the user's message asks for it. If no tool is needed, just answer normally. After a tool runs you will be told what it found; then answer the user in one or two short sentences from that result. Never invent file names. You cannot delete, move or change anything — say so if asked.''';
}

/// Places the model's [raw] "when" in time, or null when it names no time
/// this tool understands. Three forms, no date library — the model is told
/// exactly these, so anything else is the model improvising and the caller
/// asks the user to clarify rather than setting a wrong reminder:
/// - absolute: "18:00", "6pm", "6:30pm", "18" (today; already past
///   rolls to tomorrow — a reminder must ring in the future);
/// - relative: "in 20 minutes", "in 2 hours";
/// - day-anchored: "tomorrow at 9", "today at 9:30".
DateTime? parseReminderWhen(String raw, DateTime now) {
  var text = raw.trim().toLowerCase();
  if (text.isEmpty) return null;
  // A small model may keep the preposition ("at 6pm"): forgive it.
  text = text.replaceFirst(RegExp(r'^at\s+'), '');

  // "in 20 minutes" / "in 2 hours" — relative to now.
  final rel = RegExp(
    r'^in\s+(\d+)\s*(minutes?|mins?|hours?|hrs?)$',
  ).firstMatch(text);
  if (rel != null) {
    final n = int.tryParse(rel.group(1)!) ?? 0;
    if (n <= 0) return null;
    final hours = rel.group(2)!.startsWith('h');
    return now.add(Duration(seconds: n * (hours ? 3600 : 60)));
  }

  DateTime atTime(int hour, int minute) =>
      DateTime(now.year, now.month, now.day, hour, minute);

  // "tomorrow at 9" / "tomorrow at 9:30pm" — and "today at …" the same
  // way, without the roll-forward below (today means today).
  final day = RegExp(
    r'^(tomorrow|today)\s+at\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$',
  ).firstMatch(text);
  if (day != null) {
    final time = _clockParts(day.group(2)!, day.group(3), day.group(4));
    if (time == null) return null;
    final base = DateTime(now.year, now.month, now.day);
    final anchor = day.group(1) == 'tomorrow'
        ? base.add(const Duration(days: 1))
        : base;
    return DateTime(anchor.year, anchor.month, anchor.day, time.$1, time.$2);
  }

  // "18:00" / "6pm" / "6:30pm" / "18" — today, or tomorrow when that
  // time already passed (a reminder in the past would fire at once, which
  // is never what "remind me at 6" meant after 6).
  final abs = RegExp(r'^(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$').firstMatch(text);
  if (abs != null) {
    final time = _clockParts(abs.group(1)!, abs.group(2), abs.group(3));
    if (time == null) return null;
    var due = atTime(time.$1, time.$2);
    if (!due.isAfter(now)) due = due.add(const Duration(days: 1));
    return due;
  }
  return null;
}

/// An hour and minute from the model's words, or null when they are not a
/// clock time. 12-hour words need their meridiem ("6" alone is 06:00 only
/// when the model wrote no am/pm — bare "13" is 13:00); out-of-range is
/// out, never wrapped.
(int, int)? _clockParts(String hourRaw, String? minuteRaw, String? meridiemRaw) {
  final hourIn = int.tryParse(hourRaw) ?? -1;
  final minute = minuteRaw == null ? 0 : (int.tryParse(minuteRaw) ?? -1);
  if (minute < 0 || minute > 59) return null;
  final meridiem = meridiemRaw?.toLowerCase();
  if (meridiem == 'am' || meridiem == 'pm') {
    if (hourIn < 1 || hourIn > 12) return null;
    var hour = hourIn % 12;
    if (meridiem == 'pm') hour += 12;
    return (hour, minute);
  }
  if (hourIn < 0 || hourIn > 23) return null;
  return (hourIn, minute);
}

/// A due time in the words the confirmation uses: "6:00pm".
String reminderClockLabel(DateTime dueAt) {
  final hour = dueAt.hour;
  final meridiem = hour < 12 ? 'am' : 'pm';
  final twelve = hour % 12 == 0 ? 12 : hour % 12;
  final mm = dueAt.minute.toString().padLeft(2, '0');
  return '$twelve:$mm$meridiem';
}

/// A folder or a file named in the ask: "what's in my downloads" implies a
/// listing, and a word with an extension implies a file.
final RegExp _fileWords = RegExp(
  r'\b(files?|folders?|director(y|ies)|dir|downloads?|documents?|docs?|'
  r'pictures?|photos?|pics?)\b',
);
final RegExp _fetchVerbs = RegExp(
  r'\b(get|fetch|grab|pull|bring|send|copy|find|download|give)\b',
);
final RegExp _namedFile = RegExp(r'\b[\w-]+\.[a-z0-9]{1,8}\b');

/// Why the tool the model asked for must NOT run for [ask], or null when it
/// may. The model chooses; this decides.
///
/// The rule is the user's own words: a tool may only run when the ask implies
/// the thing the tool does. "What's in my Downloads" implies a listing;
/// "delete everything" implies nothing that exists here, so no tool runs no
/// matter what the model wrote. The check is deliberately generous — a missed
/// implication costs a conversational answer, not an action — because the
/// real boundary is the tool set itself: two tools only read, and the
/// reminder tool only promises.
final RegExp _remindWords = RegExp(r'\bremind\b');

String? toolRefusal(ToolCall call, String ask) {
  final text = ask.toLowerCase();
  switch (call.tool) {
    case NexusTool.listLocalFiles:
      if (!_fileWords.hasMatch(text)) {
        return 'the ask does not mention files or folders';
      }
    case NexusTool.getFile:
      if (call.file.isEmpty) return 'the ask named no file to get';
      if (!_fetchVerbs.hasMatch(text) && !_namedFile.hasMatch(text)) {
        return 'the ask does not ask for a file';
      }
    case NexusTool.setReminder:
      if (!_remindWords.hasMatch(text)) {
        return 'the ask does not ask for a reminder';
      }
  }
  return null;
}

/// The real work behind a tool call: one sentence describing what happened.
/// The one this device uses is [LocalToolRunner]; a test hands the loop a spy.
abstract class ToolRunner {
  Future<String> run(ToolCall call);
}

/// The tools, done for real: a folder listed on this device, a file
/// fetched from a paired one through the *existing* fetch, and a reminder
/// registered with the *existing* engine.
///
/// All three are seams. [roots] resolves where the three folders are (a test
/// points them at a temp directory; the product uses [localFolders]),
/// [fetch] runs the fetch the view hands in — the same resolution and the
/// same executor a typed "get report.pdf" runs, so the tool path cannot
/// drift from the typed one — and [remind] registers with the reminder
/// engine the view owns, so a tool-set reminder fires, persists, and syncs
/// exactly like a typed one.
class LocalToolRunner implements ToolRunner {
  LocalToolRunner({
    required this.fetch,
    Future<Map<String, String>> Function()? roots,
    this.remind,
  }) : _roots = roots ?? localFolders;

  /// Fetches [name] (possibly from [from]) and answers what the fetch said.
  final Future<String> Function(String name, String? from) fetch;

  /// Registers a reminder for [what] at [when] and answers what the engine
  /// said. Null in tests that never set reminders — a set_reminder call
  /// then confirms without registering, so the prompt and the gate stay
  /// testable without an engine.
  final Future<String> Function(String what, DateTime when)? remind;

  final Future<Map<String, String>> Function() _roots;

  /// How many names one listing shows before it stops. Enough to answer
  /// "what's in there", short enough to leave room for the conversation in a
  /// 0.5B model's context.
  static const int listedNames = 25;

  @override
  Future<String> run(ToolCall call) async {
    switch (call.tool) {
      case NexusTool.listLocalFiles:
        return _list(call.folder);
      case NexusTool.getFile:
        final file = call.file;
        if (file.isEmpty) return 'Which file should I get?';
        final from = call.from;
        return fetch(file, from.isEmpty ? null : from);
      case NexusTool.setReminder:
        final what = call.reminderWhat;
        if (what.isEmpty) return 'What should I remind you about?';
        final when = parseReminderWhen(call.reminderWhen, Reminders.now());
        if (when == null) {
          // The model named a time this tool cannot place — a wrong
          // reminder is worse than a question, so ask for the time in
          // words the parser understands.
          return 'What time should I remind you to $what? '
              'A time like 6pm, in 20 minutes, or tomorrow at 9.';
        }
        final register = remind;
        if (register == null) {
          return 'Reminder set for ${reminderClockLabel(when)} — '
              "I'll tell you then.";
        }
        return register(what, when);
    }
  }

  /// Lists one folder, in words the model can answer from and a person could
  /// read directly if the model has nothing to add. An empty folder, a folder
  /// that is not there, and a folder that cannot be read are three different
  /// truths, and each is said as itself.
  Future<String> _list(String? folder) async {
    if (folder == null) {
      return 'Which folder? I can look in Downloads, Documents or Pictures.';
    }
    final path = (await _roots())[folder.toLowerCase()] ?? '';
    if (path.isEmpty) {
      return "I can't see the $folder folder on this device.";
    }
    final directory = Directory(path);
    if (!directory.existsSync()) return 'There is no $folder folder here yet.';
    final List<FileSystemEntity> entries;
    try {
      entries = directory.listSync(followLinks: false);
    } on FileSystemException {
      return "I couldn't read the $folder folder.";
    }
    if (entries.isEmpty) return 'The $folder folder is empty.';
    final names = [
      for (final entry in entries)
        '${entry.path.split(Platform.pathSeparator).last}'
            '${entry is Directory ? '/' : ''}',
    ]..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    final shown = names.take(listedNames).join(', ');
    final more = names.length > listedNames
        ? ', and ${names.length - listedNames} more'
        : '';
    final count = names.length == 1 ? '1 item' : '${names.length} items';
    return 'The $folder folder has $count: $shown$more.';
  }
}

/// Where the three folders are on this device, resolved the way Nexus
/// resolves storage everywhere else: Downloads through [downloadRoot] (the
/// shared folder on Android once "All files access" is granted, the app's own
/// fallback otherwise), the user's home folders on a desktop, and on Android
/// without the toggle whatever of the user's own storage Nexus is allowed to
/// see. An empty path means "not visible on this device" — the runner says
/// that instead of listing somebody else's folder.
Future<Map<String, String>> localFolders() async {
  final downloads = (await downloadRoot()).path;
  final separator = Platform.pathSeparator;
  String? documents;
  String? pictures;
  if (Platform.isAndroid) {
    final shared = await sharedStorageRoot();
    if (await allFilesAccess() && shared != null && shared.isNotEmpty) {
      documents = '$shared${separator}Documents';
      pictures = '$shared${separator}Pictures';
    } else {
      // Without the toggle, the app's own documents folder is the only
      // Documents Nexus can see; Pictures is not visible at all.
      documents = await _appDocuments();
    }
  } else {
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home != null && home.isNotEmpty) {
      documents = '$home${separator}Documents';
      pictures = '$home${separator}Pictures';
    }
  }
  return {
    'downloads': downloads,
    'documents': documents ?? '',
    'pictures': pictures ?? '',
  };
}

Future<String?> _appDocuments() async {
  try {
    return (await getApplicationDocumentsDirectory()).path;
  } catch (_) {
    return null;
  }
}
