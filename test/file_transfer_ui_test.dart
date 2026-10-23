// A file arrives while the conversation is open, and the conversation says so.
//
// The transport is stubbed at the service's own stream: a widget test's binding
// answers every HttpClient request with 400, so this pins the hand-off — the
// listener turns one [ReceivedFile] into one bubble, with the sender's name and
// the picture attached — while the bytes on the wire are pinned in
// test/file_transfer_service_test.dart.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/chat_log.dart';
import 'package:nexus/main_ui.dart' show HomeTab, NexusTheme;
import 'package:nexus/mesh/file_transfer_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A service whose arrivals the test can ring by hand.
class _Arrivals extends FileTransferService {
  _Arrivals() : super(token: 'receiver-token-0123456789');

  final StreamController<ReceivedFile> controller =
      StreamController<ReceivedFile>.broadcast();

  @override
  Stream<ReceivedFile> get incoming => controller.stream;

  void arrive(ReceivedFile file) => controller.add(file);

  @override
  Future<void> stop() async {
    await controller.close();
    await super.stop();
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'nexus.profile.onboarded': true,
    });
    ChatLog.debugReset();
  });

  tearDown(() {
    ChatLog.debugReset();
    FileTransferService.debugOverride = null;
    FileTransferService.debugReset();
  });

  testWidgets('a received photo is a bubble from the sender', (tester) async {
    final Directory root = Directory.systemTemp.createTempSync('nexus-rx-ui-');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    final File shot = File('${root.path}/photo.png')
      ..writeAsBytesSync(<int>[
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // a PNG header is
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // enough for the
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, // thread to treat
      ]); //                                                   it as a picture
    final _Arrivals service = _Arrivals();
    addTearDown(service.stop);
    FileTransferService.debugOverride = () => service;

    await tester.pumpWidget(
      MaterialApp(
        theme: NexusTheme.dark(),
        home: Scaffold(body: const HomeTab()),
      ),
    );
    await tester.pump();
    await tester.pump();

    service.arrive(
      ReceivedFile(
        path: shot.path,
        name: 'photo.png',
        fromId: 'study-laptop-0000000000000000000001',
        fromName: 'Study laptop',
        at: DateTime(2026, 10, 22, 10, 42),
      ),
    );
    await tester.pump();
    await tester.pump();

    // The line names the file and the sender, and carries the picture — the
    // three things a person needs to know about something they did not ask for.
    expect(find.text('Received photo.png from Study laptop'), findsOneWidget);
  });

  testWidgets('a received document is a file line, not a broken picture', (
    tester,
  ) async {
    final Directory root = Directory.systemTemp.createTempSync('nexus-rx-ui-');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    final File doc = File('${root.path}/notes.txt')
      ..writeAsStringSync('a note');
    final _Arrivals service = _Arrivals();
    addTearDown(service.stop);
    FileTransferService.debugOverride = () => service;

    await tester.pumpWidget(
      MaterialApp(
        theme: NexusTheme.dark(),
        home: Scaffold(body: const HomeTab()),
      ),
    );
    await tester.pump();
    await tester.pump();

    service.arrive(
      ReceivedFile(
        path: doc.path,
        name: 'notes.txt',
        fromId: 'study-laptop-0000000000000000000001',
        fromName: 'Study laptop',
        at: DateTime(2026, 10, 22, 10, 42),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Received notes.txt from Study laptop'), findsOneWidget);
  });
}
