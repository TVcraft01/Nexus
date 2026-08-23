# Nexus — your devices, one system

A local-first mesh where your devices find each other, pair in seconds, and talk
to each other directly. **No cloud, no account, no third-party server** —
everything stays on your own devices and your own network.

The heart of the vision is a voice-first personal assistant that lives on your
hardware and acts across your devices. The mesh below is the ground that
assistant stands on: without devices that can find, trust, and talk to each
other, nothing else works.

One Flutter codebase: Android + Linux today, Windows next, then macOS and web.

## What works right now (v0.1 — the mesh)

- **Devices find each other** on the same network automatically (multicast
  discovery). No configuration, no server.
- **Honest presence.** A device shows *Online* only when we have actually
  talked to it directly over TCP in the last few seconds. Discovery only makes
  a device *visible* — the app says so when something is "Seen on network" but
  not reachable. Nothing ever claims to work when it doesn't.
- **Pairing in seconds.** One device shows a QR code + an 8-character code
  (valid 5 minutes). The other enters it (or scans the QR on Android later).
  The code *is* the shared secret: the pairing handshake and everything after
  it is encrypted with a key derived from it (AES-GCM + HKDF). A stranger on
  your network can't pair with you and can't read your traffic. A device that
  sends a wrong code is rejected.
- **Clipboard everywhere.** Copy text on any device; it appears on every
  paired device's clipboard tray, encrypted end to end. Nothing overwrites
  your clipboard without you choosing — auto-apply is off by default.
- **Address re-finding.** If a paired device's IP changes (router reboot),
  the next successful contact updates its stored address automatically.
- **Everything persists on-device** — identity, pairing secrets, clipboard
  history — in the app's private data directory. Nothing leaves your device.

## What's verified

- 21 automated tests pass, including a **real two-instance pairing and
  encrypted clipboard exchange over localhost** (two `MeshService` instances
  on the same machine), wrong-code rejection, tamper/truncation rejection,
  offline honesty, and persistence across restarts.
- The Linux release binary runs clean and announces itself on the network
  (verified with an external UDP probe).
- The Android debug APK builds successfully.

What has **not** been verified yet: real Wi-Fi pairing between two physical
devices, and the UI end to end on a phone. That's the first thing to test.

## Try it (one machine, two windows)

You can test the whole mesh on a single computer:

```bash
# terminal 1 — first instance (default data)
./build/linux/x64/release/bundle/nexus

# terminal 2 — second instance with its own identity
NEXUS_DATA_DIR=/tmp/nexus2 ./build/linux/x64/release/bundle/nexus
```

Both windows discover each other ("Nearby"), then pair: on one, *Pair a
device → Show my code*; on the other, *Pair a device → Enter a code* (address
should be prefilled as 127.0.0.1). After pairing, copy text in one window and
watch it arrive in the other's clipboard tray.

> The second instance may note "Port 51820 was busy — using port X". That's
> the app being honest, not a bug.

## Try it (phone + PC)

1. Plug your Android phone in and run `flutter run -d <device>`, or install
   `build/app/outputs/flutter-apk/app-debug.apk`.
2. Run the Linux app on your PC. Both devices are on the same Wi-Fi.
3. Pair as above. Copy something on the phone; it lands on the PC's tray and
   vice versa.

## Auto-update

Both platforms update themselves from GitHub releases on startup:

- **Linux**: the app shows an **"Update & restart"** banner, downloads the new
  build, swaps it in, and relaunches.
- **Android**: the app shows an **"Update & install"** banner, downloads the APK,
  and hands it to the system installer (you confirm in the OS dialog).

Every push to `main` builds both the Linux bundle and Android APK on GitHub
Actions and publishes them as a release. `./update.sh` for manual rebuilds.

## Building

```bash
flutter pub get
flutter build linux --release   # → build/linux/x64/release/bundle/nexus
flutter build apk --debug        # → build/app/outputs/flutter-apk/app-debug.apk
flutter analyze && flutter test  # checks + all tests
```

## Roadmap (in order)

1. **The mesh** — ✅ done (v0.1): discovery, honest presence, pairing,
   encrypted messaging, clipboard everywhere.
2. **Files & photos** — send files between paired devices with progress,
   encrypted, direct device-to-device.
3. **The brain on your PC** — a local AI (downloaded once, runs entirely on
   your machine) that your phone reaches over the mesh. Your PC thinks, your
   phone is the voice and face.
4. **Voice in, voice out** — talk to the assistant, it answers aloud. Fully
   offline.
5. **Memory, reminders, notes** — the assistant knows you: "remind me to call
   Sam at 7", "remember this fact", "what did I save last week?".
6. **Control & agents** — open apps and answer questions about your PC;
   hand a task to your PC's coding agent from your phone and get the result
   back.
7. **Windows, then macOS and web** — same codebase.

## Honesty rules (the spec that matters)

- If a feature isn't working, the app **says so**, clearly and calmly — no
  silent "it should work" claims.
- "Online" means reachable *right now*, verified by a direct connection.
- Your data and your pairing secrets never leave your devices.
- Everything here is on-device first; the internet is an opt-in you control.
