// What a reply means when it writes a file.
//
// The bubble, the streaming path and the save page all ask one function where
// the prose stops and the file begins, so these tests pin that function: the
// common case, the half-arrived block, and the names a model is allowed to
// suggest.
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/artifacts.dart';

void main() {
  test('a block is a file, and the sentences around it are the prose', () {
    final NexusArtifactSplit split = splitNexusArtifacts(
      'Here is the file.\n\n'
      '<artifact filename="hello.py" language="python">\n'
      'print("hello")\n'
      '</artifact>\n\n'
      'Run it with python3.',
    );

    expect(split.artifacts, hasLength(1));
    final NexusArtifact artifact = split.artifacts.single;
    expect(artifact.filename, 'hello.py');
    expect(artifact.language, 'python');
    expect(artifact.languageLabel, 'Python'.toLowerCase());
    expect(artifact.code, '\nprint("hello")\n');
    // The prose keeps both sentences, and the tag is nowhere in it.
    expect(split.prose, contains('Here is the file.'));
    expect(split.prose, contains('Run it with python3.'));
    expect(split.prose, isNot(contains('<artifact')));
  });

  test('two blocks are two files, in the order the model wrote them', () {
    final NexusArtifactSplit split = splitNexusArtifacts(
      '<artifact filename="a.txt" language="text">one</artifact>'
      '<artifact filename="b.dart" language="dart">void main() {}</artifact>',
    );
    expect(split.artifacts.map((NexusArtifact a) => a.filename), <String>[
      'a.txt',
      'b.dart',
    ]);
    // Nothing said around them: there is no bubble to draw.
    expect(split.prose, isEmpty);
  });

  test('a half-written block is neither shown nor saved', () {
    // The common streaming case: the opening tag has arrived and the closing
    // one has not. Printing the raw tag in large type is the bug this avoids,
    // and saving half a file is the other.
    final NexusArtifactSplit streaming = splitNexusArtifacts(
      'Sure — here it is:\n<artifact filename="hello.py" language="python">\nprin',
      streaming: true,
    );
    expect(streaming.artifacts, isEmpty);
    // The newline the block started on is kept: the prose is not trimmed
    // while the answer is still arriving.
    expect(streaming.prose.trim(), 'Sure — here it is:');
    expect(streaming.prose, isNot(contains('<artifact')));
  });

  test('a complete block is an artifact even while the answer streams', () {
    // The other half of the rule: once both tags are in, the card is live
    // before the reply is finished — the user does not wait for the whole
    // sentence to see the file it produced.
    final NexusArtifactSplit split = splitNexusArtifacts(
      '<artifact filename="a.txt">done</artifact> and one more word',
      streaming: true,
    );
    expect(split.artifacts.single.filename, 'a.txt');
    expect(split.prose, 'and one more word');
  });

  test('prose keeps its trailing space while it streams', () {
    // Trimming both ends drew "One,two," until the next token landed: the
    // space is the gap between the word that arrived and the one still coming.
    expect(splitNexusArtifacts('One, ', streaming: true).prose, 'One, ');
    // Once the answer is whole, the edges are tidied for good.
    expect(splitNexusArtifacts('One, two.  ').prose, 'One, two.');
  });

  test('a model cannot name a path outside the folder it is saved in', () {
    const NexusArtifact escape = NexusArtifact(
      filename: '../../etc/passwd',
      language: '',
      code: '',
    );
    expect(escape.safeFilename, 'passwd');
    expect(escape.safeFilename, isNot(contains('/')));

    const NexusArtifact hidden = NexusArtifact(
      filename: '...bashrc',
      language: '',
      code: '',
    );
    expect(hidden.safeFilename, 'bashrc');

    const NexusArtifact nameless = NexusArtifact(
      filename: '',
      language: '',
      code: '',
    );
    expect(nameless.safeFilename, 'artifact.txt');
    // No language is not an empty label on the card.
    expect(nameless.languageLabel, 'Text');
  });
}
