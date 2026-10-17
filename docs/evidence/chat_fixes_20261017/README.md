# Three fixes from the phone: a red notice, controls on every reply, and a seam for the day there is no PC

Captured 2026-10-17 from `lib/main_ui.dart` as a Linux desktop window (900 × 1000,
floating under Hyprland, driven by `tool/ui_driver.py`). Two runs, because the two
things being photographed need different PCs: one aimed at a dead port
(`--dart-define=NEXUS_OLLAMA_HOST=http://127.0.0.1:9`) for the failure, one aimed
at this machine's own Ollama for the answer.

| photo | what it shows |
| --- | --- |
| `01-error-notice.png` | a message sent to a PC that is not there: **"PC not found. On-device AI coming soon."** in a red notice with a warning sign |
| `02-error-notice-crop.png` | the same notice, cropped and doubled |
| `03-reply-actions.png` | a real llama3.2 reply, with two small controls under it |
| `04-reply-actions-crop.png` | the reply and its controls, cropped and doubled |

## 1. The failure is not a reply

`NexusErrorBubble` is a separate widget, not a `NexusChatBubble` with different
colours. It is drawn `#FFEBEE` inside a `#E6A5A0` rim with `#B3261E` ink, a
`warning_amber_rounded` icon at 18dp, on Nexus's side of the thread. Dark mode gets
its own wash (`#3A1B1B`, ink `#FFB4AB`) because a pale red block on a black page is
a glare rather than a warning.

The screenshot is measured, not eyeballed. The wash occupies a 296 × 41 px block
whose most common colour in the capture is `(251, 231, 235)`; the capture path
renders the theme background `(246, 246, 245)` where the token is `#F7F7F5`, so the
frame is about 2% darker across the board and the block is exactly the light red it
was given. The widget test pins the values without that offset:
`a PC that cannot be reached shows a red notice, and never says it` reads the
`BoxDecoration` back from the rendered widget and finds `kNexusErrorWash`,
`kNexusErrorRim`, `kNexusErrorInk` and the warning glyph.

The notice can be copied and cannot be spoken: the row under it holds the copy
control and no speaker, and `_answer` never calls `SpeechOutput.speak` on the
failure path. The test installs a fake speaker and asserts it was never asked.

## 2. Every answer carries both controls

The row under a Nexus message is `_MessageActions` — a 16dp copy glyph and a 16dp
speaker glyph, 32dp tap targets, 24px apart. It is rendered for **every** Nexus
message: the two opening lines, every answer the model writes, and (copy only) the
error notice. It is deliberately not conditional on `SpeechOutput.available`; a
control that appears on one message and not the next reads as a bug, which is
exactly what the phone reported.

In `03-reply-actions.png` the reply is real — "Hello there, how are you?" from
llama3.2 — and the row under it measures as two glyph clusters at x 198–208 and
222–233, i.e. the copy and speaker icons under the newest answer rather than only
under the greeting. The widget test checks it per bubble rather than by counting
icons: both the greeting's bubble and the reply's bubble must contain one of each,
and the user's own message must contain neither.

## 3. A seam for the brain

`lib/core/local_ai_service.dart` is the interface — one method, `generateResponse`,
plus the test override and the choice of what answers when nothing is faked.
`OllamaService implements LocalAiService` and is that default today; the shell asks
`LocalAiService.current` in both `_answer` and `_liveAnswer`. The on-device engine
the app already ships the runtime for (`llamadart` and `libllama.so`) becomes a
second implementation, and the screens do not change to get it.

The failure sentence changed with the seam, and it is pinned in
`test/local_ai_service_test.dart` word for word: **"PC not found. On-device AI
coming soon."** That is the honest thing to show — with no PC the app has no brain,
and the next one is being built rather than something the user can install today.

`flutter test` is 1148 passing, 2 skipped; `flutter analyze` stays at its pinned 60
findings; `flutter build linux --debug` and `flutter build apk --debug` both
succeed. Nothing here ran on the phone: the icons and colours are a desktop
rendering of the same widgets, and the TTS engine behind the speaker is still
Android-only.
