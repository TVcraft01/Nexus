# Attachments: camera and screen capture (2026-10-18)

What the composer's two new buttons are, and what was actually verified for
them — the distinction this note cares about is between *checked on this
machine* and *needs a phone*.

## What was built

| Piece | Where |
|---|---|
| The two composer buttons, left of the field | `lib/main_ui.dart` (`_AttachButton`, `kAttachCamera`, `kAttachScreen`) |
| Full-screen camera: preview, shutter, X | `lib/ui/camera_page.dart` |
| One screenshot through MediaProjection | `android/.../ScreenCaptureService.kt`, `android/.../MainActivity.kt` (`SCREEN_CHANNEL`) |
| The Dart seam for that capture | `lib/core/screen_capture.dart` |
| Captions, prompts, and the store that keeps the bytes | `lib/core/attachments.dart` |
| The thumbnail bubble and the viewer | `lib/main_ui.dart` (`NexusAttachmentBubble`), `lib/ui/image_viewer_page.dart` |
| The picture surviving a restart | `lib/core/chat_log.dart` (`ChatEntry.imagePath`, stored as `image`) |

The brain is never handed pixels. Each attachment leaves a caption in the
thread (`Photo attached` / `Screenshot attached`) and the model receives one
bracketed sentence instead: `[User attached a photo]` /
`[User attached a screenshot]`. Both strings are decided in one place
(`AttachmentKind`), so the bubble and the prompt cannot drift.

## Verified here

```
flutter test test/attachments_test.dart   # 17 passed
flutter test                              # 1346 passed, 2 skipped
flutter analyze                           # 60 issues, 0 warnings (baseline)
flutter build apk --debug                 # rc=0 — Kotlin compiled
```

What the 17 tests hold, beyond the two literals above:

- the store copies a capture into its folder, keeps the original when there is
  no folder, and answers null for a file that has already gone;
- the composer draws both buttons at ≤34px, and they sit in the field's row;
- tapping the camera opens the capture page and X comes back to the composer;
- a device with no camera shows a sentence, not a black screen;
- a screenshot becomes a thumbnail, is persisted with its path, and the brain
  is asked with `[User attached a screenshot]` and never with the image;
- a refused capture says so, adds no bubble, and asks the brain nothing;
- tapping a thumbnail opens the black viewer, and closing it returns;
- a restored conversation still shows the picture, and a picture that has been
  deleted keeps its caption.

## Not verified here — needs the phone

No device was attached (`adb devices` empty; no AVD on this machine), so the
three platform paths are compiled and reasoned about but unproven:

1. **Camera preview and shutter.** The plugin is exercised only as far as its
   "no camera" branch; a real `takePicture()` and its file have not been seen.
2. **The projection dialog and one real frame.** The service is written for
   Android 14's rules — foreground service of type `mediaProjection` started
   *before* `getMediaProjection()`, and a `MediaProjection.Callback` registered
   before `createVirtualDisplay()` (Android 14 throws `IllegalStateException`
   without it) — but the only proof that it captures is a real screenshot.
3. **The row on a real screen.** The layout was rendered once as a throwaway
   golden and read by eye; it is not a committed golden test.

Until those three are run on the A25 with `./update-phone.sh`, the honest
statement is: the code is compiled, the wiring is tested, and the phone half is
untested.
