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
(pass 3a), and for **every mesh-paired peer in both directions** from
`mesh: sign control with a per-pair key derived from the pairing secret`
(pass 3b). The unsigned path below is what survives those passes: one-way
pairings, where no shared secret was ever established.

**Where:** `lib/mesh/file_transfer_service.dart`, `_controlGate`, used by
`_acceptPing` and `_acceptMouse`, dispatched from `_serve`.

**What is true today:**

- A control request is **signed** (`x-nexus-nonce`, `x-nexus-ts`,
  `x-nexus-signature` = HMAC-SHA256 over
  `nexus/control/v1|<sender>|<nonce>|<ts>|ping` or `…|mouse|<dx>|<dy>|<click>`)
  with whichever secret this pair shares. There are two, and the newer one wins
  when both exist:
  - **per-pair control key** — HKDF over the mesh pairing secret, salted with
    both ids, domain-separated by `nexus/control/v1`. Both sides derive it; it
    never travels. A mesh pairing therefore signs in **both directions**, which
    is what a one-way QR cannot do.
  - **this device's transfer token** — what a peer that scanned this device's
    code holds.

  A receiver accepts **either** key while builds from before 3b are in the
  field, and refuses a signature that matches neither. The sender uses the
  token whenever its row has one, because that is the only proof an older
  receiver can check; it uses the derived key only when there is no token, which
  is the direction of a pairing that never carried one. That split is deliberate
  and it is why 3b closes the gap without breaking a single existing pairing: a
  new build signs with what the other side understands. A timestamp outside
  ±120 s or a nonce seen before is **refused with 401** and nothing is shown or
  moved.
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
*pairing* devices — one that paired only through the shell, or that has not
signed to you yet this process — can post an unsigned ping and get a badged
notification attributed to that device. They cannot choose the text (the name
comes from your record) and they cannot move the cursor, but they can make your
own device appear to nudge you. A fresh install has no token of its own until it
first shows a code, so during that window it refuses every signed request and
accepts unsigned ones from devices it knows.

A **mesh-paired** peer in the direction that never carried a token — the
scanned device pinging the scanner — is no longer in that set: 3b gives both
sides a key, so that ping signs from the first one. The residual population is
one-way pairings whose sender has no token for the receiver, and builds older
than 3b.

Also worth stating: the nonce cache is per process, so a restart re-opens a
≤120 s replay window for a captured control request. Closing that needs
persistent replay state, which is not worth it for a notification.

**Why the unsigned path still exists:** a shell-only pairing shares exactly one
secret, and it travels one way. The device that scans learns the other's
transfer token; the device that was scanned does not learn the scanner's, so it
has nothing to sign with on that path. Refusing all unsigned requests would
break those pairings outright, and a ping is the only way such a peer can reach
this device.

**Metering:** every accepted unsigned request writes one line,
`control: unsigned from <name> <version>` (`version` is the peer's last presence
claim, or `unknown`), and increments `unsignedControlSeen` in the store with
`unsignedControlLast` alongside it. A released build has no console, so the
counter — not the log line — is the observable.

**Removal condition:** delete the unsigned path once `unsignedControlSeen` stops
growing from builds that sign — i.e. zero accepted unsigned requests whose
version is 3b or later, over a release cycle. Do not delete it on the strength of
the mechanism existing: 3b closed the *tokenless* direction only, and the one-way
half is still live until those pairings age out or are re-paired through the
mesh.

**Known gap for the next pass:** the token-signed path is not metered. 3b left it
in place on purpose (it is what an older receiver verifies, and what every
existing pairing uses), so `unsignedControlSeen` cannot say when *it* is dead.
Deleting the token path needs its own count — the same shape, a different field —
before it can be removed honestly.

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
