# Known surfaces

Places where the code does something that is defensible today but is **not**
what a careful reader would assume from the name. Each entry says what ships,
what an attacker or a bug can do with it, and what closing it would cost.

This file exists so these do not live only in a commit message. If you change
the behaviour below, update the entry in the same commit.

---

## Unauthenticated `/nexus/ping` and `/nexus/mouse`

**Ships in:** every build from the first file-link release through
`shell: bootstrap MeshService and NexusStore on the launched path` (pass 1).
Still present after pass 1 — deliberately, not by oversight.

**Where:** `lib/mesh/file_transfer_service.dart`,
`_acceptPing` and `_acceptMouse`, dispatched from `_serve`.

**What is true today:** the file link's four endpoints share one listener.
`/nexus/file` verifies an HMAC over `sender|nonce|filename|size`, keyed with the
receiver's own pairing token. `/nexus/hello` is public by design (it hands out
the nonce that makes the signature possible). `/nexus/ping` and `/nexus/mouse`
accept a request with **no signature and no token at all** — the helper's own
comment states the reason: the shell's pairing is one-way, and the side that did
not scan has no token to sign with.

**What that means in practice:** anything on the same local network that can
reach the listening port can

- POST `/nexus/ping` with `x-nexus-device` and `x-nexus-name` set to anything,
  and the victim's shell shows **"Ping from &lt;name&gt;"** as a snackbar on
  Android/iOS and a `notify-send` desktop notification on Linux (see
  `_onPing` in `main_ui.dart`). The name is attacker-chosen; there is no
  pairing lookup and no signature to check. This is a spoofing/phishing surface:
  a convincing name is enough to make the notification look like it came from a
  device the user trusts.
- POST `/nexus/mouse` with `{x, y, click}` and the event is published on the
  `mouse` stream. There is no pointer bridge consuming it yet, so the effect is
  a log line rather than a cursor movement — but the endpoint is live, and the
  first consumer that lands will inherit the missing check.

Neither endpoint persists anything and neither can read a file, run a command,
or change pairing state.

**Why pass 1 did not fix it:** moving the listener off 51820 is not the moment
to change what the protocol means. The honest fix is a signed request, which
needs a secret both sides hold; at pass 1 the scanning side held the token and
the scanned side held its own, and only a bidirectional pairing gives both.

**Still open after pass 2.** The shell's QR now carries a mesh code
(`mesh_code`, see `lib/core/pair_bridge.dart`), so a pairing *does* give both
sides a shared secret — but the file link's endpoints were deliberately left
alone in that pass; changing what `/nexus/ping` requires is its own commit with
its own audit of every caller. Ping auth is pass 3, and until it lands this
entry stands as written.

**What fixing it looks like:** require the same nonce+HMAC scheme `/nexus/file`
already uses on `/nexus/ping` and `/nexus/mouse`, or retire both endpoints in
favour of mesh messages once pass 3 rebinds the tabs. Either way, the test that
should exist first is one asserting a signature-less ping is *refused*; the
current behaviour is recorded in `test/file_transfer_service_test.dart`
("a ping needs no token — a known surface").

---

## The notification permission is asked for on every launch

**Ships in:** every build since the mesh gained a foreground service
(`NexusSyncService`), including the launched path after pass 1.

**Where:** `android/app/src/main/kotlin/dev/nexus/nexus/MainActivity.kt`,
`askToShowSyncNotification`, called from the `startSyncService` handler. The
handler runs once per process, when the shell starts the mesh.

**What is true today:** the call asks whenever the permission is not granted.
There is no "already asked" flag and no `shouldShowRequestPermissionRationale`
check, so a user who declined is asked again on the next launch. What stops it
becoming a nag is Android 13's own two-strike rule: after two declines the
system auto-denies without showing a dialog, and the app keeps asking into a
void — one wasted call per launch, no visible prompt.

**What that means in practice:** a user who declined once sees the dialog once
more, then never again. A user who reinstalls or resets the permission is asked
again from the first strike. Nothing is blocked either way: the mesh runs
without the notification; the foreground service is what keeps it alive.

**Why it is not fixed here:** the honest fix is to ask on the screen where the
user turns mesh pairing on, rather than at launch, and to remember that they
said no. Both are behaviour changes with their own on-device verification, and
none of it can be tested off a phone — no device was attached when this was
written (see `NotificationPermissionTest`, which pins the SDK/grant rule only).

---
