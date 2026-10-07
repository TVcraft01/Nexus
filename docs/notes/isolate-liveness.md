# Nexus — isolate liveness

Why an app with a live process and a live foreground service can stop answering
on its own port, and the smallest watchdog that would notice.

Design note, 2026-10-08. No code. Written from the device run of 2026-10-07
(`docs/evidence/step7_device_reconnect_20261007.md`, §4 and §8).

## The observation

On 2026-10-07 the phone made no outbound dial for **3050 s (51 minutes)** while
the PC-side poller kept sampling the whole time. The device was later read while
still in that state:

| Read | Value |
|---|---|
| app process | `pid 20498` — the same process from the 20:39:08 install, still up |
| process exit record (`dumpsys activity exit-info`) | one entry, `reason=16 (PACKAGE UPDATED)` at the install; **no exit since** |
| crashes | none in `logcat -b crash` |
| foreground service | `NexusSyncService isForeground=true foregroundId=51820`, uidState `TOP` |
| mesh listener on 51820 | **absent** — no `LISTEN` row in `/proc/net/tcp{,6}`, and the PC got an instant RST (1 ms) |
| app's own TCP sockets | **none** |
| the app's logcat output | GC/HWUI lines only — no product logging at all |

So: the process never died, the service that keeps it alive never stopped, and
yet the mesh was neither listening nor dialling.

## The two candidate causes

### (a) The Dart isolate stopped while Android kept the process alive

Android may stop an app's Dart isolate — freeze the whole isolate while the
process and its components stay alive — without killing the process or
delivering `onDestroy`. Under a foreground service this is not the documented
normal path, but "the isolate is not scheduled and nothing in-app ran" is
exactly what the reads above look like: not a crash, not a `stop()`, just a
Dart side that stopped executing.

This fits every observation, and it is **not confirmed** — see "What is still
unproven".

### (b) Something in-app closed the listener

Ruled out by code:

- `_server?.close()` occurs exactly once, in `MeshService.stop()`
  (`lib/mesh/mesh_service.dart:4064`).
- Nothing in `lib/` calls `mesh.stop()` — grep finds only tests.
- `stop()` also awaits `SyncService.stop()`, which would have taken the
  foreground notification down; the notification was still up
  (`isForeground=true foregroundId=51820`).

If (b) had happened, the notification would be gone. It was not.

A third reading — the isolate is fine and only the socket vanished — has no
mechanism in the code at all: nothing closes a listening `ServerSocket` except
`stop()`, and a socket cannot leak away under a live isolate holding it.

The most consistent reading is therefore **(a)**: the Dart side stopped while
the Android side kept the process and its notification alive, and nothing
rebuilds the mesh when that happens. The supervisor freeze fixed in `bd4f887`
explains a stalled *schedule*; it does not explain a missing *listener*. They
are two different failures.

## The minimal detection

Do not guess at isolate-suspend semantics to fix this; detect the state
instead. A foreground service already runs on a timer for its notification
(`NexusSyncService`). The smallest check that would have caught 2026-10-07 is
one line per tick:

```
the mesh is "listening" iff MeshService's server socket is bound and accepting on
its port.  Each tick, if not listening -> it is stale.
```

Two ways to ask, cheapest first:

1. **In-process, from Dart** — a heartbeat the Dart isolate must keep bumping
   (the seam added in `19b6f88` already logs the supervisor's retries; a Dart
   liveness beat is the same shape). If the service sees no bump for N ticks,
   the Dart isolate is the suspect.
2. **Out-of-process, from the service** — ask the OS: is the app's listening
   socket on 51820 present? This distinguishes "isolate stopped" from "isolate
   running but not listening", which the in-process check cannot.

A stop-watch on the *symptom* (the port) is more honest than a stop-watch on
the *assumption* (the isolate), because it needs no claim about why the socket
went away.

## The minimal repair

Once stale is detected: **call `MeshService.start()` again.** `start()` is
already idempotent on a live mesh — it returns early when `_started` is true
(`mesh_service.dart:1141`) — and its job is exactly "bind the server, wire the
supervisor, load the peer list". Re-running it is the mesh equivalent of
toggling the radio: the listener comes back, peers are dialled again, and the
foreground notification never has to move.

Two guards so the repair cannot itself become a freeze:

- cap the restart rate (no more than once per minute);
- clear `_started` before retrying, or the early-return will refuse the repair
  of a mesh that thinks it is up while the socket is gone. That is the one
  change `start()` needs to be a repair and not only a launch — a `restart()`
  entry point that stops and starts, or a `_started` that is derived from
  socket liveness rather than a boolean.

## What is still unproven

- The field state at the moment of the 51 minutes: adb came and went, and the
  fd/socket read at the exact boundary was never taken. `exit-info` and the
  service/notification reads narrow it, but the isolate itself was not observed
  stopped.
- Android's isolate-suspend semantics under a foreground service are **not
  documented enough here to write the watchdog against directly.** Building a
  repair that assumes "the isolate was frozen" would be guessing; building the
  port-liveness check above needs no such assumption, and it is the version
  that should go in first.
- The repair's own test is the open work: a hung listener rebuilt on the next
  tick, in the same mutation-checked style as the supervisor guard — with a
  deliberately dead server socket standing in for the frozen isolate.
