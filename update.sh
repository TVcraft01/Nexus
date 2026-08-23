#!/bin/sh
# update.sh — rebuild and reinstall the Linux Nexus app from the latest code.
#
# The app can also update itself from GitHub releases (Settings-less, it just
# offers "Update & restart"). Use this script when you want to build from the
# very latest source, or as the manual fallback if auto-update fails.
#
# Usage:  ./update.sh

set -e
cd "$(dirname "$0")"

echo "==> Updating Nexus (v$(grep '^version:' pubspec.yaml | awk '{print $2}' | cut -d+ -f1))"

git pull --ff-only || echo "    (could not pull — building from local code)"

echo "==> Building..."
flutter pub get >/dev/null
flutter build linux --release

INSTALL="${NEXUS_INSTALL_DIR:-$HOME/.local/share/nexus-app}"
echo "==> Installing to $INSTALL"
mkdir -p "$INSTALL"
cp -r build/linux/x64/release/bundle/* "$INSTALL/"
chmod +x "$INSTALL/nexus"

# Restart any running instance with the fresh build.
if pgrep -x nexus >/dev/null 2>&1; then
  echo "==> Restarting the running app..."
  pkill -x nexus || true
  sleep 1
fi
setsid nohup "$INSTALL/nexus" >/dev/null 2>&1 &
echo "==> Done. Nexus is running the fresh build."
