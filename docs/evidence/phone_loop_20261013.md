# The agent loop on the real phone — 2026-10-13

Verification pass on device **R5CX73XFGKW** (SM-A256E), app `dev.nexus.nexus`
0.2.1+155, headless PC, adb only. No fixes were planned for this pass; one bug
was found and fixed (see last section). Everything below is what the phone
actually did, quoted from the screen or from logcat.

## 1. Phone sanity

```
$ adb devices -l
R5CX73XFGKW            device usb:3-2 product:a25xdxx model:SM_A256E device:a25x transport_id:3

$ adb shell dumpsys package dev.nexus.nexus | grep -E "versionName|versionCode|lastUpdateTime"
    versionCode=155 minSdk=24 targetSdk=36
    versionName=0.2.1
    lastUpdateTime=2026-10-13 10:54:15
```

Rebuilt and reinstalled from HEAD for this pass (the phone had a 09:30 build of
the same versionCode, older than the agent-loop commits + the fix below).
Build: `JAVA_HOME=~/tools/jdk-21.0.12.1+1 flutter build apk --release` →
166.4 MB, `adb install -r` → Success.

## 2. The model loads on-device

```
$ adb logcat -c && adb shell am start -n dev.nexus.nexus/.MainActivity  (10:54)
10-13 10:54:32.148 25545 25545 I flutter : LLM: CPU ready, ctx 2048, 4t
```

`LLM: CPU ready, ctx 2048, 4t` — the Qwen2.5-0.5B q4 file loads and runs on the
phone's CPU. The status line under the title read `Local brain: Qwen2.5 0.5b q4`
for the whole pass (with a peer paired it does not use the phone-only
"On this device" wording). The model unloads after 300 s idle:

```
10-13 10:04:08.841 32321 32321 I flutter : LLM: qwen2.5-0.5b-instruct-q4_k_m unloaded after idle (300s)
```

## 3. "what's in my downloads" — the on-device tool loop, end to end

Typed with `adb shell input text` (apostrophe via `keyevent 75`), submitted with
the IME's Send action (the app's Send button sits under the keyboard; a tap at
its bounds hits the keyboard's action row).

The card ran the loop's own label — `Looking in Downloads…`, which only
`ToolCall.runningLabel` produces (`lib/core/agent_tools.dart:107`) — so the
phone's model emitted `TOOL:list_local_files {"dir": "Downloads"}` on-device and
the tool ran. Then the answer:

> The Downloads folder contains various files including .eslintrc.json, .exmu-cfg1.data, .gitattributes, .gitignore, .naf.txt, 0bDIUiE.png, 1CDC722C-A7E4-4279-94FA-2989D1F5762E.jpg, 200605_-_Aime.JPG, 2026-02-28T21_59_07.png, 2026-06-21_01.57.53.png, 2jHE4jz.gif, 59c9b29035735f04515ed6eb91e102f3-removebg-preview.png, 8 bit up sound effect. Part-2.mp3, 810f1cf3…

Cross-checked against the phone:

```
$ adb shell ls -a /sdcard/Download/
.eslintrc.json  .exmu-cfg1.data  .gitattributes  .gitignore  .naf.txt
.temp_mivideo/  0bDIUiE.png  1CDC722C-A7E4-4279-94FA-2989D1F5762E.jpg
200605_-_Aime.JPG  2026-02-28T21_59_07.png  2026-06-21_01.57.53.png
2jHE4jz.gif  59c9b29035735f04515ed6eb91e102f3-removebg-preview.png
8 bit up sound effect. Part-2.mp3  810f1cf3fcba1d78231e1521562fb813a03fb9fe_0.png
```

Every name the answer gave exists in `/sdcard/Download/`, in `ls` order,
including the dotfiles a plain `ls` hides (the tool lists them). Two honest
caveats: the 0.5B dropped `.temp_mivideo/` (a directory, listed with a trailing
`/` in the observation) from its sentence, and the card is clipped under the
fold — the visible text ends at `810f1cf3…`. No crash, no "couldn't answer".

Latency: ask → `Looking in Downloads…` ≈ 24 s; answer ≈ 33 s. The model is
slow but not stalled.

Screenshot: `shots-phone-loop-20261013/06-looking-in-downloads-on-device.png`,
`07-downloads-answer-on-device.png`.

## 4. Fetch from the rehearsal PC

Peer: `NEXUS_PEER_DIR=/tmp/nexus_rehearsal_dev NEXUS_PEER_PORT=51820
NEXUS_PEER_MINUTES=25 flutter test test/rehearsal_peer.dart`.

```
$ adb reverse tcp:51999 tcp:51820            # device 51999 -> PC 51820
$ adb shell am start --activity-single-top -a android.intent.action.VIEW \
    -d 'nexus://pair?address=127.0.0.1&port=51999&code=UTZJ-69BM&expires=…'
10:24:57.882 12807 I flutter : NEXUS mesh: pair-accept <- peer-pc
10:24:57.885 12807 I flutter : NEXUS mesh: pairWith -> ok
10:24:57.885 12807 I flutter : NEXUS cable: automatic pairing succeeded
```

Peer side: `pair-request <- goou4tt557c220n1qbudc3xiq65c6hdf (code matched)`,
then pings from 127.0.0.1. The status line went to
`Ready - all 1 devices reachable`.

Typed **"get report.pdf from rehearsal pc"** (the mission's phrase) — the
interpreter's own `file.fetch` shape, so the model is not consulted: the fetch
ran and the file landed as a second copy, because the phone already had one
byte-identical `report.pdf` from the 2026-10-11 pass:

```
$ adb shell ls -la /sdcard/Download/report*.pdf
-rw-rw---- 1 u0_a260 media_rw 4096 2026-10-13 10:31 /sdcard/Download/report (1).pdf
-rw-rw---- 1 u0_a260 media_rw 4096 2026-10-11 17:38 /sdcard/Download/report.pdf
$ sha256sum # both == the peer's served file
d010f6d76d0eb4dce5d5b5b34014a8a157ec4380a66c24d7d455a9bf652db14a
```

Card: `report (1).pdf · 4.0 KB - from Rehearsal PC`. Path and size confirmed on
the device. Screenshot: `shots-phone-loop-20261013/08-typed-fetch-landed.png`.

### The model-chosen `get_file` did not happen on-device

That phrase is parsed, so to exercise the tool the ask has to miss the parser.
Two such asks were run (`hey can you pull report.pdf off the rehearsal pc`,
typed twice, 61 s recorded twice):

* the card stayed on `Thinking…` for 20-60 s, then answered with **no tool
  label** — no `Fetching report.pdf…` (the loop's `getFile` label) and no
  `Looking in …` in any of the 122 recorded frames;
* no file ever landed (no third copy in Downloads);
* the answer, verbatim, both times:

> I'm sorry, but there seems to be an issue with your request. The device name
> "Rehearsal PC" is not found in the list of paired devices on this device.
> Could you please check if that's the case?

That is the model's own sentence, not the app's: the app's message for an
unresolvable fetch is `I don't see a paired device named "X".` and the card for
a fetch that ran is the file card above. So on this phone the 0.5B answered the
fetch ask in prose instead of emitting a valid `TOOL:get_file` line.

An earlier run with a typo'd ask (`geget report.pdf from rehearsal pc`, also
unparseable) answered with the *prompt's example* device name:

> I'm sorry, but there seems to be an issue with your request. There is no
> paired device named "My PC". Could you please check if that's the case?

`My PC` is the example in the tool block (`lib/core/agent_tools.dart:178`) and
is not a device on this phone (`Rehearsal PC` is). The tool block teaches a
device name the user does not have, and the phone's model copies it.

Screenshot: `shots-phone-loop-20261013/10-model-fetch-confabulation.png`.

## 5. "hello"

Typed and submitted the same way. Answered in ~12 s:

> Hello, TVcraft01! I can tell you the time, do math, search the web, save
> notes, show your PC specs, and copy text between your devices. Ask me
> anything — and if I don't understand, I'll ask you to teach me.

A greeting, personalized from the profile; no `TOOL:` line, no `{…}` syntax
anywhere on screen (grep of the screenshot: none). Screenshot:
`shots-phone-loop-20261013/09-greeting-on-device.png`.

## 6. What the on-device 0.5B did worse than desktop inference

| | desktop (1.5B / 0.5B) | phone 0.5B, on-device |
|---|---|---|
| `list_local_files` | valid TOOL line | **also valid** — the card ran `Looking in Downloads…` and a real listing came back (24 s) |
| `get_file` | valid TOOL line | **no tool line**: two 61 s runs, `Thinking…` then a prose refusal with no tool label and no file |
| device argument | — | copies the prompt's example (`My PC`), which resolves to nothing; a real device name in the ask did not fix it |
| grounding | names from the observation | dropped `.temp_mivideo/` from the listing it was given |
| speed | seconds | 12 s greeting, 24 s to the tool call, ~60 s+ for a tool-loop answer |
| protocol hygiene | clean | clean — no TOOL/JSON syntax ever reached the card, including on the fumble |

## 7. Bug found and fixed: the tool's own example sentence never reached it

Before this pass, on the phone, **"what's in my downloads" opened Chrome with a
Google search for "in my downloads"** (screenshot
`shots-phone-loop-20261013/03-downloads-answer.png`, 09:42) while
"what files are in my downloads" reached the model and listed the folder. The
`what is X` memory rule is the cause: `normalizePhrase` turns "what's" into
"what is", the rule claims the sentence, the topic is the literal string
`in my downloads`, no stored fact matches it, and `answers.dart` falls back to a
web search for that string — with the folder one tool call away. The phrase is
also the exact example in the tool block the model is given, so the documented
way to ask for a listing could not work.

Fix (`lib/core/command_interpreter.dart`): when the object of a `what is …`
question is a folder location — `in`/`inside` + one of
Downloads/Documents/Pictures (docs, photos, pics) — the rule no longer claims
it. The sentence falls through to the local brain, whose `list_local_files`
tool answers it, exactly as the tool prompt says. General knowledge
("what is the capital of france") and the personal ask-back ("what is my wifi
password") are untouched.

Verified after `flutter test test/command_interpreter_test.dart` (all pass,
including the new case), `flutter test` on the interpreter/service/loop/intent
suites (242 pass) and `flutter analyze` (no new issues in the touched files):
rebuilt, reinstalled, and the same phrase on the phone now runs
`Looking in Downloads…` → the listing above. No browser.
