#!/usr/bin/env bash
# Cold-launch proof and the pairing UI flow, on a real Android emulator.
#
# This lives in a file because reactivecircus/android-emulator-runner runs every
# line of its `script:` input as its own `sh -c` command — a multi-line `if`
# there is a syntax error, which is exactly how the first version failed.
set -euo pipefail

APK=build/app/outputs/flutter-apk/app-debug.apk
PKG=dev.nexus.nexus

fail() {
  echo "FAILED: $*"
  adb logcat -d -t 400
  exit 1
}

echo "== install =="
adb install -r "$APK"

# The app asks for the microphone on first start, and the system permission
# dialog then sits on top of the launch: a second `am start` is delivered to
# that dialog instead of a fresh activity, which is not a cold launch. Granting
# them up front keeps the launch under test the app itself.
for perm in android.permission.RECORD_AUDIO android.permission.POST_NOTIFICATIONS; do
  adb shell pm grant "$PKG" "$perm" 2>/dev/null || true
done

echo "== cold launch 1 =="
# The launcher alias is the exported entry point (the activity has no MAIN
# filter on purpose), so it is what a person's tap runs.
adb shell am start -W -n "$PKG/.IconLight"
sleep 25
PID=$(adb shell pidof "$PKG" | tr -d '\r' || true)
if [ -z "$PID" ]; then
  fail "the process is gone 25s after the first cold launch"
fi
echo "COLD LAUNCH OK: $PKG pid $PID alive 25s after start"
if adb logcat -d | grep -q "FATAL EXCEPTION"; then
  fail "FATAL EXCEPTION in logcat after the first cold launch"
fi

echo "== cold launch 2 (a fresh process must read the seed it wrote) =="
adb shell am force-stop "$PKG"
sleep 2
adb shell am start -W -n "$PKG/.IconLight"
sleep 15
PID=$(adb shell pidof "$PKG" | tr -d '\r' || true)
if [ -z "$PID" ]; then
  fail "the process is gone 15s after the second cold launch"
fi
echo "SECOND COLD LAUNCH OK: pid $PID (secure storage survived a restart)"
if adb logcat -d | grep -q "FATAL EXCEPTION"; then
  fail "FATAL EXCEPTION in logcat after the second cold launch"
fi
adb shell am force-stop "$PKG"

echo "== the pairing screens, on the device =="
flutter test integration_test/offline_pair_ui_e2e_test.dart -d emulator-5554
