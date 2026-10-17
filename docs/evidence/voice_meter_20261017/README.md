# The voice meter — photos of the running shell, and the numbers behind them

Captured 2026-10-17 from `lib/main_ui.dart` running as a Linux desktop window
(941 × 987 logical px, 2× capture). They are for *looking* at the meter, not a
phone measurement: this machine has no Android recognizer, so the app was driven
by `tool/preview_live.dart` (deleted after the photographs), a scripted
recognizer that reports loudness exactly the way Android's
`RecognitionListener.onRmsChanged` does — `-2` for a quiet room, `+10` for a
raised voice, straight down the same channel and the same
`SpeechInput.rms` stream the real one uses.

| photo | what it shows |
| --- | --- |
| `01-dictation-quiet.png` | dictation open, room quiet: the bars are dots |
| `02-dictation-loud.png` | a raised voice: the middle bar at full height, with **"hello there, how are you"** readable beside it |
| `03-dictation-soft.png` | ordinary speech: the same sentence, shorter bars |
| `04-dictation-paused.png` | the user stopped: dots again, the sentence still in the field |
| `05-draft-kept.png` | the stop square ended the session and kept the words; the meter is gone with it |
| `06-live-loud.png` | live conversation: the same readings, the dark page's own meter |
| `07-live-quiet.png` | live conversation, nothing being said |
| `08-closed.png` | the X closed the page; the composer still holds its draft |

## The numbers

`bars_probe.py` measures the tallest run of accent pixels in the composer pill —
the tallest bar. Run against every shot in this folder:

```
01-dictation-quiet.png       tallest accent column =   6 px (2x)   (~3.0dp)
02-dictation-loud.png        tallest accent column =  48 px (2x)   (~24.0dp)
03-dictation-soft.png        tallest accent column =  20 px (2x)   (~10.0dp)
04-dictation-paused.png      tallest accent column =   6 px (2x)   (~3.0dp)
05-draft-kept.png            tallest accent column =   0 px (2x)   (~0.0dp)
06-live-loud.png             tallest accent column =  24 px (2x)   (~12.0dp)
07-live-quiet.png            tallest accent column =   4 px (2x)   (~2.0dp)
08-closed.png                tallest accent column =   0 px (2x)   (~0.0dp)
```

Which is the design to the pixel. `kNexusBarMaxHeight` is 24dp and the loud shot
measures 24.0; a silent room sits on `kNexusBarMinHeight`, 3dp, and measures 3.0;
ordinary speech is `rmsToLevel(2) = 0.333` → `3 + 21 × 0.333 = 10` and measures
10.0. The meter leaves the tree with the session (0 in `05` and `08`), and the
live page's own meter — the same widget, a taller minimum — measures 2.0dp quiet
and 12.0dp for the bar profile that stands at its left edge. **The bars are
driven by the readings, not by a timer**: nothing changed between those frames
but the numbers fed to `SpeechInput.rms`.

Each bar is a plain `Container` rather than a
ticker or an animated one (see the second-run note below — both the 110ms and the
50ms easing it went through were measured as lag on a phone): a reading moves a
bar, and nothing else does — a meter that moved while the
room was quiet would say the phone was hearing a voice, which is the one claim it
must never make. Those four heights were measured again in the final code, after
the mechanism settled, by rendering the composer and reading the frame back:
**6 px quiet, 48 px loud, 20 px soft, 6 px paused** at 2× — the same numbers as
the captures, with the same one-pixel slack for the rounded ends. That last probe
is deliberately not kept as a test: reading a frame back needs real async, and in
this harness real async is also what lets the shell's runtime font load reach out
to the network, where it fails and reports itself. An artefact of the harness
rather than of the meter — but enough to make a committed pixel test fail for
reasons that have nothing to do with the bars. What *is* committed is
`test/main_ui_test.dart`'s `the bars stand up with the voice and fall back to
dots`, which measures the same 3dp / 10dp / 24dp through the layout engine.

The pill in `02-dictation-loud.png`, read back with OCR while the bars are at
full height:

```
@ ""l hello there, how are you o
```

— the sentence is legible *beside* the meter. That is the layout decision this
change made: the bars stand between the X and the text, never behind it.

## What this does not prove

Nothing here is a phone. The real `onRmsChanged` also brings its own timing,
its own noise floor and its own device quirks, and the six on-device checks still
need `adb` and a real recognizer. What the captures do prove is that the reading
travels from the platform seam to the pixels: the same stream, one number in,
one bar height out, in the direction and at the scale the design asks for.

`run.log` is the app's own `mic:` output from the session these photographs came
from — session starts, partial words, and the two endings (`stopped` for the
stop square, `closed` for the live page's X).

## The fixes, and what the second phone run changed about them

The photographs above predate all of them. They cover three questions: who owns
the field while the mic is open, which theme the live page is, and whether live
conversation ever opens the microphone without being asked.

**The meter is now instant, because the phone said the easing was the lag.** The
50ms `AnimatedContainer` written after the first phone report was still too slow
on hardware — a bar that eases towards a reading is a bar that is always behind
it. Every bar is a plain `Container` now: no tween, no implicit animation, no
curve, no timer. The reading rebuilds the row and the height *is*
`minHeight + (maxHeight - minHeight) × level` — for the middle bar, exactly
`3 + 21 × level` dp. `onRmsChanged` in `MainActivity.kt` logs every reading it
receives as `rms_val: <dB> t=<elapsedRealtime>` (`adb logcat | grep rms_val`),
which is the measurement that decides whether the platform is even delivering
readings fast enough to look live, and the numbers a future calibration reads.

1. **The field is read-only while listening, and the keyboard leaves.**
   `_Composer`'s `TextField` is `readOnly: listening` with
   `enableInteractiveSelection: !listening`, and `_listen` unfocuses the field as
   its session opens, so the keyboard and the recognizer can never both be
   writing the same draft — the unfocus is what closes the live input connection
   a focused field would otherwise still be holding. Stop or X ends the session
   and the draft is editable again; the test types at the field through a real
   input connection while the mic is open and proves nothing lands.
2. **The live page follows the theme.** `_LivePalette.of(context)` gives the
   page the app's surface and ink in light mode and keeps the immersive
   `kNexusLiveGround` (`#111113`) in dark mode. The old page was that dark ground
   in both brightnesses, which is how a light-theme phone ended up with a black
   screen it could not explain.
3. **Live conversation never opens the microphone by itself.** The auto-restart
   timer is gone — `kNexusLivePause` no longer exists and `_HomeTabState` holds
   no live-mode timer at all. The page has two live states: `listening` (purple
   breathing orb, red-washed "Recording" pill) and not-listening, which is either
   `waiting` — a turn was heard, the orb is grey and still, the pill is grey and
   says "Mic off", and the status line says "Mic off — tap to continue." — or
   `guarded`, which is where the 30-second guard leaves it and which says "Mic
off. Nothing is recording." Both wait for a tap, and there are two ways to give
   it: the "Tap to continue" button, or the orb itself, which is the biggest
   thing on the page. "The mic is on if and only if the page says Listening" is
   now a property of the code rather than a promise about it.

The committed cover is `test/main_ui_test.dart`: `the field cannot be typed into
while the mic is open`, `the composer pill is the theme's surface in both
themes`, `live conversation takes the dark ground in dark mode`, `live
conversation listens at once, then waits to be asked` (which pumps thirty
seconds at a waiting page and proves the microphone is still closed, then opens
the next turn from the button and the one after that from the orb), and the
rewritten `the guard ends a live turn nobody finishes` — where thirty more
seconds change nothing and the resume tap opens a fresh turn that answers to the
same guard. `flutter analyze` stays at its pinned 60 findings; `flutter build
apk --debug` succeeds on the final code.

**The phone itself is still the last word.** The previous pass was blocked
because the device was in the user's hand, and the fixes above came from the
user's own hardware findings rather than from this repo's measurements: the
`rms_val` line is what should settle the meter's cadence next, and one
uninterrupted run should confirm the live page never returns to "Recording"
without a tap.
