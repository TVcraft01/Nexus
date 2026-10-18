# Capability gating: one place that knows what this device can do

Date: 2026-10-18 · build: `flutter build apk --debug`, installed on the phone ·
device: SM-A256E (a25x) — the same unit every phone run uses

The shell grew up on one phone, and its hardware seams grew up with it:
`SpeechInput.available` is `defaultTargetPlatform == android`, the launcher icon
is an Android activity, the on-device model is a native library that some builds
carry and others do not. Each of those answered its own question correctly, and
none of them could answer the *UI's* question — should this control be on screen
at all? — so the answer was scattered and, on an iPhone, would have been wrong in
several places at once.

`lib/core/device_capabilities.dart` is that one place now. It answers in
**capabilities**, not platforms — "can this device listen", not "is it an
Android" — because the second is the thing callers get subtly wrong when a new
platform arrives.

## What it answers

| member | rule | where it lands |
| --- | --- | --- |
| `microphoneAvailable` / `hasMicrophone()` | the platform has a recognizer at all, and the user has not refused the permission for good | the composer's mic and live buttons are **not drawn** without one |
| `hasNfc()` | asked of the platform once (`hasNfc` on `dev.nexus.nexus/device`); no handler means no radio | nothing reads it yet; the first feature that does has an answer to read |
| `supportsOnDeviceAi()` | the build carries the engine (`kOnDeviceAiPlatforms`: Android, Linux) **and** the device has the RAM floor (`kLlmRamFloorBytes`, 4 GB) | Settings → Brain: the download and delete rows, replaced on a device that cannot run it by `kNoOnDeviceAiText` |
| `supportsWakeWord` | Android only (openWakeWord over ONNX Runtime) | the Voice section, and the Wake word row |
| `supportsSpokenReplies` | the platform's own TTS, wired up for Android | the same section, and the Speak replies row |
| `supportsLauncherIcons` | Android only (activity aliases) | already honest in `IconService`; now stated in one voice |
| `openAppSettings()` | `openAppSettings` on the device channel | the button on the refused-permission dialog |

Two rules that took thought, and are written in the code where they can be
argued with:

* **Hidden is not the same as disabled.** A *refused* microphone is still a real
  button: it is drawn muted, it says why in the composer, and tapping it offers
  the settings page where the permission lives. A device with *no* microphone was
  never going to listen, and a permanently dead control in the composer's
  tightest row is a promise the app cannot keep — so that one is not drawn, and
  the pill is shorter for it. The iOS/desktop build is the second case.
* **Hiding the voice half must not take the send arrow with it.** The mic slot
  also holds the send arrow (the hold recogniser wraps the whole slot, on
  purpose). With the microphone gone, the slot keeps the one control a device
  with no voice still needs: the arrow appears with the first character typed.
  That bug was caught by the widget test that types on such a device and presses
  send — it failed with "found 0 widgets" and the fix went in before this run.

## The refused permission now has a door

Android shows its permission dialog once. After a refusal, the old shell left
the control inert with a sentence on it — accurate, and a dead end. Now the
refusal opens a dialog (`showNexusPermissionDialog`) that names the permission
and offers **Open settings**, which calls `openAppSettings()` on the platform
(the activity method that already existed for the capability rows). `Not now`
costs nothing; taking the door is one call to the platform, which is the whole of
what a shell can do about a permission.

## The run, on the phone

The point of this run is the negative space: on the one device that *has*
everything, nothing was taken away, and the streaming that was working before is
still working after.

* `01-home-composer-on-android.png` — the composer with its mic and live buttons
  exactly where they were, and `This device answers — nothing here goes to a
  cloud.` under them.
* `02-settings-voice-and-brain.png` — Settings on Android: **Voice & speech**
  with its full subtitle, then

  ```
  BRAIN
  AI status        Answers on this device. No network, no      On-Device (Loaded)
                   account, nothing leaves it.
  On-device model  Qwen2.5 0.5b q4 — 469 MB on this device     Downloaded
  Delete model     Frees 469 MB. Answers come from your PC ›
  instead
  ```

  i.e. the download half of the section is still there on the device that can
  use it, and the status row still reports the phone as the brain.
* `03-thinking.png`, `04-first-token.png`, `05-growing.png`, `06-answer.png` —
  one turn, read back with `tesseract` at about 1 s apart:

  ```
  Tell me about the ocean
  Nexus is thinking...
  Nexus is thinking...
  The
  The ocean is vast and mysterious, encompassing
  ... the largest body of water on Earth.
  ... It's a complex system with diverse life forms that support ecosystems and
      provide essential resources for human populations. The ocean's depth
      ranges from shallow ...
  ```

  The token-by-token growth is the streaming slice, unbroken by the gating:
  `LocalAiService.current` and the two screens were not touched.

## Tests

* `test/device_capabilities_test.dart` (new, 16 tests) — the platform matrix:
  an iPhone gets no on-device AI, a 2 GB Android does not either, one byte under
  the RAM floor is under it, a platform whose memory cannot be read is not
  blocked, the wake word and launcher icons are Android-only, NFC with no handler
  is false rather than a throw, and `openAppSettings()` answers false when there
  is no page to open.
* `test/main_ui_test.dart` — a device with no microphone is offered neither
  button **and can still send what is typed**; a refused microphone opens the
  dialog, `Not now` opens nothing, and taking the door calls the platform once;
  an unsupported device is told `On-device AI is not supported on this device.
  Connect to a PC.` with no download row and no sentence pointing at one; an
  iPhone gets no Voice section at all.
* The two tests that used to assert the *old* behaviour were rewritten rather
  than deleted: the inert live button is now the absent live button, and the
  refused mic's dead control is now the dialog's door.

Whole suite: **1203 passing, 2 skipped** (was 1184 before this slice).
`flutter analyze`: **60 issues**, the same info-level notices as before, no new
ones. Still no `integration_test` harness in this project, so the phone run above
is the real APK driven with real taps and its frames read back — as every other
phone run here.
