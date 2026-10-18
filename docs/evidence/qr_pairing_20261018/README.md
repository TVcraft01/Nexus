# QR pairing — what the shell does now (2026-10-18)

The Devices tab, the pairing sheet, the code this device shows and the scanner
that reads another one, driven on the real Linux desktop build through the real
compositor (`tool/ui_driver.py`: hyprctl geometry, grim, tesseract, `/dev/uinput`).
Not a widget test — the PNGs below are frames of the app running.

| # | Frame | What it shows |
|---|-------|---------------|
| 1 | `01-devices.png` | `PAIRED`: This Phone, My PC, Studio Mac, each with a word and a dot; the `Pair a device` row |
| 2 | `02-pair-sheet.png` | The sheet's two answers: `Scan QR code`, `Show my QR code` |
| 3 | `03-show-qr.png` | The code this device shows, its name, and its id |
| 4 | `04-scan-no-camera.png` | A desktop build with no camera plugin: the guidance, not a crash and not a `MissingPluginException` in the log |
| 5 | `05-devices-plus-phone.png` | The same tab on the phone (SM-A256E, Android 16, release build 0.4.0): the `+` in the header beside `Devices`, above the same three paired rows |
| 6 | `06-pair-sheet-phone.png` | The sheet on the phone: `Scan QR code`, `Show my QR code` |
| 7 | `07-camera-permission.png` | `Allow Nexus to take pictures and record video?` — asked by `mobile_scanner` when the page opens |
| 8 | `08-scanner-phone.png` | After `While using the app`: the scanner page, live and waiting, with `Point at the QR code on the other device` |

## The payload, read back off the screen

`zbarimg` on frame 3 decodes the QR the page actually painted:

```
{"type":"nexus_pair","device_name":"tvcraft01s-pc","device_id":"a2ei86yfg61ogr021qu6q9xmh85o3ovv","public_key":"N4___y9R2pYdNBJK67izMHnVQEd3JMdj7WxE9CN8aEQ"}
```

Field order is the order `PairInvite.encode` writes, and the values are the
`PairIdentity` the page was built with — the name from the platform, the id from
`generateDeviceId`, and a 32-byte placeholder key in the shape the mesh's real
one will have. `decoded-payload.txt` is that command's output.

## What is covered by tests instead

- `test/pair_invite_test.dart` — the payload: encode/parse round trip, every way
  a scanned string can be nearly ours (a link, a vCard, truncated JSON, a
  renamed field, a 3-character id) and be refused, plus the placeholder key's
  shape and the identity's stability.
- `test/paired_devices_test.dart` — the list: add, dedupe on id, forget (never
  this device), listeners, and the store read back after a restart.
- `test/pair_flow_test.dart` — the screen: the rows, Forget, the sheet, the QR
  page, a scan that pairs (`Paired with Ocean Phone`), the same device twice,
  backing out of the camera, a non-Nexus code (`This is not a Nexus device
  code.`), a legacy `nexus://pair` code (its own sentence), a good code closing
  the page with the invite, and a platform with no scanner saying so.

## The camera, on the phone

Frames 5–8 are the Android side of the same walk, driven over adb. The journey
the user takes is the whole of what can be driven without another screen to point
at: the header button, the sheet, the platform's permission prompt, and a live
preview behind a scanner that is actually listening.

What that leaves unproven on hardware is the last inch — holding the phone at a
code on another screen and seeing the list grow. A camera cannot be aimed over
adb, so the scan itself is covered in `test/pair_flow_test.dart` instead: the
page is handed the barcode a camera would have reported, and everything after
that point is the real widget — the sheet closing, `Paired with Ocean Phone`, the
same device scanned twice, a non-Nexus code, a legacy `nexus://pair` code, and a
platform with no scanner saying so in words. `test/pair_qr_probe.dart` exists for
the day somebody does hold the phone up: it writes a code of this build's own
shape to a file (`dart run test/pair_qr_probe.dart`), so the other screen is a
browser tab rather than a second phone.
