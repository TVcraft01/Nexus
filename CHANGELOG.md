# Changelog

Notable changes to Nexus, newest first. This is the project's first changelog —
it was added during the file-fetch sprint, so the entries below start there and
earlier work is not listed. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased] — file-fetch sprint

### Added

- **Ask your PC for a file by name.** On a device paired with your PC you can
  type a plain sentence like `get report.pdf from my pc` and the file is sent
  over your own local network and saved to your Downloads folder. Nothing goes
  through the cloud, and there are no accounts to make.
- **A rehearsal you can run yourself, with no windows.** `tool/rehearsal.sh`
  starts two separate Nexus processes and moves a real file from one to the
  other over a real connection, then tells you whether the bytes that arrived
  are identical to the bytes that left. It is a quick way to check the fetch
  path on a headless machine.
- **A one-computer proof of pairing by code.** The automated walkthrough can
  pair a device to a server running on the same machine through the `127.0.0.2`
  address, so the "type the other device's code" path is genuinely exercised
  even when you only have one computer.

### Fixed

- **Typing a pairing code no longer fills in the wrong port.** When you opened
  the pairing sheet and chose "Enter a code" yourself, the Port box used to come
  pre-filled with the port of another device it had noticed nearby, which made
  the code you typed fail. The box now starts empty so you type the number you
  were actually given.
- **The automated test run no longer touches your real files.** It used to
  serve files from, and save fetched files into, your real home folder and
  `~/Downloads`. Both now live inside the run's own temporary folder and are
  removed afterwards, so a test run can never overwrite or delete your files.

### Changed

- **The automated walkthrough now drives its windows on their own desktop
  workspace.** A full-screen app left open on your normal workspace can no
  longer cover the two Nexus windows mid-test. Before each screen read the
  walkthrough re-checks that its workspace is the one actually showing, and
  puts your desktop back where it was when the run ends.

### Known limits

- Only proven on one machine, over a loopback connection. A real two-computer
  LAN run, an Android phone, and Windows or macOS are all still untested.
- Each walkthrough run opens two windows (a server and a requester); the bulk
  validation loop opens sixteen. The default command opens two.

### Evidence

- [First full GUI walk-through (2026-10-04)](docs/evidence/gui_walkthrough_20261004.txt)
- [Loopback / requester-only walk-through (2026-10-05)](docs/evidence/gui_walkthrough_loopback_20261005.txt)
