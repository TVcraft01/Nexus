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

**Metering:** every accepted control request writes one line,
`control: <path> from <name> <version>` (`path` is `unsigned`, `token` or
`derived`; `version` is the peer's last presence claim, or `unknown`), and
increments `NexusStore.controlPathSeen(path)` with `controlPathLast(path)`
alongside it. A released build has no console, so the counter — not the log
line — is the observable. The paths are counted apart because they die on three
different questions, and one mixed total could answer none of them.
`unsignedControlSeen` / `unsignedControlLast` remain as readers of the
`unsigned` path, under the names this note and the commit that introduced them
use.

**Removal condition:** delete the unsigned path once
`controlPathSeen(unsigned)` stops growing from builds that sign — i.e. zero
accepted unsigned requests whose version is 3b or later, over a release cycle.
Do not delete it on the strength of the mechanism existing: 3b closed the
*tokenless* direction only, and the one-way half is still live until those
pairings age out or are re-paired through the mesh.

**The token path's own condition:** `controlPathSeen(token)` is the count that
was missing when this note was first written. Delete the token path once it
stops growing, which is when every one-way pairing has been re-paired through
the mesh (so both sides hold a derived key) or has gone away. Until then it is
the only thing an older receiver and an older sender can use, and removing it
would turn working pings into 401s in both directions.

---

## The Devices list is lazy, and the test that measures it is not

**Ships in:** every build with the `DevicesTab` list, i.e. all of them. Found by
accident during pass 3c, when the peer-request policy table was briefly drawn
*inside* that list.

**Where:** `test/main_ui_test.dart`, `Devices shows a dot and a word per peer`,
against `DevicesTab`'s `ListView` in `lib/main_ui.dart`. It asserts
`find.text('Online')` finds 2, `find.text('Offline')` finds 1, and
`find.byType(NexusStatusDot)` finds 3 after opening the tab.

**What is true today — both sides are responsible:**

- *Test side:* the counts are of what is **built**, and the list only builds what
  fits the viewport. The finders themselves are not over-specific; the
  assumption "built == exists" is what is wrong. The failure surfaces as a
  *lower* count, so it reads as a device that went missing rather than one that
  scrolled out of the built area.
- *List side:* `DevicesTab` puts fixed-height blocks above a lazy list, so the
  height of everything above the cards decides whether the cards exist for the
  test. Nothing in the list signals that it is being counted this way.

**Measured, not guessed (2026-10-28):** with a 140 px block above the cards (the
approval card's height) the test passes; with a 600 px block (a settings
section) it fails on its first assertion with `Expected: exactly 2 matching
candidates / Actual: Found 1 widget with text "Online"`.

**What it costs:** a future change that adds one long block to the top of this
list will read as "the mesh lost a device". Two ways out, both small, neither
taken yet: assert per row — find the row by key and read its own dot — or scroll
each row into view before counting (the file already does that for
`Pair a device`). Until one lands, keep additions to this list short: the
peer-request **card** (140 px, and only while a request waits) is inside that
budget, which is why the pre-approval table is a sheet behind a Settings row
(pass 3c) instead of a section on this list.

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
