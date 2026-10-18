# The Pro shell on the A25: what really happened

Date: 2026-10-18 · `flutter build apk --debug` · installed over wireless adb on a
**Galaxy A25 5G (SM-A256E), Android 16 (One UI 8)**, 1080×2340 @ 420 dpi, 6 GB
of RAM of which Android reports 5.5 GB usable · driven entirely over adb
(`input tap`/`input text` and `uiautomator dump` for the targets' real bounds)

The desktop pass (`docs/evidence/pro_shell_20261018/`) watched the new screens on
a big window with a keyboard. This pass put the same build on the phone the app
is actually for, and it found four things the desktop could not.

## The run

| # | Frame | What it shows |
|---|-------|---------------|
| 1 | `01-welcome.png` | A genuine first launch (`has_onboarded` absent from a fresh install): **Welcome to Nexus. / Let's get your private AI set up.**, the RAM it read (**This device has 5 GB of RAM** — `/proc/meminfo` says 5,517,752 kB), **Recommended: Qwen 2.5 0.5B** with its 469 MB, **Download Recommended AI**, **Skip for now** |
| 2 | `02-home-after-skip.png` | **Skip for now** lands on Home. `has_onboarded` is `true` in `shared_prefs` — the screen does not come back |
| 3 | `03-settings-theme.png` | Settings → THEME on the phone: Follow system, Dark mode (disabled while following), **Accent colour — Nexus Purple**, **Pick a custom color** |
| 4 | `04-colour-wheel.png` | The wheel, opened on the accent in force: the thumb sits on the purple hue, the swatch and `Hex #773DDC` agree. Dragging on the wheel repaints the app behind the dialog — no Apply |
| 5 | `05-devices.png` | Devices with a bin on both peers and none on This Phone, **Pair a device**, **Discover Nearby Devices** |
| 6 | `06-forget-dialog.png` | The bin opens **Forget this device? / My PC will have to pair with this device again before it can send or receive anything.** with Cancel and a red **Forget** — nothing has happened yet |
| 7 | `07-discover-snackbar.png` | Discover spends two seconds as **Looking for devices…** with a spinner, then the snackbar: **Nearby discovery coming soon. Use QR for now.** |
| 8 | `08-model-download.png` | A real 469 MB download over the phone's Wi-Fi: **Downloading Qwen 2.5 0.5B / 67% of 469 MB — keep Nexus open**, and `LLM: model cached (469 MB, hash ok)` in logcat — the SHA-256 is checked on the device |
| 9 | `09-volume-action.png` | `set volume to 30` → **ⓘ Volume set to 30%.** — an executed action, and the music stream really moved (`STREAM_MUSIC` speaker 4/15) |
| 10 | `10-model-claims-brightness.png` | `set brightness to 60` → **Brightness set to 60%.** as *ordinary prose*, twice, on both models, while `settings get system screen_brightness` stayed 41 and the mode stayed automatic |
| 11 | `11-accent-survives-restart.png` | After picking a lime on the wheel, `am force-stop` and a cold launch: the app opens in that lime. `flutter.accent_seed = 4290829362` (`0xFFC0DC32`) on disk. Reset afterwards put it back to purple (`0xFF773DDC`) |
| 12 | `12-16kb-compatibility.png` | The debug build's own warning on Android 16: **"This app isn't 16 KB-compatible. ELF alignment check failed"** — `libonnxruntime.so`, `libllama.so`, `libggml-*.so`, `libimage_processing_util_jni.so` |

## What was fixed because of this pass

**The accent was not a preference.** It lived in `_NexusUiAppState._accent`, so
the lime survived until Android reclaimed the process — on a phone, hours. It is
now `flutter.accent_seed`, read in `main()` **before the first frame** (a
`setState` after the first frame would flash the shipped purple and swap under
the user's eyes) and written on every change. `test/appearance_test.dart` holds
the three facts: a stored seed opens the app in that colour, the purple seed is
answered by the shipped purple and not by a derived lookalike, and a store that
cannot be read costs the colour rather than throwing.

**A brightness write is now checked, not assumed.** `MainActivity.setBrightness`
used to call `Settings.System.putInt` twice and report success. It now reads the
value back and, when the write did not land, opens the display settings and says
so instead of claiming the screen changed. (This pass never made the action fire
— see below — so the guard is covered by reasoning and by the Kotlin compile,
not by a phone run.)

## What this pass found and did *not* fix

**The model can claim an action it never took — fixed, not yet re-run on the phone.** The shell's chat path read the reply, and only if the *whole* reply was one JSON object did anything happen; there was no deterministic path at all, while the older shell (`assistant_view.dart`) had always used `CommandInterpreter` first. Worse, the interpreter did not know the phrasing that was used: `brightness` had to arrive as "brightness 60", so "set brightness to 60" was handed to the model. `actionFromPhrase` in `system_actions.dart` now bridges the interpreter's vocabulary to `SystemActionCall`, `_send` runs that before it reaches for the model, and the interpreter takes "set brightness to 60" (and "set the volume"). `test/action_phrase_test.dart` holds both halves: the eight phrasings that must execute and the ones that must not (a bare "flashlight" is a toggle, "dimmer" is a relative step, "brightness 300" is out of range — all left to the model rather than guessed). The APK was built and installed once more at 17:5x, but **the phone dropped off the network before this build could be exercised**, so the phone-side proof of the four actions is still owed.

The original finding, for the record:** `shared_prefs` is explicit
about it: `"Volume set to 30%."` is stored with `"system": true`, while
`"Brightness set to 60%."`, `"Bluetooth turned on."` and `"Flashlight turned
on."` are stored as ordinary assistant text. The 0.5B and then the 1B both
answered the brightness request with the exact sentence pattern of the previous
*successful* action, and `screen_brightness` never changed. That is the worst
failure mode this app can have — the one thing its whole pitch forbids — and it
is a prompt/history problem, not a channel problem: the same channel executed
`volume` correctly one message earlier. The next pass should look at whether the
shell's own outcome lines leak into the model's history (they are supposed to be
filtered), because a lie the model tells once becomes context it copies.

**16 KB page alignment is a release blocker on this phone.** The debug build
runs, but its native libraries (`llamallama`/`ggml` from `llamadart`, ONNX
Runtime, some Flutter plugins) are not 16 KB-aligned. Android 15+ phones with
16 KB pages — and Play's checks — will refuse them. This is a dependency upgrade,
not a code change.

**"This device has 5 GB of RAM" on a phone sold as 6 GB.** `totalMem` reports
the usable figure (5.52 GB) and the label truncates. The recommendation is
correct by the rule the task set, but the number reads as a bug to somebody
holding a 6 GB phone.

**Selecting a model that is not downloaded silences a model that is.** Tapping
Llama 3.2 1B moved the selection before its 771 MB existed, and the AI status
row went from *Answers on this device* to *No AI available* while a working
469 MB model sat on the disk. Honest, but it turns a two-tap experiment into a
three-minute outage.

**Design notes, small.** The snackbar is Material's inverse surface — a white
pill in a near-black app. The copy glyph under each answer is unlabelled and
sits orphaned below error cards. `HEX ▾` in the wheel looks like a dropdown and
is not one, and the RGB row duplicates the hex field two lines above it.

## Not tested, and why

**Wi-Fi.** `adb` is connected over Wi-Fi, so a test that turned the radio off
would have ended the session and taken the phone off the network. The Wi-Fi path
(`setWifiEnabled`, then the panel fallback) is the same shape as the Bluetooth
one, and neither was reached by the model in this pass.

**The torch.** No camera/flash state could be attributed to the app: the reply
was prose, and the only camera lines in logcat are from another app's session.

**A second model swap at runtime.** Both models ended up downloaded (469 MB +
771 MB), but the swap between two *present* files — the disposal path that keeps
two engines from living at once — was not driven on the phone.
