# The first run, a colour wheel, and a device you can forget

Date: 2026-10-18 · build: `flutter build linux --debug`, launched with a **fresh
`XDG_DATA_HOME`** (so the app really was a first run), window 880×960 on a
dedicated workspace, driven through `tool/ui_driver.py`

A first launch used to be the same screen as every other launch, with the model
download buried in Settings. This pass watches the app greet a phone that has
never run it, read that phone's memory, recommend a model from it, and then
never show that screen again — plus the two new things a user can reach: the
accent colour they can pick themselves, and the devices they can forget.

## The run

| # | Frame | What it shows |
|---|-------|---------------|
| 1 | `01-welcome.png` | A fresh install: **Welcome to Nexus. / Let's get your private AI set up.**, then the RAM the app read for itself (**This device has 8 GB of RAM** — `/proc/meminfo` on this desktop, `ActivityManager.totalMem` on Android), the reason in one line, **Recommended: Llama 3.2 1B** with its 771 MB and its blurb, **Download Recommended AI**, **Skip for now** |
| 2 | `02-shell-second-launch.png` | The app stopped and started again with the same data home: **no welcome screen**. It opens on Home, which is the whole contract of `has_onboarded` |
| 3 | `03-theme-section.png` | Settings → Theme with the new accent control: **Accent colour** with the disc, *Buttons, switches and the active tab — Nexus Purple*, and the button that replaced the five presets: **Pick a custom color** |
| 4 | `04-colour-wheel.png` | The wheel itself: an HSV hue wheel with its thumb on the current accent, a brightness slider, RGB/HEX readouts, the hex bar (`Hex #773DDC`) and **Done**. The app behind it is already painted with the accent in force — there is no Apply |
| 5 | `05-devices-tab.png` | Devices: a **bin on every peer** (*My PC*, *Studio Mac*) and none on **This Phone**, then **Pair a device** and **Discover Nearby Devices** |

The preference file the run left behind, exactly as written:

```json
{"flutter.on_device_model":"llama-3.2-1b","flutter.has_onboarded":true}
```

Two facts in one line: leaving the welcome screen — by either button — records
that it has been seen, and the recommendation is what gets *selected*, so the
Settings row offers exactly the download the user skipped.

## What this run does not drive, and why

**The pointer.** This session's virtual mouse (`/dev/uinput` through
`tool/ui_driver.py`) registers with the kernel and moves the cursor, but its
button events never reach the compositor — verified against a workspace-bar
click, which is compositor-level and did nothing. So the walk was driven with
the keyboard (`wtype`), which works, and the frames above are all reachable
that way. The three interactions that need a *drag or a tap* were therefore not
driven here, and are held by widget tests instead:

- **Picking a colour on the wheel** — `test/main_ui_test.dart`: *the colour
  wheel repaints the app while it is being dragged* taps `Pick a custom color`,
  taps the real `ColorPicker` (the package's own gesture surface), asserts the
  whole `ColorScheme` follows and that *Reset* returns to the shipped purple.
- **The forget confirmation** — `test/pair_flow_test.dart`: the bin asks first,
  *Cancel* leaves the pairing alone, the bin + confirm removes the row and says
  so, and the store agrees with the screen.
- **Discover Nearby Devices** — `test/pair_flow_test.dart`: tap → *Looking for
  devices…* with a spinner → two seconds → the snackbar naming QR.

The colour wheel *rendering* in a real window is what frame 4 adds: the package
lays out, the dialog is the app's own theme, and the hex readout is live.

## What changed

| file | what it is now |
| --- | --- |
| `lib/core/onboarding.dart` | `Onboarding.key` (`has_onboarded`) with `isDone()` / `complete()`. A store that cannot be read answers **true**: a first-run page that never ends is worse than one that never shows |
| `lib/core/device_memory.dart` | `DeviceMemory.totalBytes()` — `device_info_plus` on Android (`physicalRamSize`, the number the phone's own settings screen shows) and the existing `/proc/meminfo` reader everywhere else, so the recommendation and `DeviceCapabilities`' own floor check cannot disagree — plus `recommendedModel()` (> 6 GB → the 1B, else the 0.5B), `DeviceMemory.label()` and `recommendationReason()` |
| `lib/main_ui.dart` | `WelcomeView` (RAM row, recommendation, download with progress, skip) behind a `NexusUiApp` gate that draws neither screen until the flag is read; `NexusAccent` as a class with `NexusAccent.custom()` deriving the light and dark readable values; `_AccentRow`/`_AccentWheelDialog` replacing the five swatches; the Devices bin, its red confirm, and Discover |
| `lib/core/system_actions.dart` | four more actions — `set_wifi`, `set_bluetooth`, `set_volume`, `set_brightness` — in the vocabulary, the prompt rules the model reads, the parser (states are `on`/`off`, levels are whole numbers in range) and the planner. The shell writes **no** sentence for them: only the phone knows whether Android allowed the switch |
| `android/…/MainActivity.kt` | `setWifi` / `setBluetooth`: attempt the real switch (`WifiManager.setWifiEnabled`, `BluetoothAdapter.enable`), check what actually happened, and fall back to the system panel with a sentence that says which of the two happened |
| `AndroidManifest.xml` | `CHANGE_WIFI_STATE`, without which the attempt is not even legal |

## Not covered here

**The phone.** No device was on adb for this pass, so none of the four new
system actions has been run on Android: `set_wifi` and `set_bluetooth` are
best-effort by design (Android 10 and 12 stopped letting ordinary apps switch
those radios) and on the A25 they will most often end at the settings panel —
which is exactly what the Kotlin does not claim otherwise, but it has not been
watched on a phone. Volume and brightness go through the same handlers the
command surface already used; those are new only as *action vocabulary*.

**The wheel's own drag on a phone.** A wheel is a finger control, and the only
gesture evidence is a synthetic tap in a widget test.
