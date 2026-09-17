import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/system_command.dart';
import 'package:nexus/mesh/updater.dart';

/// Unpacks for real when the archive exists, so the test still exercises the
/// swap against an extracted bundle — without shelling out to `tar`, which made
/// a suite run launch an external program.
class _Unpacker {
  _Unpacker({this.bundle});

  /// The files the "archive" holds, as `path: contents`.
  final Map<String, String>? bundle;

  final commands = <String>[];
  int exitCode = 0;

  Future<ProcessResult> run(String program, List<String> arguments) async {
    commands.add([program, ...arguments].join(' '));
    if (exitCode != 0) {
      return ProcessResult(0, exitCode, '', 'tar: cannot open');
    }
    // `tar -xzf <archive> -C <dir>`
    final target = arguments[arguments.indexOf('-C') + 1];
    for (final entry in (bundle ?? const {}).entries) {
      final file = File('$target/${entry.key}');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(entry.value);
    }
    return ProcessResult(0, 0, '', '');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('extractAndSwap replaces the install dir with the new bundle', () async {
    final tmp = await Directory.systemTemp.createTemp('nexus_update_test');
    final installDir = '${tmp.path}/install';
    Directory(installDir).createSync(recursive: true);
    File('$installDir/nexus').writeAsStringSync('old-binary');
    File('$installDir/lib').writeAsStringSync('old-lib');

    // A bundle that looks like the real one (nexus binary at the root).
    final unpacker = _Unpacker(
      bundle: {'nexus': 'new-binary', 'lib/libapp.so': 'new-lib'},
    );
    final archive = '${tmp.path}/update.tar.gz';

    final ok = await Updater.extractAndSwap(
      archive,
      installDir,
      run: unpacker.run,
    );
    expect(ok, isTrue);

    // The new content is in place.
    expect(File('$installDir/nexus').readAsStringSync(), 'new-binary');
    expect(File('$installDir/lib/libapp.so').readAsStringSync(), 'new-lib');
    // The old install is preserved as .old.
    expect(File('$installDir.old/nexus').readAsStringSync(), 'old-binary');
    // And the archive really was handed to the unpacker, in the directory the
    // swap is about to move into place.
    expect(unpacker.commands, [
      'tar -xzf $archive -C $installDir.new',
    ]);

    await tmp.delete(recursive: true);
  });

  test('refuses an archive without a nexus binary', () async {
    final tmp = await Directory.systemTemp.createTemp('nexus_update_test2');
    final installDir = '${tmp.path}/install';
    Directory(installDir).createSync(recursive: true);
    File('$installDir/nexus').writeAsStringSync('old');

    final unpacker = _Unpacker(bundle: {'readme.txt': 'not a nexus bundle'});
    final archive = '${tmp.path}/bad.tar.gz';

    final ok = await Updater.extractAndSwap(
      archive,
      installDir,
      run: unpacker.run,
    );
    expect(ok, isFalse);
    // The original install is untouched.
    expect(File('$installDir/nexus').readAsStringSync(), 'old');
    expect(Directory('$installDir.old').existsSync(), isFalse);

    await tmp.delete(recursive: true);
  });

  test('refuses to swap when the unpacker fails', () async {
    final tmp = await Directory.systemTemp.createTemp('nexus_update_test3');
    final installDir = '${tmp.path}/install';
    Directory(installDir).createSync(recursive: true);
    File('$installDir/nexus').writeAsStringSync('old');

    final unpacker = _Unpacker()..exitCode = 2;
    final ok = await Updater.extractAndSwap(
      '${tmp.path}/broken.tar.gz',
      installDir,
      run: unpacker.run,
    );
    expect(ok, isFalse);
    expect(File('$installDir/nexus').readAsStringSync(), 'old');
    expect(Directory('$installDir.old').existsSync(), isFalse);

    await tmp.delete(recursive: true);
  });

  test('without a runner the swap unpacks through the shared one', () async {
    // Production behaviour, proven rather than assumed: the product passes no
    // runner and reaches the single shared seam — which is the real
    // `Process.run` outside the test suite, and neutralised inside it.
    final tmp = await Directory.systemTemp.createTemp('nexus_update_test4');
    final installDir = '${tmp.path}/install';
    Directory(installDir).createSync(recursive: true);
    File('$installDir/nexus').writeAsStringSync('old');

    final unpacker = _Unpacker(bundle: {'nexus': 'new'});
    final previous = systemCommandRunner;
    systemCommandRunner = unpacker.run;
    try {
      expect(
        await Updater.extractAndSwap('${tmp.path}/update.tar.gz', installDir),
        isTrue,
      );
      expect(unpacker.commands, ['tar -xzf ${tmp.path}/update.tar.gz -C $installDir.new']);
    } finally {
      systemCommandRunner = previous;
    }

    await tmp.delete(recursive: true);
  });

  group('the Android installer hand-off', () {
    const channel = MethodChannel('dev.nexus.nexus/installer');

    /// Drives the real `applyUpdate` against the statuses the Kotlin side
    /// returns (`MainActivity.installApk`), with no device in the loop.
    Future<UpdateApply> handOff(String? status) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'installApk');
        expect(call.arguments, {'path': '/tmp/nexus.apk'});
        return status;
      });
      try {
        return await Updater.applyUpdate('/tmp/nexus.apk');
      } finally {
        messenger.setMockMethodCallHandler(channel, null);
      }
    }

    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);

    test('a launched installer is its own outcome', () async {
      expect(await handOff('launched'), UpdateApply.installerOpened);
    });

    test('the permission step is not a failure and not a silent success',
        () async {
      // Android opened the "install unknown apps" screen and kept the file; the
      // install resumes on return. It used to be reported as success, so the app
      // said nothing at all while the user was looking at a settings list.
      final outcome = await handOff('permission');
      expect(outcome, UpdateApply.needsPermission);
      expect(updateHandoffNote(outcome), isNotNull);
    });

    test('an error status or a thrown channel is a failure', () async {
      expect(await handOff('error'), UpdateApply.failed);

      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'NO_PATH');
      });
      try {
        expect(await Updater.applyUpdate('/tmp/nexus.apk'), UpdateApply.failed);
      } finally {
        messenger.setMockMethodCallHandler(channel, null);
      }
    });
  });
}
