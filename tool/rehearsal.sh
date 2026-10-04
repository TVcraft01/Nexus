#!/usr/bin/env bash
# Two-process file-fetch rehearsal.
#
# Runs the real Nexus pipeline in TWO separate OS processes (two `flutter test`
# VMs) instead of one:
#
#   process 1 (requester, test/rehearsal_requester.dart)
#       pairs with the peer, parses "get report.pdf from my pc", resolves the
#       device, and runs the fetch through the real StorageService adapter and
#       DeviceExecutor, saving the bytes.
#   process 2 (peer, test/rehearsal_peer.dart)
#       serves report.pdf from a real MeshService and accepts the pairing.
#
# Both are the production classes; only pairing is passed through a filesystem
# handoff because the code is random. The requester also asserts the received
# bytes equal the source bytes.
#
# Usage:  tool/rehearsal.sh
# Exits non-zero if either side fails.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=/tmp/nexus_rehearsal
rm -rf "$WORK"
mkdir -p "$WORK"

echo "== peer (process 1) =="
flutter test test/rehearsal_peer.dart >"$WORK/peer.log" 2>&1 &
PEER_PID=$!
trap 'kill "$PEER_PID" 2>/dev/null || true' EXIT

for _ in $(seq 1 150); do
  [ -f "$WORK/peer.json" ] && break
  sleep 1
done
if [ ! -f "$WORK/peer.json" ]; then
  echo "peer never published its pairing code" >&2
  tail -40 "$WORK/peer.log" >&2
  exit 1
fi
echo "peer published $(cat "$WORK/peer.json")"

echo "== requester (process 2) =="
flutter test test/rehearsal_requester.dart

# Let the peer observe `done` and shut down cleanly.
timeout 60 bash -c "while kill -0 $PEER_PID 2>/dev/null; do sleep 1; done" || true

echo "== result =="
cat "$WORK/result.json"
echo
