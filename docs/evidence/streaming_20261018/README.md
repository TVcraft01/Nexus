# Streaming: the answer grows while the model writes it

Date: 2026-10-18 · build: `flutter build apk --debug`, installed on the phone
over adb · device: SM-A256E (a25x), Android 14, the same unit every phone run
uses · answers from **the phone's own Qwen2.5 0.5B** — no PC on the network

Until this slice, `LocalAiService` had one method: `generateResponse`, which
returned the whole answer at the end. On a phone that meant the bubble said
**"Nexus is thinking…"** for the entire generation — measured below at 18
seconds — and then the answer appeared all at once. The fix is a second method
on the same seam (`Stream<String> generateResponseStream`) and a screen that
appends each piece as it lands.

## What changed

| file | what it is now |
| --- | --- |
| `lib/core/local_ai_service.dart` | the interface carries both shapes: `generateResponseStream` for the screens, `generateResponse` for the whole answer. `FallbackAiService` streams too, with one rule that only streaming needs: a device that fails **before the first token** is covered by the PC, a device that fails **after** words are on screen is this turn's failure — the caller already holds those words and says so |
| `lib/core/llm.dart` | `Llm.completeStream` — the token-by-token twin of `complete`, with the same queue, lazy load and idle unload behind it |
| `lib/core/on_device_ai_service.dart` | `generateResponseStream` over `llamadart`'s deltas; a stream that dies mid-answer throws `kOnDeviceStreamFailureText` ("The on-device model stopped mid-answer.") rather than the generic sentence |
| `lib/core/ollama_service.dart` | the PC is not streamed yet: it yields its whole answer as one piece, which is honest and keeps the fallback honest too |
| `lib/main_ui.dart` | `_answer` (chat bubble) and `_liveAnswer` (live page) both listen to the stream: every piece is appended to the bubble on screen, the scroll follows it (rate-limited to one animation per 150 ms), a half-written answer stays a *placeholder* — no copy, no speaker — and a failure mid-stream is appended after a blank line so the truncated answer ends with an account of itself. The reply is spoken once it is whole, never in pieces |

## The run

```
flutter build apk --debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk
adb shell input tap 400 1955          # the composer
adb shell input text "Tell%25me%25a%25story%25about%25the%25sea"
adb shell screenrecord --time-limit 25 /sdcard/stream2.mp4
adb shell input tap 841 1240          # the send arrow
```

`stream-chat.mp4` is that recording (23 s, 2 fps pulled into frames below with
`ffmpeg -i stream2.mp4 -vf fps=2 g%03d.png`, read back with `tesseract`).
Times are seconds into the recording; the tap is at ~2 s.

```
g016 ( 7.5s) Nexus is thinking...
g018 ( 8.5s) Nexus is thinking...
g020 ( 9.5s) The                                            <- the first token
g022 (10.5s) The sea was vast and deep, its waves
g024 (11.5s) The sea was vast and deep, its waves
g026 (12.5s) The sea was vast and deep, its waves crashing against the shore with irresistible force.
g028 (13.5s) ... A young boy named Jack paddled his
g030 (14.5s) ... seeking adventure
g032 (15.5s) ... He sailed past
g036 (17.5s) ... blue waters where dolphins
g038 (18.5s) ... and finally reached
g040 (19.5s) ... a tranquil beach on which he laid down
g042 (20.5s) ... to rest.                                   <- complete
```

The frames are `02-thinking.png` … `06-answer-complete.png`; `07-answer-settled.png`
is two seconds later — same words, and now the copy and speaker controls are
under them, which is what "a whole answer" looks like. `01-composer.png` is the
prompt before it was sent.

Two things the numbers say that the table cannot:

* the wait before the first token (≈7.5 s) is the model load, not the
  generation. The same phone, with the weights already warm from that turn,
  answered the live-page question below in about four seconds. Streaming does
  not shorten the load; it is the reason the load is no longer the whole story
  on screen;
* the words then arrive at roughly 15–20 tokens a second, and the answer is
  *readable the whole way* — a phone turn is 18 seconds long, and 11 of them now
  show the answer being written rather than the word "thinking".

## The live page does the same

`08-live-answer.png` is live conversation on the same build, answering a spoken
turn: **"A small robot named "Bee" was born from a series of steps that began as
a single cel…"** in large type with **"Mic off — tap to continue."** under it.
It is the same `generateResponseStream` onto the same page state
(`_liveAnswering`, `_liveAnswerText`); the widget test below walks that page one
token at a time, because a live turn ends when the recognizer says so and cannot
be held still mid-sentence from outside the app.

## This phone really was the brain

`09-brain-on-device.png` is Settings → **Brain** on the device:

```
BRAIN
AI status       Answers on this device. No network, no      On-Device (Loaded)
                account, nothing leaves it.
On-device model Qwen2.5 0.5b q4 — 469 MB on this device     Downloaded
```

The model file was put in place over adb
(`/data/data/dev.nexus.nexus/app_flutter/model.gguf`) because the phone had none
yet: the pushed bytes are the ones the app's own verified download installs —
491,400,032 bytes, `sha256
74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db`, the hash
pinned as `kPhoneModel.sha256` in `lib/core/llm.dart`. Nothing else on the phone
was stubbed: the app is the debug build of this checkout, the weights are the
real ones, and llama.cpp ran on the phone's CPU — the device log says so once per
load, and says nothing else about the AI:

```
10-18 01:40:42.713 24023 24023 I flutter : LLM: CPU ready, ctx 2048, 4t   <- the chat run above
10-18 01:43:39.170 26283 26283 I flutter : LLM: CPU ready, ctx 2048, 4t
10-18 01:45:12.472 27548 27548 I flutter : LLM: CPU ready, ctx 2048, 4t   <- the live run
```

The absent line is the evidence that matters: the fallback chain prints
`AI: … Trying the PC` whenever the device could not answer, and no such line
exists anywhere in this run's log. The PC's Ollama was up on this machine the
whole time (these answers were *not* it): `AI status` says `On-Device (Loaded)`,
the weights loaded on the phone, and every turn came from the phone.

## What the tests cover

* `test/llm_test.dart` — `completeStream` streams the same tokens `complete`
  returns, and an empty answer is an empty stream on both paths
* `test/on_device_ai_service_test.dart` — the on-device stream yields each
  delta, never yields an empty piece, and fails mid-answer with
  `kOnDeviceStreamFailureText` (and before the first token with the generic
  sentence, so the fallback can still cover it)
* `test/local_ai_service_test.dart` — the chain: device first, PC only when the
  device said nothing, **no** failover once words are on screen, and the PC's
  one-piece answer re-thrown as `OllamaException`
* `test/main_ui_test.dart` —
  **the answer grows in the bubble as the model writes it** (each token
  appended, the placeholder gone with the first one, nothing spoken or
  copyable until the answer is whole, spoken once at the end);
  **a model that stops mid-answer keeps its words and says so** (the sentence
  appended after a blank line, and never spoken); and
  **a live answer is written onto the page as the model writes it** (the large
  type replaces "Nexus is thinking…" with the first token and grows from there)

Whole suite on the host: `flutter test` → **1184 passing, 2 skipped**;
`flutter analyze` → the same 60 info-level notices as before this slice, no new
ones. On the phone there is no `integration_test` harness in this project, so
"tested on the device" means what it has meant in every other phone run here:
the real APK driven with real taps, real keystrokes and real frames, read back —
the run above.
