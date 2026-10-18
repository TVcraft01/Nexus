# System actions: the model asks, the app does, the thread says so

Date: 2026-10-18 · build: `flutter build linux --debug`, run against **the real
Ollama on this machine** (`llama3.2`, 2.0 GB) with no fake in the loop · window
880×1000 on a dedicated workspace, driven through `tool/ui_driver.py` (hyprctl,
grim, tesseract, `/dev/uinput`, wtype) · a separate `XDG_DATA_HOME`, so the run
started from an empty thread

The assistant could read and talk; it could not *do*. This slice gives it five
things it may ask for — torch, alarm, timer, app, battery — and gives the shell
the only two decisions that matter: is this reply an action, and what does the
user see afterwards.

## The run

```
flutter build linux --debug
XDG_DATA_HOME=/tmp/nexus-actions/data ./build/linux/x64/debug/bundle/nexus
python3 tool/ui_driver.py ... type "set a timer for 30 seconds"
python3 tool/ui_driver.py ... type "turn on the flashlight"
python3 tool/ui_driver.py ... type "hello, who are you?"
```

| # | Frame | What it shows |
|---|-------|---------------|
| 1 | `01-shell.png` | The thread before anything: "Hey, what do you need?", and the composer's brain note, *Your PC answers — nothing here goes to a cloud* |
| 2 | `02-timer-pill.png` | `set a timer for 30 seconds` answered by a pill: **✓ Timer set for 30 seconds.** — the model wrote `{"action":"set_timer","seconds":30}`, and none of it reached the screen |
| 3 | `03-two-pills.png` | The next turn, `turn on the flashlight`: **ⓘ I can't use the flashlight on Linux — Nexus does that on your phone.** The refusal is the Linux backend's own sentence, and the pill is grey rather than red because a fact is not a fault |
| 4 | `04-prose-still-answers.png` | `hello, who are you?` → *I'm Nexus, your private assistant.* in an ordinary bubble, with copy and speaker. The action vocabulary did not turn the assistant into a command parser |

The timer in frame 2 really ran: `DesktopDeviceActionBackend` sends
`notify-send` and sleeps, which is the desktop's version of the phone's
`AlarmClock.ACTION_SET_TIMER`.

## What changed

| file | what it is now |
| --- | --- |
| `lib/core/system_actions.dart` | the vocabulary (`kSystemActionNames`), the rules the model is given (`kSystemActionRules`), the strict parser (`SystemActionCall.tryParse`), the runner (`DeviceSystemActions`) and the `SystemActions` seam. Parsing is brace-counting inside prose, then `jsonDecode`, then a per-action range check — an unknown name, a missing argument, `24:10`, a zero-second timer or `"state":"maybe"` is **not an action**, it is text |
| `lib/core/on_device_ai_service.dart` | the persona's third rule changed from *"you can only talk"* to *"never say you did something yourself — the app does it and tells them"*, and the system turn is now the persona plus the five actions |
| `lib/core/ollama_service.dart` | the same rules for the PC: `system` on `/api/generate`, a leading system message on `/api/chat`. A `const` field, so a test can assert what the model was told without reading the wire |
| `lib/main_ui.dart` | the interception, in both the thread and the live page: a reply that opens with `{` does not stream into a bubble (half a JSON object is not a sentence), a parsed call is run before anything is shown, and the result replaces the placeholder as `NexusSystemBubble` — a raised pill with a tick or an information mark. Malformed JSON, an unknown action and plain prose all fall through to the ordinary bubble, unchanged |

The native side is the one that was already there: `AgentActions.flashlightToggle`,
`alarmSet`, `timerSet`, `appOpen` and `batteryGet` are wired to
`dev.nexus.nexus/device` (`torch`, `setAlarm`, `setTimer`, `openApp`, `battery`)
and covered by `test/device_executor_test.dart`. This slice adds a vocabulary and
a sentence, not a second channel.

## The bug the run found

The first pass excluded the action line from the history the model is shown —
the reasoning being "the shell said it, the model didn't". On the second turn
that produced **two user messages in a row**, and `llama3.2` answered `turn on
the flashlight` by setting the timer again. Measured directly:

```
history: [user: set a timer for 30 seconds, user: turn on the flashlight]
  → {"action":"set_timer","seconds":30}
history: [user: set a timer for 30 seconds, assistant: Timer set for 30 seconds.,
          user: turn on the flashlight]
  → {"action":"set_flashlight","state":"on"}
```

So the pill goes back as the assistant's own turn. It is still drawn as a pill
and still never written by the model; it is only *context* that it was said.
`test/main_ui_test.dart` pins the corrected shape.

## What is covered by tests instead

- `test/system_actions_test.dart` — 15 tests: the vocabulary and the rules
  agreeing with each other, all five parses, a JSON block inside a chatty
  sentence, braces inside a string, every near-miss refused (unknown action,
  missing or out-of-range arguments, truncated JSON, a bare array, prose), the
  action-and-argument mapping onto the native method for each of the five, the
  shell's wording for the three it knows completely, the phone's wording for the
  two it knows better, a refusal staying a refusal, and a channel that throws
  becoming a sentence rather than a stack trace.
- `test/main_ui_test.dart` — 5 widget tests: an action reply becomes a pill and
  the JSON never appears (including after a relaunch), a near-action is shown as
  the answer it is and nothing is run, a refused action keeps the phone's words,
  the action line travels back to the model as the answer it was, and a spoken
  request on the live page is run there too — the pill in the large type, then
  the same line in the thread when the page closes.
- `test/ollama_service_test.dart`, `test/on_device_ai_service_test.dart` — the
  system turn actually carries the rules on both the PC and the phone, and a
  conversation is still sent as a system turn followed by the turns.

## Not covered here

**Android.** The release APK builds (`flutter build apk --release`, 212.8 MB)
but the phone never stayed on adb long enough to receive it: it was off wireless
debugging at the start of this pass, came back on USB partway through, and
dropped again during the 212 MB install — so the five native methods were not
exercised on hardware here. They are the methods the command layer has been
using (`torch`, `setAlarm`, `setTimer`, `openApp`, `battery`), and the mapping
onto them is what `test/system_actions_test.dart` pins, but two things still
need a phone: that the 0.5B model follows the JSON instruction at all, and that
the torch visibly comes on from a pill. `adb install -r
build/app/outputs/flutter-apk/app-release.apk` then "it's dark in here" is the
whole check — and the one chip worth watching is the 0.5B model, not the
channel.
