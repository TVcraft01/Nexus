# Known surfaces

Places where the code does something that is defensible today but is **not**
what a careful reader would assume from the name. Each entry says what ships,
what an attacker or a bug can do with it, and what closing it would cost.

This file exists so these do not live only in a commit message. If you change
the behaviour below, update the entry in the same commit.

---

## `/nexus/ping` and `/nexus/mouse`: the unsigned path for one-way pairings

**Ships in:** every build from the first file-link release. Authenticated for
token holders from `file link: sign ping and mouse with the pairing token`
(pass 3a) onward; the unsigned path below is what survives that pass.

**Where:** `lib/mesh/file_transfer_service.dart`, `_controlGate`, used by
`_acceptPing` and `_acceptMouse`, dispatched from `_serve`.

**What is true today:**

- A control request is **signed** (`x-nexus-nonce`, `x-nexus-ts`,
  `x-nexus-signature` = HMAC-SHA256 over
  `nexus/control/v1|<sender>|<nonce>|<ts>|ping` or `…|mouse|<dx>|<dy>|<click>`)
  whenever the sender holds this device's transfer token — which is what its
  QR carried, and therefore what a device that scanned this one has. A
  signature that does not verify, a timestamp outside ±120 s, or a nonce seen
  before is **refused with 401** and nothing is shown or moved.
- A request with **no signature** is accepted only when the sender's id is a
  device this shell has paired (shell list or mesh record). It is marked
  unverified, the shell appends "(unverified)" to the notification, and the
  name shown is the name in *that record*, never the `x-nexus-name` the request
  claimed. An unsigned request from an id this shell does not know is refused
  with 401 — that is the stranger-on-the-Wi-Fi attack the first version of this
  entry recorded.
- `/nexus/mouse` is refused unless the signature verified. A name is a label; a
  cursor is an effect.
- Once an id has signed successfully in this process, unsigned requests from it
  are refused for the rest of the process: a signature that could be stripped
  would otherwise be a downgrade rather than a proof.

**What is still open:** an attacker who knows the device id of one of your
paired devices — before that device has ever signed to you this process — can
post an unsigned ping and get a badged notification attributed to that device.
They cannot choose the text (the name comes from your record) and they cannot
move the cursor, but they can make your own device appear to nudge you. A fresh
install has no token of its own until it first shows a code, so during that
window it refuses every signed request and accepts unsigned ones from devices it
knows.

Also worth stating: the nonce cache is per process, so a restart re-opens a
≤120 s replay window for a captured control request. Closing that needs
persistent replay state, which is not worth it for a notification.

**Why the unsigned path exists at all:** the transfer token travels one way.
The device that scans learns the other's token; the device that was scanned does
not learn the scanner's. So a peer this shell scanned holds only its *own*
token and has nothing to sign with, even on a current build — refusing all
unsigned requests would break half of all live pairings.

**Removal condition:** the unsigned path can be deleted once 3b ships — token
exchange over the authenticated mesh pairing. At that point both sides hold a
secret for each other, every control request can be signed, and no unproven
request is accepted at all. Do not delete it before then: a ping is the only way
a one-way peer can reach this device.

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
