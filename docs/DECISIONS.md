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
