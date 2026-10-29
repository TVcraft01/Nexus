# Changelog

Notable changes to Nexus, newest first. This is the project's first changelog —
it was added during the file-fetch sprint, so the oldest entry below is that
sprint and earlier work is not listed. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

Nothing yet. Pass A (translation) is the next pass.

## [1.0.1] — 2026-10-29

A patch over 1.0.0. The 1.0.0 tag was cut before the mesh work was
verified on a device and before the command audit, and its release
assets were then rebuilt over the same version by every later push —
so the tag, the binaries and the changelog had stopped agreeing. This
release is that verification, its fixes, and a version number that
moves again.

### Added

- **A half-command asks its question.** "set a timer" or "get
  report.pdf" used to go to the model, which answered in prose and ran
  nothing. The composer now shows the interpreter's own question —
  "How long should the timer run?", "Which device?" — and what you type
  next answers it: "5 minutes" runs the timer. An answer that is itself
  a command wins outright, so an abandoned question never swallows the
  next instruction.

### Fixed

- **Thirteen parser gaps** found by the audit's corpus: phrasings that
  were read as the wrong action, or as nothing at all. Unspecified verbs
  ("play", "pause" with no object) no longer invent their content.
  Every phrase that was fixed is now a test in
  `test/command_inventive_test.dart`, and every action is named by at
  least one test in `test/command_coverage_test.dart`.
- **A critic test that never sent.** The widget helper tapped a send
  button mid-animation, the message stayed in the field, and the
  assertion found its own text there — a green test for an unsent
  message. It now settles, presses at the button's centre, and asserts
  the field is empty.
- **CI's analyze gate.** The new audit tests shipped with five unused
  imports, which `flutter analyze` treats as fatal, so CI was red on a
  tree whose test suite was green. Fixed; analyze is clean.
- **A release that can no longer be overwritten.** While `pubspec.yaml`
  said 1.0.0, the release job rebuilt and clobbered the `v1.0.0`
  assets on every push while the tag stayed put. The version now moves
  per release, and the release body is taken from this file.
- **The v1.0.0 GitHub release is deleted.** Its assets had been rebuilt
  from a later commit than its tag, so they were not 1.0.0. The `v1.0.0`
  git tag remains and the code is still checkoutable; the release that
  would have lied is gone. Publishing is now frozen: the step runs only
  when the version's tag does not exist yet.

### Changed

- The launched composer no longer hands a sentence to the model when
  the interpreter has already read it; the model answers what the
  parser cannot.
- `DeviceExecutor` is constructed on the launched path, so typed
  actions run against real devices there and not only in the old view.
- Identity is persisted across launches instead of rotating each time.
- `FileTransferService` listens on 51821; the legacy 51820 is still
  dialled so older peers are not stranded.

### Verified

- Notification permission, two-strike behaviour, on R5CX73XFGKW.
- 3a capability badge, on device.
- 3c peer-request card, approve and refuse, on device.

### Known limits

- 3b derived-key pairing between mixed clients is unverified.
- Auto and deny approval policies are unverified on device; only the
  ask-every-time path has been driven.
- `adb connect` refused during this pass, so nothing here is a fresh
  device result: the checks above are the ones recorded at 3c, not
  re-run today.
- Seven of the audit's twenty-two critic sentences parse but have no
  executor — they are answered honestly and nothing runs. That is 3e.
- No translation (Pass A), no AI/provider toggle (Pass B), no
  car-song verb (3d).
- SSH is verified against a simulated runner only, not a real server.

## [1.0.0] — 2026-10-28

### Added

- **Secure QR pairing.** Showing a QR starts a single-use request that
  expires in ~120 s — it never pairs anything by itself. The scanning
  device sends a request, the showing device taps Allow on a prompt that
  names the 4-digit code both sides display, and only then is a session
  established. The QR carries just version, pairing id, ephemeral public
  key, expiry, and nonce (plus the address needed to reach back); no
  contacts, files, clipboard, location, history, or device names. Pairing
  events (shown, requested, accepted, denied, revoked, expired) are kept
  in an on-device audit log, and either side can revoke at any time.
- **Capabilities: Nexus proposes, you decide.** Settings has a new
  "Capabilities" section where every optional feature is a choice with a
  plain-English description and an on/off switch — never on by default,
  no bundled consent. Location reminders, clipboard sync, voice input,
  file sharing, notification sharing, and location sharing all start off
  on a fresh install. Mesh pairing itself is now an explicit opt-in
  toggle (off on a fresh install) instead of always-on; only the local
  model stays on (without it the app does nothing) and is explained in
  the list itself instead of toggled.
- **Location reminders.** Say "remind me to take milk at the store" and
  Nexus asks for Always location, resolves the place with a single
  OpenStreetMap lookup, and rings when you arrive — even with the app
  closed. The row says the price before the toggle can move; turning it
  off means no lookup ever happens.
- **Peer actions, approved per action.** A paired device can ask this
  one to do something, and the ask arrives as a card rather than a
  command: it names the peer, the action, and what it would do, then
  waits for Approve or Refuse. Which actions a peer may even ask for is
  an explicit table, and the card is the only way one runs.
- **The launched shell.** The chat you get on launch is the mesh-aware
  one — composer, cards, device badges, interpreter. The older
  AssistantView still has its entry point and is retired in 3e, not
  here.
- **A server agent over SSH.** Point Nexus at a Linux box and it runs a
  command and reads the answer in a page that yields to the keyboard.
- **Wake word, off by default.** openWakeWord on the phone; turning it
  on is a capability row that states its cost first.
- **Capability announcements with provenance.** Each device says what
  it can do and where that claim came from, so a card never promises a
  peer capability that nothing proved.
- **Tailscale.** Pair over a tailnet by name, not only by LAN address.

### Honest note

- Nexus asks before it does anything optional. If you turn off location,
  no location lookup ever happens. If you turn off clipboard sync, nothing
  you copy leaves this device. If file sharing is off, paired devices are
  told so instead of seeing your files. Scanning a QR never reads the
  other device's data and never pairs without both sides confirming. The
  one thing that stays on by default is the local model, because without
  it the app does nothing — it is explained on first launch.

## [0.4.0] — 2026-10-13

### Added

- **Reminders.** Say "remind me to take milk at 6" and Nexus rings a real
  notification at 6 — on this device, and on every paired device. Works
  offline: a reminder set in airplane mode still fires.

### Known limits

- Reminders are time only — no location reminders yet ("remind me at the
  store" comes later).
- The phone model is small and slow: it reads, it doesn't remember.
- Tools are read-only, except reminders: listing folders, fetching files,
  and setting reminders. Nothing is ever deleted, moved, or changed.

## [0.3.0] — 2026-10-13

### Added

- **The AI can act now.** Ask "what's in my Downloads" and it lists your
  real files; ask for `report.pdf` from a paired device and it fetches the
  file over your own local network.

### Fixed

- **"Who is X" and "why…" questions reach the AI** instead of opening a
  browser search.
- **Folder questions no longer get swallowed by the memory rule.** Asking
  about Downloads, Documents, or Pictures lists the folder instead of
  recalling an unrelated memory.
- **The update banner no longer nags on the current version.** The shipped
  version is read correctly, so Nexus only offers an update when a newer
  one actually exists.
- **The mesh releases its port on restart**, so restarting Nexus rejoins
  the network cleanly instead of colliding with its own old socket.
- **The Linux installer names the missing system library** instead of
  failing silently when it is absent.

### Known limits

- The phone model is small: answers are slow and it forgets details — it
  reads, it doesn't remember.
- Tools are read-only: listing folders and fetching files only, no
  deleting, moving, or changing anything.
- A tool fetch reports back in words; there is no tappable file card for
  it yet.

## [0.2.0] — 2026-10-12

### Added

- **Nexus answers on its own, even offline.** Your phone and your PC each
  carry a small AI model inside the app, so everyday questions get a real
  answer with no connection and nothing ever leaves your devices.
- **Talk to it.** Tap the microphone and say what you want — including
  `get report.pdf from my pc`, which fetches the file over your own
  network. Misheard words that used to break a request are repaired before
  anything runs.
- **Copy once, paste anywhere.** Text you copy on one paired device
  appears on the others — codes and links apply themselves, everything
  else waits for one tap.
- **One phone is enough.** With nothing paired, Nexus is complete as it
  is: it greets you, shows this phone in Devices, and answers on this
  device. Pairing a second device is an invitation, never a missing step.
- **Timers, reminders, and quick math** from the same place you ask
  everything else.

### Known limits

- No wake word yet — you open the assistant, then talk or type.
- No iPhone or macOS builds yet — Linux, Windows, and Android.
- The small model on phones is slower than the PC's and knows less.
- No location-based reminders yet.

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
