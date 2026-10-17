# The chat after the brain — following the thread, copying a line, and the live turn that never ended

Captured 2026-10-17 from `lib/main_ui.dart` running as a Linux desktop window
(900 × 1000 logical px, floating under Hyprland, driven by `tool/ui_driver.py` —
the same uinput + OCR harness the other evidence runs use). The answers in these
frames are real llama3.2 replies from this machine's Ollama on `11434`.

| photo | what it shows |
| --- | --- |
| `01-live-listening.png` | live conversation listening, with **"what is the weather"** forming in large type |
| `02-live-thinking.png` | the turn ended on its own and the page is **"Nexus is thinking…"**, mic off |
| `03-live-answer.png` | the model's reply in large type, grey orb, **"Mic off — tap to continue."** |
| `04-live-still-waiting.png` | five seconds later: the same page, the microphone still closed — nothing auto-listened |
| `05-thread-followed.png` | the Home thread after eight messages: the greeting and the first messages are scrolled off, the newest is above the composer |
| `06-copied.png` | a long press on the newest bubble; **"Message copied"** in the snack bar |
| `07-copied-snack.png` | the same frame, cropped and doubled, so the snack bar is readable |

## What was actually wrong with live mode

Not the request and not the answer: `_liveAnswer` already called Ollama and the
page already had a thinking state. The turn never *ended*. Live conversation has
no finger to release and no stop button, so the only thing that could finish a
turn was the recognizer's own `onResults` — and this phone's on-device recognizer
does not always send one. The previous on-device log says it plainly:

```
10-16 10:47:58.875  NexusInstaller: speech: …Girl
10-16 10:47:59.984  flutter : mic:stop 2026-10-16T10:47:59.982589 reason=cancelled
```

interim words, and then nothing — the session was ended by the user, not by a
transcript. In dictation that is invisible (the finger releases, and `finish()`
asks for the words); in live mode there is nobody to ask, so the page sat on
"Listening…" and no request was ever made.

**The fix is one idea, and it lives in the shell rather than in the platform
seam:** a live turn ends on the quiet after speech. Every loudness reading the
phone already sends for the meter is checked against two thresholds —
`kSpeechVoiceDb` (2 dB) says the room has a voice in it, `kSpeechQuietDb`
(0.5 dB) says it has gone quiet again, and the gap between them is the
hysteresis that stops a fan from ending a sentence. An interim word counts as a
voice too, and it pushes the end back; after 1.2 s (`kSpeechTurnGap`) of quiet,
the shell calls `SpeechInput.finish()` once — `stopListening()` on Android — and
the recognizer answers with the transcript it has been holding. From there the
existing path runs unchanged: the words go to the PC, the orb turns blue, the
reply takes the large type, it is spoken, and the page waits.

The run above is that sequence with a scripted microphone (`tool/preview_live.dart`,
deleted after the run — it reported `-2`/`+8` dB and three words the way
`onRmsChanged` does):

```
mic:start 2026-10-17T23:27:31.482803 mode=live
mic:partial what is the weather
mic:settle 2026-10-17T23:27:35.098015      <- the quiet after speech, 3.6 s in
mic:partial what is the weather
mic:stop 2026-10-17T23:27:35.099585 reason=final
```

Three seconds later the page said "Nexus is thinking…", and the answer landed at
35 s (llama3.2 writing a paragraph on this CPU, inside the 30 s request timeout).
`04-live-still-waiting.png` is five seconds after the answer: same page, still no
microphone.

## The three things that were added around it

1. **The thread follows the newest line.** `_HomeTabState._threadScroll` is the
   thread's controller, and `_scrollToLatest` animates to `maxScrollExtent`
   inside a post-frame callback — after the frame that added the bubble is laid
   out, so the target is the *new* end of the thread and not the old one. It is
   called on send and when an answer replaces its placeholder. Proven two ways:
   the widget test (`the thread follows the newest message to the bottom`) sends
   eight messages and asserts the view is at `maxScrollExtent` and the newest
   answer is inside the viewport, and `05-thread-followed.png` is the real app
   after eight messages — "Hey, what do you need?" is gone off the top and the
   newest bubble is the last thing above the composer.
2. **A bubble can be copied, on both sides.** Every bubble is wrapped in a
   `GestureDetector` whose long press writes the whole sentence to the clipboard
   and shows **"Message copied"**. Measured on the real app: the clipboard held
   the previous contents before the press and **"Say OK. Request hotel eight"**
   after it, then **"Copy me please"** for the next one, with the snack bar on
   screen (`06-copied.png`, `07-copied-snack.png`). Placeholders copy nothing —
   "Nexus is thinking…" is not a sentence anybody wants on their clipboard.
3. **Replies are read out loud, and can be heard again.** `_answer` speaks a
   real reply as it lands (`SpeechOutput.current.speak`), and `_liveAnswer` does
   the same on the live page. A small 16dp speaker under every Nexus message
   replays it on demand. The failure notice is deliberately *not* spoken, and has
   no speaker at all: it is the shell talking, not the assistant.
   The fresh composer note changed with it: it used to say typing reached
   nobody, and now says **"Your PC answers — nothing here goes to a cloud."**

   > **Changed after this run.** The speaker was first drawn only where
   > `SpeechOutput.available`; a phone run showed what that looks like — a
   > control on the greeting and not on the answers, which reads as a bug. Every
   > Nexus message now carries a **copy** and a **speaker** in a row under the
   > bubble, and a failed request is a separate red `NexusErrorBubble` with a
   > warning icon, no speaker, and the sentence **"PC not found. On-device AI
   > coming soon."** (the brain now sits behind `LocalAiService`, whose next
   > implementation is the on-device engine). The tests for both are in
   > `test/main_ui_test.dart`: `a PC that cannot be reached shows a red notice,
   > and never says it` and `a reply is spoken as it lands, and can be heard
   > again`.

The field was already locked while listening (`readOnly`, no interactive
selection, unfocused as the session opens — the previous slice's fix, still
covered by `the field cannot be typed into while the mic is open`); the one thing
added is a guard on the IME's submit path, so no keyboard can post a message
while the recognizer owns the field.

## What this does not prove

Nothing here is a phone. The speech engine that reads replies aloud, the
recognizer's real `onRmsChanged` cadence, and the on-device `stopListening()`
round trip are all Android-only, and this desktop has neither: the speaker was
verified with a fake `SpeechOutput` in the widget tests, and the live turn was
verified with a scripted recognizer that reports the same stream the platform
does. Two things still need the phone: that a real recognizer answers
`finish()` with the transcript it had (it does in every dictation hold, which is
the same call), and that the 1.2 s pause feels right against a real room. The
`mic:settle` line is in the shell's log (`adb logcat | grep mic:`) so a device
run can read back exactly when it fired.

`flutter test` is 1145 passing, 2 skipped; `flutter analyze` stays at its pinned
60 findings; `flutter build linux --debug` and `flutter build apk --debug` both
succeed on the final code.
