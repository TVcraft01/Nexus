# Nexus: The Local-First AI Assistant

Nexus is an AI assistant that runs on the devices you already own. It pairs your
phone and your PC directly, keeps the answers and the memories on those
machines, and never asks you to make an account.

Version **1.0.1**.

## Features

### On-Device AI
Nexus runs Qwen 2.5 0.5B or Llama 3.2 1B on the phone itself, or routes a
question to Ollama on your paired PC when it is reachable and better suited.
Both paths are local; there is no API key and no cloud model.

### Vision
Photos and screenshots are read on the device with ML Kit, and described by a
local vision model when one is installed. Ask what is on the screen, or send a
photo from the camera roll and ask about it.

### Voice
Speech recognition and spoken replies run on the device. Push to talk, dictate
into the composer, or start live conversation — a hands-free loop that listens,
answers, and reads the answer back.

### Mesh
Phone and PC find each other on your own network, pair by scanning a QR code,
and stay connected over a direct socket. Files move between them without an
upload: `get report.pdf from my pc` on the phone is enough. Paired devices can
also share compute — the phone can run a request on the PC's larger model.

#### Discovery

Nearby devices are found by UDP multicast and broadcast on port 51822, with a
unicast hello to every address this device has seen before. That socket is
best-effort: a unicast reply lets two Nexus devices find each other on a router
that drops multicast, and the app says when it cannot receive instead of
claiming to listen.

TCP is the guaranteed path. Every paired device is probed on its last-known
address and port, and — only on this device's own private `/24` — the subnet is
swept when that address is stale. A device counts as found only after the
pairing key is proved, so an open port with the wrong key is never a peer. The
Settings → Devices section says, per device, whether it was found via UDP, found
via TCP, or not reachable, and whether UDP discovery is unavailable at all.

On the Samsung Android 16 test phone the socket bound at launch never receives a
datagram from the network: its own loopback probe does not arrive, the kernel
answers `NoPorts` for packets sent to it, a `nc` listener on the same port does
receive them, and inbound TCP works. Rebinding heals a deaf launch socket on
that phone once, but not the network path itself. That is recorded in
`docs/DECISIONS.md` as an unexplained, device-specific observation.

### Server Agent
A deliberately narrow SSH client for Linux servers you own. It explores a
machine read-only (CPU, memory, disks, Docker, GPU), has the local model write a
two-sentence summary, and keeps that summary in the memory vault. Changes only
happen through pre-approved playbooks — starting with a Minecraft server — and
every command is shown before anything runs.

## Install

### Android

The release build is an APK signed with the project's own key:

```
build/app/outputs/flutter-apk/app-release.apk
```

Install it over USB with `adb`, or copy it to the phone and open it (allow
installing from unknown sources for your file manager):

```bash
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

A Play Store bundle is built alongside it at
`build/app/outputs/bundle/release/app-release.aab`.

The first launch offers to download a model (469 MB or 771 MB). Nothing else is
required to start using the assistant.

### Linux Desktop

The release build is a self-contained folder — the binary plus its Flutter
assets and libraries:

```
build/linux/x64/release/bundle/
```

Run it in place:

```bash
./build/linux/x64/release/bundle/nexus
```

To share it, copy the whole `bundle` folder (not just the `nexus` binary) to
another x86-64 Linux machine and run `./nexus` from inside it. It needs a
desktop session with GTK 3 and OpenGL.

On the PC, Nexus detects a local Ollama at `127.0.0.1:11434` and advertises it to
the phone during pairing, so the phone can send heavy questions to the desktop.

## Privacy Guarantee

**Nexus is 100% local. No data, audio, or images are ever sent to a cloud
server. No accounts are required. All AI processing happens on-device or via
your own paired local network.**

Nothing leaves a device unless you send it yourself: a file to a device you
paired, a message to your own PC, or a request to a server you added in the
Server Agent. There is no cloud copy, no telemetry, and no training on your
data.

Nexus learns about you using a local memory vault, including the summaries it
writes about servers you connect. That vault never leaves your device, is never
used to train models, and you can view, edit, or delete it at any time in
Settings › Privacy.

The full text is in the app at **Settings › Privacy › Privacy Policy**.
