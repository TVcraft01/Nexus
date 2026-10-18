// The send transport, with real bytes.
//
// This is the half a widget test cannot do (real file IO does not run inside a
// widget test's fake clock), so it is a plain test: a file on disk, an outbox
// in a temp folder, and a check that what lands is what was sent — byte for
// byte — with progress that only ever moves forward.
//
// It also pins the sentence. This build stages the file rather than delivering
// it, and the result says so in as many words; a test fails if that stops being
// true, because a progress bar that completes over a "Sent!" nobody sent is the
// one thing this app cannot ship.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/file_link.dart';
import 'package:nexus/core/paired_devices.dart';

const PairedDevice _laptop = PairedDevice(
  id: 'laptop000000000000000000000000001',
  name: 'Study laptop',
  publicKey: 'laptop-key',
);

/// A file of [bytes] bytes, deterministic so a mismatch is readable.
File _source(Directory dir, int bytes) {
  final File file = File('${dir.path}/photo.png');
  file.writeAsBytesSync(List<int>.generate(bytes, (int i) => i % 251));
  return file;
}

void main() {
  late Directory root;
  late Directory outbox;

  setUp(() {
    root = Directory.systemTemp.createTempSync('nexus-filelink-');
    outbox = Directory('${root.path}/outbox')..createSync();
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('moves the whole file, reporting progress as it goes', () async {
    final File source = _source(root, 300 * 1024);
    final List<double> progress = <double>[];
    final FileLink link = FileLink(outbox: () async => outbox);

    final FileSendResult result = await link.send(
      path: source.path,
      device: _laptop,
      onProgress: progress.add,
    );

    expect(result.ok, isTrue);
    expect(result.path, isNotNull);
    final File landed = File(result.path!);
    expect(landed.existsSync(), isTrue);
    // The outbox copy is named for what it is: when it was prepared, who it is
    // for, and what the file was called.
    expect(landed.path.split('/').last, endsWith('-${_laptop.id}-photo.png'));
    expect(landed.readAsBytesSync(), source.readAsBytesSync());

    // Progress is a fraction of the real size, never backwards, and finished.
    expect(progress, isNotEmpty);
    expect(progress.last, 1);
    for (int i = 1; i < progress.length; i++) {
      expect(progress[i], greaterThanOrEqualTo(progress[i - 1]));
    }
    expect(progress.every((double p) => p >= 0 && p <= 1), isTrue);
  });

  test('the result says it is prepared, not delivered', () async {
    final File source = _source(root, 1024);
    final FileLink link = FileLink(outbox: () async => outbox);

    final FileSendResult result = await link.send(
      path: source.path,
      device: _laptop,
    );

    expect(result.ok, isTrue);
    expect(result.message, contains('Study laptop'));
    expect(result.message, contains('has not left this phone'));
  });

  test('a file that is already gone is a sentence, not an empty send',
      () async {
    final FileLink link = FileLink(outbox: () async => outbox);

    final FileSendResult result = await link.send(
      path: '${root.path}/never-existed.png',
      device: _laptop,
    );

    expect(result.ok, isFalse);
    expect(result.message, 'That file is no longer on this device.');
    expect(outbox.listSync(), isEmpty);
  });

  test('with nowhere to put it, it says that instead of half-succeeding',
      () async {
    final File source = _source(root, 1024);
    final FileLink link = FileLink(outbox: () async => null);

    final FileSendResult result = await link.send(
      path: source.path,
      device: _laptop,
    );

    expect(result.ok, isFalse);
    expect(result.message, contains('nowhere to prepare'));
  });
}
