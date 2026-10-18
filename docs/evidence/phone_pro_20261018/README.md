# The Pro pass, on the phone — 18 October 2026

A real Galaxy A25 5G (SM-A256E, Android 15, 1080×2340), a signed **release**
build of `0.4.0` (versionCode 157), and nothing stubbed. Every screen below was
driven through `adb` (`input tap`/`swipe` for touch, Flutter's own semantics for
the words on screen), so what the captures show is the app running from the APK
that was installed over the one from the night before.

```
flutter build apk --release            # 212.8 MB, 84 s
adb uninstall dev.nexus.nexus          # the phone had a debug-signed build
adb install app-release.apk            # release keystore, data wiped: 469 MB model absent
adb reverse tcp:11434 tcp:11434        # the PC's Ollama, as "localhost" on the phone
```

The reverse tunnel is a test rig, not a product feature: it is what lets the
phone's default Ollama host (`localhost:11434`) reach the PC's `llama3.2`, so the
PC fallback could be exercised without a second machine on the LAN. It was
**removed** for the on-device proof and is not left in place.

## What was checked, and what it looked like

| Requirement | On the phone |
|---|---|
| No invented greeting or user message | `01` — "Hey, what do you need?" over an empty thread; no bubbles at all |
| Typed turn is silent | `02` — a typed "hello" answered with copy + speaker controls and **no** `TextToSpeech` activity in `logcat` |
| Speaker is still manual | the same turn, tapping **Read aloud**: `TextToSpeech: Create TextToSpeech` → `com.google.android.tts` bound → `Synthesis request` → audio. Also the first-run note: Samsung's private TTS engine refuses non-allowlisted packages and the app correctly lands on Google's |
| Text selection, not long-press copy | `03` — a hold selects the word "assist" with handles and the Copy/Share/Select all toolbar; nothing is written to the clipboard |
| Follow the phone's light/dark | the app opened dark on a dark phone; `ThemeMode.system` is the default |
| Theme section and five accents | `04` — Follow system, Dark mode, and Nexus Purple / Ocean Blue / Emerald Green / Sunset Orange / Slate Grey |
| Dark-mode toggle | `05` — switching Follow system off enables the row; tapping it repaints the whole app light. The  busy spinner is two frames and was not caught by a 300 ms screencap; it is
  proven at 1341–1363 of `test/main_ui_test.dart` |
| Accents repaint the app | `06`/`07` — Ocean turns the active tab and switches blue, Sunset orange, Slate grey; purple restored afterwards |
| Settings always opens at the top | scrolled to About, opened Home, came back: THEME at the top again |
| Delete model is red and asks first | `11` — red row and icon; "Delete AI Model?", "This will free up 469 MB, but you will not be able to chat offline — answers would come from your PC instead.", Cancel / **Delete** in red |
| Delete actually deletes | `13` — after Delete: "AI status: No AI available", the Download model row is back. (The "Freed 469 MB." snackbar had expired by the capture — it is asserted in the widget test) |
| Live mode: Claude-shaped page | `08` — dark-ink large-type transcript area, pulse, rolling waveform at the bottom, Recording badge, privacy line; no giant centre orb |
| Live mode hears and answers | `09` — a spoken "Hello" (right, accent ink) and the answer in large type, mic off with "Tap to continue" |
| A spoken turn is spoken back | `logcat` shows the TTS synthesis request at the moment the live answer landed, while every typed turn before it was silent |
| Live mode remembers context | the live answer followed the conversation; the turn is passed as history (see `test/main_ui_test.dart`, "live conversation remembers the turns before it") |
| Closing live keeps the turns | `10` — the spoken "Hello" and its answer are in the chat thread, below the earlier typed exchange |
| Silence gap 2.0 s | the turn survived a normal thinking pause and ended on silence, not mid-sentence |
| On-device answers | `15` — "The sky is typically blue…" answered with the Ollama tunnel **removed**, from Qwen2.5 0.5B on the phone; warm answers land in ~6–7 s |
| PC fallback | `14` — with the model deleted and Ollama reachable, the status reads "Answers come from your PC over the local network" and a question is answered by `llama3.2` |

## Two bugs the phone found, both fixed in this pass

1. **The brain status was read once.** The Settings → AI status row kept saying
   "No AI" after Ollama came up, and the Home composer's line kept saying
   "Your own devices answer" after the model had been downloaded. Both screens
   now take a `refreshEpoch` from the shell, bumped whenever their tab is
   selected, and re-read `AiStatus` on the way in. Proven on the device: with
   the app running and no model, `adb reverse` was added, Home → Settings, and
   the row changed to "PC (Ollama)" without a restart (`14`); after the model
   finished downloading, Home was reopened and the composer line changed to
   "This device answers — nothing here goes to a cloud" (`15`).
2. **About claimed the shell had no model.** It read "UI shell preview — front
   end only — no mesh, store or model attached" while the model was answering
   questions. It is now a Version row: "Nexus 0.4.0 — on-device answers, no
   account, no cloud" (`12`).

Both are covered by new widget tests (`opening a tab asks its screen to look
again`, `the composer line is re-read when Home is opened again`, `the Brain rows
follow a model that arrives while open`, `the About row names the build, not an
empty shell`), and the whole suite is green: **1252 passed, 2 skipped**;
`flutter analyze` stays at **60** issues.

## What is not proven here

- **The dark-mode spinner.** Two frames long; the screencap takes ~300 ms. The
  widget test asserts the spinner exists for the frame that applies the theme.
- **The "Freed 469 MB." snackbar** was missed by the capture window; the rows
  changing back to "Download model" are the proof that the delete happened.
- **Screen or camera sharing** does not exist yet — deliberately, per the brief.
- **The live page in light mode** is light, not the dark room the brief asked
  for; the page follows the theme (`08` was taken in light mode). Worth a
  decision: always dark like a viewfinder, or themed like every other page.
- **The chat thread is in memory only.** Reinstalling or relaunching starts on
  the welcome screen again; nothing here persists a conversation.
- **Samsung's TTS quirk**: `SamsungTTS` refuses `dev.nexus.nexus`
  ("not allowed to bind to private engine"), so speech goes through Google's
  engine. The app handles it, but the fallback is worth knowing about.
- **The recording badge and waveform were exercised through a real spoken
  turn**, not through audio injected by the rig: the sentence in `09` was said
  by the person holding the phone.
