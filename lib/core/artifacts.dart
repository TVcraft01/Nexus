// Artifacts: a file the assistant wrote *inside* its reply.
//
// A model asked for code has always been able to produce it, but only as a
// fenced block in the middle of a paragraph: the user had to select the block,
// copy it, open a file manager and paste it somewhere. An `<artifact>` block is
// the same text with an address — a filename, a language, and a card in the
// thread — so the reply can be *kept* rather than copied.
//
// The format is deliberately tiny and readable:
//
//   <artifact filename="hello.py" language="python">
//   print("hello")
//   </artifact>
//
// Parsing lives in core rather than in the widget for the usual reason: the
// bubble, the streaming path, and the tests all need the same answer about
// where the prose stops and the file begins. A half-written block is the
// common case while the model is still typing, so [streaming] trims a dangling
// opening tag instead of printing it in large type.
import 'package:flutter/foundation.dart' show immutable;

/// One file the assistant wrote, with the two labels the card shows.
@immutable
class NexusArtifact {
  const NexusArtifact({
    required this.filename,
    required this.language,
    required this.code,
  });

  /// The name the user would save it as. Never a path: a model that writes
  /// `../../etc/passwd` gets a file called `passwd`, because the card is a
  /// suggestion and the app chooses where it lands.
  final String filename;

  /// The language label. Empty when the model did not say; the card says
  /// "Text" instead of inventing one.
  final String language;

  /// The block's body, exactly as written — no trimming of indentation, which
  /// is the one thing that would change what the code means.
  final String code;

  /// The word on the card: the language, or "Text" when there is none.
  String get languageLabel =>
      language.trim().isEmpty ? 'Text' : language.trim();

  /// A filename that is safe to write: no separators, no leading dot, and a
  /// fallback for a model that forgot the attribute.
  String get safeFilename {
    final String base = filename
        .replaceAll('\\', '/')
        .split('/')
        .last
        .trim()
        .replaceAll(RegExp(r'^\.+'), '');
    final String cleaned = base.replaceAll(RegExp(r'[^A-Za-z0-9._\- ]'), '_');
    return cleaned.isEmpty ? 'artifact.txt' : cleaned;
  }
}

/// A reply split into what to say and what to save.
@immutable
class NexusArtifactSplit {
  const NexusArtifactSplit({required this.prose, required this.artifacts});

  /// The reply with every artifact block removed: what the bubble reads.
  final String prose;

  /// The files it wrote, in the order they appeared.
  final List<NexusArtifact> artifacts;

  bool get hasArtifacts => artifacts.isNotEmpty;
}

/// Matches a complete block. The attribute order is the model's business, and
/// both `filename`/`language` are optional by the time the body is found: a
/// block without a name is still code the user can read.
final RegExp _artifactBlock = RegExp(
  r'<artifact\b([^>]*)>([\s\S]*?)</artifact>',
  caseSensitive: false,
);

final RegExp _artifactOpen = RegExp(r'<artifact\b', caseSensitive: false);

final RegExp _attribute = RegExp(
  r'''(filename|language|name|lang)\s*=\s*["']([^"']*)["']''',
  caseSensitive: false,
);

/// Splits [text] into the prose and the artifacts it carries.
///
/// [streaming] is true while the model is still writing. It changes one thing:
/// a block whose opening tag has arrived but whose closing tag has not is cut
/// from the prose, so the user never sees raw `<artifact filename=…>` on
/// screen. The same block is returned as an artifact only once it is whole —
/// half a file is not a file.
NexusArtifactSplit splitNexusArtifacts(String text, {bool streaming = false}) {
  final List<NexusArtifact> found = <NexusArtifact>[];
  String prose = text.replaceAllMapped(_artifactBlock, (Match match) {
    final Map<String, String> attributes = _attributesOf(match.group(1) ?? '');
    found.add(
      NexusArtifact(
        filename:
            attributes['filename'] ??
            attributes['name'] ??
            'artifact.${_extensionFor(attributes['language'] ?? attributes['lang'] ?? '')}',
        language: attributes['language'] ?? attributes['lang'] ?? '',
        code: match.group(2) ?? '',
      ),
    );
    return '';
  });

  final bool dangling = streaming && _hasOpenBlockWithoutClose(prose);
  if (dangling) {
    prose = prose.substring(0, _artifactOpen.allMatches(prose).last.start);
  }

  return NexusArtifactSplit(
    prose: _tidy(prose, streaming: streaming),
    artifacts: found,
  );
}

/// Whether [text] contains an opening tag whose block has not closed. Used by
/// the streaming path to decide whether to keep waiting for the rest.
bool _hasOpenBlockWithoutClose(String text) {
  final int opens = _artifactOpen.allMatches(text).length;
  final int closes = RegExp(
    r'</artifact>',
    caseSensitive: false,
  ).allMatches(text).length;
  return opens > closes;
}

Map<String, String> _attributesOf(String raw) {
  final Map<String, String> out = <String, String>{};
  for (final RegExpMatch match in _attribute.allMatches(raw)) {
    out[match.group(1)!.toLowerCase()] = match.group(2)!.trim();
  }
  return out;
}

/// A filename for a block that forgot one, from its language.
String _extensionFor(String language) {
  return switch (language.trim().toLowerCase()) {
    'dart' => 'dart',
    'python' || 'py' => 'py',
    'javascript' || 'js' => 'js',
    'typescript' || 'ts' => 'ts',
    'json' => 'json',
    'html' => 'html',
    'css' => 'css',
    'sql' => 'sql',
    'bash' || 'sh' || 'shell' => 'sh',
    'yaml' || 'yml' => 'yaml',
    'kotlin' => 'kt',
    'swift' => 'swift',
    'java' => 'java',
    'c' => 'c',
    'cpp' || 'c++' => 'cpp',
    'markdown' || 'md' => 'md',
    _ => 'txt',
  };
}

/// Trims the edges and no more than three consecutive blank lines. A bubble
/// with the block cut out has a hole where the block was; two newlines read as
/// a paragraph, six read as a mistake.
///
/// While the model is still writing, the *trailing* whitespace is kept: it is
/// the space between the word that just arrived and the one after it, and
/// trimming it drew "One,two," on screen until the next token landed.
String _tidy(String text, {bool streaming = false}) {
  final String collapsed = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return streaming ? collapsed.trimLeft() : collapsed.trim();
}
