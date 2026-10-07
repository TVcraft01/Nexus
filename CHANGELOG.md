# Changelog

Notable changes to Nexus, newest first. This is the project's first changelog —
it was added during the file-fetch sprint, so the oldest entry below is that
sprint and earlier work is not listed. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased] — automatic reconnect

### Added

- **Devices now show a Reconnecting status and recover automatically after
  sleep, WiFi changes, or short outages. No cloud, no action needed.**
- **A device Nexus is trying to reach says so, and how long the wait is.**
  While the connection supervisor retries a paired device that dropped, its
  row reads `Reconnecting · next try in 4s` (or plain `Reconnecting…` when it
  has no scheduled wait to show) instead of the `Offline · last seen …` every
  absent device used to show. The device's detail sheet shows the same three
  states in its own words, and the line above the list counts a device being
  retried as not reachable right now.

### Fixed

- **A device that died silently used to look healthy forever.** The mesh's
  "last seen" timestamp advanced whenever Nexus *sent* something, so a peer
  that had gone away without saying goodbye kept looking fresh, and nothing
  watching it could notice the drop. Nexus now watches the last contact the
  peer itself proved.
- **A device that had stopped kept answering.** A mesh that had shut down left
  the connection the other device had opened still answering presence, so the
  peer went on believing the link was healthy and never started reconnecting.
  Those connections are now closed with the mesh.

### Known limits

- Reconnecting needs the device to be awake to help. OS suspend, airplane mode
  and radios-off all mean no route exists until the device wakes, and a link
  that cannot be made — an uninstalled or unpaired peer, a blocked port — does
  not come back on its own.
- Proven on one Linux box over loopback. The Android network-change signal is
  covered by tests against a fake, not on a phone: a real phone through sleep,
  a WiFi-to-cellular handover or a radio drop is still untested, and so is the
  background service meant to keep Nexus reconnecting with the window closed.

## [Unreleased] — file-fetch sprint

### Added

- **A long download no longer looks stuck.** While the assistant is pulling a
  file it now says how far along it is — `Getting big.bin from My PC… 50% (15 MB
  of 30 MB)` — so you can tell a slow transfer from a stalled one. A device that
  never told Nexus how big the file is gets the bytes received and no invented
  percentage.
- **Your phone keeps receiving while the app is in the background.** On Android
  the mesh now runs inside a foreground service with an ongoing notification, so
  a request from your PC does not stop the moment you leave Nexus on the phone.
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

- **On Android, a fetched file lands where you can actually find it.** Files
  used to be saved into Nexus's own app folder, which the Files app hides, so a
  download that worked looked like it had never arrived. They now go to your
  shared **Downloads** folder, and when Android has not granted Nexus access to
  it yet the app offers that permission at the moment you fetch something —
  declining is fine, the file still arrives, and the result tells you where it
  went.
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
- The Android pieces below the fetch itself — the background service, its
  notification, and the permission offer — are built, packaged, and covered by
  tests, but none of them has been run on a real phone yet.
- Each walkthrough run opens two windows (a server and a requester); the bulk
  validation loop opens sixteen. The default command opens two.

### Evidence

- [First full GUI walk-through (2026-10-04)](docs/evidence/gui_walkthrough_20261004.txt)
- [Loopback / requester-only walk-through (2026-10-05)](docs/evidence/gui_walkthrough_loopback_20261005.txt)
