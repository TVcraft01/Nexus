# Demo — fetch a file from your PC by asking for it

This walks the first Project Nexus vertical slice end to end, on two paired
devices and nothing else:

```
  phone                                             PC
    │  "get report.pdf from my pc"                    │
    │ ─── parse locally (rule-based, no model) ───►   │
    │ ─── file.get over the encrypted mesh ─────────► │
    │ ◄── file.chunk (the bytes of report.pdf) ────── │
    │  saves it to Downloads/                         │
```

No cloud, no accounts, no AI model — the sentence is matched by a local
rule, the file is served by the peer, and the bytes only ever cross your
local network.

See [CHANGELOG.md](../CHANGELOG.md) for what changed in each release.

**What you need:** a Linux/Windows machine (the "PC") and an Android phone,
both on the same Wi-Fi/LAN. Or, as a fallback, two Linux instances on one
machine (see [One-machine fallback](#one-machine-fallback)).

---

## Rehearsal result (2026-10-02)

**What was actually run — a two-OS-process rehearsal.** The real Nexus
pipeline, in **two separate processes**, pairing over real loopback TCP
sockets and moving `report.pdf` from one to the other. Not the in-process
test, and not two threads: two `flutter test` VMs.

- **Environment:** Omarchy `7.2.5-3-omarchy` (Arch-based, Hyprland 0.56.2,
  Wayland), Flutter 3.47.5 / Dart 3.13.4, commit `8a70ca2` plus the
  uncommitted file-fetch working tree.
- **Sentence executed:** `get report.pdf from my pc`
- **File:** `report.pdf`, 4096 bytes, served by the peer's own `MeshService`.
- **Outcome: PASS.**
  - in flight: `Getting report.pdf from Rehearsal PC…`
  - saved: `Saved report.pdf from Rehearsal PC to /tmp/nexus_rehearsal/downloads/report.pdf.`
  - the received bytes **equal the source bytes** (4096 == 4096, byte-for-byte).
- **Command:** `tool/rehearsal.sh` — see
  [Two-process rehearsal](#two-process-rehearsal).

**The GUI walk-through was then automated — two desktop instances, one
command.** `tool/gui_walkthrough.sh` builds the bundle (unless `--no-build`
reuses one), launches two real desktop windows with separate
`NEXUS_DATA_DIR` **and** separate `XDG_DATA_HOME` — so each instance's
profile lives inside the run's own evidence directory, and it points the
served folder and the save folder there too with `NEXUS_SERVED_ROOT` and
`NEXUS_DOWNLOADS_DIR` (see [Environment overrides](#environment-overrides))
— so the developer's real profile, home directory and `~/Downloads` are never
read or written — pairs them by driving the real
widgets (real clicks, real typing), submits the two commands below into the
assistant, and verifies both saved files by size and sha256 before printing
`PASS`:

```bash
./tool/gui_walkthrough.sh
```

One invocation runs the walk **once** and opens exactly two windows (a server
and a requester; a requester-only run opens one). It does not repeat, and a
retried step re-reads and re-clicks rather than relaunching the app. Bulk
validation is therefore opt-in: it means running the command again, and each
run opens two windows — an eight-run loop opens sixteen. If Nexus keeps
opening on screen, it is a loop calling this script, not this script looping.

A recorded run is checked in at
[`docs/evidence/gui_walkthrough_20261004.txt`](evidence/gui_walkthrough_20261004.txt);
full run dirs are regenerable with the same command (one under
`/tmp/nexus_gui/<timestamp>/` per run). It ended:

```
PASS — every file landed byte-identical in /home/tvcraft01/Downloads
  OK  report.pdf   4096 bytes       sha256 4e441a35…7205ec
  OK  big.bin      30000000 bytes   sha256 cc9a9318…03111a
```

That block is the dated run in the checked-in transcript, recorded before the
harness became hermetic — it landed its files in the real `~/Downloads`. The
current harness sets `NEXUS_SERVED_ROOT` and `NEXUS_DOWNLOADS_DIR`, so the same
`PASS` line now names its own run directory, e.g.
`/tmp/nexus_gui/<stamp>/downloads`.

In that run the requester paired with the server (`pairWith -> ok`,
`pair-request … (code matched)`), its Devices tab showed the server
**Online**, and its assistant showed, for each command, the in-flight
confirmation (chip **Working**) and then the outcome (chip **Done**):

| typed | outcome | bytes |
|---|---|---|
| `get report.pdf from my pc` | `Saved report.pdf from tvcraft01s-pc to /home/tvcraft01/Downloads/report.pdf.` + **Done** | 4096 = 4096, identical |
| `get big.bin from my pc` | `Saved big.bin from tvcraft01s-pc to /home/tvcraft01/Downloads/big.bin.` + **Done** | 30,000,000 = 30,000,000, identical |

The `Saved …` lines and `Done` chips are what the requester's window shows
(step 4 documents them). The run's own machine evidence is the size and
`sha256` verify lines above, `99_result.png`, and both mesh logs — the
transient **"Getting … / Working"** state is shown by the app but is *not*
captured as run evidence, because the script verifies the received bytes
rather than reading the outcome text back off the screen.

The same script also drives one **negative** path, without touching the happy
run:

```bash
./tool/gui_walkthrough.sh --negative
```

It pairs the same two instances, asks for a name the server does not have
(`get doesnotexist.pdf from my pc`), waits for the app's own not-found
wording (`<device> has no file named doesnotexist.pdf.`), and fails unless
nothing landed in the run's own download directory.

### Environment overrides

The walkthrough keeps everything inside its own run directory by setting two
startup overrides the app honors. Both default to the app's normal behavior
when unset — a hand-run Nexus still serves the home directory and saves to the
real Downloads folder:

| variable | effect | default when unset |
|---|---|---|
| `NEXUS_SERVED_ROOT` | the folder the device serves to paired peers (the Files tab and a fetch both read it) | the home directory (`$HOME` / `USERPROFILE`), or Android shared storage |
| `NEXUS_DOWNLOADS_DIR` | the folder a fetched or downloaded file is written into | the platform Downloads folder, else `$HOME/Downloads`, else the app documents folder |

The walkthrough sets both per instance, so `report.pdf`/`big.bin` are served
from `/tmp/nexus_gui/<stamp>/served` and fetched into
`/tmp/nexus_gui/<stamp>/downloads` — never into the developer's real
`~/Downloads`. Its `cleanup` therefore removes only paths under the run
directory.

### Two machines (requester-only)

The walk above runs both sides on one box. To point a requester here at a
Nexus already running on another machine on the LAN, pass the remote's mesh
address and port plus the pairing code its own **Devices → Show my code**
screen is showing:

```bash
# On box A: run Nexus, and put report.pdf and big.bin in its home dir — the
#           same deterministic fixtures this script generates on one box.
# On box B:
./tool/gui_walkthrough.sh --no-build \
  --peer-host <A-ip> --peer-port <A-port> --peer-code <XXXX-XXXX>
```

Box B then launches **only** its requester window, opens
**Devices → Add device → More ways to connect → Enter a code from the other
device**, types the code, A's address, and A's port, and fetches the two
files, verifying both by size and sha256. There is no local server: the code
comes from A's screen (this script cannot read another machine), and A must
hold the fixtures in its served home directory.

> **Status: the code path is exercised; a real second host is not.** No second
> physical machine was reachable here, so a two-box LAN run has never produced
> a recorded PASS. The requester-only pair path itself — typing the code,
> address and port into that same sheet — is exercised on one machine by
> `--peer-loopback` below, recorded in
> [`docs/evidence/gui_walkthrough_loopback_20261005.txt`](evidence/gui_walkthrough_loopback_20261005.txt).
> What remains unexercised is only the transport to a *different* host on a
> real LAN; do not read this section as a recorded two-host success.

#### One-machine smoke of the requester-only path

`--peer-loopback` runs the requester-only code path on this box: it launches a
local server, reads that server's pairing code from its window and its mesh
port from its log the way a person would, then drives the requester through the
same manual **Enter a code** tab against the loopback alias `127.0.0.2` (a
different address from discovery's `127.0.0.1`, so the typed-address path is
what actually runs):

```bash
./tool/gui_walkthrough.sh --no-build --peer-loopback
```

It is a smoke of the code path, **not** a real LAN test — the peer is a second
process on the same machine reached over loopback.

**What the automated walk-through does not cover:** a physical Android
phone, and Windows/macOS hosts. The one-machine walk runs both windows as
Linux desktop instances; `--peer-host` drives a requester-only run against a
Nexus on another machine, and `--peer-loopback` exercises that same code path
on one machine — but a run against a real second host is still unexercised
(see [Two machines](#two-machines-requester-only)).

**Bug found and fixed by this walkthrough.** A fresh profile that paired a
device *before* finishing first-run setup ended up with the composer hidden
(`_onboardingActive`), while the setup steps were never shown (they were
gated on "no paired devices") — so the assistant could not be used at all.
`_buildResult` now shows the setup view whenever onboarding is still active,
regardless of whether a device is paired (`lib/ui/assistant_view.dart`).
`test/onboarding_paired_test.dart` guards it: it reproduces a paired device
with setup still pending and fails against the pre-fix view.

The success path is covered by `tool/rehearsal.sh`; the failure path — a real
pull whose local write fails — is covered by `test/mesh_test.dart` ("a failed
local save is named as storage, not blamed on the network"), and the
not-found path through the real UI by `./tool/gui_walkthrough.sh --negative`.

**What this does *not* cover:** the physical phone, and still a recorded run
against a real second host — the requester-only path is exercised by
`--peer-loopback`, but only over loopback, never across two machines. The
one-machine walk uses Linux desktop instances over loopback; an Android build,
a real phone over Wi-Fi, and a Windows/macOS host remain untested. The [two-process rehearsal](#two-process-rehearsal) above is the
CI-runnable check; the manual steps 1–5 below are what was walked here.

---

## 1. Run both sides

These steps are the manual walk-through, exactly as walked on the two desktop
instances above (use a second desktop where a phone is named, or the
[One-machine fallback](#one-machine-fallback)).

**PC (Linux):**

```bash
flutter pub get
flutter run -d linux
```

On Windows, build with `flutter build windows --release` and run the app, or
`flutter run -d windows`.

**Phone (Android):** enable USB debugging, plug it in, then

```bash
flutter devices                 # find the phone's device id
flutter run -d <device-id>
```

Or build once and install the APK:

```bash
flutter build apk --release
# → build/app/outputs/flutter-apk/app-release.apk
#   dev.nexus.nexus (matches the installed app, so an over-install keeps your
#   pairing). The release build is signed by android/app/nexus-release.jks.
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

The build needs a JDK on `PATH` (`JAVA_HOME`) and `ANDROID_HOME` pointing at an
SDK with platform 36 and build-tools 36; `flutter doctor` says which piece is
missing. To check what actually landed in the package:

```bash
aapt2 dump badging build/app/outputs/flutter-apk/app-release.apk      # id, version, SDKs
aapt2 dump permissions build/app/outputs/flutter-apk/app-release.apk  # what it may ask for
```

---

## 2. Pair the two devices

Pairing is a code you show on one device and enter on the other — the code
*is* the key, there is no server involved.

1. On the **PC**, open the **Devices** tab and tap
   **"Show my code on another device"**. A short code (and a QR) appears.
2. On the **phone**, open the **Devices** tab, tap **"Scan a QR code"** and
   point it at the PC's QR — or type the code into **"Enter a code"** and
   confirm the PC's address.
3. Both devices now show each other as **Online**.

   If they don't, confirm both are on the same network; "Online" means a real
   connection was verified, not just "seen nearby".

   **Two desktops have no camera.** On one of them, open **Devices → Show my
   code on another device → More ways to connect → Show my code instead**; on
   the other, open the same sheet and choose **Enter a code from the other
   device**, then type the shown code with Address `127.0.0.1` and the peer's
   *shown* port (see the gotchas).

---

## 3. Put the file where the PC serves it

The PC serves its **home directory** (on Android, the phone serves its shared
storage instead — the PC is the one that needs the file here).

Copy the file you want to fetch into the PC's home directory:

```bash
cp /somewhere/report.pdf ~/report.pdf        # Linux
# Windows: copy report.pdf into C:\Users\<you>\
```

The file may sit in a subfolder too (the fetch searches a few levels deep),
but the root is the simplest thing to demo. Check the served folder from the
phone any time in the **Files** tab — you should see `report.pdf` listed
under the PC.

---

## 4. Ask for it

On the **phone**, in the assistant's command bar, type exactly:

```
get report.pdf from my pc
```

- **While it is in flight:** the request card appears with the assistant's
  confirmation, **"Getting report.pdf from My PC…"**, and the chip reads
  **Working**.
- **When it succeeds:** the same card updates to the outcome,
  **"Saved report.pdf from My PC to <path>."**, with the status chip
  **Done**.

The **save path** printed in that line is the real location. It is the
platform's Downloads folder when there is one, otherwise
`$HOME/Downloads`, otherwise the app's documents folder. On Linux the default
is `~/Downloads/report.pdf`; on Android it is the app's Downloads/documents
location named in the message.

The command works the same typed on the PC (the PC asks another paired
device) — the parser, the device resolution and the executor are identical on
both platforms. Saying **"my laptop"**, **"my computer"** or the device's own
name also resolves, because the kind is matched against the platform each
device reported.

### If it doesn't work

- **"I don't see a paired device named \"pc\"."** — nothing paired is a
  desktop. Pair the PC (step 2); check it shows Online.
- **"My PC has no file named report.pdf."** — the file isn't under the PC's
  served folder (step 3). Case doesn't matter; the location does.
- **"I couldn't reach My PC."** — the PC went offline or left the network.
- **A question, not a fetch** — the interpreter needed a file with an
  extension and a device. `get report.pdf` alone asks which device.

---

## 5. Prove nothing left the local network

The transfer only uses the existing encrypted mesh: TCP between the two
devices and UDP multicast discovery on the LAN. There is no HTTP, no cloud
endpoint, no telemetry.

**Watch the sockets.** On the PC, while the fetch runs:

```bash
ss -tnp | grep -i nexus          # only LAN peers, no external addresses
lsof -i -P -n | grep -i nexus    # same view via lsof (Linux)
```

You should see the peer's private address (e.g. `192.168.x.x` or
`10.x.x.x`) on the mesh port, and nothing pointing at a public IP.

**Pull the plug on the internet.** Turn off the WAN/internet on your router
(or use a hotspot with no data), keeping both devices on the same LAN, and
run the demo again. It still works — nothing in the path needs the internet.

**Block egress and confirm.** Add a firewall rule that drops all outbound
traffic from the app to anything but your LAN subnet, and the fetch still
completes.

---

## Connection behavior

Nexus does **not** promise "never disconnects". What it promises is that a
device you have already paired comes back **by itself** — no tapping, no
re-pairing, no cloud — usually within a minute of the peer returning. The
numbers below come from `lib/mesh/connection_supervisor.dart` and are asserted
by `test/connection_supervisor_test.dart`, including a real two-mesh test
where a peer goes away and is re-established with nothing touching the app.

### What the supervisor does

- **Heartbeat — every 3 s.** While a peer is healthy, one small presence
  frame each way, so silence can mean something.
- **Silence means a drop — after 9 s.** Three missed beats, so a single lost
  frame is not a drop. The mesh's own presence window is 25 s wide, so the
  supervisor deliberately calls a dead link first.
- **Retry with backoff — 2 s → 60 s.** 2 s, 4 s, 8 s, 16 s, 32 s, then 60 s
  and 60 s forever: a device that is off costs one ping a minute, and a
  device that comes back is still redialled within the minute.
- **A network change retries at once.** WiFi back after sleep, WiFi handing
  over to cellular, the radio dropping and returning — the waits were measured
  against a network that no longer exists, so they are thrown away and the
  peer is dialled immediately instead of waiting out a 60 s backoff.
- **"Heard from" means the peer proved it was there**, never "we sent it
  something". A write into a dead route succeeds locally often enough that
  send-side freshness would keep a dead link looking healthy forever.
- **The supervisor runs with the mesh** — the mesh's own `start()` creates it
  — and on Android that same call starts the `dataSync` foreground service
  (`NexusSyncService`) that keeps the process, and therefore the mesh, alive
  with the window closed.

### What you see on screen

Devices → a paired device's row has three connection states:

- **Online** — `Online`: a verified contact inside the mesh's 25 s window.
- **Reconnecting** — `Reconnecting · next try in 4s`, or plain
  `Reconnecting…` when there is no scheduled wait to show. The number is the
  wait the supervisor is actually on, so it grows with the curve above rather
  than promising a fast answer that is not coming. It is redrawn as the screen
  updates (the supervisor and the mesh both announce their state changes), not
  by a per-second clock. The device's detail sheet shows the same three states
  in its own words, and the line above the list counts a device being retried
  as not reachable right now — so the strip and the row never contradict each
  other.
- **Offline** — `Offline · last seen 3m ago` (or `never`): no verified
  contact, and the supervisor is not retrying this peer.

`Nearby` is unchanged and is a different thing: the device is *visible* — its
announcements are being heard — but it has not proved a connection.

The states are decided in `lib/ui/devices_view.dart`; the retry they show is
the real `ConnectionSupervisor` the mesh runs, forwarded through the mesh's
own notifier.

### What breaks it

Auto-reconnect cannot create a link that cannot exist. It does not help when:

- **the OS suspends the app** — Android deep suspend/Doze: nothing runs until
  the device wakes;
- **airplane mode is on, or the radios are off** — there is no route;
- **the peer was uninstalled or unpaired**, or is on another network — a link
  that cannot be made is not a link that comes back;
- **a host firewall drops inbound on the mesh port** (see
  [Gotchas observed](#gotchas-observed)).

### Two bugs that had to be fixed

Both were load-bearing for the promise — a retry curve that noticed nothing,
and a peer that could not tell the other side had stopped:

- **Send-side freshness masked dead routes.** The mesh's "last seen"
  timestamp advanced when *we* sent a ping, so a peer that had silently gone
  away kept looking fresh and no supervisor watching it could ever notice.
  The supervisor now watches the last contact the peer itself proved.
- **Ghost sockets after the mesh stopped.** A mesh that had shut down kept
  answering presence on the connection the *other* device had opened, so the
  peer went on seeing a healthy link to a device that was gone — and the
  reconnect could never start, because nothing ever looked dropped. Accepted
  connections are now destroyed with the mesh.

> **Honesty note:** every number above is from the code and from tests that run
> headless on **one Linux box over loopback** — the retry curve is driven by an
> injected clock and hand-driven ticks rather than by waiting, and the two-mesh
> reconnect test uses short real windows over that loopback. Nothing here has
> run on a phone: the Android network-change signal (`ConnectivityManager` →
> the `dev.nexus.nexus/network_events` channel, no new permission) is
> unit-tested against a fake stream, and the `dataSync` foreground service that
> is meant to keep the mesh ticking with the window closed is built and
> exercised in Dart but has never kept a real phone reconnecting. A real phone
> through deep suspend, a WiFi→cellular handover or a radio drop is untested.

---

## Two-process rehearsal

The automated end-to-end test in `test/mesh_test.dart` runs both mesh
endpoints in **one** process. `tool/rehearsal.sh` removes exactly that
caveat: it runs the same production classes in **two** OS processes.

- `test/rehearsal_peer.dart` — a real `MeshService` serving `report.pdf`,
  which publishes its one-time pairing code to a handoff file and holds the
  mesh open.
- `test/rehearsal_requester.dart` — a real `MeshService` that pairs with that
  code over loopback, then runs the production chain
  `CommandService → file_fetch core seam → MeshService adapter → DeviceExecutor`
  with the literal sentence, and asserts the saved bytes equal the source.

```bash
tool/rehearsal.sh
```

Pairing is brokered through a small file (`/tmp/nexus_rehearsal/peer.json`)
only because the code is random; everything else — sockets, framing,
encryption, the file protocol, the parser, the executor — is the app's own
code, not a stand-in. Both sides also print their real mesh logs.

Because those two files do not end in `_test.dart`, the ordinary
`flutter test` run does not pick them up; run them explicitly (or via the
script). They live in `test/` so `test/flutter_test_config.dart` still
neutralises system commands for them.

### Gotchas observed

- **Two instances on one machine pick different ports by themselves.**
  `MeshService` tries the canonical mesh port (`51820`) first, then the port
  in its store. The second instance therefore lands elsewhere automatically
  (observed: peer `51820`, requester `53401`) — no manual port juggling.
- **Discovery's multicast lock is a phone-only facility.** Off-device it logs
  `multicast lock unavailable` and falls back to loopback/broadcast. Pairing
  is by explicit `address:port`, so the fetch never depends on discovery
  working on the desktop.
- **Served root = home directory.** The PC serves its home dir (`$HOME`, or
  `USERPROFILE` on Windows); a file that is not there (or within 3 levels of
  subfolders) produces `"… has no file named …"`. `fileRoot` (test-only) and
  the `NEXUS_SERVED_ROOT` environment variable override this — the app serves
  home when neither is set.
- **Firewall.** The two ends talk over TCP on the mesh port; a host firewall
  that drops inbound on that port stops pairing. Allow the app on your LAN.
- **The pairing code expires in 5 minutes.** Generate it last and enter it
  promptly; an expired code looks identical but the other side answers
  nothing (`"No answer from the device…"`). Hit **Show a new code** and retry.
- **The second instance's mesh port is taken.** Both instances want the
  canonical `51820`; the one that loses falls back and says so in its own UI
  (`"Port 51820 was busy — Nexus is using port 45519"`). When entering a code
  by hand, type the peer's *shown* port, not your own prefilled one.
- **The Linux desktop build needs a deprecation relaxation.** Under clang 22
  the `tray_manager` plugin trips `-Werror` on `app_indicator_new`; the
  project's `linux/CMakeLists.txt` keeps `-Werror` but adds
  `-Wno-error=deprecated-declarations` so the build succeeds.

---

## One-machine fallback

No phone handy? Run two Linux instances on one machine and pair them — the
file fetch is the same code path, just both ends on the same box. The
automated walk-through does the whole thing (launch, pair, fetch, verify):

```bash
./tool/gui_walkthrough.sh
```

Or drive it by hand:

```bash
flutter run -d linux                         # instance A
NEXUS_DATA_DIR=/tmp/nexus2 flutter run -d linux   # instance B
```

Pair A and B with a code as in step 2, put `report.pdf` in A's home
directory, then in B's assistant type the same sentence. To keep the
fallback's served folders apart, set A's home via the environment as needed.

---

## Automated evidence

The whole vertical is covered by tests, including the wire path:

- `test/file_fetch_parser_test.dart` — the accepted phrasings and the
  missing-device question.
- `test/file_fetch_test.dart` — the fetch orchestrator and the service's
  device resolution over a fake mesh (bytes land, missing file, unreachable
  peer, unpaired device).
- `test/device_executor_test.dart` — the executor pulls into the save dir and
  the bytes are on disk.
- `test/mesh_test.dart` — **"file.fetch end to end: a real peer serves
  report.pdf and the phone saves it"**: two real `MeshService` endpoints
  paired over loopback, one serving `report.pdf`, the other parsing the
  sentence, resolving the device and running the fetch. It asserts the
  announced save path and that the received bytes equal the source file.
  Both endpoints are in **one** process.
- `tool/rehearsal.sh` — the **two-process** version of the same path (see
  [Two-process rehearsal](#two-process-rehearsal)). This is the check that
  closes the "one process" caveat above.
- `tool/gui_walkthrough.sh` — the same path through the **real desktop UI**:
  two real windows, real clicks and typing, both files verified by size and
  sha256 before it prints `PASS`. `--negative` drives one fetch that must
  fail (the app's own not-found wording, nothing saved); `--peer-host` runs
  requester-only against a server on another machine, and `--peer-loopback`
  exercises that same requester-only path on one machine (the two-host LAN run
  remains unexercised). Needs a live Wayland/Hyprland session, so it is not the CI
  check; `tool/rehearsal.sh` is. It runs once per invocation and opens two
  windows; running it repeatedly for bulk validation is opt-in.

Run the suite with:

```bash
tool/rehearsal.sh   # two-process; requires a working Flutter toolchain
flutter test        # the whole unit/widget suite
```

> **Honesty note:** the GUI walk-through ran on **two Linux desktop
> instances on one machine over loopback** — not across two machines, and not
> on a phone. The GUI, the pairing-code exchange, the parser, the mesh
> adapter and the executor are all real; only the *transport* is loopback. A
> Windows/macOS host and a physical Android phone over Wi-Fi remain untested.
