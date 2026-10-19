// The camera page, without a lens.
//
// Two things on this page decide whether the photo that comes back is a photo:
// the shutter waits for the sensor to expose its first frame, and the bytes are
// copied while the controller is still alive. Both are measured on the A25 —
// black photos came from a shot taken too early — so both are pinned here
// through [CameraSession], the seam that stands in for the plugin's controller.
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:nexus/core/attachments.dart';
import 'package:nexus/ui/camera_page.dart';

/// A session with no sensor behind it: it answers when told to, and records
/// every call in the order the page makes it.
class _FakeSession implements CameraSession {
  _FakeSession(this.shotPath, {this.events});

  final String shotPath;
  final List<String>? events;
  int initializes = 0;
  int shots = 0;
  int disposals = 0;
  bool failShot = false;
  bool _initialized = false;

  @override
  Future<void> initialize() async {
    initializes++;
    _initialized = true;
  }

  @override
  bool get initialized => _initialized;

  @override
  Widget preview() => const ColoredBox(color: Colors.black);

  @override
  Future<XFile> takePicture() async {
    shots++;
    if (failShot) throw StateError('the lens refused');
    return XFile(shotPath);
  }

  @override
  Future<void> dispose() async {
    disposals++;
    events?.add('dispose');
  }
}

/// The store, without the disk: it says what it was handed and where that went.
class _RecordingStore extends AttachmentStore {
  _RecordingStore({this.events}) : super(directory: () async => null);

  static const String permanent = '/kept/photo.jpg';
  final List<String>? events;
  final List<String> kept = <String>[];

  @override
  Future<String?> keep(
    String sourcePath, {
    required AttachmentKind kind,
  }) async {
    kept.add(sourcePath);
    events?.add('keep');
    expect(kind, AttachmentKind.photo);
    return permanent;
  }
}

/// What the page popped with.
class _Opened {
  String? path;
}

const CameraDescription _back = CameraDescription(
  name: 'back',
  lensDirection: CameraLensDirection.back,
  sensorOrientation: 90,
);

void main() {
  setUpAll(() {
    // No font download in a test; the fallback face is what every shell test
    // uses, and text metrics are not the subject here.
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  late _RecordingStore store;
  late List<String> events;

  setUp(() {
    events = <String>[];
    store = _RecordingStore(events: events);
    AttachmentStore.override = () => store;
  });

  tearDown(() => AttachmentStore.override = null);

  /// Pushes the page the way the composer does, and leaves the route on screen.
  Future<_Opened> open(WidgetTester tester, _FakeSession session) async {
    final _Opened opened = _Opened();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () async {
              opened.path = await Navigator.of(context).push<String>(
                MaterialPageRoute<String>(
                  builder: (_) => CameraPage(
                    cameras: () async => const <CameraDescription>[_back],
                    session: (_) => session,
                  ),
                ),
              );
            },
            child: const Text('open camera'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open camera'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    return opened;
  }

  testWidgets('the shutter waits for the sensor to expose a frame', (
    tester,
  ) async {
    final _FakeSession session = _FakeSession('/cache/shot.jpg');
    await open(tester, session);

    expect(session.initializes, 1);
    expect(find.byKey(kCameraShutter), findsOneWidget);

    // 100 ms in: the preview is live, but the sensor has not had its 300 ms.
    // A shot here is the black rectangle the device came back with.
    await tester.tap(find.byKey(kCameraShutter));
    await tester.pump();
    expect(session.shots, 0, reason: 'a dark sensor is not asked for a photo');

    // Past the warm-up, the same tap is a shot.
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(kCameraShutter));
    await tester.pumpAndSettle();
    expect(session.shots, 1);
  });

  testWidgets('the shot is copied before the camera is closed', (tester) async {
    final _FakeSession session = _FakeSession(
      '/cache/shot.jpg',
      events: events,
    );
    final _Opened opened = await open(tester, session);
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byKey(kCameraShutter));
    await tester.pumpAndSettle();

    // The store was handed the camera's own file — the copy is what makes the
    // shot permanent — and the page closed with the copy's path.
    expect(store.kept, <String>['/cache/shot.jpg']);
    expect(opened.path, _RecordingStore.permanent);
    expect(find.byType(CameraPage), findsNothing);

    // The order is the fix: copy first, dispose after. A dispose before the
    // copy is what leaves a half-written, black JPEG behind.
    expect(events, <String>['keep', 'dispose']);
    expect(session.disposals, 1);
  });

  testWidgets('a shot that fails leaves the page open, with a sentence', (
    tester,
  ) async {
    final _FakeSession session = _FakeSession('/cache/shot.jpg')
      ..failShot = true;
    final _Opened opened = await open(tester, session);
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byKey(kCameraShutter));
    await tester.pumpAndSettle();

    expect(find.text('The photo could not be taken.'), findsOneWidget);
    expect(find.byType(CameraPage), findsOneWidget);
    expect(opened.path, isNull);
    expect(store.kept, isEmpty, reason: 'a failed shot is not kept');
  });

  testWidgets('a device with no camera says so instead of a black screen', (
    tester,
  ) async {
    final _FakeSession session = _FakeSession('/cache/shot.jpg');
    await tester.pumpWidget(
      MaterialApp(
        home: CameraPage(
          cameras: () async => const <CameraDescription>[],
          session: (_) => session,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(kCameraUnavailableText), findsOneWidget);
    expect(find.byKey(kCameraClose), findsOneWidget);
    expect(find.byKey(kCameraShutter), findsNothing);
    expect(session.initializes, 0, reason: 'there was nothing to open');
  });
}
