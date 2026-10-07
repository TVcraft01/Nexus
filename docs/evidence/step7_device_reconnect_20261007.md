# Nexus — step 7 report: one dialer, rebuilt APK, fast-path verdict

Device run 2026-10-07; report written 2026-10-08.

- Host: headless Linux PC (`wlp0s20f3` = 10.238.55.21/24, tailscale 100.120.66.13). No
  `gui_walkthrough.sh`, no desktop window, no compositor change — the screen was never taken.
- Phone: Samsung SM-A256E, serial `R5CX73XFGKW`, Android 16 / SDK 36, arm64-v8a, app id
  `goou4tt557c220n1qbudc3xiq65c6hdf`, `swlan0` = 10.238.55.30/24 (the phone is the AP).
- Peer: `peer-pc` ("Rehearsal PC", linux), on the PC.

## Verdict at a glance

| # | Step | Result |
|---|------|--------|
| 1 | `test/rehearsal_peer.dart` store-ordering bug | **fixed** — `5b132ed` |
| 2 | One dialer per peer (supervisor owns scheduling) | **done, mutation-proven** — `c179789` |
| 3 | Rebuild + reinstall from HEAD | **done** — sha256 `1f0eb359…b6b3b`, versionCode 153 |
| 4 | ConnectivityMonitor fast path | **trigger isolated, latency unmeasured — no PASS** (§4) |
| 5 | Headless re-verification | **green** (§5) |
| 6 | Commit + push | `cded0b7..c179789`; `origin/main` = `c1797895ac569531963459f3078b8f63ad2f075d` |

---

## 1. `test/rehearsal_peer.dart` — `5b132ed`

The bug: the peer built its store and wrote it **before** reading it —

```dart
final store = NexusStore(explicitPath: '${home.path}/peer_store.json')..port = _port;
await store.save();
```

`save()` writes the map the store holds, and a store that has never loaded holds only
defaults. A restart therefore overwrote the file and came back paired with nobody, so it
never dialled the phone. On the 2026-10-07 device run that read as a reconnect failure in
the product and was not one.

The fix, load first and only then point it at the peer port:

```dart
Future<NexusStore> openPeerStore(String path) async {
  final store = NexusStore(explicitPath: path);
  await store.load();
  store.port = _port;
  await store.save();
  return store;
}
```

with the device-run evidence cited in the comment.

Guard: `test/rehearsal_peer_store_test.dart` opens the same path twice — exactly what a
second `flutter test test/rehearsal_peer.dart` does — pairs a device, then asserts the
restarted store still has the port and still lists the phone id. It was verified to
**bite**: with the old ordering it fails (`Expected: contains 'goou4tt…'  Actual:
MappedListIterable<…>:[]`), with the fix it passes.

Files: `test/rehearsal_peer.dart` (+22/−3), `test/rehearsal_peer_store_test.dart` (+56).

---

## 2. One dialer per peer — `c179789`

**The ownership line.** The **supervisor owns scheduling**: when a paired peer is dialled
— every `heartbeatInterval` while the link is up, on the backoff curve while it is down,
and at once on a network change. The **mesh owns reporting**: whether a peer has proved it
is there (`MeshTransport.lastHeardAt`, fed only by verified pongs) and the one on-demand
dial (`beat()`) the supervisor dials with.

Why it mattered: two independent things dialled a paired peer, so the wire followed
neither schedule, the countdown on the device row was a lie, and a supervisor reconnect
could not be told apart from the mesh sweep's next tick — which is what made the
connectivity-monitor fast path impossible to prove.

`lib/mesh/mesh_service.dart` (+48/−3):

- `Future<void> _presenceSweep() => _heartbeat(includeSupervised: false);`
- the periodic timer and the startup kick now call `_presenceSweep()`, not `_heartbeat()`
- `Future<void> _heartbeat({bool includeSupervised = true})`, with this gate inside the
  target loop:

  ```dart
  if (!includeSupervised &&
      _supervisor?.running == true &&
      _paired.containsKey(peer.id)) {
    continue;
  }
  ```

- `beat()` still calls `_heartbeat()` (defaults `includeSupervised: true`) and is the
  supervisor's hand to dial with; `_sendEnc()` still dials on demand for a send the user
  asked for. The sweep keeps the devices nobody is scheduling and takes paired peers back
  whenever no supervisor is running, so a mesh is never silent — it just stops scheduling
  what someone else is scheduling.

Documented on both sides: the class header of `lib/mesh/connection_supervisor.dart` (+13)
and on `_presenceSweep` / `beat` in `mesh_service.dart`. The commit message records the
same split.

**Test** — `test/connection_supervisor_test.dart` (+101):
`the mesh sweep leaves a peer the supervisor holds down to the supervisor`. A real
`ServerSocket` stands in for the peer and counts accepted connections as dials (it answers
nothing, so presence can never be verified and the link has to go down).
`heartbeatInterval: 100 ms`, `connectTimeout: 200 ms`, the peer already paired before
`mesh.start()`. Asserts: the supervisor dials at least once; the link goes `!up` with
`attempts > 0`; then 1.5 s of window adds **≤ 2** dials; then after `sup.stop()` dials
resume.

**Mutation proof** — the part that makes it proof and not hope. Neutralising the gate
(`false &&`) makes the same 1.5 s window show **15** dials:

```
Expected: a value less than or equal to <2>
  Actual: <15>
```

i.e. the 100 ms sweep re-dialling a peer the supervisor holds. The file was restored and
its sha256 checked before and after
(`f04724886aa28dc644952d10654068cffaab8759e5d5b455a40befe1d79f33c3`).

Files: `lib/mesh/connection_supervisor.dart` (+13),
`lib/mesh/mesh_service.dart` (+48/−3), `test/connection_supervisor_test.dart` (+101).

---

## 3. Rebuild + reinstall

Built in `/home/tvcraft01/nexus_build` — a `git archive HEAD` tree plus
`android/local.properties`. (`/tmp` is a 3.8 GB tmpfs and filled up mid-build, which
Gradle reports as `Could not add entry … UncheckedIOException` on its `fileHashes.bin`;
the build tree had to move off it.)

- artifact: `/home/tvcraft01/nexus_build/build/app/outputs/flutter-apk/app-release.apk`
- size 72,781,089 bytes
- sha256 `1f0eb359fdd0d3ef034d4213b09a451c97859a49ddf255062a63374db36a6b3b`
- versionCode **153**, versionName 0.1.53, minSdk 24, targetSdk 36
- `adb install -r` → **Success** over the existing app, `lastUpdateTime=2026-10-07 20:39:08`
- app pid **20498**; foreground service `NexusSyncService isForeground=true foregroundId=51820`
- mesh listening confirmed on the wire by its own announcements:
  `announced id=goou4tt… port=51820 (3/3 targets)`
- the previous HEAD build is preserved for comparison:
  `/home/tvcraft01/nexus_artifacts/app-release-cded0b7.apk`,
  sha256 `33567eab6d6b7cf32f8b66b346ad19fc7e973158facbbd151d5282146fb521e5`

---

## 4. ConnectivityMonitor fast path — **NOT ISOLATED** (no PASS claimed)

### The channel, and why it is the right one

The peer is unreachable (the PC's ufw drops inbound 51820, and the peer app was not
running), so the supervisor sat in Reconnecting throughout the dialling window. Every dial
is therefore
a 5 s `SYN_SENT` (`state 02`) to the peer port, visible from the phone as a line in
`/proc/net/tcp`, sampled at 0.25 s by `/data/local/tmp/synpoll3.sh`.

One "attempt" is a burst that walks the peer's five stored addresses at 5 s each:

```
6401A8C0 (192.168.1.100) → 010012AC (172.18.0.1) → 010011AC (172.17.0.1)
→ 1537EE0A (10.238.55.21, source 1E37EE0A = swlan0) → 0D427864 (100.120.66.13)
```

24–25 s per burst, all five in every burst.

### The steady state — this is the number the UI countdown shows

The capture runs 20:58:32 → 22:32:54 (5662 s). Dials were seen from 20:58:45 to
21:42:04 — **46 attempts**, recorded as 48 in-flight windows because two of them are a
single attempt split by a missed sample — and then **no dial at all for the remaining
3050 s (51 minutes)**, while the poller kept sampling (7370 lines over 2612 s before,
8328 over 3050 s after, ≈2.8/s both sides, so the silence is real and not a dead poller).
That silence is unexplained and is listed in §7.

Of the 45 attempt-to-attempt gaps, **40 are 59–62 s**: measured directly as 18×60 s,
16×61 s, 2×59 s, 2×62 s (mean **60.47 s** — the 60 s cap), plus the two split artifacts
which recombine to 61 s each (16 s+45 s, 20 s+41 s). The remaining five gaps are the
toggle cluster below, and nothing else in the window deviates.

The steady state is anchored by `/tmp/probe_ladder.log`, a separate run:

```
T1791398556 040000C0:B698 6401A8C0:CA6C
T1791398617 040000C0:D2F2 6401A8C0:CA6C      gap = 61
```

### What happened at the airplane toggle

```
T1791399525 040000C0:9790 6401A8C0:CA6C    last pre-toggle burst starts
T1791399549 040000C0:8276 0D427864:CA6C    its last in-flight sample
T1791399550 -                              first quiet sample
BURST_END 1791399556
AM_ON     1791399556
AM_OFF    1791399564
DONE      1791399608

T1791399569 040000C0:95C6 6401A8C0:CA6C    first dial after the toggle
```

The toggle landed entirely inside a 20 s window with nothing in flight, and the next dial
is a **fresh attempt starting from address #1**. Then the burst starts run:

```
1791399569  (+44)   1791399595  (+26)   1791399621  (+26)   1791399647  (+26)
1791399680  (+33)   1791399739  (+59)   1791399801  (+62)
…then 60/61s until the last attempt starts at 1791402100 (21:41:40), ends 1791402124
```

Those five gaps — 44, 26, 26, 26, 33 — are the **only** deviations from the steady state
anywhere in the dialling window (the 16 s / 20 s / 41 s / 45 s entries are poller splits;
each pair sums to 61 s).

### What this does and does not establish

It **favours the callback strongly**: 26 s ≈ 24 s burst + 2 s backoff, i.e. the schedule
restarted at `initialBackoff` and then re-climbed to the 60 s cap. That is the fingerprint
of `ConnectionSupervisor.onNetworkChanged()` — zero attempts, zero `nextAttemptAt`, zero
`lastBeatAt`, tick at once. On the timer alone the next burst could not have come before
≈1791399586, and could never have been three bursts 26 s apart. The wire demonstrably
followed the callback rather than the countdown.

It does **not** meet the brief's acceptance criteria, and I am not calling it a PASS:

- no logcat line for the transition — `MainActivity.watchNetwork` posts `networkChanged`
  with no `Log` call, so the callback instant is not on the record anywhere;
- no dial within 1–2 s: the first observable dial is 5 s after `AM_OFF`, 13 s after
  `AM_ON`;
- the channel cannot show that case: while the radio is off there is no route, a connect
  fails immediately, and the attempt never enters `SYN_SENT` — the poller's quiet window
  `1791399550..1791399568` is exactly that blind spot;
- and the observation window is shorter than it first looks: the dialling stops entirely at
  1791402124, so the steady state above rests on ~40 minutes of wire, not on the full
  capture (§8).

**The restart confound is excluded (checked 2026-10-08), so the trigger is attributable.**
An earlier draft of this section listed "a fresh supervisor produces the same
reset-and-re-climb signature" as an unexcluded confound. It is now excluded, and by
exclusion the reset can only have been the connectivity callback:

- a fresh supervisor needs either a new process — the app's process was still the one from
the 20:39:08 install (`pid 20498`, elapsed `03:39:55`, no crash record) — or a
`MeshService.stop()` + `start()` cycle, which would have taken the foreground notification
down with it (`stop()` awaits `SyncService.stop()`), and that notification was still up
(`isForeground=true foregroundId=51820`, uidState `TOP`);
- `attempts` / `nextAttemptAt` are reset in exactly two places:
`ConnectionSupervisor.onNetworkChanged()`, and `tick()`'s "heard from inside the timeout"
recovery, which needs the peer itself to answer — it never did (every dial stayed
`SYN_SENT`; the PC has no listener on 51820 and its ufw drops it); `stop()` clears the link
state, and the only other way a link is rebuilt from zero is the peer leaving
`MeshTransport.peers()` (i.e. being unpaired), which would have stopped the dials entirely
instead of resuming them.

So: **the connectivity callback demonstrably ran at the toggle, and the retry schedule was
thrown away and restarted because of it** — the wire followed the callback, not the
countdown. That is the fast path's *mechanism*.

**What is still not proven is the latency**, which is what the brief asked for: a dial
within 1–2 s of the transition. The first dial that left any trace came 13 s after `AM_ON`
and 5 s after `AM_OFF`, and the channel cannot do better than that — while the radio is off
there is no route, so a connect fails immediately and never enters `SYN_SENT`. The attempt
`onNetworkChanged()` fired at once is invisible by construction on this channel.

**Verdict: trigger isolated, latency unmeasured — not the PASS the brief defined, and none
is claimed.**

### The seam that would isolate it — **added 2026-10-08** (`19b6f88`)

The measurement was missing both halves of the story: `MainActivity.watchNetwork` posted
`networkChanged` to Dart with no `Log` call, and the supervisor scheduled a retry silently.
Both now log under one tag, `NexusSupervisor`:

- `MainActivity.watchNetwork` logs
  `networkChanged available <network> (active=… caps=… link=…)` (and the same for `lost`)
  from inside the callback, before the channel post, so the line carries the callback's own
  timing rather than the main looper's. It logs each network object's own description, which
  already carries the transports and the interface name, so it needs no API-30 guard
  (`LinkProperties.interfaceName`) on a minSdk-24 app;
- `ConnectionSupervisor` logs a network change with the waits it discarded, every retry with
  its attempt number and the wait it chose, and a peer coming back up.

One command now reads the whole story on one clock:

```
adb logcat -v epoch | grep NexusSupervisor
```

which correlates 1:1 with a `/proc/net/tcp` `SYN_SENT` poller on the same device clock. It is
observability only — the scheduling behaviour is unchanged, and the same 883 tests and the
same analyzer count pass with the lines in.

**Not yet exercised on hardware**: this is the seam, not a measurement. To turn it into one,
rerun the airplane toggle and read the gap between the `networkChanged` line and the first
`attempt … out` line — neither of which needs the radio to be up, which is exactly what the
`SYN_SENT` channel could not do.

Two further ideas remain unused: surface `supervisor.attempts` / `nextAttemptAt` in the app's
status so a UI dump reads the schedule with no logging at all, and use a route-preserving
trigger (flip the default network between two live paths) instead of airplane mode, which
removes the route and so blinds the `SYN_SENT` channel.

---

## 5. Headless re-verification (re-run 2026-10-08, after the changes below)

- `flutter test` → `01:01 +883 ~2: All tests passed!`, exit 0 — the 882 above plus the new
  freeze guard.
- `flutter analyze lib test tool` → **60 issues, 0 errors, 0 warnings** (all `info`;
  `flutter analyze` exits 1 whenever it reports any issue, which is the baseline here).
- `./tool/rehearsal.sh` → exit 0, and this run exercises the fixed peer:

  ```json
  {"outcomeOk":true,"outcomeMessage":"Saved report.pdf from Rehearsal PC to
   /tmp/nexus_rehearsal/downloads/report.pdf.","savedBytes":4096,"sourceBytes":4096,
   "bytesIdentical":true}
  ```

- `JAVA_HOME=… ./gradlew :app:testDebugUnitTest` → **BUILD SUCCESSFUL**, 21 tests 0 failed —
  `dev.nexus.nexus.ContactMatchTest` 18, `dev.nexus.nexus.NotificationPermissionTest` 3.
  Re-run because `MainActivity.kt` changed: the first attempt failed to compile
  (`Unresolved reference 'transports'` — a system API), and `LinkProperties.interfaceName`
  (API 30) was avoided rather than risked on a minSdk-24 app.
- Note: the 883 includes the untracked mesh-memory work present in this working tree; the
  committed HEAD alone is a smaller set.
- `gui_walkthrough.sh` was not run. The PC screen was never touched.

---

## 6. Commits

```
5b132ed  fix(test): rehearsal peer keeps its port and pairings across a restart
         test/rehearsal_peer.dart (+22/−3), test/rehearsal_peer_store_test.dart (+56)

c179789  refactor(mesh): supervisor owns reconnect scheduling
         lib/mesh/connection_supervisor.dart (+13), lib/mesh/mesh_service.dart (+48/−3),
         test/connection_supervisor_test.dart (+101)
```

Second pass, 2026-10-08 (§8):

```
bd4f887  fix(mesh): a beat that never answers cannot freeze the retry schedule
         lib/mesh/connection_supervisor.dart, test/connection_supervisor_test.dart (+93/−2)

19b6f88  chore(mesh): log the network transitions and the retries they reset
         android/…/MainActivity.kt (+43), lib/mesh/connection_supervisor.dart (+35/−2)
```

Pushed as **`cded0b7..c179789`** for the first pass and **`c179789..19b6f88`** for the
second; `git rev-parse origin/main` = `19b6f886a680a2ea460d7624b8ce2a4fad9bfcec` at the time
of writing (this report is committed after that).

Uncommitted and untouched, exactly as they were before this mission:
`TOMORROW.md`, `lib/core/conversation.dart`, `lib/core/protocol.dart`,
`lib/mesh/mesh_service.dart` (the memory hunks only), `lib/ui/assistant_view.dart`
(all modified); `lib/core/mesh_memory.dart`, `test/mesh_memory_test.dart` (untracked).

---

## 7. What remains unproven

- **The ConnectivityMonitor fast path's sub-second latency and its isolation** (§4). The
  schedule reset at the transition is measured; the callback itself is not isolated.
- **The real LAN port 51820.** The PC's ufw drops inbound 51820 (it allows tcp/udp 53317
  and udp 53), so no plain-LAN pairing or reconnect could be exercised on this host and the
  peer ran on 53317. This is a host finding, not a product bug; no elevation was requested
  or approved, and ufw was not changed.
- **Windows and macOS peers.**
- **USB-key / camera-control vision** — future mission.
- **Why the dialling stopped at 21:42:04** — investigated on 2026-10-08, see §8. The
  supervisor's own schedule is ruled out as the cause except for one freeze it did not guard
  against, which is now fixed and guarded by a test; the field state itself (a live process
  with no mesh listener at all) is still not explained.
- **Cleanup that still needs adb:** the pushed `/data/local/tmp/*.sh` probe scripts
  (`synpoll3.sh`, `fastpath2.sh`, `amcycle.sh`, `fa3.sh`, …) are still on the phone. adb came
  and went through the second pass and was gone again by the end of it (the phone
  re-enumerates as MTP only, with no adb interface); the phone itself still answers ping and
  its hotspot is up.

---

## 8. The 51-minute silence — second pass, 2026-10-08

§4 left one thing unexplained: after the attempt that started at `1791402100` (21:41:40), the
phone made **no dial at all for 3050 s** while the poller kept sampling at ~2.8 lines/s on
both sides of the boundary. This pass chased it with the phone back on adb.

### What the device showed

| Observation | Value |
|---|---|
| app process | `pid 20498`, elapsed `03:39:55` — the same process from the 20:39:08 install |
| app crashes | none in `logcat -b crash` |
| foreground service | `NexusSyncService isForeground=true foregroundId=51820`, uidState `TOP` |
| mesh TCP listener on 51820 | **absent** — an instant RST from the PC (1 ms), and no `LISTEN` row in `/proc/net/tcp` or `/proc/net/tcp6` |
| dials, 225 s of polling | **zero** `SYN_SENT` to `:CA6C`, with the poller alive throughout |
| app's own logcat output | nothing but GC/HWUI lines from `pid 20498` — no product logging at all |
| routes | `swlan0` 10.238.55.30/24 up; `v4-rmnet0` 192.0.0.4/32 up carrying the default route the dials used |

The zero dials are meaningful rather than a channel artefact: the walk's fourth address is
`10.238.55.21`, which is on `swlan0`'s own `/24` with the link route present, so that connect
could not fail for lack of a route. Had the loop been dialling, it would have shown.

### The candidates, ruled in and out by code

| | Candidate | Verdict |
|---|---|---|
| a | `lastHeardAt` moves on our own send, so the peer looks permanently up | **ruled out** — `MeshTransport.lastHeardAt` is `_verified` (`mesh_service.dart:1081`), moved only by `_noteSeen(..., verified: true)` (`:3278`), and the heartbeat passes `verified: false` |
| b | an attempt cap, an int overflow, or an unbounded wait in the curve | **ruled out** — no attempt cap exists; `backoffFor` returns `maxBackoff` as soon as the doubling reaches it (`connection_supervisor.dart:150-160`); `attempts` is an `int` and `nextAttemptAt` a `DateTime` |
| c | the connectivity stream closing stops the ticks | **ruled out** — ticks come from `Timer.periodic(tickInterval, …)` (`:178`) plus `onNetworkChanged()`; the stream only adds wakeups, and `_subscription` is cancelled nowhere but `stop()` |
| d | a mutual freeze: the mesh leaves supervised peers to the supervisor, and the supervisor stops | **the one that survives** — below |
| e | the peer's address list emptying, so nothing gets dialled | **ruled out** — `peers()` reads `_paired.values` (`mesh_service.dart:1069`), loaded once at `start()`, and `_heartbeat`'s `targets` always contains every paired peer (`:3466`) |

### (d): the freeze, and the fix

`tick()` set `_ticking = true` and held it across `await transport.beat()`
(`connection_supervisor.dart:217-286` before this pass), with the only release in the
`finally`. A `beat()` that never completes — one dial blocked inside the OS — therefore made
**every later tick return at the method's first line**, permanently: no attempt, no
notification, no reconnect, while the process looked perfectly alive. And because the mesh's
sweep deliberately leaves a supervised peer alone (`MeshService._presenceSweep`,
`mesh_service.dart:3450-3456`), nobody dialled that peer at all. Nothing needed that wait:
whether a beat worked is decided by a later tick, and `beat()` is idempotent while one
exchange is running.

Fixed in `bd4f887` — the dial happens after the latch is released, and is not awaited.

**Guard**: `test/connection_supervisor_test.dart`, *a beat that never completes cannot stop
the retry loop*. A transport whose `beat()` returns a never-completing future, ten minutes of
ticks on the fake clock, and the curve must keep climbing; it also requires `start()` to
complete with such a transport, since the mesh awaits it. Mutation-checked by holding the
latch again — the same test then fails at attempt 1:

```
Expected: a value greater than <6>
  Actual: <1>
```

### What is still not explained

The freeze explains a stalled *schedule*; it does not explain a missing **listener**.
`MeshService.stop()` is the only thing that closes the server, and it would have taken the
foreground notification down with it (`stop()` awaits `SyncService.stop()`), yet that
notification was still up — so as far as the app's own code goes the mesh was never stopped,
while it was not listening and held no sockets on the port at all. The most consistent
reading is that the Dart side stopped while the Android service kept the process and its
notification alive, and that nothing rebuilds the mesh when that happens.

Confirming it needs the one observation this pass could not get: adb came and went, and was
gone again by the time `dumpsys activity exit-info dev.nexus.nexus` (Android's own record of
why an app died) and the app's fd/socket state could be read. That is the next thing to check
— and the log seam added in `19b6f88` makes the run that checks it cheap.
