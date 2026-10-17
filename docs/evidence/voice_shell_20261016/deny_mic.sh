#!/usr/bin/env bash
# Stages the refused-microphone path with no dialog to race: `user-fixed` makes
# Android answer the ask immediately denied, so the ask still runs (and still
# gates the session) but nobody can tap "Allow" first.
set -u
ADB="$HOME/Android/Sdk/platform-tools/adb"
PKG=dev.nexus.nexus
PERM=android.permission.RECORD_AUDIO

"$ADB" shell pm set-permission-flags $PKG $PERM user-fixed
"$ADB" shell pm revoke $PKG $PERM
"$ADB" shell am start -n $PKG/.MainActivity >/dev/null
sleep 6

# The 16 KB page-size warning owns the screen on launch; it is not our app, so
# it is dismissed before anything is measured.
for i in 1 2 3; do
  focus=$("$ADB" shell dumpsys window 2>/dev/null | grep -m1 mCurrentFocus)
  case "$focus" in
    *android}*) "$ADB" shell input tap 247 2092; sleep 2 ;;
    *) break ;;
  esac
done
echo "focus before the tap: $("$ADB" shell dumpsys window 2>/dev/null | grep -m1 mCurrentFocus)"

"$ADB" logcat -c
"$ADB" shell input tap 966 1964          # the mic: this is the ask
sleep 2.5
echo "focus after  the tap: $("$ADB" shell dumpsys window 2>/dev/null | grep -m1 mCurrentFocus)"
echo "permission state: $("$ADB" shell dumpsys package $PKG 2>/dev/null | grep -m1 'RECORD_AUDIO:')"
"$ADB" exec-out screencap -p > /tmp/n_refused.png

echo "=== mic/speech log ==="
"$ADB" logcat -d 2>/dev/null | grep -E "mic:|speech:" || echo "(none — no session was started)"
