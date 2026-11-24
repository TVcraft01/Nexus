// The no-network pairing, driven through its real screens.
//
// This runs as a real app process (Linux under xvfb in CI, Android emulator in
// the emulator job), not in the widget-test sandbox: the two pair pages are
// mounted side by side, each bound to its own live [MeshService] with a real
// socket, a real identity seed and the real six-digit exchange. Nothing here
// calls the pairing API directly — the test types into the fields and taps the
// buttons a person would, and reads the codes off the screens.
//
// The two devices share one process on purpose. Two OS processes cannot be
// driven by one Flutter test, and what this is meant to prove is the flow the
// user sees plus the keys it leaves behind, which one process can do honestly.
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nexus/core/identity.dart';
import 'package:nexus/core/identity_seed_store.dart';
import 'package:nexus/core/store.dart';
import 'package:nexus/mesh/mesh_service.dart';
import 'package:nexus/ui/offline_pair_page.dart';
import 'package:nexus/ui/theme.dart';
import 'package:qr_flutter/qr_flutter.dart';

class _MemorySeedStore implements IdentitySeedStore {
  final Map<String, Map<String, dynamic>> values = {};

  @override
  Future<Map<String, dynamic>?> read() async => values['seed'] == null
      ? null
      : Map<String, dynamic>.of(values['seed']!);

  @override
  Future<void> write(Map<String, dynamic> identity) async {
    values['seed'] = Map<String, dynamic>.of(identity);
  }

  @override
  Future<void> delete() async => values.remove('seed');
}

Finder _page(MeshService mesh) => find.byWidgetPredicate(
  (w) => w is OfflinePairPage && identical(w.mesh, mesh),
);

Finder _inPage(MeshService mesh, Finder matching) =>
    find.descendant(of: _page(mesh), matching: matching);

Future<int> _freePort() async {
  final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = probe.port;
  await probe.close();
  return port;
}

Future<String> _sha256Of(File file) async {
  final hash = await Sha256().hash(await file.readAsBytes());
  return hash.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Pumps until [finder] matches, or gives up after [timeout].
///
/// The pairing steps are async (a key is derived and a frame is sealed), so a
/// single `pumpAndSettle` can return before the next card is built. This is a
/// bounded wait, not a sleep: it fails the test at the timeout with the screen
/// as it actually was.
Future<void> _pumpUntil(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) return;
  }
}

/// The longest run of digits on the screen — the six-digit confirmation code.
String _codeOn(WidgetTester tester, MeshService mesh) {
  final texts = tester
      .widgetList<Text>(_inPage(mesh, find.byType(Text)))
      .map((t) => t.data ?? '')
      .where((t) => RegExp(r'^\d{6}$').hasMatch(t))
      .toList();
  expect(
    texts,
    isNotEmpty,
    reason: 'no six-digit code is visible on ${mesh.identity.name}\'s screen',
  );
  return texts.first;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'two screens pair with no network, then a file crosses the socket',
    (tester) async {
      // Two real screens side by side need room: at the default 800x600 the
      // lower half of each page is off-screen and a tap would miss a button
      // that a person on a real desktop would simply scroll to.
      tester.view.physicalSize = const Size(1600, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final tmp = await Directory.systemTemp.createTemp('nexus_ui_e2e');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });

      Future<MeshService> device(String id, String name) async {
        final store = NexusStore(explicitPath: '${tmp.path}/$id.json')
          ..port = await _freePort()
          ..pairingEnabled = true
          ..fileShare = true;
        await store.save();
        final root = Directory('${tmp.path}/$id-root')
          ..createSync(recursive: true);
        final mesh = MeshService(
          identity: DeviceInfo(id: id, name: name, platform: 'linux'),
          store: store,
          fileRoot: root.path,
          heartbeatInterval: const Duration(seconds: 2),
          onlineWindow: const Duration(seconds: 15),
          connectTimeout: const Duration(milliseconds: 500),
        )..useIdentitySeedStoreForTest(_MemorySeedStore());
        await mesh.start();
        return mesh;
      }

      final laptop = await device('ui-laptop', 'Study PC');
      final phone = await device('ui-phone', 'Kitchen phone');
      addTearDown(() async {
        await laptop.stop();
        await phone.stop();
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: buildNexusTheme(brightness: Brightness.dark),
          home: Scaffold(
            body: Row(
              children: [
                Expanded(child: OfflinePairPage(mesh: laptop)),
                const VerticalDivider(width: 1),
                Expanded(child: OfflinePairPage(mesh: phone)),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Both sides show a first code. It is taken the way a person takes it:
      // tap Copy, read the clipboard (a real one, on the real platform).
      expect(_inPage(laptop, find.byType(QrImageView)), findsOneWidget);
      await tester.tap(_inPage(laptop, find.text('Copy code')));
      await tester.pumpAndSettle();
      final laptopQr1 =
          (await Clipboard.getData('text/plain'))?.text ?? '';
      expect(laptopQr1, startsWith('NEXUS1.'));

      // The phone switches to "Enter their code" and pastes it, exactly the
      // string fallback a desktop without a camera gets.
      await tester.tap(_inPage(phone, find.text('Enter their code')));
      await tester.pumpAndSettle();
      await tester.enterText(
        _inPage(
          phone,
          find.widgetWithText(TextField, 'The code from the other device'),
        ),
        laptopQr1,
      );
      await tester.pumpAndSettle();
      await tester.tap(_inPage(phone, find.text('Use this code')));
      await _pumpUntil(tester, _inPage(phone, find.byType(QrImageView)));

      expect(_inPage(phone, find.byType(QrImageView)), findsOneWidget);
      await tester.tap(_inPage(phone, find.text('Copy answer')));
      await tester.pumpAndSettle();
      final phoneQr2 =
          (await Clipboard.getData('text/plain'))?.text ?? '';
      expect(phoneQr2, startsWith('NEXUS2.'));

      // The laptop takes the answer back, and both screens must agree.
      await tester.enterText(
        _inPage(laptop, find.widgetWithText(TextField, 'Their answer')),
        phoneQr2,
      );
      await tester.pumpAndSettle();
      await tester.tap(_inPage(laptop, find.text('Check answer')));
      await _pumpUntil(tester, _inPage(laptop, find.textContaining('They match')));
      await tester.pumpAndSettle();

      final codeOnLaptop = _codeOn(tester, laptop);
      final codeOnPhone = _codeOn(tester, phone);
      // DELIBERATELY BROKEN for one commit: the e2e job must fail on this and
      // the revert immediately after must be green. Do not keep.
      expect(
        codeOnLaptop,
        '000000',
        reason: 'deliberate failure to prove the e2e gate',
      );
      expect(
        codeOnLaptop,
        codeOnPhone,
        reason: 'the two screens must show the same six digits',
      );

      // Both people tap "they match".
      await tester.tap(
        _inPage(laptop, find.textContaining('They match')),
        warnIfMissed: false,
      );
      await _pumpUntil(tester, _inPage(laptop, find.textContaining('Paired with')));
      await tester.pumpAndSettle();
      await tester.tap(
        _inPage(phone, find.textContaining('They match')),
        warnIfMissed: false,
      );
      await _pumpUntil(tester, _inPage(phone, find.textContaining('Paired with')));
      await tester.pumpAndSettle();

      expect(_inPage(laptop, find.textContaining('Paired with')), findsOneWidget);
      expect(_inPage(phone, find.textContaining('Paired with')), findsOneWidget);
      expect(laptop.pairedDevices.single.id, 'ui-phone');
      expect(phone.pairedDevices.single.id, 'ui-laptop');
      expect(laptop.pairedDevices.single.pairingProtocol, 1);
      expect(phone.pairedDevices.single.pairingProtocol, 1);

      // The pairing carries no address, so the two devices find each other on
      // the network the way they would after airplane mode is switched off.
      final deadline = DateTime.now().add(const Duration(seconds: 25));
      while (DateTime.now().isBefore(deadline) &&
          !(laptop.isOnline('ui-phone') && phone.isOnline('ui-laptop'))) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      expect(
        laptop.isOnline('ui-phone'),
        isTrue,
        reason: 'the paired devices never proved each other on the network',
      );

      // A real file, over the real socket, with the key the screens just made.
      final source = File('${tmp.path}/holiday.jpg');
      await source.writeAsBytes(
        List<int>.generate(64 * 1024 + 3, (i) => (i * 17) % 251),
      );
      final want = await _sha256Of(source);
      final saved = await laptop.pushLocalFile(
        laptop.pairedDevices.single,
        source.path,
        destinationPath: 'from-laptop/holiday.jpg',
      );
      expect(saved, isNotNull, reason: laptop.lastFileError);

      final received = File('${tmp.path}/ui-phone-root/from-laptop/holiday.jpg');
      expect(await received.exists(), isTrue);
      expect(await _sha256Of(received), want);
      expect(await received.length(), await source.length());
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
