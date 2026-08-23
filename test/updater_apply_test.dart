import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/mesh/updater.dart';

void main() {
  test('extractAndSwap replaces the install dir with the new bundle', () async {
    final tmp = await Directory.systemTemp.createTemp('nexus_update_test');
    final installDir = '${tmp.path}/install';
    Directory(installDir).createSync(recursive: true);
    File('$installDir/nexus').writeAsStringSync('old-binary');
    File('$installDir/lib').writeAsStringSync('old-lib');

    // Build a tarball that looks like the real bundle (nexus binary at root).
    final staging = '${tmp.path}/staging';
    Directory('$staging/lib').createSync(recursive: true);
    File('$staging/nexus').writeAsStringSync('new-binary');
    File('$staging/lib/libapp.so').writeAsStringSync('new-lib');
    final archive = '${tmp.path}/update.tar.gz';
    final tar = await Process.run('tar', ['-czf', archive, '-C', staging, '.']);
    expect(tar.exitCode, 0, reason: tar.stderr.toString());

    final ok = await Updater.extractAndSwap(archive, installDir);
    expect(ok, isTrue);

    // The new content is in place.
    expect(File('$installDir/nexus').readAsStringSync(), 'new-binary');
    expect(File('$installDir/lib/libapp.so').readAsStringSync(), 'new-lib');
    // The old install is preserved as .old.
    expect(File('$installDir.old/nexus').readAsStringSync(), 'old-binary');

    await tmp.delete(recursive: true);
  });

  test('refuses an archive without a nexus binary', () async {
    final tmp = await Directory.systemTemp.createTemp('nexus_update_test2');
    final installDir = '${tmp.path}/install';
    Directory(installDir).createSync(recursive: true);
    File('$installDir/nexus').writeAsStringSync('old');

    final staging = '${tmp.path}/staging';
    Directory(staging).createSync(recursive: true);
    File('$staging/readme.txt').writeAsStringSync('not a nexus bundle');
    final archive = '${tmp.path}/bad.tar.gz';
    await Process.run('tar', ['-czf', archive, '-C', staging, '.']);

    final ok = await Updater.extractAndSwap(archive, installDir);
    expect(ok, isFalse);
    // The original install is untouched.
    expect(File('$installDir/nexus').readAsStringSync(), 'old');
    expect(Directory('$installDir.old').existsSync(), isFalse);

    await tmp.delete(recursive: true);
  });
}
