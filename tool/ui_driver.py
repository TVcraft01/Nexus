#!/usr/bin/env python3
"""Input + screen-reading seam for tool/gui_walkthrough.sh.

The walkthrough drives the real app through the real compositor. This module
is the *only* place that knows how: window geometry and focus (hyprctl),
screenshots (grim), OCR and text matching (tesseract), the pointer
(/dev/uinput) and the keyboard (wtype). The bash script speaks to it only
through the contract below, so the driving can be read, tested and replaced
apart from the walkthrough's own control flow.

Contract (import, or the same names as CLI subcommands):

    focus_window(pid)                      bring a window to the front
    region_for(pid) -> "X,Y WxH"           a window's own rectangle, or None
    window_state(pid) -> dict | None       workspace/floating/at/size/focused
    switch_workspace(name)                 show a workspace on this monitor
    ensure_window(pid, x, y, *, workspace) float + size a window at a corner,
                                           re-read and retried until the
                                           compositor agrees it took
    click(x, y)                            move the pointer and left-click
    click_text(text, *, pid/region, ...)   click where `text` is on screen
    wait_text(text, timeout, *, pid, ..., reads)  poll until `text` is on screen
                                                 stable for `reads` polls
    type_text(s)                           type a string into the focused field
    press_key(name)                        press one key ("Return", …)
    screenshot(path, region=None)          save a PNG of a region (all screen if none)

Everything else is plumbing behind those — compositor, capture/OCR, pointer,
keyboard and the thin matching policy — kept in their own sections so each can
be replaced without touching the others.

Screen coordinates are region-relative: pass a region and the module adds its
origin back before clicking, so callers never mix absolute and window-local
coordinates. A read addressed by pid first makes the workspace the window lives
on the one its own monitor is *showing* (not the globally focused monitor — on
a multi-output box those differ), because grim crops from the compositor's
composite of what is on screen: a window whose workspace its monitor is not
showing is not in that composite, so the crop would read something else. The
latest frame of any read goes to
$NEXUS_UI_WORK/screen.png (defaults to a temp dir); it is working state, not
evidence.
"""
from __future__ import annotations

import contextlib
import ctypes
import fcntl
import json
import os
import re
import struct
import subprocess
import sys
import tempfile
import time

WORK = os.environ.get("NEXUS_UI_WORK") or os.path.join(
    tempfile.gettempdir(), "nexus_ui"
)
SCREEN = os.path.join(WORK, "screen.png")
# Optional evidence log: every time a session's window had to be re-placed,
# re-focused or had its workspace re-shown, record it here (set NEXUS_UI_LOG).
LOG = os.environ.get("NEXUS_UI_LOG") or ""
NEXUS_WINDOW_CLASS = "dev.nexus.nexus"


def _note(message: str) -> None:
    """Append a one-line note to the evidence log, when one is configured."""
    if not LOG:
        return
    try:
        with open(LOG, "a") as fh:
            fh.write(f"{time.strftime('%H:%M:%S')} {message}\n")
    except OSError:
        pass


# --------------------------------------------------------------------------
# compositor — window geometry, focus, placement
# --------------------------------------------------------------------------
def _clients() -> list[dict]:
    out = subprocess.run(
        ["hyprctl", "clients", "-j"], capture_output=True, text=True
    ).stdout
    try:
        parsed = json.loads(out)
    except json.JSONDecodeError:
        return []
    return parsed if isinstance(parsed, list) else []


def region_for(pid: int) -> str | None:
    """A window's own "X,Y WxH", or None when it is not on screen."""
    for client in _clients():
        if client.get("pid") == int(pid):
            x, y = client["at"]
            w, h = client["size"]
            return f"{x},{y} {w}x{h}"
    return None


def focus_window(pid: int) -> None:
    subprocess.run(
        ["hyprctl", "dispatch", f'hl.dsp.focus({{window="pid:{pid}"}})'],
        capture_output=True,
    )
    time.sleep(0.4)


def _client_for(pid: int) -> dict | None:
    for client in _clients():
        if client.get("pid") == int(pid):
            return client
    return None


def window_state(pid: int) -> dict | None:
    """The placement-relevant state of a window, or None if it is gone.

    Read straight from the compositor — `workspace` by name, the `floating`
    flag, and the `at`/`size` rectangle the click math later relies on — plus
    whether it is the focused window (focusHistoryID 0), so a caller can prove
    what it asked for actually took instead of assuming the dispatch landed.
    """
    client = _client_for(pid)
    if client is None:
        return None
    ws = client.get("workspace") or {}
    at = client.get("at") or [None, None]
    size = client.get("size") or [None, None]
    return {
        "workspace": str(ws.get("name", ws.get("id", ""))),
        "monitor": client.get("monitor"),
        "floating": bool(client.get("floating")),
        "at": (at[0], at[1]),
        "size": (size[0], size[1]),
        "fullscreen": int(client.get("fullscreen") or 0),
        "focused": client.get("focusHistoryID") == 0,
    }


def active_workspace() -> str:
    """The name of the workspace currently shown on this monitor."""
    out = subprocess.run(
        ["hyprctl", "activeworkspace", "-j"], capture_output=True, text=True
    ).stdout
    try:
        return str(json.loads(out).get("name", ""))
    except json.JSONDecodeError:
        return ""


def monitor_active_workspace(monitor: int | None) -> str:
    """The workspace shown on monitor `monitor` (by id), or "" if unknown.

    A window's visibility depends on the workspace *its own monitor* is
    showing, not on the globally focused monitor: on a two-output box the
    focused monitor can sit on workspace 1 while the harness's window is fully
    visible on workspace 97 of the other output. Comparing against
    `active_workspace()` there is always wrong and makes every read look like it
    needs a switch.
    """
    if monitor is None:
        return ""
    out = subprocess.run(
        ["hyprctl", "monitors", "-j"], capture_output=True, text=True
    ).stdout
    try:
        for m in json.loads(out):
            if m.get("id") == monitor:
                return str((m.get("activeWorkspace") or {}).get("name", ""))
    except json.JSONDecodeError:
        return ""
    return ""


def switch_workspace(workspace: str) -> None:
    """Show `workspace` on this monitor (creating it if it does not exist)."""
    subprocess.run(
        ["hyprctl", "dispatch", f'hl.dsp.focus({{workspace="{workspace}"}})'],
        capture_output=True,
    )
    time.sleep(0.3)


def move_to_workspace(pid: int, workspace: str) -> None:
    """Send a window to a workspace without following it there."""
    focus_window(pid)
    subprocess.run(
        ["hyprctl", "dispatch", f'hl.dsp.window.move({{workspace="{workspace}"}})'],
        capture_output=True,
    )
    time.sleep(0.4)


def _dispatch(cmd: str) -> None:
    subprocess.run(["hyprctl", "dispatch", cmd], capture_output=True)


def _float_rect(pid: int, x: int, y: int, width: int, height: int) -> None:
    """Float the focused window and drive it to the requested rectangle.

    Two compositor traps sit here. First, `hl.dsp.window.float()` is a *toggle*,
    not a setter: calling it on an already-floating window un-floats it, and the
    resize/move that follow then apply to a tiled window. So read the flag and
    toggle only when the window is actually tiled. Second, a window that is
    fullscreen ignores resize and move outright — and a freshly launched window
    can *inherit* fullscreen from whatever was on the workspace it opened on
    (the observed 0,0/1920x1080 placement after an occluder was fullscreen on
    the default workspace), so clear fullscreen first.
    """
    focus_window(pid)
    state = window_state(pid)
    if state is None:
        return
    if state["fullscreen"]:
        _note(f"unfullscreen pid={pid} state={state['fullscreen']}")
        _dispatch("hl.dsp.window.fullscreen()")  # toggle: fullscreen -> normal
        time.sleep(0.6)
        state = window_state(pid) or state
    if not state["floating"]:
        _dispatch("hl.dsp.window.float()")
        time.sleep(0.5)
    _dispatch(f"hl.dsp.window.resize({{x={width}, y={height}}})")
    time.sleep(0.4)
    _dispatch(f"hl.dsp.window.move({{x={x}, y={y}}})")
    time.sleep(0.6)


def ensure_window(
    pid: int,
    x: int,
    y: int,
    width: int = 880,
    height: int = 1000,
    workspace: str | None = None,
    attempts: int = 5,
) -> dict | None:
    """Place a window and keep re-reading the compositor until it agrees.

    A dispatch that returns "ok" is not proof the window moved — the move can
    be dropped while the window is still settling, which leaves the click math
    aimed at a rectangle the window no longer occupies. So each attempt reads
    the state back and only retries what is still wrong: the workspace, the
    floating flag, and the exact `at`/`size`. Returns the settled state, None
    when the window is gone, or the last (unsettled) state if retries run out.
    """
    state = None
    for _ in range(max(1, attempts)):
        state = window_state(pid)
        if state is None:
            return None
        if workspace is not None and state["workspace"] != str(workspace):
            _note(f"place pid={pid} workspace {state['workspace']}->{workspace}")
            move_to_workspace(pid, workspace)
        if (
            state["fullscreen"]
            or not state["floating"]
            or state["at"] != (x, y)
            or state["size"] != (width, height)
        ):
            _note(
                f"place pid={pid} rect {state['at']}/{state['size']}"
                f"->{x},{y}/{width}x{height} floating={int(state['floating'])}"
            )
            _float_rect(pid, x, y, width, height)
        state = window_state(pid)
        if state is None:
            return None
        settled = (
            not state["fullscreen"]
            and state["floating"]
            and state["at"] == (x, y)
            and state["size"] == (width, height)
            and (workspace is None or state["workspace"] == str(workspace))
        )
        if settled:
            # Make the dedicated workspace the visible one on the window's own
            # monitor, and the target the focused window, so the next read/click
            # lands on it.
            if workspace is not None:
                shown = monitor_active_workspace(state["monitor"]) \
                    if state["monitor"] is not None else active_workspace()
                if shown != str(workspace):
                    _note(f"show pid={pid} workspace ->{workspace}")
                    switch_workspace(workspace)
            if not state["focused"]:
                _note(f"refocus pid={pid}")
                focus_window(pid)
                state = window_state(pid) or state
            return state
        time.sleep(0.3)
    return state


def _ensure_visible(pid: int | None) -> None:
    """Show a window's workspace before we screenshot its region, and confirm it.

    grim captures whatever workspace is on screen, not a window's pixels, so
    reading a region while the desktop is showing another workspace reads the
    wrong window entirely (the observed server-code miss: OCR saw the
    developer's editor, not the Nexus window). And on a single monitor a switch
    is not proof the next capture is of the right workspace: an app left on the
    desktop can take the view back within the same second — the host app does
    on this box, many times a minute — so a one-shot switch can be undone
    before grim fires. Re-assert until `active_workspace()` agrees, then let the
    caller capture immediately; thefts that happen between steps are counted in
    repairs.log rather than silently tolerated.
    """
    if pid is None:
        return
    state = window_state(pid)
    if state is None:
        return
    ws, mon = state["workspace"], state["monitor"]
    if not ws:
        return

    def on_screen() -> bool:
        if mon is not None:
            return monitor_active_workspace(mon) == ws
        return active_workspace() == ws

    if on_screen():
        return
    _note(f"show pid={pid} workspace ->{ws}")
    for _ in range(6):
        switch_workspace(ws)
        if on_screen():
            return
    _note(f"show pid={pid} workspace ->{ws} did-not-hold")


def _state_line(state: dict) -> str:
    at = f'{state["at"][0]},{state["at"][1]}'
    size = f'{state["size"][0]}x{state["size"][1]}'
    return (
        f'workspace={state["workspace"]} floating={int(state["floating"])} '
        f'fullscreen={state["fullscreen"]} at={at} size={size} '
        f'focused={int(state["focused"])}'
    )


def nexus_window_count() -> int:
    return sum(1 for c in _clients() if c.get("class") == NEXUS_WINDOW_CLASS)


# --------------------------------------------------------------------------
# capture + OCR — screenshots and the words on them
# --------------------------------------------------------------------------
def screenshot(path: str, region: str | None = None) -> str:
    """Save a PNG of `region`, or of the whole screen when none is given."""
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    cmd = ["grim"]
    if region:
        cmd += ["-g", region]
    cmd.append(path)
    subprocess.run(cmd, check=True, capture_output=True)
    return path


def _words(path: str) -> list[dict]:
    """OCR words as {text, x0, y0, x1, y1, line} in region coordinates.

    Sparse-text mode on purpose: the default page segmentation misses this
    UI's low-contrast text buttons entirely ("Show my code on another
    device" is simply absent from a default run), while sparse mode reads
    them and keeps the rail labels readable too.
    """
    out = subprocess.run(
        ["tesseract", path, "stdout", "--psm", "11", "tsv"],
        capture_output=True,
        text=True,
    ).stdout
    words = []
    for row in out.splitlines()[1:]:
        cols = row.split("\t")
        if len(cols) != 12:
            continue
        try:
            conf = float(cols[10])
            left, top, w, h = int(cols[6]), int(cols[7]), int(cols[8]), int(cols[9])
        except ValueError:
            continue
        text = cols[11].strip()
        if conf < 0 or not text:
            continue
        words.append(
            {
                "text": text,
                "x0": left,
                "y0": top,
                "x1": left + w,
                "y1": top + h,
                "line": (cols[2], cols[3], cols[4]),
            }
        )
    return words


def _norm(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", text.lower()).strip()


def _word_score(got: str, want: str) -> int:
    """How well one OCR word matches one wanted word.

    tesseract clips glyphs on this UI ("Pair" -> "Pai", "Pairing" ->
    "Paifing"), so an exact match is best, a shared prefix of at least three
    characters is acceptable, and anything else is no match at all.
    """
    if got == want:
        return 3
    short, long_ = sorted([_norm(got), _norm(want)], key=len)
    if len(short) >= 3 and long_.startswith(short):
        return 2
    return 0


def _runs(words: list[dict], phrase: str) -> list[dict]:
    """Every place `phrase` appears as consecutive words on one OCR line.

    Matching per word and requiring them to be adjacent on the same line is
    what keeps a rail label apart from a paragraph that happens to mention
    the same word — the failure mode of matching whole lines.
    """
    want = _norm(phrase).split()
    if not want:
        return []
    by_line: dict[tuple, list[dict]] = {}
    for w in words:
        by_line.setdefault(w["line"], []).append(w)
    runs = []
    for line_words in by_line.values():
        line_words.sort(key=lambda w: w["x0"])
        for i in range(len(line_words) - len(want) + 1):
            scores = [
                _word_score(line_words[i + k]["text"], want[k])
                for k in range(len(want))
            ]
            if all(s > 0 for s in scores):
                run = line_words[i : i + len(want)]
                runs.append(
                    {
                        "score": min(scores),
                        "x0": min(w["x0"] for w in run),
                        "y0": min(w["y0"] for w in run),
                        "x1": max(w["x1"] for w in run),
                        "y1": max(w["y1"] for w in run),
                    }
                )
    return runs


def _match(words, phrase, x_max, y_min, y_max):
    runs = []
    for r in _runs(words, phrase):
        if x_max is not None and r["x0"] > x_max:
            continue
        if y_min is not None and r["y0"] < y_min:
            continue
        if y_max is not None and r["y1"] > y_max:
            continue
        runs.append(r)
    if not runs:
        return None
    best = max(r["score"] for r in runs)
    top = [r for r in runs if r["score"] == best]
    # Topmost of the equally good ones: headers sit above their content.
    return sorted(top, key=lambda r: (r["y0"], r["x0"]))[0]


# --------------------------------------------------------------------------
# pointer — /dev/uinput, the only mouse-injection device this box has
# --------------------------------------------------------------------------
UINPUT = "/dev/uinput"
EV_SYN, EV_KEY, EV_REL = 0x00, 0x01, 0x02
BTN_LEFT = 0x110
REL_X, REL_Y, REL_WHEEL = 0x00, 0x01, 0x08
UI_SET_EVBIT = 0x40045564
UI_SET_KEYBIT = 0x40045565
UI_SET_RELBIT = 0x40045566
UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY = 0x5502
UI_DEV_SETUP = 0x405C5503


class _InputId(ctypes.Structure):
    _fields_ = [
        ("bustype", ctypes.c_uint16),
        ("vendor", ctypes.c_uint16),
        ("product", ctypes.c_uint16),
        ("version", ctypes.c_uint16),
    ]


class _UinputSetup(ctypes.Structure):
    _fields_ = [
        ("id", _InputId),
        ("name", ctypes.c_char * 80),
        ("ff_effect_max", ctypes.c_uint32),
    ]


def _emit(fd, etype, code, value):
    os.write(fd, struct.pack("llHHi", 0, 0, etype, code, value))


def _open_mouse():
    fd = os.open(UINPUT, os.O_RDWR | os.O_NONBLOCK)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_REL)
    fcntl.ioctl(fd, UI_SET_KEYBIT, BTN_LEFT)
    for rel in (REL_X, REL_Y, REL_WHEEL):
        fcntl.ioctl(fd, UI_SET_RELBIT, rel)
    setup = _UinputSetup(
        id=_InputId(0x03, 0x1, 0x1, 1),
        name=b"nexus-gui-walkthrough",
        ff_effect_max=0,
    )
    buf = ctypes.create_string_buffer(ctypes.sizeof(_UinputSetup))
    ctypes.memmove(buf, ctypes.byref(setup), ctypes.sizeof(_UinputSetup))
    fcntl.ioctl(fd, UI_DEV_SETUP, buf)
    fcntl.ioctl(fd, UI_DEV_CREATE)
    time.sleep(1.5)
    return fd


def _close_mouse(fd):
    time.sleep(0.3)
    fcntl.ioctl(fd, UI_DEV_DESTROY)
    os.close(fd)


@contextlib.contextmanager
def _pointer():
    fd = _open_mouse()
    try:
        yield fd
    finally:
        _close_mouse(fd)


def click(x: int, y: int) -> None:
    """Move the pointer to absolute (x, y) and click the left button."""
    subprocess.run(
        ["hyprctl", "dispatch", f"hl.dsp.cursor.move({{x={int(x)}, y={int(y)}}})"],
        capture_output=True,
    )
    time.sleep(0.25)
    with _pointer() as fd:
        _emit(fd, EV_KEY, BTN_LEFT, 1)
        _emit(fd, EV_SYN, 0, 0)
        time.sleep(0.12)
        _emit(fd, EV_KEY, BTN_LEFT, 0)
        _emit(fd, EV_SYN, 0, 0)
        time.sleep(0.5)


# --------------------------------------------------------------------------
# keyboard — wtype
# --------------------------------------------------------------------------
def type_text(s: str) -> None:
    subprocess.run(["wtype", "-d", "12", "--", s], check=True)


def press_key(name: str) -> None:
    subprocess.run(["wtype", "-k", name], check=True)


# --------------------------------------------------------------------------
# the contract: click / wait for the text I mean
# --------------------------------------------------------------------------
class WindowGone(RuntimeError):
    pass


def _origin(region: str) -> tuple[int, int]:
    at, _ = region.split(" ", 1)
    x, y = at.split(",")
    return int(x), int(y)


def _resolve_region(pid: int | None, region: str | None) -> str:
    if region:
        return region
    if pid is None:
        raise ValueError("need a pid or a region")
    resolved = region_for(int(pid))
    if resolved is None:
        raise WindowGone(f"window {pid} is not on screen (no geometry)")
    return resolved


def _find(region: str, text: str, x_max, y_min, y_max) -> dict | None:
    screenshot(SCREEN, region)
    return _match(_words(SCREEN), text, x_max, y_min, y_max)


def click_text(
    text: str,
    *,
    pid: int | None = None,
    region: str | None = None,
    x_max: int | None = None,
    y_min: int | None = None,
    y_max: int | None = None,
    dy: int = 0,
) -> bool:
    """Click where `text` is; False when it is not on screen."""
    _ensure_visible(pid)
    resolved = _resolve_region(pid, region)
    hit = _find(resolved, text, x_max, y_min, y_max)
    if hit is None:
        return False
    # The read above took a moment (screenshot + OCR); if anything switched the
    # visible workspace in that gap, the click would land on it, not on this
    # window. Re-show the window's workspace immediately before clicking.
    _ensure_visible(pid)
    x = (hit["x0"] + hit["x1"]) // 2
    # A floating field label sits on the field's top border; a small downward
    # nudge lands inside the input itself.
    y = (hit["y0"] + hit["y1"]) // 2 + dy
    ox, oy = _origin(resolved)
    click(ox + x, oy + y)
    return True


def wait_text(
    text: str,
    timeout: float,
    *,
    pid: int | None = None,
    region: str | None = None,
    x_max: int | None = None,
    y_min: int | None = None,
    y_max: int | None = None,
    reads: int = 1,
) -> bool:
    """Poll until `text` is on screen; False after `timeout` seconds.

    The region is re-resolved from `pid` on every poll so a window that moves
    mid-wait is still read at its current origin.

    `reads` > 1 requires that many consecutive polls to see the text before it
    is reported present. A control can be captured mid-paint — visible in one
    frame, re-rendered in the next — so a single hit is no proof it is ready to
    receive a click. Any poll that misses resets the streak, so the hit must be
    stable across the full sequence.
    """
    deadline = time.time() + timeout
    streak = 0
    while True:
        _ensure_visible(pid)
        resolved = _resolve_region(pid, region)
        if _find(resolved, text, x_max, y_min, y_max) is not None:
            streak += 1
            if streak >= reads:
                return True
        else:
            streak = 0
        if time.time() >= deadline:
            return False
        time.sleep(1)


# --------------------------------------------------------------------------
# CLI — the same contract, for the bash caller
# --------------------------------------------------------------------------
def _flags(rest: list[str]) -> tuple[dict, list[str]]:
    """Split --flags from the phrase words that follow them."""
    opts: dict[str, object] = {}
    phrase: list[str] = []
    i = 0
    while i < len(rest):
        flag = rest[i]
        if flag in (
            "--pid", "--x-max", "--y-min", "--y-max", "--dy", "--reads",
            "--width", "--height", "--attempts",
        ):
            opts[flag] = int(rest[i + 1])
            i += 2
            continue
        if flag in ("--region", "--timeout", "--workspace"):
            opts[flag] = rest[i + 1]
            i += 2
            continue
        phrase.append(flag)
        i += 1
    return opts, phrase


def _text_command(cmd: str, rest: list[str]) -> int:
    opts, phrase = _flags(rest)
    kw = {
        "pid": opts.get("--pid"),
        "region": opts.get("--region"),
        "x_max": opts.get("--x-max"),
        "y_min": opts.get("--y-min"),
        "y_max": opts.get("--y-max"),
    }
    text = " ".join(phrase)
    if cmd == "click-text":
        if click_text(text, dy=int(opts.get("--dy", 0)), **kw):
            return 0
        print(f"NOT-FOUND {phrase}", file=sys.stderr)
        return 3
    timeout = float(opts.get("--timeout", 90))
    if wait_text(text, timeout, reads=int(opts.get("--reads", 1)), **kw):
        return 0
    print(f"NOT-FOUND {phrase}", file=sys.stderr)
    return 3


def main(argv: list[str]) -> int:
    os.makedirs(WORK, exist_ok=True)
    if not argv:
        print(__doc__, file=sys.stderr)
        return 2
    cmd, rest = argv[0], argv[1:]
    try:
        if cmd == "focus":
            focus_window(int(rest[0]))
            return 0
        if cmd in ("place", "ensure"):
            opts, _ = _flags(rest[3:])
            state = ensure_window(
                int(rest[0]), int(rest[1]), int(rest[2]),
                width=int(opts.get("--width", 880)),
                height=int(opts.get("--height", 1000)),
                workspace=opts.get("--workspace"),
                attempts=int(opts.get("--attempts", 5)),
            )
            if state is None:
                print(f"window {rest[0]} is gone", file=sys.stderr)
                return 3
            print(_state_line(state))
            settled = (
                state["floating"]
                and state["at"] == (int(rest[1]), int(rest[2]))
                and state["size"]
                == (int(opts.get("--width", 880)), int(opts.get("--height", 1000)))
                and (opts.get("--workspace") is None
                     or state["workspace"] == str(opts.get("--workspace")))
            )
            return 0 if settled else 4
        if cmd == "state":
            state = window_state(int(rest[0]))
            if state is None:
                return 3
            print(_state_line(state))
            return 0
        if cmd == "workspace":
            print(active_workspace())
            return 0
        if cmd == "switch-workspace":
            switch_workspace(rest[0])
            return 0
        if cmd == "region":
            r = region_for(int(rest[0]))
            if r is None:
                return 3
            print(r)
            return 0
        if cmd == "windows":
            print(nexus_window_count())
            return 0
        if cmd == "click":
            click(int(rest[0]), int(rest[1]))
            return 0
        if cmd == "type":
            enter = "--enter" in rest
            type_text(" ".join(a for a in rest if a != "--enter"))
            if enter:
                press_key("Return")
            return 0
        if cmd == "key":
            press_key(rest[0])
            return 0
        if cmd == "shot":
            opts, _ = _flags(rest[1:])
            pid, region = opts.get("--pid"), opts.get("--region")
            # A window given: show its workspace first, so the frame is of it and
            # not of whatever else the desktop happens to be showing.
            _ensure_visible(pid)
            # No window given: the whole screen, the failure-diagnostic frame.
            resolved = _resolve_region(pid, region) if (pid or region) else None
            screenshot(rest[0], resolved)
            return 0
        if cmd in ("click-text", "wait-text"):
            return _text_command(cmd, rest)
    except (WindowGone, ValueError, IndexError) as e:
        print(str(e), file=sys.stderr)
        return 2
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
