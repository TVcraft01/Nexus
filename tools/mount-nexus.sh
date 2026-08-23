#!/usr/bin/env bash
# Mount paired Nexus devices as folders in your file manager (Nemo, Nautilus…).
#
#   tools/mount-nexus.sh          mount at ~/Nexus Devices (foreground)
#   tools/mount-nexus.sh -u       unmount
#
# The Nexus app must be running on this computer — it serves the mesh to this
# mount through its localhost gateway. Env overrides:
#   NEXUS_STATE  path to the app's state.json (default ~/.local/share/nexus/nexus/state.json)
#   NEXUS_MOUNT  where to mount        (default ~/Nexus Devices)
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="${NEXUS_STATE:-$HOME/.local/share/nexus/nexus/state.json}"
MNT="${NEXUS_MOUNT:-$HOME/Nexus Devices}"

if [ "${1:-}" = "-u" ] || [ "${1:-}" = "--umount" ]; then
  exec python3 "$DIR/nexusfs.py" "$MNT" --state "$STATE" --umount
fi

[ -f "$STATE" ] || { echo "Nexus state not found at $STATE" >&2; exit 1; }
mkdir -p "$MNT"
exec python3 "$DIR/nexusfs.py" "$MNT" --state "$STATE"
