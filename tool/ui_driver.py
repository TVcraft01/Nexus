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
    place_window(pid, x, y)                float + size a window at a corner
    click(x, y)                            move the pointer and left-click
    click_text(text, *, pid/region, ...)   click where `text` is on screen
    wait_text(text, timeout, *, pid, ...)  poll until `text` is on screen
    type_text(s)                           type a string into the focused field
    press_key(name)                        press one key ("Return", …)
    screenshot(path, region=None)          save a PNG of a region (all screen if none)

Everything else is plumbing behind those — compositor, capture/OCR, pointer,
keyboard and the thin matching policy — kept in their own sections so each can
be replaced without touching the others.

Screen coordinates are region-relative: pass a region and the module adds its
origin back before clicking, so callers never mix absolute and window-local
coordinates. The latest frame of any read goes to $NEXUS_UI_WORK/screen.png
(defaults to a temp dir); it is working state, not evidence.
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
NEXUS_WINDOW_CLASS = "dev.nexus.nexus"


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


def place_window(pid: int, x: int, y: int, width: int = 880, height: int = 1000) -> None:
    """Float a window and give it a known rectangle, so everything after this
    addresses it by its own origin instead of guessing at the layout."""
    focus_window(pid)
    subprocess.run(
        ["hyprctl", "dispatch", "hl.dsp.window.float()"], capture_output=True
    )
    time.sleep(0.5)
    subprocess.run(
        ["hyprctl", "dispatch", f"hl.dsp.window.resize({{x={width}, y={height}}})"],
        capture_output=True,
    )
    time.sleep(0.4)
    subprocess.run(
        ["hyprctl", "dispatch", f"hl.dsp.window.move({{x={x}, y={y}}})"],
        capture_output=True,
    )
    time.sleep(0.6)


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
    resolved = _resolve_region(pid, region)
    hit = _find(resolved, text, x_max, y_min, y_max)
    if hit is None:
        return False
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
) -> bool:
    """Poll until `text` is on screen; False after `timeout` seconds.

    The region is re-resolved from `pid` on every poll so a window that moves
    mid-wait is still read at its current origin.
    """
    deadline = time.time() + timeout
    while True:
        resolved = _resolve_region(pid, region)
        if _find(resolved, text, x_max, y_min, y_max) is not None:
            return True
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
        if flag in ("--pid", "--x-max", "--y-min", "--y-max", "--dy"):
            opts[flag] = int(rest[i + 1])
            i += 2
            continue
        if flag in ("--region", "--timeout"):
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
    if wait_text(text, timeout, **kw):
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
        if cmd == "place":
            place_window(int(rest[0]), int(rest[1]), int(rest[2]))
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
