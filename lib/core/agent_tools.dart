// The tools the local model may ask for, in one place: what they are, the
// block that tells the model they exist, the parser for the model's call, the
// safety gate that decides whether the user's ask implied it, and the runner
// that does the real work.
//
// Both tools are read-only — a folder listing and a file fetch — and that is
// the boundary, not a promise: there is no delete, no move, no write, and no
// way for the model to invent one. The second boundary is [toolRefusal]: a
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
  getFile('get_file');

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
  };
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
String toolSystemPrompt(String system) => '''
$system

You can also run two read-only tools on this device when the user asks:
- list_local_files {"dir": "Downloads"} — lists what is in one of the user's folders. "dir" is exactly one of: Downloads, Documents, Pictures.
- get_file {"name": "report.pdf", "from": "My PC"} — fetches a file the user named from one of their paired devices. "from" may be left out.

To run one, reply with exactly one line and nothing else:
TOOL:<name> {"arg": "value"}

For example, the user asks "what's in my Downloads?" — reply exactly:
TOOL:list_local_files {"dir": "Downloads"}

Call a tool only when the user's message asks for it. If no tool is needed, just answer normally. After a tool runs you will be told what it found; then answer the user in one or two short sentences from that result. Never invent file names. You cannot delete, move or change anything — say so if asked.''';

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
/// real boundary is the tool set itself: both tools only read.
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
  }
  return null;
}

/// The real work behind a tool call: one sentence describing what happened.
/// The one this device uses is [LocalToolRunner]; a test hands the loop a spy.
abstract class ToolRunner {
  Future<String> run(ToolCall call);
}

/// The tools, done for real: a folder listed on this device and a file
/// fetched from a paired one through the *existing* fetch.
///
/// Both are seams. [roots] resolves where the three folders are (a test points
/// them at a temp directory; the product uses [localFolders]), and [fetch]
/// runs the fetch the view hands in — the same resolution and the same
/// executor a typed "get report.pdf" runs, so the tool path cannot drift from
/// the typed one.
class LocalToolRunner implements ToolRunner {
  LocalToolRunner({
    required this.fetch,
    Future<Map<String, String>> Function()? roots,
  }) : _roots = roots ?? localFolders;

  /// Fetches [name] (possibly from [from]) and answers what the fetch said.
  final Future<String> Function(String name, String? from) fetch;

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
