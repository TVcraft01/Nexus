// The camera door, without a camera app.
//
// The composer no longer draws a Flutter preview: a preview on some Samsung
// phones returns a black frame, so [DeviceAttachmentPickers.captureImage] hands
// the shot to the phone's own camera app through `image_picker`. What can be
// pinned here is the contract around that call — a finished file comes back as
// a [PickedAttachment], and backing out or a camera that will not open is null,
// never a throw.
import 'package:flutter/foundation.dart' show DebugPrintCallback, debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart' show XFile;
import 'package:nexus/core/attachment_pickers.dart';

void main() {
  test('answers the shot the system camera returned', () async {
    const DeviceAttachmentPickers pickers = DeviceAttachmentPickers(
      camera: _shot,
    );

    final PickedAttachment? picked = await pickers.captureImage();

    expect(picked, isNotNull);
    expect(picked!.path, '/cache/native-shot.jpg');
    expect(picked.name, 'native-shot.jpg');
  });

  test('answers null when the user backs out of the camera', () async {
    const DeviceAttachmentPickers pickers = DeviceAttachmentPickers(
      camera: _cancelled,
    );

    expect(await pickers.captureImage(), isNull);
  });

  test('a camera that will not open is null, not a throw', () async {
    final List<String> lines = <String>[];
    final DebugPrintCallback original = debugPrint;
    debugPrint = (String? line, {int? wrapWidth}) {
      if (line != null && line.startsWith('ATTACH: the camera')) {
        lines.add(line);
      }
    };
    try {
      const DeviceAttachmentPickers pickers = DeviceAttachmentPickers(
        camera: _refused,
      );
      expect(await pickers.captureImage(), isNull);
      expect(lines, hasLength(1));
      expect(lines.single, contains('the camera could not be opened'));
    } finally {
      debugPrint = original;
    }
  });
}

Future<XFile?> _shot() async => XFile('/cache/native-shot.jpg');

Future<XFile?> _cancelled() async => null;

Future<XFile?> _refused() async => throw StateError('no camera app');
