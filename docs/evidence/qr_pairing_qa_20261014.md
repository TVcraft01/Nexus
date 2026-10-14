# QR pairing — manual QA script (2026-10-14)

Automated coverage: `test/qr_pairing_test.dart` (8 tests: roundtrip,
expiry, version, tamper, defaults-off, scan-leaks-nothing, mutual-confirm
+ single-use + revoke over real sockets, toggle-off refusal) and the
rewritten sheet test in `test/pairing_recovery_test.dart`. Full suite:
1047 passed, 2 skipped, 0 failed. Debug APK builds (`APK_EXIT=0`).

No Android device was attached at build time (`adb devices` empty), so the
camera / two-phone steps below need human hands. Do them with two fresh
installs (A = shower, B = scanner).

## Setup

```bash
export PATH=~/Android/Sdk/platform-tools:$PATH
adb install -r build/app/outputs/flutter-apk/app-debug.apk
adb shell pm clear dev.nexus.nexus   # fresh install state, both phones
adb logcat -c
```

## 1. Fresh install defaults (both phones)

Settings → Capabilities: every toggle OFF (Mesh pairing, Clipboard sync,
File sharing, Notifications, Location sharing, Location reminders, Voice
input). Only Local AI model stays on.

```bash
adb shell "run-as dev.nexus.nexus cat files/nexus/state.json" \
  | python3 -m json.tool | grep -E "pairingEnabled|clipboardSync|fileShare|notificationShare|locationShare|locationReminders|voiceInput"
```

Expected: all `false` (keys absent = false).

## 2. Pairing request flow

1. A: Settings → turn ON Mesh pairing. Devices → Add device → More ways
   → Show my code instead. A 4-digit code + QR shows ("expires in
   2 minutes", "nothing pairs until you tap Allow").
2. B: turn ON Mesh pairing. Devices → Add device → Scan a QR code.
   - Deny the camera permission first: expect the "camera could not
     start" guidance (not a crash).
   - Allow, scan A's QR. B shows "Request sent — ask the other device to
     tap Allow (code XXXX)". The code matches A's.
3. A shows "A device wants to pair. Code: XXXX. Allow?" → Deny first:
   B reports declined; A can show a new code (single-use: old pid dead).
4. Scan again → A taps Allow → both toast "Paired 🎉".

Expected logs (A then B):

```bash
adb logcat -d | grep -E "NEXUS (mesh|scan)"
# NEXUS mesh: qr-shown pid=<id> code=<4-digit> exp=<ms>
# NEXUS scan: raw=nexus://pair?v=2… format=... (B)
# NEXUS scan: v2 qr pid=<id> code=<4-digit> (request only — no data read, no pairing yet)
# NEXUS mesh: qr-request -> <ip>:<port> pid=<id> code=<4-digit> (B)
# NEXUS mesh: qr-request raw from=<id> pid=<id> (A)
# NEXUS mesh: qr-request staged pid=<id> code=<4-digit> awaiting-confirm (A)
# NEXUS mesh: qr-accept -> <id> pid=<id> (A)
# NEXUS mesh: qr-accept <- <id> pid=<id> (B)
```

Scan alone (kill B before Allow): A stays unpaired, B stays unpaired —
`adb` check `state.json` → `paired` holds no new entry on either side.

## 3. Expiry + single-use

- Wait 2 min (or change A date +3 min): B scans → "That QR expired".
- Reuse an accepted QR: A answers "already used, show a fresh code".

## 4. Capabilities stay OFF after pairing

With A+B paired, all four sharing toggles still OFF:

- B copies text → A shows nothing (clipboard off).
- B Files → A's device → "File sharing is off on this device."
- Turn each ON one at a time and confirm the feature starts working.

## 5. Revoke + audit

A: device node → Unpair (or detail → Forget device). A drops B at once.

```bash
adb shell "run-as dev.nexus.nexus cat files/nexus/state.json" \
  | python3 -c "import json,sys; [print(e['t'], e['event'], e.get('detail','')) for e in json.load(sys.stdin)['settings']['pairingAudit']]"
```

Expected trail on A: `qr-shown`, `qr-request-got`, `paired`, `revoked`
(plus `qr-denied` / `qr-expired` if exercised).

## 6. Hostile networks (if available)

- AP isolation on: request fails with "Could not reach … Same Wi-Fi? VPN
  or AP isolation may block it." (not a silent spinner).
- VPN up on one side: QR carries the primary address only; discovery +
  manual address entry remain the fallback — same honest error otherwise.
- Emulator camera cannot scan a real QR: type the 4-digit code path is
  manual-code only; QR needs two physical devices.
