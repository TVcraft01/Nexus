# Decisions

Choices that removed something from the interface, and why, so the next
person does not put it back by accident.

## Hidden: the "Cloud sync" row in Settings

The row said "No account, no server copy" and its only behaviour was a snack
bar saying the same thing. There is no cloud service, no upload path and no
account in this app — `lib/core` has no client for one, and nothing in the
sync layer leaves the LAN. A row that exists to explain that it does nothing
is a promise of a feature, so it was removed from `lib/ui/settings_tab.dart`.

If a real sync service is ever added, the row comes back **with it**, not
before it.

## Hidden: the "Notification sync" switch on a device card

Tapping it wrote a preference through `NotificationSync.set()`, and nothing
read that value: no notification is ever forwarded between peers. The switch
therefore reported a setting that had no effect, which is the "setting that
cannot work" case in the UI rules.

Removed from the device card. The `NotificationSync` store itself is left in
place so an existing user's stored preference is not destroyed, and so a real
implementation can pick it up later — but nothing in the UI claims it works
until it does.

## Demo devices only when asked for

`kSeedPairedDevices` — This Phone, My PC, Studio Mac, and the 16 GB on the
example PC — used to be what a fresh install showed, so a real run presented
three devices that were not there. The first row is now this machine, built
from the platform the build runs on and the name the mesh knows it by, and the
examples only appear when `NEXUS_DEMO_DEVICES=1` is set (the screenshot harness
does) or inside a widget test. A release build never asks; a paired list with
nothing in it shows the empty state instead.

## No cancel while a pairing request is in flight

The pairing sheet disables its button and says "Pairing…" while it waits, which
satisfies the response half of §9's Doherty rule. The cancel half is not
there: `MeshService.pairWith` and `pairWithQrCandidates` return when the other
device answers or the socket times out, and no handle comes back to abandon
that wait. Adding a Cancel button without that handle would be a control that
does nothing, so it is a product decision first: give the mesh an abortable
pairing, then draw the button. Until then the request ends on its own and the
sheet stays open with the error, so the flow can be retried.

## No cancel once a send to another device has started

The "Send to <device>" control shows "Sending…" and the file arrives or the
error arrives, but a transfer in flight cannot be stopped from the UI. Same
reason as pairing: the transfer is a `Future` with no abort path. The button
is not drawn until the transfer layer can abandon one.

## First run has no step counter

Section 9 asks multi-step flows for "Step 2 of 3". First run asks exactly one
question — how Nexus should answer — so a counter there would invent steps. It
stays a single screen. Pairing, which really has two stages, now says
"Step 2 of 2" on its second screen.

## The Dark mode switch stays disabled while the system setting is in charge

Two ways to remove the dead control were available: draw a hint line under it,
or make a tap release the system setting and set dark in one gesture. The hint
line is what shipped, because the second option silently changes a preference
the user set elsewhere. If that trade is revisited, the change belongs in
`SettingsTab` next to `onFollowSystemChanged`, not in the switch itself.

## Android's local-network permission is not why discovery went deaf

Android 16 gates local-network access behind a permission, but it is opt-in for
apps and an app targeting API 36 receives an implicit grant through `INTERNET`;
enforcement proper starts at API 37 with `ACCESS_LOCAL_NETWORK`. The test phone
runs Android 16 with `targetSdk=36` and holds no `ACCESS_LOCAL_NETWORK` grant, and
the same process accepts inbound TCP from another device over the LAN, which that
policy would have to block as well. So the policy is not the cause here.

What the phone does is bind 51822, log `listening on 0.0.0.0:51822`, announce to
three targets every three seconds, and answer ICMP port-unreachable from the
network: a socket that sends and never receives. A bound socket that hears
nothing looked exactly like a healthy one in the status line, so the status now
carries `selfCheck`, the answer to one loopback datagram sent through the same
receive path, and `canReceive` is false when that packet never comes back. When
the probe cannot even be sent the answer stays unknown rather than accusing a
socket that may be fine.

## The Samsung test phone cannot receive UDP discovery, cause unproven

Observed on the SM-A256E (Android 16, `targetSdk=36`, package `dev.nexus.nexus`):
the discovery socket binds 51822 and announces, but no datagram ever reaches it.
The details, so a future investigation does not repeat them:

- its own loopback test packet never arrives (zero read events), while a socket
  bound a moment later in the same process — including one bound to 51822 —
  hears its own packet, so the port and the receive path are fine;
- replacing the launch socket heals it once (`selfCheck` becomes true), which is
  why the app now rebinds before declaring UDP unavailable;
- packets sent from this PC to `192.168.1.8:51822` never reach the app: the
  phone's UDP `NoPorts` counter rises by exactly the number sent, while a plain
  `nc -u -l` listener on the same port from `adb shell` does receive them;
- inbound TCP 51820 from the PC works, and the phone's active default network is
  Wi-Fi (103), so the app's sockets are on the right interface;
- no VPN, the multicast lock is held, and granting `NEARBY_WIFI_DEVICES` (runtime
  and appop) plus the allowed `ACCESS_LOCAL_NETWORK` appop changed nothing, so
  the local-network permission policy is not the cause;
- `/proc/net` is masked for `adb shell` and denied to the app, so the socket
  table could not be read from either side.

The cause is therefore recorded as **unknown and device-specific**. What the app
does about it is in the code, not in a guess: UDP stays best-effort, a deaf
socket is rebound up to three times, and discovery falls back to a TCP pass that
proves each peer with its pairing key.
