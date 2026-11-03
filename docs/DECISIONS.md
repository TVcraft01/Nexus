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
