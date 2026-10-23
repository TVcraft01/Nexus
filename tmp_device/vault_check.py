#!/usr/bin/env python3
"""Tap and read Nexus on the phone by label, for the vault check.

Not evidence by itself: this is the working seam the screenshots in
tmp_device/ are taken through. Usage:

    python3 tmp_device/vault_check.py read
    python3 tmp_device/vault_check.py tap "Web search"
    python3 tmp_device/vault_check.py shot vault
    python3 tmp_device/vault_check.py type "TVCraft"
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


def tap(node):
    x = (node["bounds"][0] + node["bounds"][2]) // 2
    y = (node["bounds"][1] + node["bounds"][3]) // 2
    sh("shell", "input", "tap", str(x), str(y))


def find(label, exact=True):
    for n in nodes():
        value = n["desc"] or n["text"]
        if not value:
            continue
        if (value == label) if exact else (label.lower() in value.lower()):
            return n
    return None


def shot(name):
    raw = subprocess.run(
        ["adb", "-s", DEV, "exec-out", "screencap", "-p"],
        capture_output=True,
        timeout=120,
    ).stdout
    path = f"tmp_device/{name}.png"
    with open(path, "wb") as fh:
        fh.write(raw)
    print(path)


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else "read"
    if command == "read":
        for n in nodes():
            value = n["desc"] or n["text"]
            if value:
                print(f"{n['bounds']}  {value}")
    elif command == "tap":
        node = find(sys.argv[2], exact=len(sys.argv) < 4)
        if node is None:
            raise SystemExit(f"not on screen: {sys.argv[2]}")
        tap(node)
        time.sleep(0.8)
    elif command == "shot":
        shot(sys.argv[2])
    elif command == "type":
        field = next(
            (n for n in nodes() if n["class"].endswith("EditText")), None
        )
        if field is None:
            raise SystemExit("no text field on screen")
        tap(field)
        time.sleep(0.5)
        sh("shell", "input", "text", sys.argv[2].replace(" ", "%s"))
        time.sleep(0.4)
