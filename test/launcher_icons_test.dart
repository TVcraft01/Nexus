// The two launcher icons, and which alias wears which.
//
// Android shows the icon of whichever activity alias is enabled, so the whole
// icon switch rests on a wiring that is one regex away from being wrong: the
// icon generator (`dart run flutter_launcher_icons`, run twice — the light set
// from pubspec.yaml and the dark set from dark_icons.yaml) rewrites *every*
// line of AndroidManifest.xml that mentions `android:icon`, activity-alias
// lines included. Run the dark set last, as the pipeline's own instructions
// say, and both aliases come out pointing at the dark icon: the light alias
// then shows the wrong mark, the light resources are referenced by nothing and
// are dropped from the APK, and the app still launches with no error at all.
//
// That happened on this branch. This test is the thing that would have caught
// it, because neither the build nor the Kotlin alias test looks at which icon
// a given alias points to.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The manifest, as text. The wiring is static, so it is read rather than
/// rendered: no device and no build are needed to know what shipped.
String _manifest() =>
    File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

/// The `android:icon` of one activity alias, by its manifest name.
String _iconOfAlias(String alias) {
  final block = RegExp(
    '<activity-alias\\b[^>]*?android:name="\\.$alias"[^>]*?>',
    dotAll: true,
  ).firstMatch(_manifest());
  expect(block, isNotNull, reason: 'alias .$alias is declared');
  final icon = RegExp(r'android:icon="([^"]+)"').firstMatch(block!.group(0)!);
  expect(icon, isNotNull, reason: 'alias .$alias declares its own icon');
  return icon!.group(1)!;
}

File _res(String path) =>
    File('android/app/src/main/res/$path');

void main() {
  test('each launcher alias wears its own icon, never the other one', () {
    expect(_iconOfAlias('IconLight'), '@mipmap/ic_launcher_light');
    expect(_iconOfAlias('IconDark'), '@mipmap/ic_launcher_dark');

    // The application's own icon is a third reference to the same generator
    // rewrite — it is the mark other apps see for Nexus (app info, recents),
    // and it is the light one because light is the alias that ships enabled.
    final app = RegExp(
      '<application\\b[^>]*?>',
      dotAll: true,
    ).firstMatch(_manifest())!;
    expect(
      RegExp(r'android:icon="([^"]+)"').firstMatch(app.group(0)!)!.group(1),
      '@mipmap/ic_launcher_light',
      reason: 'the fallback mark agrees with the alias that is enabled',
    );
  });

  test('both adaptive icons exist and point at their own layers', () {
    for (final variant in ['light', 'dark']) {
      final xml = _res('mipmap-anydpi-v26/ic_launcher_$variant.xml');
      expect(xml.existsSync(), isTrue,
          reason: 'the $variant adaptive icon is where the manifest says');
      final body = xml.readAsStringSync();
      expect(
        body,
        contains('@color/nexus_icon_${variant}_background'),
        reason: 'the $variant background is its own token, not the other one',
      );
      expect(body, contains('@mipmap/ic_launcher_${variant}_foreground'));
    }

    // The two backgrounds are the page colours, and they must differ: an
    // adaptive icon whose two variants share a colour would look like a
    // successful switch that changed nothing.
    final colours = _res('values/nexus_icons.xml').readAsStringSync();
    final light = RegExp(
      r'nexus_icon_light_background">(#[0-9A-Fa-f]{6})',
    ).firstMatch(colours)!.group(1);
    final dark = RegExp(
      r'nexus_icon_dark_background">(#[0-9A-Fa-f]{6})',
    ).firstMatch(colours)!.group(1);
    expect(light, isNot(dark));
  });

  test('every density carries both icon sets, square and adaptive', () {
    // A missing layer is not a build error — the resource simply is not there,
    // and the alias falls back to the other variant's artwork or to the
    // default icon, which looks like a design change rather than a bug.
    for (final density in [
      'mdpi',
      'hdpi',
      'xhdpi',
      'xxhdpi',
      'xxxhdpi',
    ]) {
      for (final variant in ['light', 'dark']) {
        for (final layer in ['', '_foreground']) {
          final file = _res('mipmap-$density/ic_launcher_$variant$layer.png');
          expect(file.existsSync(), isTrue,
              reason: '${file.path} is part of the $variant set');
          expect(file.lengthSync(), greaterThan(0), reason: file.path);
        }
      }
    }
  });
}
