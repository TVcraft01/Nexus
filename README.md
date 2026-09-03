# Nexus

**Your devices, one system.**

A local-first mesh that lets your devices find each other, pair in seconds, and talk directly — no cloud, no account, no third-party server.

```
  ┌─────────┐         ┌─────────┐         ┌─────────┐
  │  Phone  │◄──encrypted──►│   PC   │◄──encrypted──►│  Pi   │
  └─────────┘    mesh    └─────────┘    mesh    └─────────┘
```

---

## Features

| Feature | Description |
|---------|-------------|
| **Auto-discovery** | Devices find each other on the network automatically — no configuration needed. |
| **End-to-end encrypted** | Every message, file, and clipboard sync is encrypted with AES-GCM. No plaintext ever leaves your device. |
| **Pair in seconds** | Scan a QR code or enter an 8-character code. That code *is* the encryption key. |
| **Clipboard sync** | Copy on one device, paste on any paired device. |
| **File access** | Browse, copy, rename, and delete files across paired devices. |
| **Cross-network** | Works over LAN, VPN, and Tailscale — your devices can talk from anywhere. |
| **Honest presence** | A device shows "Online" only when it's actually reachable right now, not just "seen on the network." |
| **On-device everything** | Identity, pairing secrets, and settings live in the app's private directory. Nothing leaves your device. |

---

## Quick Start

### Prerequisites

- [Flutter SDK](https://flutter.dev/docs/get-started/install) (3.x or later)
- For Windows: `flutter create --platforms=windows .` (run once)

### Run from source

```bash
git clone https://github.com/TVcraft01/Nexus.git
cd Nexus
flutter pub get
flutter run
```

### One-liner (with mise)

```bash
git clone https://github.com/TVcraft01/Nexus.git && cd Nexus && mise install && mise exec -- flutter pub get && mise exec -- flutter run
```

---

## Platforms

| Platform | Status | Notes |
|----------|--------|-------|
| **Linux** | ✅ Stable | Full support, auto-update, system tray, file-manager mount |
| **Android** | ✅ Stable | Full support, auto-update, USB-OTG serial |
| **Windows** | 🚧 Next | Same codebase, build with `flutter build windows` |
| **macOS** | 📋 Planned | |
| **iOS** | 📋 Planned | |

---

## Build

```bash
flutter pub get

# Linux
flutter build linux --release
# → build/linux/x64/release/bundle/nexus

# Android APK
flutter build apk --debug
# → build/app/outputs/flutter-apk/app-debug.apk

# Windows
flutter build windows
# → build/windows/x64/runner/Release/nexus.exe
```

---

## Try it on one machine

You can test the full mesh with two windows on one computer:

```bash
# Terminal 1 — first instance
./build/linux/x64/release/bundle/nexus

# Terminal 2 — second instance with its own identity
NEXUS_DATA_DIR=/tmp/nexus2 ./build/linux/x64/release/bundle/nexus
```

Both windows discover each other under **Nearby**. Pair them: on one, tap *Pair a device → Show my code*; on the other, tap *Pair a device → Enter a code* (address fills in automatically). Copy text in one window and it lands on the other's clipboard.

---

## File Manager Mount (Linux)

Mount paired devices as folders in your file manager:

```bash
pip3 install --user fusepy
tools/mount-nexus.sh
```

Default mount point: `~/Nexus Devices`. Set `NEXUS_MOUNT` to change it. Unmount with `tools/mount-nexus.sh --umount`.

---

## Auto-Update

Both Linux and Android update themselves from GitHub releases on startup:

- **Linux** — "Update & restart" banner: downloads, swaps, relaunches.
- **Android** — "Update & install" banner: downloads the APK, hands it to the system installer.

Every push to `main` builds both platforms on GitHub Actions and publishes a release. Use `./update.sh` for manual rebuilds.

---

## How It Works

```
Device A                         Device B
────────                         ────────
1. Announce (UDP multicast)
                                  2. Hear announcement
3. Pair: show QR + code
                                  4. Scan QR / enter code
5. Encrypted handshake (AES-GCM + HKDF)
                                  6. Trust established
7. ──── encrypted TCP ────────►
   clipboard, files, commands
                                  8. ◄── encrypted TCP ─────
```

- **Discovery** uses UDP multicast (LAN) and direct unicast (VPN/Tailscale).
- **Pairing** derives an encryption key from the 8-character code. No code, no connection.
- **All traffic** after pairing is encrypted end-to-end. The mesh is just the transport.

---

## Roadmap

1. ✅ **Mesh** — discovery, honest presence, pairing, encrypted messaging, clipboard sync
2. ✅ **Files & photos** — cross-device file browsing, copy, move, delete
3. 🔜 **Windows** — same codebase, native build
4. 🔜 **Local AI assistant** — voice-first, runs on your PC, your phone is the interface
5. 📋 **Voice I/O** — talk to the assistant, get spoken answers. Fully offline.
6. 📋 **Memory & reminders** — "remind me to call Sam at 7", "what did I save last week?"
7. 📋 **Control & agents** — open apps, answer questions, hand tasks between devices

---

## Philosophy

Nexus is built on a few non-negotiable principles:

- **Honesty over optimism.** If something isn't working, the app says so — no silent failures, no "it should work" promises.
- **On-device first.** Your data stays on your device. The internet is an opt-in you control.
- **No cloud, no account.** Your devices talk to each other directly. No servers, no subscriptions, no lock-in.

---

## Contributing

Nexus is open source. Contributions are welcome — open an issue or submit a pull request.

```bash
flutter analyze && flutter test   # run checks before submitting
```

---

## License

See [LICENSE](LICENSE) for details.
