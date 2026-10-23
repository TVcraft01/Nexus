#!/usr/bin/env python3
"""Type one phrase into Nexus on the phone and read the thread back.

Not evidence by itself — a working state file for the Core-15 check — but the
screenshots it leaves in tmp_device/ are. Needs the phone on adb:
    python3 tmp_device/phone_cmd.py "text 5551234"
"""
import re
import subprocess
import sys
import time

DEV = "R5CX73XFGKW"


def sh(*args, timeout=90):
    return subprocess.run(
        ["adb", "-s", DEV, *args], capture_output=True, text=True, timeout=timeout
    )


def nodes():
    sh("shell", "uiautomator", "dump", "/sdcard/window.xml")
    xml = sh("shell", "cat", "/sdcard/window.xml").stdout
    out = []
    for m in re.finditer(r"<node\b[^>]*>", xml):
        tag = m.group(0)

        def g(key):
            mm = re.search(key + r'="([^"]*)"', tag)
            return mm.group(1) if mm else ""

        bounds = [int(n) for n in re.findall(r"\d+", g("bounds"))]
        out.append(
            {
                "class": g("class"),
                "text": g("text"),
                "desc": g("content-desc"),
                "bounds": bounds,
            }
        )
    return out


def field():
    for n in nodes():
        if n["class"].endswith("EditText") and len(n["bounds"]) == 4:
            return n
    return None


def tap(node):
    x = (node["bounds"][0] + node["bounds"][2]) // 2
    y = (node["bounds"][1] + node["bounds"][3]) // 2
    sh("shell", "input", "tap", str(x), str(y))


def send(text):
    box = field()
    if box is None:
        raise SystemExit("no composer field on screen")
    tap(box)
    time.sleep(0.6)
    sh("shell", "input", "keyevent", "KEYCODE_MOVE_END")
    sh("shell", "input", "text", text.replace(" ", "%s"))
    time.sleep(0.3)
    # The composer's send button, not Enter: the field is multi-line, so Enter
    # is a newline and the phrase would only sit in the box.
    for n in nodes():
        if n["desc"] == "Send":
            tap(n)
            return
    sh("shell", "input", "keyevent", "KEYCODE_ENTER")


def screen_lines():
    return [
        n["desc"] or n["text"]
        for n in nodes()
        if (n["desc"] or n["text"]) and len(n["desc"] or n["text"]) > 1
    ]


def focus():
    raw = sh("shell", "dumpsys", "window", "displays").stdout
    m = re.search(r"mCurrentFocus=([^\n]+)", raw)
    return m.group(1).strip() if m else ""


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--read":
        print("FOCUS:", focus())
        for line in screen_lines():
            print(" ", line)
        raise SystemExit(0)
    send(" ".join(sys.argv[1:]))
    time.sleep(3)
    print("FOCUS:", focus())
    for line in screen_lines():
        print(" ", line)
