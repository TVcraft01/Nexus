# Nearby devices, mesh codes, and "Send to…" (2026-10-18)

What was built for the three things asked for, and — separately — what was
proven. The phone half is blocked and is stated as blocked rather than
implied.

## 1. The scanner reads a real device's code

`PairInvite` gained `addresses`, `port` and `code`, and
`PairInvite.fromAnyCode` reads **both** formats in the world:

- this shell's own `nexus_pair` JSON (now carrying the address, so the code on
  screen says who this is *and* where it is), and
- the mesh's `nexus://pair` URI, which carries the device id, its name, the
  address it can be reached at and the one-time code.

A v2 token (`QrPairingToken`) is refused in its own words: it is a real Nexus
code, so calling it a stranger's QR would be wrong, and it carries no device id
by design (ephemeral, single-use), so a screen with no mesh behind it has
nothing honest to store from one.

`PairQrPage` now resolves this device's own addresses (`localAddresses`, the
same rule the mesh uses) and puts them in the code, showing the line
**Reachable at 192.168.1.7**.

## 2. Discovery is real

`lib/mesh/nearby.dart` wraps the mesh's own `DiscoveryService` — the same
multicast-UDP protocol the real app runs, port 51822, announce + unicast reply
— and the Devices tab uses it:

- **Discover Nearby Devices** opens the socket, listens for
  `kNexusDiscoverWindow` (7 s, three announce cycles), and lists what answered;
- each answer is a row with the platform word and the address it came from, and
  tapping it pairs that device **with the address and port it announced**;
- the Online/Offline word on a paired row is now what the network is saying:
  a device heard in the last minute is online, and its row says
  `Seen just now at 192.168.1.44`;
- stopping happens when the tab goes away, so nothing announces into an empty
  room.

This is multicast UDP discovery, not DNS-SD: the mesh has never advertised
`_nexus._tcp` and a second mechanism would find nothing the mesh could pair
with.

## 3. "Send to…"

An image bubble carries a **Send to…** control, and the full-screen viewer
carries the same button. It opens a sheet listing the paired devices (never
this phone), each with whether it is being heard right now; tapping one shows a
progress bar and then one sentence.

The transport is `lib/core/file_link.dart`. It **stages** the file — a real
chunked copy into `<documents>/outbox`, real bytes, real progress — and says so:
*"Prepared for Study PC (1 KB). The mesh link is not wired into this screen
yet, so the file has not left this phone."* The mesh's own `pushLocalFile`
exists and is the thing that will sit behind this seam; until it does, no screen
claims a delivery that did not happen.

## Verified

```
flutter test      # 1365 passed, 3 skipped
flutter analyze   # 60 issues, 0 warnings (baseline unchanged)
flutter build apk --debug   # rc=0
```

New tests: `test/nearby_test.dart` (6), `test/file_link_test.dart` (4),
`test/send_to_device_test.dart` (4), and 6 rewritten/added in
`test/pair_flow_test.dart` — including that the mesh's own `nexus://pair` code
pairs with its address, that a live v2 code is refused in its own words, that a
heard device becomes a row and pairs with the address it used, that a paired
device being heard says so, that the picker lists peers and not this phone, that
the bar reads the real progress, and that a phone with nothing paired is told
how to add one.

The announce side was run for real on this LAN, not mocked:

```
flutter test test/live_nearby_probe_test.dart \
  --dart-define=NEARBY_PHONE_IP=192.168.1.8 --dart-define=NEARBY_SECONDS=6

NEXUS discovery: listening on 0.0.0.0:51822
NEXUS discovery: announced id=studypc000000000000000000000000001 port=51820
  (3/3 targets: multicast + 1 known + loopback)
```

## Blocked: the phone pass

`adb devices` was empty for the whole of this work, and it was retried:

- USB: the A25 (`R5CX73XFGKW`) appeared twice for about thirty seconds and then
  vanished; a twelve-attempt reconnect loop (adb restart, five-second spacing)
  never saw it again. `adb tcpip 5555` could not be run, because it needs that
  brief USB window.
- Wireless debugging: `adb mdns services` lists no `_adb-tls-connect._tcp`, and
  the port it advertised earlier (`192.168.1.8:35301`) refuses connections. The
  phone answers `ping`, so it is on the network — it is the debugging transport
  that is off.

So the APK was built and not installed, and none of the following has been seen
on a screen: the Nearby section filling with a real device, the pair-by-tap
snackbar, the QR page's address line, or the send sheet's bar and sentence. They
are covered by tests and by the live probe above; they are **not** covered by a
phone run, and this note does not claim otherwise.

To run it when the phone is back:

```
adb devices                                  # or: adb connect <ip>:<port>
flutter test test/live_nearby_probe_test.dart \
  --dart-define=NEARBY_PHONE_IP=<phone ip> --dart-define=NEARBY_SECONDS=300 &
adb install -r build/app/outputs/flutter-apk/app-debug.apk
# Devices → Discover Nearby Devices → tap the "Study PC" row
# Chat → the screen-share button → Start now → tap the image → Send to… → Study PC
```
