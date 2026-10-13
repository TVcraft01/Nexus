# Location reminders on the real phone — 2026-10-13

Device **R5CX73XFGKW** (SM-A256E, Android 16), app `dev.nexus.nexus`,
debug APK built from `9d2765f` + fixes below, headless PC, adb only.
SDK `~/Android/Sdk`, JDK Temurin 17 (`~/jdk17`, fetched today).
Release 0.2.1 was uninstalled to allow the debug signature; see §7.

Env for every command: `export PATH=~/Android/Sdk/platform-tools:$PATH`

## 1. Build: two real bugs found by compiling, both fixed

- `LocationReminders.kt:211` — `fired.isNotEmpty` used as a property on a
  `List`; Kotlin needs the call. (`compileDebugKotlin` failed; fixed.)
- `addProximityAlert` threw at runtime, caught by our own guard and
  visible in logcat: `W NexusLocation: fence failed: pending intent must
  be mutable`. The fence `PendingIntent` copied the alarm pattern
  (`FLAG_IMMUTABLE`), but the system writes `KEY_PROXIMITY_ENTERING`
  into it on delivery — proximity intents must be `FLAG_MUTABLE`
  (guarded to Android 12+, mutable-by-default below). Exact-alarm
  intents stay immutable. Fixed, rebuilt, fence arms clean
  (no `NexusLocation` warnings since).

## 2. Verified on device (adb, no UI)

- **Fresh install:** `state.json` holds identity only → every capability
  getter falls to `false`. Manifest declares `FINE` + `BACKGROUND`
  location; runtime shows both ungranted before first toggle.
- **Full loop, twice** (store-injected reminder at the device's own fix
  `45.750240,6.415991`, 200 m radius, app restarted):
  1. fence armed with no errors;
  2. ENTER fired while already inside → notification posted on the
     **nexus-reminders** channel, text exactly
     `buy milk — you arrived at Current spot.` (39 chars) /
     `drink water — you arrived at Current spot.` (42 chars);
  3. fired id recorded in `nexus_location_reminders.xml`;
  4. Dart collected it, store shows `"fired":true`, prefs cleared
     (`<map />`) — each fire collected exactly once.
- **Cross-run leak found and fixed:** an `install -r` + store replace
  left the previous run's fence armed (Dart's armed-set was in-memory
  only), posting a second notification for a reminder the store no
  longer held. Two changes: notification ids are now stable DJB2
  (Dart `String.hashCode` is re-seeded every launch; Kotlin side
  computes the same hash with `Long` arithmetic so overflow matches),
  and `_collectFiredPlaces` retires unknown fired ids via
  `removeLocationGeofences`. Re-verified: exactly one live notification
  per reminder; restart replaces the fence instead of doubling it.
- **Shell-spoofed fence broadcasts do NOT deliver** (`exported=false`
  on the receiver — correct; only the system's `PendingIntent`
  delivery path works). Manual `am broadcast` is therefore not a valid
  fire test; the store-injection loop above is.

## 3. Nominatim contract (host-side, device has internet)

`curl 'https://nominatim.openstreetmap.org/search?q=test&format=jsonv2&limit=1'`
with the app's `User-Agent` returns a normal `[{lat, lon, …}]` payload.
URL params are asserted in unit tests; the live on-device lookup was
not exercised (needs the agent UI).

## 4. Remaining manual QA (needs a human + screen)

No UI automation exists headless; each item needs fingers:

1. **Fresh install → Settings → Capabilities.** Location, Clipboard,
   Voice are off; Mesh pairing and Local AI model are explanation rows.
2. **Tap Location reminders.** Foreground dialog appears; on grant, the
   background dialog appears (one channel result held across both —
   watch `adb logcat | grep NexusLocation` for silence, i.e. success).
3. **Deny either dialog.** Switch stays off; SnackBar names `Always`
   permission + Time reminders; `Open Settings` lands on app details:
   `adb shell dumpsys package dev.nexus.nexus | grep -E 'FINE|BACKGROUND'`
   shows the grant states.
4. **Grant both, ask** “remind me to buy milk when I get to the grocery
   store”. Confirm exactly one lookup: the confirmation sentence says
   OpenStreetMap once; `state.json` gains the cached coordinates.
5. **Closed-app fire:** grant background, set a reminder, force-stop,
   walk into the fence → notification on nexus-reminders.
6. **Toggle off** → agent says reminders are off, no lookup, no fence
   (`dumpsys location | grep -i proxim` shows no Nexus fence).
7. **Time reminder** still fires at its minute (untouched path).

## 5. Notes

- `pm clear` does **not** retract posted notifications — stale records
  in `dumpsys notification` after a wipe are corpses, not double fires.
  Compare extras text, not record counts.
- `ReminderAlarms.notificationId` still uses `String.hashCode` (stable
  Kotlin side, unstable Dart side) — same latent class as §2 fixed for
  fences. Left untouched: time reminders are released behavior.
- Untracked leftovers unrelated to this mission, left alone:
  `docs/evidence/phone_loop_*` (earlier agent-loop pass),
  `test/clip_probe_driver.dart` (temporary clipboard driver, says so
  in its own header).
