# Nexus

Nexus runs on the devices you already own, keeps everything local, and never asks for an account.

## The problem

Your devices hold pieces of your life, but they do not talk to each other. Instead, they send your data to servers owned by someone else, and charge you for the return trip. Nexus pairs your own devices directly, so asking one of them reaches what the others hold.

## Why it is not a $3,499 box

Ghost is a $3,499 screenless box from Ghost.ai, backed by an $11M seed round led by a16z: an RTX Pro 4000 with 64 GB of RAM and a 1 TB SSD that runs Qwen-3.8 and Gemma-4-31B in your home, controlled from a phone app, shipping the last week of October 2026. Nexus starts from the opposite assumption: the phone and laptop you already have are enough, so there is nothing new to buy, nothing to plug in, and nothing to replace. It is free and open source, and your devices talk to each other directly instead of through a central box.

## What works today

- **Ask for a file by name.** Type or say `get report.pdf from my pc` on a paired device and the file arrives in your Downloads folder. The transfer stays on your local network.



- **Talk instead of typing.** Speech recognition runs on the device, and what you say goes through the same assistant as what you type.



- **Hear the answer.** Spoken replies are read aloud with on-device text to speech.



- **Plain arithmetic.** Ask `what is 18 percent of 240` and Nexus answers with the number.



- **Reconnects by itself.** A paired device that sleeps, changes Wi-Fi, or drops off the network shows as reconnecting and comes back on its own. Nothing to re-pair, nothing to tap.



- **Encrypted between your devices.** Every message and file travels under AES-GCM with keys derived by HKDF. The pairing code is the key. There is no server that can read it.



- **No cloud, no account.** Discovery, pairing, and transfer all happen between your devices. Turning off the internet and keeping local Wi-Fi is enough.



Works today on Linux desktop, Windows, and Android.

## Screenshots

Screenshots coming after the v0.3 release.

## What does not work yet

- **No wake word.** You open the assistant, then talk or type.
- **No USB.** Pairing and transfer run over the local network only.
- **No macOS or iOS builds.** Published today: Linux x86_64, Windows x86_64, and Android.

## Install

Linux (x86_64):

```bash
curl -fsSL https://raw.githubusercontent.com/TVcraft01/Nexus/main/tools/install.sh | bash
```

Windows (PowerShell):

```powershell
irm https://raw.githubusercontent.com/TVcraft01/Nexus/main/tools/install.ps1 | iex
```

Android: download [Nexus-0.2.0.apk](https://github.com/TVcraft01/Nexus/releases/download/v0.2.0/Nexus-0.2.0.apk) from the [latest release](https://github.com/TVcraft01/Nexus/releases/latest) and install it. It installs over the previous version — nothing is uninstalled, nothing is lost.

Then pair two devices with a code and try `get report.pdf from my pc`. The full walkthrough is in [docs/DEMO.md](docs/DEMO.md).

## Learn more

- [ARCHITECTURE.md](ARCHITECTURE.md) — how Nexus is shaped and where a change lands.
- [docs/DEMO.md](docs/DEMO.md) — the file-fetch demo, step by step.
- [CHANGELOG.md](CHANGELOG.md) — what changed, newest first.

## License

Open source under the [MIT license](LICENSE). Free, like the app itself.
