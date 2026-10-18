// Draws a pairing QR on a desktop screen, for the one part of the pairing walk
// a phone cannot do by itself: scanning.
//
// The scanner needs a real code in front of a real camera, and the code has to
// be one this build would accept — the four fields `PairInvite.parse` insists
// on, with a device id long enough to be one — and the modules come from the
// same `qr` package the app's own "Show my QR" page uses. The page it writes is
// an SVG of the modules on white, sized to the window, which is what a monitor
// can hold up for a phone.
//
// The payload is written here rather than built by `PairInvite.encode` on
// purpose: this probe is `dart run`, and `pair_invite.dart` imports Flutter for
// its platform name and its print. The shape is the one that file documents —
// `test/pair_invite_test.dart` is where the encoder and this parser are held to
// each other, and `--name` overrides the device name for a run that wants one.
//
//     dart run test/pair_qr_probe.dart            # writes /tmp/nexus-pair-qr.html
//     xdg-open /tmp/nexus-pair-qr.html            # and point the phone at it
//
// Not a test, and named so `flutter test` will not run it: it is a probe, like
// `clip_probe_driver.dart` and `llm_live_smoke.dart` next to it.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

// `qr` arrives through `qr_flutter`, which is the dependency the app itself
// declares; a `dart run` script cannot import `qr_flutter` (it pulls in
// Flutter), so the probe reaches for the package underneath it.
// ignore: depend_on_referenced_packages
import 'package:qr/qr.dart';

/// 32 random bytes as base64url, the shape `placeholderPublicKey` writes — the
/// scanner only checks that the field is there, but a probe that shipped an
/// obviously-fake key would prove less than one that carried a real-looking
/// payload.
String _publicKey() {
  const String alphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
  final Random random = Random.secure();
  return String.fromCharCodes(
    List<int>.generate(43, (_) => alphabet.codeUnitAt(random.nextInt(64))),
  );
}

void main(List<String> args) {
  final String payload = jsonEncode(<String, String>{
    'type': 'nexus_pair',
    'device_name': args.isNotEmpty ? args.first : 'Living Room PC',
    'device_id': 'probe-living-room-pc-000000000001',
    'public_key': _publicKey(),
  });

  final QrImage image = QrImage(
    QrCode.fromData(data: payload, errorCorrectLevel: QrErrorCorrectLevel.M),
  );
  final int modules = image.moduleCount;
  // Four modules of quiet zone all round: a QR needs the margin to be read, and
  // a code that fills its own edge is a code a camera cannot lock onto.
  const int quiet = 4;
  final int side = modules + quiet * 2;

  final StringBuffer svg = StringBuffer()
    ..write('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 $side $side" '
        'shape-rendering="crispEdges" width="100%" height="100%">')
    ..write('<rect width="$side" height="$side" fill="#ffffff"/>')
    ..write('<path fill="#000000" d="');
  for (int row = 0; row < modules; row++) {
    for (int col = 0; col < modules; col++) {
      if (image.isDark(row, col)) {
        svg.write('M${col + quiet} ${row + quiet}h1v1h-1z');
      }
    }
  }
  svg.write('"/></svg>');

  final File out = File(
    args.length > 1 ? args[1] : '/tmp/nexus-pair-qr.html',
  );
  out.writeAsStringSync(
    '<!doctype html><meta charset="utf-8"><title>Nexus pairing code</title>'
    '<body style="margin:0;background:#fff">'
    '<div style="position:fixed;inset:0">$svg</div>',
  );
  stdout
    ..writeln('wrote ${out.path}')
    ..writeln('payload: $payload');
}
