# Nexus on an iPhone

The iPhone is a **light device**: it pairs, browses and receives files, and shares the
clipboard. The heavy work — the language model, the vision descriptions, anything that
changes the world — happens on the paired PC.

Target device: **iPhone 6s, iOS 15.0.2, 2 GB RAM, arm64**. No Mac is available, so the
build happens on a GitHub macOS runner and the installing happens on the Linux PC.

---

## What works, and what iOS does not allow

| Feature | On the iPhone | Why |
|---|---|---|
| Pairing by QR code | **works** | `mobile_scanner` (iOS 12+), camera permission |
| Mesh connection to a paired device | **works, while the app is open** | pure-Dart sockets; iOS suspends the process in the background |
| Browse a PC's shared folders | **works** | the PC serves the files; the phone only asks |
| Download a file from the PC | **works** | saved into the app's own Documents |
| Rename / delete a file on the PC | **works** | server-side operations |
| Send this phone's clipboard to the PC | **works** | writing to the pasteboard needs no permission |
| Receive the PC's clipboard here | **works, with a visible cost** | reading the pasteboard makes iOS show "Pasted from Nexus" on 15.x; there is no silent read |
| Read text / name objects in a photo | **works** | Apple's Vision framework, on the device — see [Vision](#vision) |
| Wake word ("Hey Nexus") | **not available** | this build bundles it for Android only (`supportsWakeWord`) |
| On-device model (llama.cpp) | **not available** | `kOnDeviceAiPlatforms` is android and linux; a 2 GB phone could not hold the weights anyway |
| Remote control of this iPhone | **impossible** | iOS forbids an app injecting input. The screen and input channels are Android-only |
| Background sync | **not possible** | iOS suspends the app; the socket dies with it |
| Notifications pushed from the PC | **not possible** | Android uses a notification listener; iOS has no equivalent |
| Nearby discovery (LAN scan) | **not yet** | this app announces over UDP multicast, which on iOS needs the paid `com.apple.developer.networking.multicast` entitlement. Pairing by QR avoids the need entirely. `NSBonjourServices` declares `_nexus._tcp` for the day this moves to Bonjour, which needs no entitlement |

Settings says all of this in the app, on iOS, under **This phone**.

---

## Vision

`lib/core/vision_engine.dart` is the one interface for text recognition and image
labelling. The method channel is `dev.nexus.nexus/vision`, and each platform answers it:

| | Android | iOS |
|---|---|---|
| text | ML Kit, `text-recognition:16.0.1` | `VNRecognizeTextRequest` |
| objects | ML Kit, `image-labeling:17.0.9` | `VNClassifyImageRequest` |
| implementation | `android/app/src/main/kotlin/dev/nexus/nexus/VisionBridge.kt` | `ios/Runner/VisionBridge.swift` |

This split exists for one reason: the `google_mlkit_*` Dart packages declared
`s.ios.deployment_target = '15.5'`, and an iPhone 6s cannot run anything above 15.0.2.
CocoaPods would never have resolved a 15.0 build with those pods. Vision has been in iOS
since 13, so it adds no floor and no download.

Nothing in the pod graph now requires more than **iOS 15.0**. If a dependency ever does,
`pod install` fails with the pod's name instead of the build failing on the phone.

---

## How to build

There is no Mac. `.github/workflows/ios-unsigned.yml` runs on a `macos-latest` runner,
builds with `--no-codesign`, and uploads an unsigned `.ipa`.

### It is manual-only, and that has a consequence

The workflow has a single trigger, `workflow_dispatch`. GitHub will only dispatch a
workflow **that exists on the default branch**, so while this file lives only in an
unmerged pull request, `gh workflow run` answers:

```
HTTP 404: workflow ios-unsigned.yml not found on the default branch
```

Merge it to `main` first, then:

```bash
gh workflow run ios-unsigned.yml --ref main -f deployment_target=15.0
gh run watch
gh run download --name nexus-unsigned-ipa
```

One verified run of this build produced:

- `nexus-unsigned.ipa`, 23 MB
- `Payload/Runner.app` → `Runner`, a `Mach-O 64-bit arm64` executable
- `MinimumOSVersion = 15.0`, `UIDeviceFamily = [1, 2]`, `UIRequiredDeviceCapabilities = [arm64]`
- no ML Kit and no ONNX Runtime anywhere in the app bundle

### What comes out is not installable as-is

It is **unsigned**. A sideloader re-signs it with your own Apple ID. A free Apple ID gives
a **7-day** certificate, **3 apps** per device and **10 App IDs** per week.

---

## Installing on the iPhone

### 1. On the iPhone

1. Plug it into the PC, unlock it, tap **Trust**, enter the passcode.
2. **There is no Developer Mode to enable.** Developer Mode arrived in iOS 16; on 15.0.2
   there is nothing to turn on, and the certificate is trusted after install instead.
3. Join the same **Wi-Fi** as the PC — sideloaders refresh over the local network, and
   cellular is not enough.

### 2. On the PC: the USB daemon

`usbmuxd` is what lets anything talk to an iPhone over USB. It is not installed on this
machine, and installing it needs admin rights. Run this yourself:

```bash
sudo pacman -S --needed usbmuxd
```

Then start it, so it is running now and after a reboot:

```bash
sudo systemctl enable --now usbmuxd
```

Check that the phone is visible:

```bash
idevice_id -l          # prints the device UDID when it works
```

`libimobiledevice` (which provides `idevice_id`, `iproxy` and the rest) is already
installed.

### 3. On the PC: sign and install with xtool

```bash
# once: the Apple ID is typed here, by you, and the password never leaves this terminal
xtool auth login

xtool devices                                  # confirm the phone is seen
xtool install nexus-unsigned.ipa
```

Alternatives that work from a non-Mac PC: SideStore, AltStore (needs AltServer), or
Sideloadly under Wine. All of them re-sign the same unsigned IPA; none of them need a Mac.

### 4. After it installs

Settings → General → VPN & Device Management → your Apple ID → **Trust**, otherwise iOS
refuses to launch the app.

Re-sign before the 7 days run out, or the app stops opening.

---

## Why `llamadart` and `open_wake_word` are still dependencies

Neither can be excluded for iOS alone: `pubspec.yaml` has no per-platform dependency
switch, so removing either would also remove it from Android, where both are used.

- **`llamadart`** ships an iOS framework and compiles, but nothing calls it there —
  `kOnDeviceAiPlatforms` is `{android, linux}`, so the on-device model is never offered
  and never loaded on iOS.
- **`open_wake_word`** needed two Podfile changes to build at all (see below). It is not
  used on iOS; `supportsWakeWord` is Android-only.

### The two Podfile changes, and why

1. **`use_frameworks! :linkage => :static`.** `open_wake_word` pulls in the
   `onnxruntime-c` pod, which ships a *statically linked* binary. CocoaPods refuses that
   combination under dynamic frameworks:
   `[!] The 'Pods-Runner' target has transitive dependencies that include statically linked binaries`.
2. **A `post_install` header path for the `open_wake_word` target.** Its podspec searches
   `${PODS_ROOT}/onnxruntime-c/include`, a directory that pod never creates — it ships a
   framework, so the headers live inside `onnxruntime.xcframework`. The plugin's iOS half
   had never been compiled, and failed with
   `'onnxruntime_cxx_api.h' file not found with <angled> include`.

Both are in `ios/Podfile`, with the same reasoning in comments.

---

## What is not done

- **Nothing has been installed on an iPhone.** The build and the `.ipa` are verified; the
  install path is written down, not walked.
- **No iOS implementation of the `dev.nexus.nexus/*` channels.** There are 14 of them and
  they are answered by 5,096 lines of Kotlin. On iOS the Dart side either checks the
  platform first or catches the failure, so nothing crashes — but features behind them
  (torch, phone actions, reminders, USB serial, screen capture, the wake word, the local
  model) do not exist here.
- **Nearby discovery does not work on iOS**, for the entitlement reason in the table
  above. Pairing is by QR.
- **The app icon is Flutter's default.** `flutter create` generated the icon set and
  `flutter_launcher_icons` has not been run for iOS.
