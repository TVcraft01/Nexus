# Nexus

### Your devices, one system.

**Nexus** connects your phone, PC, and other devices into a single, private mesh.
No cloud. No accounts. No one in the middle.

> Copy text on your phone. Paste it on your PC.
> Browse files across devices. Send commands from one to another.
> All encrypted. All direct. All yours.

---

## Why Nexus

Today, your devices don't talk to each other. They talk to servers — someone else's computers — and hope for the best.

Nexus changes that. Your devices find each other, pair in seconds, and communicate directly. Everything stays on your hardware. No subscriptions. No telemetry. No fine print.

---

## What It Does

**Copy once, paste everywhere.**
Copy text on any paired device and it lands on every other device's clipboard. Encrypted, instant, automatic.

**Your files, across all your devices.**
Browse, copy, rename, and delete files on any paired device from any other. No cloud drive needed.

**Pairs in seconds.**
Show a code. Enter it. Done. The code *is* the encryption key — no account, no server, no setup wizard.

**Honest presence.**
A device shows "Online" only when it's actually reachable — not when it was "seen on the network five minutes ago."

**Works anywhere.**
LAN, VPN, Tailscale — Nexus adapts to your network. Your devices can talk from the same room or across the world.

---

## Install

**One command. Any platform.**

Mac & Linux (terminal):

```bash
curl -fsSL https://raw.githubusercontent.com/TVcraft01/Nexus/main/tools/install.sh | bash
```

Windows (PowerShell — no bash needed):

```powershell
irm https://raw.githubusercontent.com/TVcraft01/Nexus/main/tools/install.ps1 | iex
```

Both download the latest release and install it under `~/.nexus/` — no Flutter, no SDK, no account. To update later, run the same command again.

After install, look for **Nexus** in your app menu (Linux) or Start menu (Windows). It runs in the system tray — close the window and it keeps running.

**Or build from source** (Mac & Linux):

```bash
git clone https://github.com/TVcraft01/Nexus.git && cd Nexus && flutter pub get && flutter run
```

Windows PowerShell can't use `&&` — either PowerShell 7 or separate lines:

```powershell
git clone https://github.com/TVcraft01/Nexus.git
cd Nexus
flutter pub get
flutter run
```

**Try it on one machine:**

```bash
~/.nexus/nexus &  NEXUS_DATA_DIR=/tmp/nexus2 ~/.nexus/nexus
```

Both windows discover each other and pair. Copy something. Watch it appear.

---

## Build from Source

```bash
flutter pub get
flutter build linux --release    # Linux
flutter build apk --release      # Android
flutter build windows --release  # Windows (creates the Windows runner first)
```

---

## How It Works

```
  Phone                    PC                    Tablet
    │                       │                       │
    │◄──── encrypted ──────►│◄──── encrypted ──────►│
    │       TCP mesh        │       TCP mesh        │
    │                       │                       │
    └─────── direct ────────┴─────── direct ────────┘
              No server. No cloud. Just your devices.
```

1. **Discover** — devices find each other on the network (UDP multicast + direct unicast).
2. **Pair** — scan a QR or enter a code. The code becomes the encryption key.
3. **Connect** — all traffic is encrypted end-to-end with AES-GCM. The mesh is just the transport.

---

## What's Inside

- **End-to-end encryption** — AES-GCM + HKDF. Every message, file, and clipboard sync.
- **No cloud** — your data stays on your device. Period.
- **Auto-update** — Linux and Android update from GitHub releases on startup; Windows re-runs the one-line installer.
- **File manager mount** (Linux) — paired devices appear as folders in your file manager.
- **System tray** (Linux) — keeps running when you close the window.

---

## Roadmap

- ✅ Mesh networking, pairing, encrypted messaging
- ✅ Clipboard sync across devices
- ✅ Cross-device file access
- ✅ Windows support (installer + Start-menu shortcut)
- 🔜 Local AI assistant
- 🔜 Voice interface
- 🔜 Smart reminders and memory

---

## Contributing

Contributions are welcome. Open an issue or submit a pull request.

```bash
flutter analyze && flutter test
```

---

## License

MIT — see [LICENSE](LICENSE).
