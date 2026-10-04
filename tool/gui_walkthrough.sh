#!/usr/bin/env bash
# Unattended two-window GUI walkthrough for the file-fetch vertical slice.
#
# This is the GUI twin of tool/rehearsal.sh. Where that script drives two
# `flutter test` VMs (no windows), this one launches TWO REAL DESKTOP BUILDS
# with distinct NEXUS_DATA_DIR values and drives them the way a person would:
# real clicks and real keystrokes into the real widgets, the real pairing
# sheet, and the real command bar. Nothing is stubbed — both sides are the
# production app binary, and no step is handed to a human.
#
# The driving itself (compositor geometry, grim screenshots, tesseract OCR,
# /dev/uinput pointer, wtype keyboard) lives entirely in tool/ui_driver.py.
# This script owns the *walk*: which windows to launch, what to click, what to
# type, what to wait for. Every screen read and every input goes through that
# helper's contract — focus_window / region_for / click_text / wait_text /
# type_text / press_key / screenshot — so nothing here calls tesseract, grim,
# wtype or /dev/uinput directly. See tool/ui_driver.py for the contract.
#
# The whole walk — build, launch, pair, two fetches, verify — runs inside ONE
# invocation, because a background process started here is gone as soon as
# the invocation returns.
#
# Usage:
#   tool/gui_walkthrough.sh                 # build if needed, then run
#   tool/gui_walkthrough.sh --no-build      # reuse an existing bundle
#   tool/gui_walkthrough.sh --kill-orphans  # also close every Nexus first
#   tool/gui_walkthrough.sh --negative      # one fetch that must FAIL: the
#                                           # app says it cannot find the
#                                           # name, and nothing lands on disk
#
# --negative reuses the same build, launch, pair and seam; only the fetch step
# differs, so it never disturbs the default happy path.
#
# Cleanup kills only the two instances this run launched — their PIDs are
# recorded as they start, and a PID is killed only while it still carries this
# run's data dir. A developer's own open Nexus is never touched unless
# --kill-orphans is given.
#
# NEXUS_GUI_TIMEOUT bounds ONE step, in seconds (default 90) — not one long
# wait at the end. The first step to fail is named and the script exits
# non-zero.
#
# Exit code 0 = every fixture landed with matching size + sha256 (happy path),
# or the app reported the name missing and nothing landed (--negative).
set -uo pipefail
cd "$(dirname "$0")/.."

BUILD=1
KILL_ORPHANS=0
NEGATIVE=0
for arg in "$@"; do
  case "$arg" in
    --no-build)     BUILD=0 ;;
    --kill-orphans) KILL_ORPHANS=1 ;;
    --negative)     NEGATIVE=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

UI=tool/ui_driver.py
STEP_TIMEOUT="${NEXUS_GUI_TIMEOUT:-90}"
STAMP=$(date +%Y%m%d-%H%M%S)
BUNDLE=build/linux/x64/debug/bundle/nexus
WORK="/tmp/nexus_gui/$STAMP"
HOME_DIR="${HOME:?HOME must be set}"
DL_DIR="$HOME_DIR/Downloads"
SERVER_DIR="$WORK/server"
REQUESTER_DIR="$WORK/requester"
# Each instance gets its own XDG_DATA_HOME, so the profile it reads and writes
# (app-id based, one file shared by every instance) lives inside this run's
# evidence dir. The user's real profile is never opened, let alone rewritten.
SERVER_DATA="$WORK/data-server"
REQUESTER_DATA="$WORK/data-requester"
# What is load-bearing here is the two logs plus the sizes and sha256 that
# verify prints; screenshots are diagnostic only. On a passing run the only one
# kept is the final 99_result.png. On a failure the run also keeps ONE
# fail-$STEP.png (whole screen) — a flaky step is hard to explain from logs
# alone — which is the one piece of the pruned diagnostics deliberately
# restored. The driver's working frame still lives in scratch, not here.
SCRATCH="${TMPDIR:-/tmp}/nexus-ui-$STAMP"
export NEXUS_UI_WORK="$SCRATCH"

# name:bytes — the server serves these from its home dir; the requester types
# "get <name> from my pc" for each. Deterministic bytes so the expected sha256
# is reproducible run to run. big.bin is the size docs/DEMO.md quotes.
FIXTURES=("report.pdf:4096" "big.bin:30000000")

# The negative path's subject: a name the served root definitely lacks. Its
# wording is the app's own, from lib/core/answers.dart (FileFetchWords.notFound):
#     '<device> has no file named <filename>.'
# The device name is dynamic, so the assertion is the filename-independent
# wording plus the requested stem; the guard below keeps it tied to that source
# instead of a remembered paraphrase.
NEG_NAME="doesnotexist.pdf"
NEG_STEM="${NEG_NAME%.*}"
NEG_WORDS="has no file named"

STEP="startup"
say()  { printf '%s\n' "$*"; }
step() { STEP="$1"; say ""; say "== $STEP =="; }
fail() {
  say ""
  say "FAIL: step '$STEP' — $*"
  # One diagnostic frame, written only on failure. Best effort on purpose: a
  # window that is already gone must not hide the real failure.
  ui shot "$WORK/fail-$STEP.png" >/dev/null 2>&1 || true
  say "evidence: $WORK (both logs, fail-$STEP.png)"
  exit 1
}

# --- cleanup ----------------------------------------------------------------
# Runs on every exit. Removes the fixtures this run copied into the served
# home dir (a 30 MB big.bin in $HOME is a real mess), then kills only the
# instances it launched: the PIDs it recorded, and only while each still
# carries this run's data dir (so a reused PID is never killed).
cleanup() {
  for spec in "${FIXTURES[@]}"; do
    rm -f "$HOME_DIR/${spec%%:*}" "$DL_DIR/${spec%%:*}"
  done
  # A negative file should never exist; remove it anyway so an interrupted run
  # cannot leave a stray doesnotexist.pdf behind.
  rm -f "$DL_DIR/$NEG_NAME"
  rm -rf "$SCRATCH"
  [ "${NEXUS_GUI_KEEP:-}" = 1 ] && return 0
  [ -f "$WORK/pids" ] || return 0
  for p in $(sort -u "$WORK/pids" 2>/dev/null); do
    env=$(tr '\0' '\n' </proc/"$p"/environ 2>/dev/null)
    case "$env" in
      *"NEXUS_DATA_DIR=$WORK/"*) kill "$p" 2>/dev/null || true ;;
    esac
  done
}
trap cleanup EXIT

mkdir -p "$WORK" "$SERVER_DIR" "$REQUESTER_DIR" "$DL_DIR"

# --- driver seam ------------------------------------------------------------
# Everything that touches the compositor, the screen or the input devices goes
# through here. This script never calls tesseract, grim, wtype or /dev/uinput.
ui() { python3 "$UI" "$@"; }

need() { command -v "$1" >/dev/null 2>&1 || fail "missing tool: $1"; }

# "x y w h" for a pid, or empty when the window is gone.
geom() {
  local r xy wh
  r=$(ui region "$1" 2>/dev/null) || return 1
  [ -n "$r" ] || return 1
  xy="${r%% *}"; wh="${r##* }"
  printf '%s %s %s %s' "${xy%%,*}" "${xy##*,}" "${wh%%x*}" "${wh##*x}"
}

focus() { ui focus "$1" >/dev/null 2>&1 || true; }

# Click the on-screen text `phrase` in window `pid`; extra flags (--x-max,
# --y-min, --y-max, --dy) narrow where it may land.
click_text() { # pid phrase [filters...]
  local pid="$1" phrase="$2"; shift 2
  ui click-text "$phrase" --pid "$pid" "$@" >/dev/null \
    || fail "no clickable text \"$phrase\" in window $pid"
}

# Wait for `phrase` to appear on screen in window `pid`, bounded by
# STEP_TIMEOUT.
wait_text() { # pid phrase [filters...]
  local pid="$1" phrase="$2"; shift 2
  ui wait-text "$phrase" --pid "$pid" --timeout "$STEP_TIMEOUT" "$@" >/dev/null \
    || fail "waited ${STEP_TIMEOUT}s for \"$phrase\" on screen in window $pid"
}

# Click `phrase` only once it is actually on screen. OCR can miss a control
# that is present but not yet painted — the pairing sheet's `Code` field just
# after the Pair click is the observed case — so a single-shot click_text is a
# race. Wait for the phrase, click it, and retry up to N times, all within the
# step's own timeout.
CLICK_ATTEMPTS="${NEXUS_CLICK_ATTEMPTS:-3}"
click_text_wait() { # pid phrase [filters...]
  local pid="$1" phrase="$2"; shift 2
  local deadline=$(( $(date +%s) + STEP_TIMEOUT ))
  local attempt left per
  for (( attempt = 1; attempt <= CLICK_ATTEMPTS; attempt++ )); do
    left=$(( deadline - $(date +%s) ))
    [ "$left" -gt 0 ] || break
    # Split what is left across the attempts that remain.
    per=$(( left / (CLICK_ATTEMPTS - attempt + 1) ))
    [ "$per" -ge 1 ] || per=1
    if ui wait-text "$phrase" --pid "$pid" --timeout "$per" "$@" >/dev/null 2>&1 \
       && ui click-text "$phrase" --pid "$pid" "$@" >/dev/null 2>&1; then
      return 0
    fi
    say "  \"$phrase\" not clickable yet (attempt $attempt/$CLICK_ATTEMPTS)"
    sleep 0.5
  done
  fail "no clickable text \"$phrase\" in window $pid after $CLICK_ATTEMPTS attempts"
}

# Wait for a line to appear in a log, bounded by STEP_TIMEOUT.
wait_log() {
  local file="$1" pattern="$2" what="$3"
  local deadline=$(( $(date +%s) + STEP_TIMEOUT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    grep -qE "$pattern" "$file" 2>/dev/null && return 0
    sleep 0.5
  done
  fail "waited ${STEP_TIMEOUT}s for $what (no /$pattern/ in $file)"
}

# --- preflight --------------------------------------------------------------
step "preflight"
for tool in flutter hyprctl jq grim tesseract wtype wl-copy wl-paste \
            setsid nohup python3 sha256sum stat; do
  need "$tool"
done
[ -f "$UI" ] || fail "missing the UI driver seam: $UI"
[ -w /dev/uinput ] || fail "/dev/uinput is not writable — cannot inject clicks"
hyprctl clients -j >/dev/null 2>&1 || fail "no Hyprland session to drive"
ui windows >/dev/null 2>&1 || fail "the UI driver seam ($UI) is not runnable"
say "tools present; UI driver reachable, Hyprland session reachable"

# --- build ------------------------------------------------------------------
if [ "$BUILD" = 1 ]; then
  step "build"
  flutter build linux --debug >"$WORK/build.log" 2>&1 || {
    tail -30 "$WORK/build.log" >&2
    fail "flutter build linux --debug failed"
  }
  say "built $BUNDLE"
fi
[ -x "$BUNDLE" ] || fail "no desktop bundle at $BUNDLE (run without --no-build)"

# --- fixtures (the server's served root is its home dir) --------------------
step "fixtures"
for spec in "${FIXTURES[@]}"; do
  name="${spec%%:*}"; bytes="${spec##*:}"
  src="$HOME_DIR/$name"
  python3 -c 'import sys
open(sys.argv[1], "wb").write(bytes((i * 37 + 11) % 256 for i in range(int(sys.argv[2]))))' \
    "$src" "$bytes"
  # Never let a leftover file make the app rename its save ("name (1).ext").
  rm -f "$DL_DIR/$name"
  say "  $(sha256sum "$src" | awk '{print $1}')  $bytes  $name"
done

# --- first-run state --------------------------------------------------------
# Without onboarded=true the composer stays hidden behind first-run setup and
# there is nothing to type into, so both instances are seeded with a finished
# profile in their own data home.
step "profile"
for data in "$SERVER_DATA" "$REQUESTER_DATA"; do
  mkdir -p "$data/dev.nexus.nexus"
  cat >"$data/dev.nexus.nexus/shared_preferences.json" <<'EOF'
{"flutter.nexus.profile.userName":"Alex","flutter.nexus.profile.assistantName":"Nexus","flutter.nexus.profile.onboarded":true}
EOF
done
say "seeded a finished profile in each instance's own XDG_DATA_HOME"

# --- launch two real instances ---------------------------------------------
step "launch"
# Only when asked: a developer may have their own Nexus open, and the default
# walk must not close it.
if [ "$KILL_ORPHANS" = 1 ]; then
  say "  --kill-orphans: closing every Nexus on the desktop first"
  pkill -x nexus 2>/dev/null || true
  sleep 1
fi
setsid nohup env NEXUS_DATA_DIR="$SERVER_DIR" XDG_DATA_HOME="$SERVER_DATA" \
  "$BUNDLE" >"$WORK/server.log" 2>&1 &
echo "$!" >"$WORK/pids"
setsid nohup env NEXUS_DATA_DIR="$REQUESTER_DIR" XDG_DATA_HOME="$REQUESTER_DATA" \
  "$BUNDLE" >"$WORK/requester.log" 2>&1 &
echo "$!" >>"$WORK/pids"

# Wait for both instances to exist AND to have a window on screen. Matching by
# each one's own data dir means a developer's Nexus, or a stale one, is neither
# counted nor mismatched.
deadline=$(( $(date +%s) + STEP_TIMEOUT ))
SPID=""; RPID=""
while :; do
  for p in $(pgrep -x nexus 2>/dev/null); do
    env=$(tr '\0' '\n' </proc/"$p"/environ 2>/dev/null)
    case "$env" in
      *"NEXUS_DATA_DIR=$SERVER_DIR"*)    SPID="$p" ;;
      *"NEXUS_DATA_DIR=$REQUESTER_DIR"*) RPID="$p" ;;
    esac
  done
  if [ -n "$SPID" ] && [ -n "$RPID" ] \
     && [ -n "$(ui region "$SPID" 2>/dev/null)" ] \
     && [ -n "$(ui region "$RPID" 2>/dev/null)" ]; then
    break
  fi
  [ "$(date +%s)" -lt "$deadline" ] \
    || fail "did not see both Nexus windows (server=${SPID:-none} requester=${RPID:-none})"
  sleep 0.5
done
printf '%s\n%s\n' "$SPID" "$RPID" >>"$WORK/pids"
say "server pid $SPID, requester pid $RPID"

# --- deterministic window placement ----------------------------------------
# Both windows are floated and sized by the compositor, so everything after
# this addresses them by their own origin instead of guessing at the layout.
step "placement"
place() { ui place "$1" "$2" "$3" >/dev/null 2>&1 || true; }
place "$SPID" 8 8
place "$RPID" 900 8
for pid in "$SPID" "$RPID"; do
  g=$(geom "$pid") || fail "window $pid vanished during placement"
  say "  $g  (pid $pid)"
done

# --- the server shows a code ------------------------------------------------
step "server-code"
focus "$SPID"
click_text "$SPID" Devices --x-max 120        # the rail's Devices destination
click_text "$SPID" "Show my code on another device"
click_text "$SPID" "More ways to connect"
click_text "$SPID" "Show my code instead"

# The app's own "Copy code" button is the exact source: read the code it puts
# on the clipboard rather than trusting OCR with a secret.
CODE=""
wl-copy --clear 2>/dev/null || true
sleep 0.3
click_text "$SPID" "Copy code"
sleep 0.5
CODE=$(timeout 5 wl-paste 2>/dev/null | tr -d '\n' | head -c 40)
case "$CODE" in
  [A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]-[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]) ;;
  *) fail "could not read the pairing code from the clipboard (got '${CODE:-empty}')" ;;
esac
say "pairing code $CODE"

# --- the requester enters it ------------------------------------------------
step "pair"
focus "$RPID"
click_text "$RPID" Devices --x-max 120
click_text "$RPID" "Add device"
click_text "$RPID" "More ways to connect"
# Pair with the device discovery already found: that row's Pair button
# prefills the address and port, so the code is the only thing left to type.
click_text "$RPID" Pair --y-min 420
# The field can take a beat to paint after the row's Pair click; wait for it
# rather than clicking at nothing.
click_text_wait "$RPID" Code --y-max 420 --dy 22
sleep 0.4
ui type "$CODE"   || fail "could not type the pairing code"
# Every field in the sheet submits the same form on Enter.
ui key Return     || fail "could not submit the pairing code"

# --- both sides agree the pairing happened ----------------------------------
step "online"
wait_log "$WORK/requester.log" 'pairWith -> ok' "the requester to pair"
wait_log "$WORK/server.log" 'code matched' "the server to accept the pairing"
say "  $(grep -h 'pairWith -> ok' "$WORK/requester.log" | tail -1)"
say "  $(grep -h 'code matched' "$WORK/server.log" | tail -1)"
# The pairing sheet pops itself on success (lib/ui/pair_sheet.dart: `_pair`
# calls Navigator.pop when the result is ok), but the rail sits behind the
# sheet's scrim until the route animation finishes. Wait for the rail to be
# readable instead of racing the dismissal with a single click.
wait_text "$RPID" Devices --x-max 120
wait_text "$RPID" Online
say "  requester shows the server Online"

# --- ask, the way a person asks --------------------------------------------
# The composer is the last row of the Assistant page; the rail's Assistant
# destination brings that page back after the Devices detour.
ask_for() { # name
  local name="$1"
  focus "$RPID"
  click_text "$RPID" Assistant --x-max 120
  sleep 0.6
  click_composer
  sleep 0.5
  ui type "get $name from my pc" || fail "could not type \"get $name from my pc\""
  ui key Return                  || fail "could not send the request"
}

# The composer is the page's last row. Wait for its own placeholder before
# clicking — the page is still settling right after the rail switch, so a
# single click races the transition. If OCR cannot read the dim hint at all,
# the last row of the window is where the field always sits.
click_composer() {
  local x y w h
  if ui wait-text "Ask anything" --pid "$RPID" --y-min 700 --timeout "$STEP_TIMEOUT" >/dev/null 2>&1 \
     && ui click-text "Ask anything" --pid "$RPID" --y-min 700 >/dev/null 2>&1; then
    return 0
  fi
  read -r x y w h <<<"$(geom "$RPID")"
  ui click $(( x + w / 2 )) $(( y + h - 34 )) || fail "could not click the composer"
}

# The pull writes the destination in place (mesh_service.dart opens it with
# FileMode.write and streams chunks into it), so the file exists — partial —
# long before the transfer is done. A fetch is finished when its size has
# reached the fixture's own size; anything else is still in flight.
wait_file() { # name bytes
  local name="$1" bytes="$2"
  local deadline=$(( $(date +%s) + STEP_TIMEOUT ))
  local got=""
  while [ "$(date +%s)" -lt "$deadline" ]; do
    got=$(stat -c %s "$DL_DIR/$name" 2>/dev/null || true)
    [ "$got" = "$bytes" ] && return 0
    sleep 0.5
  done
  fail "$name never finished landing in $DL_DIR (have ${got:-nothing}, want $bytes bytes)"
}

# --- the negative path ------------------------------------------------------
# Same build, launch, pair, and composer; only the fetch differs. The server
# does not have this name, so the app's own words must say so and nothing may
# land. Exits here without touching the happy path's two fetches.
if [ "$NEGATIVE" = 1 ]; then
  grep -q "$NEG_WORDS" lib/core/answers.dart \
    || fail "FileFetchWords.notFound no longer says '$NEG_WORDS'"
  step "fetch $NEG_NAME (negative)"
  ask_for "$NEG_NAME"
  # The reply is the app's own not-found sentence. OCR must read its wording
  # and the requested stem in the assistant's answer.
  wait_text "$RPID" "$NEG_WORDS"
  wait_text "$RPID" "$NEG_STEM"
  say "  requester shows “$NEG_WORDS $NEG_STEM …”"
  step "verify (nothing landed)"
  if [ -e "$DL_DIR/$NEG_NAME" ]; then
    fail "$NEG_NAME should not have landed, but $DL_DIR/$NEG_NAME exists"
  fi
  say "  absent  $DL_DIR/$NEG_NAME (as expected)"
  ui shot "$WORK/99_result.png" --pid "$RPID" \
    || fail "could not take the final screenshot"
  say ""
  say "== result =="
  say "NEGATIVE PASS — the app said it could not find $NEG_NAME and nothing landed in $DL_DIR"
  say "evidence: $WORK (both logs, 99_result.png, wording above)"
  exit 0
fi

step "fetch report.pdf"
ask_for report.pdf
wait_file report.pdf 4096
say "  report.pdf landed"

step "fetch big.bin"
ask_for big.bin
wait_file big.bin 30000000
say "  big.bin landed"

# --- verify -----------------------------------------------------------------
step "verify"
verify_one() {
  local name="$1" bytes="$2"
  local src="$HOME_DIR/$name" dst="$DL_DIR/$name"
  local want got got_bytes
  want=$(sha256sum "$src" | awk '{print $1}')
  [ -f "$dst" ] || { say "  MISSING  $dst"; return 1; }
  got=$(sha256sum "$dst" | awk '{print $1}')
  got_bytes=$(stat -c %s "$dst")
  if [ "$got" = "$want" ] && [ "$got_bytes" = "$bytes" ]; then
    say "  OK  $name  $got_bytes bytes  sha256 $got"
    return 0
  fi
  say "  MISMATCH  $name  want $bytes/$want  got $got_bytes/$got"
  return 1
}

ui shot "$WORK/99_result.png" --pid "$RPID" \
  || fail "could not take the final screenshot"

pass=1
for spec in "${FIXTURES[@]}"; do
  verify_one "${spec%%:*}" "${spec##*:}" || pass=0
done

say ""
say "== result =="
if [ "$pass" = 1 ]; then
  say "PASS — every file landed byte-identical in $DL_DIR"
  say "evidence: $WORK (both logs, 99_result.png, sizes and sha256 above)"
  exit 0
fi
say "FAIL — see $WORK for logs"
exit 1
