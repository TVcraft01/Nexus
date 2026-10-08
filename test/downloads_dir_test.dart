// What a saved file is actually called.
//
// The phone caught this one: downloading the same file twice put the literal
// text "$1" in the name — "Saved readme.md to
// /storage/emulated/0/Download/readme (2)$1". The de-duplication was a
// `replaceFirst` whose replacement string ended in `\$1`, and Dart does not
// expand capture references in a replacement string (that is what
// `replaceFirstMapped` is for), so the escape just wrote the characters "$1"
// into the filename. Every repeat download of a name collided with itself and
// got the corrupted name — in the Files tab and in the assistant's fetch
// alike, since both go through here.
//
// The counter belongs before the extension, and a leading dot is part of the
// name rather than an extension.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/ui/downloads_dir.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('downloads'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<String> pathFor(String name) =>
      downloadsFilePath(name, inDirectory: dir.path);

  void touch(String name) => File('${dir.path}/$name').writeAsStringSync('x');

  test('a name nobody has taken is used as-is', () async {
    expect(await pathFor('report.pdf'), '${dir.path}/report.pdf');
  });

  test('a taken name gets a counter before the extension', () async {
    touch('report.pdf');
    expect(await pathFor('report.pdf'), '${dir.path}/report (1).pdf');
  });

  test('the counter goes up, and never leaves a "\$1" behind', () async {
    touch('report.pdf');
    touch('report (1).pdf');
    final third = await pathFor('report.pdf');
    expect(third, '${dir.path}/report (2).pdf');
    expect(third, isNot(contains(r'$1')));
  });

  test('a leading dot is part of the name, not an extension', () async {
    touch('.gitignore');
    expect(await pathFor('.gitignore'), '${dir.path}/.gitignore (1)');
  });

  test('a name with no extension keeps the counter at the end', () async {
    touch('notes');
    expect(await pathFor('notes'), '${dir.path}/notes (1)');
  });

  test('only the last extension is treated as one', () async {
    touch('archive.tar.gz');
    expect(await pathFor('archive.tar.gz'), '${dir.path}/archive.tar (1).gz');
  });
}
