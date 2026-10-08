// The motion rules, measured on the widgets instead of described in a doc.
//
// Apple's first rule of a fluid interface is that the response happens on
// touch-**down**: a control that waits for the finger to lift feels dead, and
// no amount of easing afterwards repairs it. The second is that anything a
// finger can touch moves on a spring, because a spring can be grabbed again
// mid-flight and re-targeted — a fixed curve can only be replaced, which is
// the visible jump known as a brick wall.
//
// Both are asserted here against the real component, at real finger geometry:
// a press is timed in frames, not in vibes.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/ui/components/nexus_ui.dart';
import 'package:nexus/ui/design/tokens.dart';
import 'package:nexus/ui/theme.dart' show buildNexusTheme;

/// The damping ratio a spring is describing, from its own three parameters:
/// ζ = c / (2√(km)).
double _ratio(SpringDescription spring) =>
    spring.damping / (2 * math.sqrt(spring.mass * spring.stiffness));

/// The surface under test — scoped so an unrelated AnimatedContainer or
/// Transform elsewhere in the tree cannot make a finder ambiguous.
final Finder _surface = find.byType(NexusPressable);

/// The tint a [NexusPressable] is painting right now.
Color? _tint(WidgetTester tester) =>
    ((tester
                .widget<AnimatedContainer>(
                  find
                      .descendant(
                        of: _surface,
                        matching: find.byType(AnimatedContainer),
                      )
                      .first,
                )
                .decoration)
            as BoxDecoration?)
        ?.color;

/// The surface's live scale, read off the x axis of its transform. On a
/// scale-only matrix the z axis stays 1, so `getMaxScaleOnAxis()` reports 1
/// whatever the press is doing.
double _scale(WidgetTester tester) => tester
    .widget<Transform>(
      find.descendant(of: _surface, matching: find.byType(Transform)).first,
    )
    .transform
    .storage[0];

Future<void> _pumpPressable(
  WidgetTester tester, {
  VoidCallback? onTap,
  VoidCallback? onLongPress,
  bool enabled = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildNexusTheme(),
      home: Scaffold(
        body: Center(
          child: NexusPressable(
            onTap: onTap,
            onLongPress: onLongPress,
            enabled: enabled,
            child: const SizedBox(
              width: 200,
              height: 64,
              child: Text('Notes.txt'),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('the press shows in the frame the finger lands in', (
    tester,
  ) async {
    await _pumpPressable(tester, onTap: () {});
    expect(
      _tint(tester),
      Colors.transparent,
      reason: 'a resting surface is clear',
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Notes.txt')),
    );
    // One frame — no release, no timer, no debounce. Anything slower than this
    // is the latency the rule exists to remove.
    await tester.pump();

    expect(
      _tint(tester),
      isNot(Colors.transparent),
      reason: 'the tint must be on screen while the finger is still down',
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(
      _tint(tester),
      Colors.transparent,
      reason: 'the tint ends with the press',
    );
  });

  testWidgets('the surface moves on a spring and is interruptible mid-flight', (
    tester,
  ) async {
    var taps = 0;
    await _pumpPressable(tester, onTap: () => taps++);

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Notes.txt')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    final pressed = _scale(tester);
    expect(pressed, lessThan(1), reason: 'a press moves the surface');

    // Released mid-flight: the spring starts from the live value and its own
    // velocity, so the surface carries on from where it was instead of
    // snapping back to 1 and animating from there. The frame after the lift is
    // therefore almost exactly where the press had got to — a jump of a whole
    // hundredth here is the visible seam this rule removes.
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 16));
    final justAfter = _scale(tester);
    expect(justAfter, lessThan(1), reason: 'no snap on release');
    expect(
      (justAfter - pressed).abs(),
      lessThan(0.005),
      reason: 'the motion continues from the live value',
    );
    expect(taps, 1, reason: 'a completed tap still fires its handler');

    await tester.pumpAndSettle();
    expect(
      _scale(tester),
      moreOrLessEquals(1, epsilon: 0.0001),
      reason: 'a critically damped spring lands exactly on 1 — no overshoot',
    );
  });

  testWidgets('dragging away cancels the press, and nothing fires', (
    tester,
  ) async {
    var taps = 0;
    await _pumpPressable(tester, onTap: () => taps++);

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Notes.txt')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    // Off the surface, which is how a scroll or a change of mind begins.
    await gesture.moveTo(
      tester.getCenter(find.text('Notes.txt')) + const Offset(0, 400),
    );
    await tester.pump(const Duration(milliseconds: 60));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(taps, 0, reason: 'a cancelled press commits nothing');
    expect(_tint(tester), Colors.transparent);
    expect(_scale(tester), moreOrLessEquals(1, epsilon: 0.0001));
  });

  testWidgets('with animations refused, the press still lands instantly', (
    tester,
  ) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: MaterialApp(
          theme: buildNexusTheme(),
          home: Scaffold(
            body: Center(
              child: NexusPressable(
                onTap: () {},
                child: const SizedBox(
                  width: 200,
                  height: 64,
                  child: Text('Notes.txt'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Notes.txt')),
    );
    await tester.pump();
    expect(
      _tint(tester),
      isNot(Colors.transparent),
      reason: 'reduced motion still owes the user response',
    );
    await gesture.up();
    await tester.pump();
    expect(
      _scale(tester),
      moreOrLessEquals(1, epsilon: 0.0001),
      reason: 'reduced motion drops the spring, not the feedback',
    );
  });

  testWidgets('a disabled surface is inert and silent', (tester) async {
    var taps = 0;
    await _pumpPressable(tester, onTap: () => taps++, enabled: false);

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Notes.txt')),
    );
    await tester.pump();
    expect(_tint(tester), Colors.transparent);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(taps, 0);
  });

  test('the file-type glyph is one icon per kind, decided by the name', () {
    expect(fileTypeIcon(name: 'Photos', isDir: true), Icons.folder_rounded);
    expect(
      fileTypeIcon(name: 'holiday.JPG', isDir: false),
      Icons.image_outlined,
    );
    expect(
      fileTypeIcon(name: 'notes.txt', isDir: false),
      Icons.description_outlined,
    );
    expect(
      fileTypeIcon(name: 'archive.tar.gz', isDir: false),
      Icons.folder_zip_outlined,
    );
    expect(
      fileTypeIcon(name: 'song.flac', isDir: false),
      Icons.audiotrack_rounded,
    );
    expect(fileTypeIcon(name: 'clip.mp4', isDir: false), Icons.movie_outlined);
    expect(fileTypeIcon(name: 'main.dart', isDir: false), Icons.code_rounded);
    expect(
      fileTypeIcon(name: 'nexus-0.1.53.apk', isDir: false),
      Icons.android_rounded,
    );
    // A name with no extension, and one that is only a dot: both are files.
    expect(
      fileTypeIcon(name: 'LICENSE', isDir: false),
      Icons.insert_drive_file_outlined,
    );
    expect(
      fileTypeIcon(name: 'trailing.', isDir: false),
      Icons.insert_drive_file_outlined,
    );
  });

  test('a spring is Apple\'s two parameters, not three', () {
    // Apple's default is critically damped: the curve settles without
    // overshooting, whatever the response is.
    final damped = NexusSpring.of();
    expect(_ratio(damped), moreOrLessEquals(1, epsilon: 0.001));
    // A quicker response is a stiffer spring — same shape, less time.
    final quick = NexusSpring.of(speed: const Duration(milliseconds: 200));
    expect(quick.stiffness, greaterThan(damped.stiffness));
    // And a momentum spring is the under-damped one, for a flick only.
    final momentum = NexusSpring.of(damping: NexusSpring.momentum);
    expect(_ratio(momentum), lessThan(1));
  });
}
